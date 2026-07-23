// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";
import { AccountantFuzzTestBase } from "../../utils/AccountantFuzzTestBase.sol";

/**
 * @title TestFuzz_SyncTrancheAccounting_Accountant
 * @notice Fuzz properties for the full pre-op tranche accounting sync: field-for-field equality against
 *         the independent RoycoTestMath mirror, wei-exact NAV conservation, junior-buffer-first loss
 *         priority with an independently recomputed coverage amount, the premium-inside-the-gain bound,
 *         independent fee-cap and carve-out-fit bounds on all three protocol fees, and the isolation of
 *         senior/junior accounting from the liquidity tranche's mark
 * @dev Every run drives a reachable market: a symmetric deposit-seeded checkpoint, a preparatory sync
 *      that can book impermanent loss or enter a fixed term, then the measured sync from there
 */
contract TestFuzz_SyncTrancheAccounting_Accountant is AccountantFuzzTestBase {
    /**
     * Scenario: a market is seeded through real deposits, run through one preparatory PnL sync (which can
     * absorb a senior loss into the junior buffer, book IL, or flip the market into a fixed term),
     * then synced again after an arbitrary elapsed window with fresh senior/junior marks and a fresh
     * liquidity mark. The measured sync's complete output — raw and effective NAVs, IL, liquidity
     * premium, all three protocol fees, coverage utilization, market state, and term end — must equal the
     * independently derived expectation field for field, and the two-term conservation identity must hold
     * at wei precision on production's own outputs. Junior-first loss priority and the premium bound are
     * additionally recomputed from the pre-sync checkpoint without running the mirror's pipeline, so a bug
     * that broke both production and the mirror identically in those steps would still be caught.
     */
    function testFuzz_Sync_MatchesIndependentMirrorFieldForField(
        uint256 _stRaw0,
        uint256 _jtRaw0,
        uint256 _ltRaw0,
        int256 _stBps1,
        int256 _jtBps1,
        uint256 _warp1,
        int256 _stBps2,
        int256 _jtBps2,
        uint256 _ltRaw2,
        uint256 _warp2,
        uint256 _jtRate,
        uint256 _ltRate
    )
        public
    {
        _stRaw0 = bound(_stRaw0, 0, MAX_NAV); // full NAV range incl. the empty-tranche edge
        _jtRaw0 = bound(_jtRaw0, 0, MAX_NAV); // full NAV range incl. the uncovered-market edge
        _ltRaw0 = bound(_ltRaw0, 0, MAX_NAV); // full NAV range incl. the no-depth edge
        _ltRaw2 = bound(_ltRaw2, 0, MAX_NAV); // fresh liquidity mark, fully independent of the senior/junior moves
        _stBps1 = bound(_stBps1, -10_000, 10_000); // -100% to +100% preparatory senior move
        _jtBps1 = bound(_jtBps1, -10_000, 10_000); // -100% to +100% preparatory junior move
        _stBps2 = bound(_stBps2, -10_000, 10_000); // -100% to +100% measured senior move
        _jtBps2 = bound(_jtBps2, -10_000, 10_000); // -100% to +100% measured junior move
        _warp1 = bound(_warp1, 0, MAX_ELAPSED); // same-block to ten years before the preparatory sync
        _warp2 = bound(_warp2, 0, MAX_ELAPSED); // same-block (instantaneous premium branch) to ten years before the measured sync
        _jtRate = bound(_jtRate, 0, WAD); // full YDM output range, the accountant caps it at the configured max
        _ltRate = bound(_ltRate, 0, WAD); // full YDM output range, the accountant caps it at the configured max

        _deploy(_defaultParams());
        jtYDM.setRates(_jtRate);
        ltYDM.setRates(_ltRate);
        _seedSymmetric(_stRaw0, _jtRaw0, _ltRaw0);

        // Preparatory sync: move both raws so the measured sync starts from an asymmetric checkpoint that can
        // carry IL, cross-tranche claims, or a fixed-term state, not just the pristine symmetric seed
        vm.warp(block.timestamp + _warp1);
        uint256 stRaw1 = _afterMove(_stRaw0, _stBps1);
        uint256 jtRaw1 = _afterMove(_jtRaw0, _jtBps1);
        kernel.doPreOp(toNAVUnits(stRaw1), toNAVUnits(jtRaw1));
        kernel.doCommit(toNAVUnits(_ltRaw0));

        // Derive the complete expected post-sync state from the committed checkpoint BEFORE production runs
        vm.warp(block.timestamp + _warp2);
        uint256 stRaw2 = _afterMove(stRaw1, _stBps2);
        uint256 jtRaw2 = _afterMove(jtRaw1, _jtBps2);
        (uint256 twJT, uint256 twLT, uint256 elapsedSincePayment) = _premiumWindow(_jtRate, _ltRate);
        RoycoTestMath.SyncInputs memory in_ = _mirrorInput(stRaw2, jtRaw2, _ltRaw2, twJT, twLT, elapsedSincePayment, _jtRate, _ltRate);
        RoycoTestMath.SyncOutputs memory out = RoycoTestMath.syncTrancheAccounting(in_);

        SyncedAccountingState memory st = kernel.doPreOp(toNAVUnits(stRaw2), toNAVUnits(jtRaw2));
        kernel.doCommit(toNAVUnits(_ltRaw2));

        // Field-for-field equality with the independent mirror
        assertEq(toUint256(st.stRawNAV), out.stRawNAV, "sync: senior raw NAV");
        assertEq(toUint256(st.jtRawNAV), out.jtRawNAV, "sync: junior raw NAV");
        assertEq(toUint256(st.stEffectiveNAV), out.stEffectiveNAV, "sync: senior effective NAV");
        assertEq(toUint256(st.jtEffectiveNAV), out.jtEffectiveNAV, "sync: junior effective NAV");
        assertEq(toUint256(st.jtImpermanentLoss), out.jtImpermanentLoss, "sync: junior impermanent loss");
        assertEq(toUint256(st.ltLiquidityPremium), out.ltLiquidityPremium, "sync: liquidity premium");
        assertEq(toUint256(st.stProtocolFee), out.stProtocolFee, "sync: senior protocol fee");
        assertEq(toUint256(st.jtProtocolFee), out.jtProtocolFee, "sync: junior protocol fee");
        assertEq(toUint256(st.ltProtocolFee), out.ltProtocolFee, "sync: liquidity protocol fee");
        assertEq(st.coverageUtilizationWAD, out.coverageUtilizationWAD, "sync: coverage utilization");
        assertEq(uint8(st.marketState), uint8(out.marketState), "sync: market state");
        assertEq(uint256(st.fixedTermEndTimestamp), out.fixedTermEndTimestamp, "sync: fixed-term end");
        // The pre-op return carries a zero liquidity placeholder: the kernel commits the fresh mark afterwards
        assertEq(st.liquidityUtilizationWAD, 0, "sync: pre-op liquidity utilization placeholder");

        // Two-term conservation at wei precision on production's own outputs
        assertEq(stRaw2 + jtRaw2, toUint256(st.stEffectiveNAV) + toUint256(st.jtEffectiveNAV), "sync: raw and effective NAVs conserve exactly");

        // Independent fee bounds sharing nothing with the mirror pipeline. Every gain a sync can book is
        // capped by the gross upside of the raw marks, computed in plain checked integers: a tranche's
        // attributed slice of one raw leg's move can never exceed the move itself (no claim exceeds the raw
        // NAV it is a claim on, and a leg that fell contributes no gain), so the senior gain, the junior net
        // gain, and every premium carved from the senior gain each fit inside grossUpside. The fee fields
        // are unsigned, so non-negativity is structural rather than asserted
        uint256 grossUpside = (stRaw2 > stRaw1 ? stRaw2 - stRaw1 : 0) + (jtRaw2 > jtRaw1 ? jtRaw2 - jtRaw1 : 0);
        // This fixture deploys every protocol fee rate at 0.1e18, so each fee is a floored 10% slice of its
        // base and ten times the fee must fit back inside the base: the senior fee's base is the senior
        // gain residual and the liquidity fee's base is the liquidity premium (both <= grossUpside). The
        // junior fee is the sum of two 10% legs (the junior tranche's own net gain and the risk premium,
        // each <= grossUpside), so five times it must fit inside grossUpside
        assertLe(toUint256(st.stProtocolFee) * 10, grossUpside, "fee bound: the senior fee exceeds 10% of the gross upside");
        assertLe(toUint256(st.ltProtocolFee) * 10, grossUpside, "fee bound: the liquidity fee exceeds 10% of the gross upside");
        assertLe(toUint256(st.jtProtocolFee) * 5, grossUpside, "fee bound: the junior fee exceeds its two 10% legs of the gross upside");
        assertLe(toUint256(st.ltLiquidityPremium), grossUpside, "fee bound: the liquidity premium exceeds the gross upside");
        // Fees are charged on gains only, never on principal: a sync with zero upside on both raw legs has
        // no gain anywhere in the waterfall (this fixture's NAV dust tolerances are zero, so any nonzero
        // gain is fee-eligible and, conversely, zero gain admits zero fees and zero premium)
        if (grossUpside == 0) {
            assertEq(toUint256(st.stProtocolFee), 0, "fee bound: a senior fee was charged with no gain booked");
            assertEq(toUint256(st.jtProtocolFee), 0, "fee bound: a junior fee was charged with no gain booked");
            assertEq(toUint256(st.ltProtocolFee), 0, "fee bound: a liquidity fee was charged with no gain booked");
            assertEq(toUint256(st.ltLiquidityPremium), 0, "fee bound: a liquidity premium was paid with no gain booked");
        }
        // Conservation including the fee carve-outs: fees and the premium are dilution claims inside the
        // conserved NAV, never additions to it, so each carve-out must fit inside the effective NAV it will
        // be minted against -- otherwise the post-sync share mints would price against NAV that does not exist
        assertLe(
            toUint256(st.ltLiquidityPremium) + toUint256(st.stProtocolFee),
            toUint256(st.stEffectiveNAV),
            "fee bound: the senior carve-outs exceed the senior effective NAV"
        );
        // The junior fee bound holds on the coinvested input domain the kernels enforce (ST and JT raw deltas share a sign,
        // so a junior gain, the only fee source, precludes same-sync coverage). Mixed-sign inputs exceed that domain and can
        // strand a fee above the coverage-slashed junior NAV, so they are exercised for mirror parity only
        if (!((in_.stRawNAVDelta < 0 && in_.jtRawNAVDelta > 0) || (in_.stRawNAVDelta > 0 && in_.jtRawNAVDelta < 0))) {
            assertLe(toUint256(st.jtProtocolFee), toUint256(st.jtEffectiveNAV), "fee bound: the junior fee exceeds the junior effective NAV");
        }

        // The committed checkpoint equals the returned state, and the liquidity mark landed
        IRoycoDayAccountant.RoycoDayAccountantState memory sAfter = accountant.getState();
        assertEq(toUint256(sAfter.lastSTEffectiveNAV), out.stEffectiveNAV, "checkpoint: senior effective NAV");
        assertEq(toUint256(sAfter.lastJTEffectiveNAV), out.jtEffectiveNAV, "checkpoint: junior effective NAV");
        assertEq(toUint256(sAfter.lastJTImpermanentLoss), out.jtImpermanentLoss, "checkpoint: junior impermanent loss");
        assertEq(toUint256(sAfter.lastLTRawNAV), _ltRaw2, "checkpoint: committed liquidity mark");
        assertEq(uint8(sAfter.lastMarketState), uint8(out.marketState), "checkpoint: market state");
        assertEq(uint256(sAfter.fixedTermEndTimestamp), out.fixedTermEndTimestamp, "checkpoint: fixed-term end");

        _assertLossPriorityAndPremiumBound(in_, out, st);
    }

    /**
     * @dev Recomputes the senior effective delta from the pre-sync checkpoint (claims decomposition plus
     *      attribution, without running the mirror's sync pipeline) and asserts the loss and gain legs:
     *      the junior leg first books its own loss as impermanent (or recovers with its own gain), then on a
     *      senior loss the junior buffer absorbs first and every covered wei deepens the impermanent loss,
     *      and on a senior gain the two premiums fit inside the gain left after impermanent-loss recovery
     */
    function _assertLossPriorityAndPremiumBound(
        RoycoTestMath.SyncInputs memory in_,
        RoycoTestMath.SyncOutputs memory out,
        SyncedAccountingState memory st
    )
        internal
        pure
    {
        // Claims decomposition: at most one cross-claim is nonzero, the rest is each tranche's self-claim
        uint256 stClaimOnJTRaw = in_.stEffectiveNAVLast > in_.stRawNAVLast ? in_.stEffectiveNAVLast - in_.stRawNAVLast : 0;
        uint256 jtClaimOnSTRaw = in_.jtEffectiveNAVLast > in_.jtRawNAVLast ? in_.jtEffectiveNAVLast - in_.jtRawNAVLast : 0;
        uint256 stClaimOnSTRaw = in_.stRawNAVLast - jtClaimOnSTRaw;
        // A zero senior raw pool routes the whole senior delta to the senior claim only if it has live value
        int256 deltaSTEff =
            (in_.stRawNAVLast == 0 ? (in_.stEffectiveNAVLast > 0 ? in_.stRawNAVDelta : int256(0)) : RoycoTestMath.attributeDeltaToClaimOnRawNAV(in_.stRawNAVDelta, stClaimOnSTRaw, in_.stRawNAVLast))
                + RoycoTestMath.attributeDeltaToClaimOnRawNAV(in_.jtRawNAVDelta, stClaimOnJTRaw, in_.jtRawNAVLast);
        int256 deltaJTEff = (in_.stRawNAVDelta + in_.jtRawNAVDelta) - deltaSTEff;
        // The junior leg adjusts the impermanent loss before the senior leg: a junior loss deepens it, a junior gain recovers it
        uint256 ilAfterJTLeg = deltaJTEff < 0
            ? in_.jtImpermanentLossLast + uint256(-deltaJTEff)
            : in_.jtImpermanentLossLast - Math.min(uint256(deltaJTEff), in_.jtImpermanentLossLast);

        if (deltaSTEff < 0) {
            // Loss priority: the junior buffer (after its own PnL) covers first, senior books only the residual
            uint256 stLoss = uint256(-deltaSTEff);
            uint256 jtEffAfterOwnPnl = deltaJTEff < 0 ? in_.jtEffectiveNAVLast - uint256(-deltaJTEff) : in_.jtEffectiveNAVLast + uint256(deltaJTEff);
            uint256 coverageApplied = Math.min(stLoss, jtEffAfterOwnPnl);
            assertEq(toUint256(st.stEffectiveNAV), in_.stEffectiveNAVLast - (stLoss - coverageApplied), "loss priority: senior books only the uncovered residual");
            assertEq(toUint256(st.jtEffectiveNAV), jtEffAfterOwnPnl - coverageApplied, "loss priority: the junior buffer absorbs the covered loss");
            // Every covered wei becomes a senior liability to the junior tranche, unless a forced wind-down erased it
            if (out.ilErased == 0) {
                assertEq(toUint256(st.jtImpermanentLoss), ilAfterJTLeg + coverageApplied, "loss priority: coverage applied books as impermanent loss");
            } else {
                assertEq(toUint256(st.jtImpermanentLoss), 0, "loss priority: a forced wind-down erases the impermanent loss");
                assertEq(out.ilErased, ilAfterJTLeg + coverageApplied, "loss priority: exactly the pre-erasure balance is erased");
            }
            assertEq(toUint256(st.ltLiquidityPremium), 0, "loss priority: no liquidity premium on a senior loss");
        } else if (deltaSTEff > 0) {
            // Premium bound: after recovering the junior tranche's impermanent loss (the first claim on senior
            // appreciation), the risk and liquidity premiums together can never exceed the residual gain
            uint256 recovery = Math.min(uint256(deltaSTEff), ilAfterJTLeg);
            uint256 residualGain = uint256(deltaSTEff) - recovery;
            assertLe(out.jtRiskPremium + out.ltLiquidityPremium, residualGain, "premium bound: both premiums fit inside the residual senior gain");
        }
    }

    /**
     * Scenario: two copies of the same market state at the same instant, differing ONLY in the liquidity
     * tranche's committed mark, are put through the identical senior/junior sync. The liquidity tranche is an
     * overlay: its mark prices the liquidity premium's driver but must never leak into the senior/junior
     * tranche accounting sync, so every senior/junior output — effective NAVs, impermanent loss, coverage utilization,
     * market state, premium, and fees — must be identical across the two copies. If perturbing the pool mark
     * could move senior or junior accounting, a swap against the pool could re-price the tranches.
     */
    function testFuzz_Sync_LiquidityMarkNeverMovesSeniorOrJuniorAccounting(
        uint256 _stRaw0,
        uint256 _jtRaw0,
        uint256 _ltRawA,
        uint256 _ltRawB,
        int256 _stBps,
        int256 _jtBps,
        uint256 _warp,
        uint256 _jtRate,
        uint256 _ltRate
    )
        public
    {
        _stRaw0 = bound(_stRaw0, 0, MAX_NAV); // full NAV range incl. the empty-tranche edge
        _jtRaw0 = bound(_jtRaw0, 0, MAX_NAV); // full NAV range incl. the uncovered-market edge
        _ltRawA = bound(_ltRawA, 0, MAX_NAV); // first liquidity mark incl. the no-depth edge
        _ltRawB = bound(_ltRawB, 0, MAX_NAV); // perturbed liquidity mark, unconstrained relative to the first
        _stBps = bound(_stBps, -10_000, 10_000); // -100% to +100% senior move
        _jtBps = bound(_jtBps, -10_000, 10_000); // -100% to +100% junior move
        _warp = bound(_warp, 0, MAX_ELAPSED); // same-block to ten years before the measured sync
        _jtRate = bound(_jtRate, 0, WAD); // full YDM output range
        _ltRate = bound(_ltRate, 0, WAD); // full YDM output range

        _deploy(_defaultParams());
        jtYDM.setRates(_jtRate);
        ltYDM.setRates(_ltRate);
        _seedSymmetric(_stRaw0, _jtRaw0, _ltRawA);

        vm.warp(block.timestamp + _warp);
        uint256 stRaw1 = _afterMove(_stRaw0, _stBps);
        uint256 jtRaw1 = _afterMove(_jtRaw0, _jtBps);

        // Copy A: sync against the seeded liquidity mark
        uint256 snapshotId = vm.snapshotState();
        SyncedAccountingState memory stA = kernel.doPreOp(toNAVUnits(stRaw1), toNAVUnits(jtRaw1));

        // Copy B: identical state and instant, but the liquidity mark is re-committed to the perturbed value first
        vm.revertToState(snapshotId);
        kernel.doCommit(toNAVUnits(_ltRawB));
        SyncedAccountingState memory stB = kernel.doPreOp(toNAVUnits(stRaw1), toNAVUnits(jtRaw1));

        assertEq(toUint256(stA.stEffectiveNAV), toUint256(stB.stEffectiveNAV), "isolation: senior effective NAV moved with the liquidity mark");
        assertEq(toUint256(stA.jtEffectiveNAV), toUint256(stB.jtEffectiveNAV), "isolation: junior effective NAV moved with the liquidity mark");
        assertEq(
            toUint256(stA.jtImpermanentLoss), toUint256(stB.jtImpermanentLoss), "isolation: impermanent loss moved with the liquidity mark"
        );
        assertEq(stA.coverageUtilizationWAD, stB.coverageUtilizationWAD, "isolation: coverage utilization moved with the liquidity mark");
        assertEq(uint8(stA.marketState), uint8(stB.marketState), "isolation: market state moved with the liquidity mark");
        assertEq(uint256(stA.fixedTermEndTimestamp), uint256(stB.fixedTermEndTimestamp), "isolation: fixed-term end moved with the liquidity mark");
        assertEq(toUint256(stA.ltLiquidityPremium), toUint256(stB.ltLiquidityPremium), "isolation: liquidity premium moved with the liquidity mark");
        assertEq(toUint256(stA.stProtocolFee), toUint256(stB.stProtocolFee), "isolation: senior fee moved with the liquidity mark");
        assertEq(toUint256(stA.jtProtocolFee), toUint256(stB.jtProtocolFee), "isolation: junior fee moved with the liquidity mark");
        assertEq(toUint256(stA.ltProtocolFee), toUint256(stB.ltProtocolFee), "isolation: liquidity fee moved with the liquidity mark");
    }
}
