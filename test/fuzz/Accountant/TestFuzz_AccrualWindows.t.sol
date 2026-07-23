// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { AccountantFuzzTestBase } from "../../utils/AccountantFuzzTestBase.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title TestFuzz_AccrualWindows_Accountant
 * @notice Fuzz properties for the premium accrual bookkeeping under interleaved syncs, deposits, and warps:
 *         the time-weighted accumulators integrate the capped yield share over a contiguous window that
 *         starts at the last premium payment, extends to the last sync with no gaps and no double-counting,
 *         and resets exactly when a sync pays the premiums - never on losses, flat syncs, or deposits
 * @dev The model tracks the expected accumulators and timestamps step by step, with each sync's
 *      premiums-paid outcome taken from the independent RoycoTestMath mirror sync rather than from
 *      production. The model lives in contract storage purely to keep stack frames small - every fuzz run
 *      starts from a fresh state, so no data leaks between runs
 */
contract TestFuzz_AccrualWindows_Accountant is AccountantFuzzTestBase {
    /// @dev The fuzzed constant yield share each mock YDM pins for the whole run
    uint256 internal pinnedJTRate;
    uint256 internal pinnedLTRate;

    /// @dev The expected accrual bookkeeping, carried across the fuzzed steps
    uint256 internal modelTwJT;
    uint256 internal modelTwLT;
    uint256 internal modelLastAccrual;
    uint256 internal modelLastPayment;

    /// @dev The running marks the next step moves from
    uint256 internal collateralNAV;
    uint256 internal ltRawNAV;

    /**
     * Scenario: a seeded market lives through eight fuzzed steps, each an arbitrary warp followed by one of
     * a flat sync, a gain sync, a loss sync, or a senior/junior deposit. The premium a gain sync pays is the
     * senior gain weighted by accumulator / window, so the accounting is only fair if the accumulator covers
     * exactly the window it is divided by: a skipped stretch under-pays the junior and liquidity tranches, a
     * double-counted one over-pays them out of the senior gain, and a reset without a payment silently
     * forfeits accrued premium. After every step the accountant's accumulators and both timestamps must match
     * a step-by-step model, and the accumulator must equal the capped constant share integrated over exactly
     * [last premium payment, last accrual] - the closed form only a contiguous window satisfies.
     */
    function testFuzz_AccrualWindows_ContiguousAndResetOnlyWhenPremiumsPay(
        uint256 _stEff0,
        uint256 _jtEff0,
        uint256 _ltRaw0,
        uint256 _jtRate,
        uint256 _ltRate,
        uint256[8] memory _warps,
        uint256[8] memory _actions,
        uint256[8] memory _moves
    )
        public
    {
        _prepareMarket(_stEff0, _jtEff0, _ltRaw0, _jtRate, _ltRate);
        for (uint256 i = 0; i < 8; ++i) {
            _step(_warps[i], _actions[i], _moves[i]);
        }
    }

    /**
     * Scenario: an attacker lands a second gain sync in the very same block as the one that just paid the
     * premiums, hoping the spent accrual window is read twice and the junior and liquidity tranches are paid
     * twice out of one senior gain. Zero elapsed time means zero fresh accrual, so the accumulators must not
     * grow between the two syncs and the second sync's premium must be derived from an empty (or unchanged)
     * window - never from re-reading the accrual the first sync already consumed.
     */
    function testFuzz_AccrualWindows_SameBlockRepeatGainSyncCannotReuseTheSpentWindow(
        uint256 _stEff0,
        uint256 _jtEff0,
        uint256 _ltRaw0,
        uint256 _jtRate,
        uint256 _ltRate,
        uint256 _window,
        uint256 _gain1,
        uint256 _gain2
    )
        public
    {
        _prepareMarket(_stEff0, _jtEff0, _ltRaw0, _jtRate, _ltRate);

        // A real accrual window from one second to the ten-year suite ceiling, then the first gain sync
        vm.warp(block.timestamp + bound(_window, 1, MAX_ELAPSED));
        _stepSync(int256(bound(_gain1, 1, 10_000))); // +0.01% to +100% gain: pays unless the gain only recovers IL
        _assertWindowBookkeeping();
        IRoycoDayAccountant.RoycoDayAccountantState memory afterFirst = accountant.getState();

        // The attack: a second gain sync with zero elapsed time (the mirror inside _stepSync re-derives the
        // exact premium this sync may pay from the unchanged model window)
        _stepSync(int256(bound(_gain2, 1, 10_000))); // +0.01% to +100% same-block follow-up gain
        _assertWindowBookkeeping();

        // Zero elapsed time accrues nothing: the accumulators can only shrink (a payout reset), never grow
        IRoycoDayAccountant.RoycoDayAccountantState memory afterSecond = accountant.getState();
        assertLe(
            uint256(afterSecond.twJTYieldShareAccruedWAD),
            uint256(afterFirst.twJTYieldShareAccruedWAD),
            "a same-block repeat sync must not grow the junior accumulator"
        );
        assertLe(
            uint256(afterSecond.twLTYieldShareAccruedWAD),
            uint256(afterFirst.twLTYieldShareAccruedWAD),
            "a same-block repeat sync must not grow the liquidity accumulator"
        );
        assertEq(
            uint256(afterSecond.lastYieldShareAccrualTimestamp),
            uint256(afterFirst.lastYieldShareAccrualTimestamp),
            "the accrual timestamp must not move within one block"
        );
    }

    /**
     * Scenario: nothing touches the market for the full ten-year fuzz ceiling, then a gain sync lands. The
     * accumulator entering that sync must equal the capped constant share integrated over exactly the whole
     * idle stretch - a decade of inactivity neither forfeits accrued premium (an under-read) nor inflates it
     * (an overflow or double-count) - and the sync must settle its payout from exactly that window.
     */
    function testFuzz_AccrualWindows_MaxElapsedWindowAccruesExactlyThenSettles(
        uint256 _stEff0,
        uint256 _jtEff0,
        uint256 _ltRaw0,
        uint256 _jtRate,
        uint256 _ltRate,
        uint256 _gain
    )
        public
    {
        _prepareMarket(_stEff0, _jtEff0, _ltRaw0, _jtRate, _ltRate);

        // The first-ever sync only initializes the accrual clock (it accrues nothing by construction)
        _stepSync(0);
        _assertWindowBookkeeping();

        // The maximal idle stretch this suite models, with no interaction in between
        vm.warp(block.timestamp + MAX_ELAPSED);

        // Pin the window the next sync will read: capped share x the full ten-year stretch, exact arithmetic
        (uint256 twJT, uint256 twLT, uint256 elapsedSincePayment) = _premiumWindow(pinnedJTRate, pinnedLTRate);
        assertEq(twJT, Math.min(pinnedJTRate, DEFAULT_MAX_JT_YIELD_SHARE_WAD) * MAX_ELAPSED, "the junior accumulator must cover the entire idle decade");
        assertEq(twLT, Math.min(pinnedLTRate, DEFAULT_MAX_LT_YIELD_SHARE_WAD) * MAX_ELAPSED, "the liquidity accumulator must cover the entire idle decade");
        assertEq(elapsedSincePayment, MAX_ELAPSED, "the premium window must span the entire idle decade");

        // The gain sync settles against that maximal window; _stepSync asserts the payout via the mirror
        _stepSync(int256(bound(_gain, 1, 10_000))); // +0.01% to +100% gain after the decade of inactivity
        _assertWindowBookkeeping();
    }

    /// @dev Bounds the seed inputs, deploys the market with the pinned YDM rates, seeds it, and starts the model
    function _prepareMarket(uint256 _stEff0, uint256 _jtEff0, uint256 _ltRaw0, uint256 _jtRate, uint256 _ltRate) internal {
        uint256 stEff0 = bound(_stEff0, 0, MAX_NAV); // full NAV range incl. the empty-tranche edge
        uint256 jtEff0 = bound(_jtEff0, 0, MAX_NAV); // full NAV range incl. the uncovered-market edge
        ltRawNAV = bound(_ltRaw0, 0, MAX_NAV); // full NAV range incl. the no-depth edge
        pinnedJTRate = bound(_jtRate, 0, WAD); // full YDM output range, the accountant caps it at the configured max
        pinnedLTRate = bound(_ltRate, 0, WAD); // full YDM output range, the accountant caps it at the configured max

        _deploy(_defaultParams());
        jtYDM.setRates(pinnedJTRate);
        ltYDM.setRates(pinnedLTRate);
        _seedSymmetric(stEff0, jtEff0, ltRawNAV);
        collateralNAV = stEff0 + jtEff0;
    }

    /// @dev Warps, dispatches one fuzzed step (sync or deposit), and asserts the window bookkeeping after it
    function _step(uint256 _warp, uint256 _action, uint256 _move) internal {
        // Same-block (0) through a year per step, so windows span multiple syncs and same-block interleavings stay in play
        vm.warp(block.timestamp + bound(_warp, 0, 365 days));
        // Uniform 20% each: flat sync, gain sync, loss sync, senior deposit, junior deposit
        uint256 action = bound(_action, 0, 4);
        if (action == 0) {
            _stepSync(0);
        } else if (action == 1) {
            // Gain of +0.01% to +100%: pays the premiums unless the whole gain recovers impermanent loss
            _stepSync(int256(bound(_move, 1, 10_000)));
        } else if (action == 2) {
            // Loss of -0.01% to -100%: never pays, the accumulators must keep growing
            _stepSync(-int256(bound(_move, 1, 10_000)));
        } else {
            // Deposits run the post-op path, which must leave the accrual bookkeeping completely untouched
            _stepDeposit(action == 3, bound(_move, 1, MAX_NAV));
        }
        _assertWindowBookkeeping();
    }

    /**
     * @dev Runs one pre-op sync moving the collateral by the signed basis points, asserting the sync output
     *      against the mirror driven by the modeled window, then applies the mirror's premiums-paid outcome
     *      to the model: accumulators zero and the payment timestamp advances only when premiums pay
     */
    function _stepSync(int256 _bps) internal {
        uint256 collateralNew = _afterMove(collateralNAV, _bps);
        _modelAccrual();

        // The reset rule: paid premiums close the window, anything else leaves it accruing
        if (_syncAndAssertPayout(collateralNew)) {
            modelTwJT = 0;
            modelTwLT = 0;
            modelLastPayment = block.timestamp;
        }
        collateralNAV = collateralNew;
    }

    /**
     * @dev Derives the expected sync output from the modeled window through the independent mirror, executes
     *      the sync plus the liquidity commit, asserts the premium-bearing fields, and returns whether the
     *      mirror says this sync paid the premiums
     */
    function _syncAndAssertPayout(uint256 _collateralNew) internal returns (bool premiumsPaid) {
        RoycoTestMath.SyncOutputs memory out = RoycoTestMath.syncTrancheAccounting(
            _mirrorInput(_collateralNew, ltRawNAV, modelTwJT, modelTwLT, block.timestamp - modelLastPayment, pinnedJTRate, pinnedLTRate)
        );

        SyncedAccountingState memory st = kernel.doPreOp(toNAVUnits(_collateralNew));
        kernel.doCommit(toNAVUnits(ltRawNAV));

        // The premiums folded into the effective NAVs tie the accrued window to the sync's actual payout
        assertEq(toUint256(st.stEffectiveNAV), out.stEffectiveNAV, "sync step: senior effective NAV must fold in exactly the modeled premium");
        assertEq(toUint256(st.jtEffectiveNAV), out.jtEffectiveNAV, "sync step: junior effective NAV must fold in exactly the modeled premium");
        assertEq(toUint256(st.ltLiquidityPremium), out.ltLiquidityPremium, "sync step: liquidity premium must come from the modeled window");
        premiumsPaid = out.premiumsPaid;
    }

    /**
     * @dev Models the accrual a sync performs before its tranche accounting: a first-ever sync initializes both
     *      timestamps and accrues nothing, every later sync extends each accumulator by the capped pinned
     *      share x seconds since the last accrual (a same-block sync extends by nothing)
     */
    function _modelAccrual() internal {
        if (modelLastAccrual == 0) {
            modelLastAccrual = block.timestamp;
            modelLastPayment = block.timestamp;
        } else if (block.timestamp > modelLastAccrual) {
            modelTwJT += Math.min(pinnedJTRate, DEFAULT_MAX_JT_YIELD_SHARE_WAD) * (block.timestamp - modelLastAccrual);
            modelTwLT += Math.min(pinnedLTRate, DEFAULT_MAX_LT_YIELD_SHARE_WAD) * (block.timestamp - modelLastAccrual);
            modelLastAccrual = block.timestamp;
        }
    }

    /// @dev Runs one post-op deposit through the kernel passthrough, which must not touch the accrual bookkeeping
    function _stepDeposit(bool _seniorSide, uint256 _add) internal {
        Operation op = _seniorSide ? Operation.ST_DEPOSIT : Operation.JT_DEPOSIT;
        collateralNAV += _add;
        kernel.doPostOp(op, toNAVUnits(collateralNAV), toNAVUnits(ltRawNAV), ZERO_NAV_UNITS, false);
    }

    /// @dev Asserts the accountant's window bookkeeping equals the model and satisfies the contiguity closed form
    function _assertWindowBookkeeping() internal view {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(uint256(s.twJTYieldShareAccruedWAD), modelTwJT, "window: junior accumulator diverged from the step model");
        assertEq(uint256(s.twLTYieldShareAccruedWAD), modelTwLT, "window: liquidity accumulator diverged from the step model");
        assertEq(uint256(s.lastYieldShareAccrualTimestamp), modelLastAccrual, "window: last accrual timestamp diverged from the step model");
        assertEq(uint256(s.lastPremiumPaymentTimestamp), modelLastPayment, "window: last premium payment timestamp diverged from the step model");

        // Contiguity closed form: with a constant pinned share, an accumulator equals the capped share
        // integrated over exactly [lastPayment, lastAccrual]. A skipped stretch reads low, a double-counted
        // one reads high, and a reset without a payment breaks the window start
        uint256 window = uint256(s.lastYieldShareAccrualTimestamp) - uint256(s.lastPremiumPaymentTimestamp);
        assertEq(
            uint256(s.twJTYieldShareAccruedWAD),
            Math.min(pinnedJTRate, DEFAULT_MAX_JT_YIELD_SHARE_WAD) * window,
            "window: junior accumulator != capped share x contiguous window"
        );
        assertEq(
            uint256(s.twLTYieldShareAccruedWAD),
            Math.min(pinnedLTRate, DEFAULT_MAX_LT_YIELD_SHARE_WAD) * window,
            "window: liquidity accumulator != capped share x contiguous window"
        );
    }
}
