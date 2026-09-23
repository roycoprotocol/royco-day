// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/accountant/IRoycoDayAccountant.sol";
import { IRoycoDayFixedRateAccountant } from "../../../src/interfaces/accountant/IRoycoDayFixedRateAccountant.sol";
import { SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FixedRateAccountantFuzzTestBase } from "../../utils/FixedRateAccountantFuzzTestBase.sol";

/**
 * @title TestFuzz_FixedAPY_FixedRateAccountant
 * @notice Fuzz properties for the headline fixed-APY guarantee: over ANY partition of a horizon into
 *         settlement windows, the committed senior effective NAV walks the closed-form iterate
 *         stEff_i = stEff_{i-1} + floor(stEff_{i-1} x rate x len_i / WAD) - linear within each window on the
 *         window-start NAV, compounding exactly at settlement cadence - independent of how each window's
 *         coupon is funded (gain, junior fronting, or a covered loss) and of any flat syncs interleaved
 *         inside the windows. The companion property quantifies the forgiveness rule: an underfunded window
 *         pays exactly what the gain and the buffer can fund, the shortfall never carries into the next
 *         window's demand, and the realized senior path can never exceed the fully funded compounded path
 * @dev The LPT YDM rate is pinned to zero throughout, so no liquidity premium folds into the senior NAV and
 *      the senior path is the pure coupon walk. Gains are sized from the committed impermanent loss so the
 *      repayment step never eats into a window's intended coupon funding: input construction reads state,
 *      but every asserted expectation is the independent closed-form iterate
 */
contract TestFuzz_FixedAPY_FixedRateAccountant is FixedRateAccountantFuzzTestBase {
    /**
     * Scenario: a market lives through 2 to 8 settlement windows of random lengths, each window peppered with
     * up to 3 flat syncs (which must accrue silently: no coupon, no restamp, no NAV movement) and closed by a
     * settling sync in one of four funding regimes - a generous gain (coupon plus excess), an exact-coupon
     * gain, a short gain with the junior buffer fronting the remainder, or a covered loss with the whole
     * coupon fronted. After every settlement the committed senior effective NAV must sit exactly on the
     * closed-form iterate, the junior NAV must be the exact conservation complement, and the coupon clock
     * must hold the settling sync's timestamp. A senior tranche that earns anything but the fixed rate -
     * repricing mid-window flows, double-charging across flat syncs, or carrying shortfalls - breaks the
     * iterate at the first divergent window.
     *
     * Domain: junior fronting and losses are budgeted to a quarter of the seeded buffer, so the coverage
     * utilization stays under the 1.1e18 liquidation threshold and the buffer is never wiped: the funding
     * regime, never a forced wind-down, decides each window's outcome. Windows longer than the 7-day term
     * can expire an in-flight lock and erase fronted-coupon IL, which moves the junior ledger but can never
     * move the senior iterate, the conservation complement, or the clock.
     */
    function testFuzz_FixedAPY_RandomSettlementCadenceCompoundsExactly(
        uint256 _stEff0,
        uint256 _jtEff0,
        uint256 _rate,
        uint256 _windows,
        uint256[8] memory _lens,
        uint256[8] memory _flats,
        uint256[8] memory _regimes,
        uint256[8] memory _extras
    )
        public
    {
        _stEff0 = bound(_stEff0, 1e18, 1e27); // a live senior tranche across nine orders of magnitude
        _jtEff0 = bound(_jtEff0, _stEff0 / 5, _stEff0); // 20% to 100% junior buffer, ample against the drain budget below
        _rate = bound(_rate, 0, 5e9); // zero-coupon through five times the default fixed rate
        uint256 windows = bound(_windows, 2, 8); // at least two windows so compounding is observable

        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _defaultParams();
        p.stFixedRatePerSecondWAD = uint64(_rate);
        _deploy(p);
        // Zero LPT yield share: the excess distribution never touches the senior NAV, so the walk is pure coupon
        lptYDM.setRates(0);
        _seedSymmetric(_stEff0, _jtEff0, 0);
        // Initialize the accrual clocks in the deploy block, the production genesis pattern
        kernel.doPreOp(toNAVUnits(_stEff0 + _jtEff0));

        // The independent closed-form iterate and the junior drain budget (fronting plus losses) that keeps the
        // run clear of the liquidation threshold: stEff grows at most (1 + 5e9 x 60d / 1e18)^8 = 1.228x while
        // the buffer keeps at least 3/4 of its seed >= 0.15x stEff0, so the coverage utilization stays under
        // ceil((1.228 + 1) / 0.15 x 0.1e18) < 1.1e18 for every seeded shape
        uint256 modelStEff = _stEff0;
        uint256 drainBudget = _jtEff0 / 4;
        uint256 drained;

        for (uint256 i = 0; i < windows; ++i) {
            uint256 len = bound(_lens[i], 2, 60 days);
            uint256 windowStart = vm.getBlockTimestamp();

            // Flat syncs inside the window: silent accrual, no coupon, no restamp, so they must not change
            // the settlement below no matter how many land or where
            uint256 flats = bound(_flats[i], 0, 3);
            uint256 committedCollateral = toUint256(accountant.getState().lastCollateralNAV);
            for (uint256 f = 0; f < flats; ++f) {
                vm.warp(windowStart + (len * (f + 1)) / (flats + 1));
                kernel.doPreOp(toNAVUnits(committedCollateral));
            }

            // The window's coupon demand per the closed form: linear on the window-start senior NAV
            vm.warp(windowStart + len);
            uint256 coupon = Math.mulDiv(modelStEff, _rate * len, WAD);

            // The settling move, sized from the committed checkpoint so the repayment step never eats into
            // the intended funding: any prior impermanent loss is refunded on top of gain-funded regimes
            uint256 committedIL = toUint256(accountant.getState().lastJTImpermanentLoss);
            uint256 regime = bound(_regimes[i], 0, 3);
            // The junior drain a regime would add: fronted coupon for a short gain, loss plus the whole coupon
            // for a markdown. Fall back to the generous regime once the budget is spent
            uint256 extra = bound(_extras[i], 1, modelStEff / 100);
            uint256 newCollateral;
            if (regime == 0 || (regime == 1 && coupon + committedIL == 0)) {
                // Generous gain: repayment + coupon + excess (the excess flows junior-side only)
                newCollateral = committedCollateral + committedIL + coupon + extra;
            } else if (regime == 1) {
                // Exact gain: repayment + coupon, not a wei more
                newCollateral = committedCollateral + committedIL + coupon;
            } else if (regime == 2) {
                // Short gain: the buffer fronts the remainder of the coupon. A zero-gain draw with no
                // repayment leg would not move the NAV, and only the movement itself prices the coupon, so
                // the gain is floored at one wei
                uint256 shortGain = bound(_extras[i], 0, coupon);
                if (shortGain + committedIL == 0) shortGain = 1;
                if (coupon == 0 || drained + (coupon - shortGain) > drainBudget) {
                    newCollateral = committedCollateral + committedIL + coupon + extra;
                } else {
                    drained += coupon - shortGain;
                    newCollateral = committedCollateral + committedIL + shortGain;
                }
            } else {
                // Covered loss: the buffer absorbs the markdown and fronts the whole coupon
                uint256 loss = bound(_extras[i], 1, Math.max(_jtEff0 / 50, 1));
                if (drained + loss + coupon > drainBudget) {
                    newCollateral = committedCollateral + committedIL + coupon + extra;
                } else {
                    drained += loss + coupon;
                    newCollateral = committedCollateral - loss;
                }
            }

            SyncedAccountingState memory st = kernel.doPreOp(toNAVUnits(newCollateral));
            modelStEff += coupon;

            // The fixed-APY walk: the committed senior NAV sits exactly on the iterate, the junior NAV is the
            // exact conservation complement, and the clock holds this settlement
            assertEq(toUint256(st.stEffectiveNAV), modelStEff, "walk: the senior effective NAV left the closed-form iterate");
            assertEq(toUint256(st.jtEffectiveNAV), newCollateral - modelStEff, "walk: the junior effective NAV is not the conservation complement");
            assertEq(_couponWindowStart(), vm.getBlockTimestamp(), "walk: the settling sync did not restamp the coupon clock");
        }

        // The committed end state equals the closed-form compounded path over the whole run
        IRoycoDayAccountant.RoycoDayAccountantState memory sEnd = accountant.getState();
        assertEq(toUint256(sEnd.lastSTEffectiveNAV), modelStEff, "walk: the final senior effective NAV left the compounded path");
    }

    /**
     * Scenario: a thin junior buffer underwrites an aggressive fixed rate through 2 to 6 windows of random
     * losses and small gains, so underfunded settlements, buffer wipes, and forced wind-downs are routine.
     * Two properties quantify the forgiveness rule at every settlement. First, the coupon actually paid is
     * exactly what the spec funds: on a markdown min(due, the buffer left after loss absorption), on a gain
     * min-funded from the residual gain and then the buffer, each recomputed inline from the committed
     * checkpoint without the mirror pipeline. Second, forgiveness never carries and never overpays: a probe
     * settlement right after each window collects exactly the new window's demand (any carried shortfall
     * would exceed it), and the realized senior path can never exceed the fully funded compounded path.
     */
    function testFuzz_FixedAPY_ForgivenessNeverCarriesAndSeniorGrowthIsBounded(
        uint256 _stEff0,
        uint256 _jtEff0,
        uint256 _rate,
        uint256 _windows,
        uint256[6] memory _lens,
        uint256[6] memory _moves
    )
        public
    {
        _stEff0 = bound(_stEff0, 100e18, 1e27); // a live senior tranche
        _jtEff0 = bound(_jtEff0, 1e18, _stEff0 / 5); // deliberately thin buffer so wipes and forgiveness are common
        _rate = bound(_rate, 1e9, 1e13); // the default rate through a punishing 10000x, so demand routinely outruns funding
        uint256 windows = bound(_windows, 2, 6);

        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _defaultParams();
        p.stFixedRatePerSecondWAD = uint64(_rate);
        _deploy(p);
        lptYDM.setRates(0);
        _seedSymmetric(_stEff0, _jtEff0, 0);
        kernel.doPreOp(toNAVUnits(_stEff0 + _jtEff0));

        // The fully funded compounded path, the one-sided ceiling on the realized walk
        uint256 ffStEff = _stEff0;

        for (uint256 i = 0; i < windows; ++i) {
            uint256 len = bound(_lens[i], 1, 30 days);
            vm.warp(vm.getBlockTimestamp() + len);

            // The committed checkpoint the settlement prices against
            IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
            uint256 stEffLast = toUint256(s.lastSTEffectiveNAV);
            uint256 jtEffLast = toUint256(s.lastJTEffectiveNAV);
            uint256 ilLast = toUint256(s.lastJTImpermanentLoss);
            uint256 committedCollateral = toUint256(s.lastCollateralNAV);
            uint256 due = Math.mulDiv(stEffLast, _rate * len, WAD);
            ffStEff += Math.mulDiv(ffStEff, _rate * len, WAD);

            // Random funding: losses up to -90% or gains up to +5%, so the demand routinely exceeds it
            uint256 newCollateral;
            uint256 expectedPaid;
            if (_moves[i] % 2 == 0) {
                uint256 lossBps = bound(_moves[i], 1, 9000);
                newCollateral = _afterMove(committedCollateral, -int256(lossBps));
                uint256 loss = committedCollateral - newCollateral;
                // Loss pipeline, recomputed inline: the buffer absorbs first, then fronts the coupon
                uint256 jtAfterLoss = jtEffLast - Math.min(loss, jtEffLast);
                expectedPaid = Math.min(due, jtAfterLoss);
            } else {
                uint256 gainBps = bound(_moves[i], 1, 500);
                newCollateral = committedCollateral + committedCollateral * gainBps / 10_000;
                uint256 gain = newCollateral - committedCollateral;
                // Gain pipeline, recomputed inline: repayment off the top, then the gain funds the coupon,
                // then the buffer (grown by the repayment) fronts the remainder
                uint256 residualGain = gain - Math.min(gain, ilLast);
                uint256 fromGain = Math.min(residualGain, due);
                expectedPaid = fromGain + Math.min(due - fromGain, jtEffLast + Math.min(gain, ilLast));
            }
            if (newCollateral == committedCollateral) continue;

            SyncedAccountingState memory st = kernel.doPreOp(toNAVUnits(newCollateral));

            // The realized coupon is exactly what the spec funds: everything above it is forgiven on the spot.
            // On a wipe markdown the senior also books the uncovered residual loss, netted out here
            uint256 lossResidual =
                (newCollateral < committedCollateral) ? (committedCollateral - newCollateral) - Math.min(committedCollateral - newCollateral, jtEffLast) : 0;
            assertEq(
                toUint256(st.stEffectiveNAV) + lossResidual,
                stEffLast + expectedPaid,
                "forgiveness: the settlement paid something other than what the gain and the buffer fund"
            );
            // The one-sided guarantee that makes forgiveness safe: the realized path never exceeds the fully
            // funded compounded path, so no settlement can ever overpay the senior tranche
            assertLe(toUint256(st.stEffectiveNAV), ffStEff, "forgiveness: the realized senior path exceeded the fully funded compounded path");

            // The no-carry probe: an immediate generously funded settlement collects exactly the new window's
            // demand, so the forgiven shortfall died with its window
            uint256 probeElapsed = 10;
            vm.warp(vm.getBlockTimestamp() + probeElapsed);
            uint256 stEffNow = toUint256(st.stEffectiveNAV);
            uint256 probeDue = Math.mulDiv(stEffNow, _rate * probeElapsed, WAD);
            ffStEff += Math.mulDiv(ffStEff, _rate * probeElapsed, WAD);
            uint256 probeIL = toUint256(accountant.getState().lastJTImpermanentLoss);
            SyncedAccountingState memory probed = kernel.doPreOp(toNAVUnits(toUint256(st.collateralNAV) + probeIL + probeDue + 1e18));
            assertEq(toUint256(probed.stEffectiveNAV), stEffNow + probeDue, "forgiveness: a forgiven shortfall carried into the next window's demand");
        }
    }
}
