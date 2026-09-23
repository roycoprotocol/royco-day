// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/accountant/IRoycoDayAccountant.sol";
import { IRoycoDayFixedRateAccountant } from "../../../src/interfaces/accountant/IRoycoDayFixedRateAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FixedRateAccountantFuzzTestBase } from "../../utils/FixedRateAccountantFuzzTestBase.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title TestFuzz_SyncTrancheAccounting_FixedRateAccountant
 * @notice Fuzz properties for the full fixed-rate pre-op tranche accounting sync: field-for-field equality
 *         against the independent RoycoTestMath fixed mirror, wei-exact NAV conservation, the fixed-flavor
 *         FIXED_TERM fee theorem (only the coupon's senior fee can survive a locked resolution), the dual
 *         clock bookkeeping (coupon clock restamps iff the collateral NAV moved, premium clock and
 *         accumulator reset iff the excess paid), the isolation of every sync output from the liquidity
 *         provider tranche's mark, and byte-identical preview against execution on reachable states
 * @dev Every run drives a reachable market: a deposit-seeded checkpoint, a preparatory sync that initializes
 *      the accrual clocks (the production genesis pattern: the kernel pre-op syncs before every operation,
 *      so the lazy accrual initialization always happens before any measured state) and can book impermanent
 *      loss or enter a fixed term, then the measured sync from there. The single collateral asset means each
 *      sync's input is one signed collateral-NAV move, so the coupon and the excess always settle against
 *      one attribution-free waterfall
 */
contract TestFuzz_SyncTrancheAccounting_FixedRateAccountant is FixedRateAccountantFuzzTestBase {
    /**
     * Scenario: a market is seeded through real deposits, run through one preparatory PnL sync (which can
     * settle a coupon, absorb losses into the junior buffer, book IL, or flip the market into a fixed term),
     * then synced again after an arbitrary elapsed window with a fresh collateral mark and a fresh liquidity
     * mark. The measured sync's complete output - collateral and effective NAVs, IL, liquidity premium, all
     * three protocol fees, coverage utilization, market state, and term end - must equal the independently
     * derived expectation field for field, the conservation identity must hold at wei precision on
     * production's own outputs, and both persisted clocks must land exactly where the mirror's settlement
     * and payout predicates say: the coupon clock restamps iff the collateral NAV moved, and the premium
     * accumulator resets with the payment stamp iff the excess cleared the dust gate.
     */
    function testFuzz_Sync_MatchesIndependentMirrorFieldForField(
        uint256 _stEff0,
        uint256 _jtEff0,
        uint256 _lptRaw0,
        int256 _bps1,
        uint256 _warp1,
        int256 _bps2,
        uint256 _lptRaw2,
        uint256 _warp2,
        uint256 _rate,
        uint256 _lptRate
    )
        public
    {
        _stEff0 = bound(_stEff0, 0, MAX_NAV); // full NAV range incl. the empty-tranche edge
        _jtEff0 = bound(_jtEff0, 0, MAX_NAV); // full NAV range incl. the uncovered-market edge
        _lptRaw0 = bound(_lptRaw0, 0, MAX_NAV); // full NAV range incl. the no-depth edge
        _lptRaw2 = bound(_lptRaw2, 0, MAX_NAV); // fresh liquidity mark, fully independent of the collateral move
        _bps1 = bound(_bps1, -10_000, 10_000); // -100% to +100% preparatory collateral move
        _bps2 = bound(_bps2, -10_000, 10_000); // -100% to +100% measured collateral move
        _warp1 = bound(_warp1, 0, MAX_ELAPSED); // same-block to ten years before the preparatory sync
        _warp2 = bound(_warp2, 0, MAX_ELAPSED); // same-block (instantaneous premium branch) to ten years before the measured sync
        _rate = bound(_rate, 0, 1e10); // zero-coupon through ten times the default fixed rate, so funded, fronted, and forgiven coupons all draw
        _lptRate = bound(_lptRate, 0, WAD); // full YDM output range, the accountant caps it at the configured max

        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _defaultParams();
        p.stFixedRatePerSecondWAD = uint64(_rate);
        _deploy(p);
        lptYDM.setRates(_lptRate);
        _seedSymmetric(_stEff0, _jtEff0, _lptRaw0);

        // Preparatory sync: initialize the accrual clocks and move the collateral so the measured sync starts
        // from an asymmetric checkpoint that can carry IL or a fixed-term state, not just the pristine flat seed
        vm.warp(vm.getBlockTimestamp() + _warp1);
        uint256 collateral1 = _afterMove(_stEff0 + _jtEff0, _bps1);
        kernel.doPreOp(toNAVUnits(collateral1));
        kernel.doCommit(toNAVUnits(_lptRaw0));

        // Derive the complete expected post-sync state from the committed checkpoint BEFORE production runs
        vm.warp(vm.getBlockTimestamp() + _warp2);
        uint256 collateral2 = _afterMove(collateral1, _bps2);
        (uint256 twLPT, uint256 elapsedSincePayment) = _premiumWindow(_lptRate);
        RoycoTestMath.FixedSyncInputs memory in_ = _fixedMirrorInput(collateral2, _lptRaw2, twLPT, elapsedSincePayment, _lptRate);
        RoycoTestMath.FixedSyncOutputs memory out = RoycoTestMath.syncFixedRateTrancheAccounting(in_);
        uint256 couponClockBefore = _couponWindowStart();
        uint256 paymentClockBefore = accountant.getRoycoDayFixedRateAccountantState().lastPremiumPaymentTimestamp;

        SyncedAccountingState memory st = kernel.doPreOp(toNAVUnits(collateral2));
        kernel.doCommit(toNAVUnits(_lptRaw2));

        // Field-for-field equality with the independent mirror
        assertEq(toUint256(st.collateralNAV), out.collateralNAV, "sync: collateral NAV");
        assertEq(toUint256(st.stEffectiveNAV), out.stEffectiveNAV, "sync: senior effective NAV");
        assertEq(toUint256(st.jtEffectiveNAV), out.jtEffectiveNAV, "sync: junior effective NAV");
        assertEq(toUint256(st.jtImpermanentLoss), out.jtImpermanentLoss, "sync: junior impermanent loss");
        assertEq(toUint256(st.lptLiquidityPremium), out.lptLiquidityPremium, "sync: liquidity premium");
        assertEq(toUint256(st.stProtocolFee), out.stProtocolFee, "sync: senior protocol fee");
        assertEq(toUint256(st.jtProtocolFee), out.jtProtocolFee, "sync: junior protocol fee");
        assertEq(toUint256(st.lptProtocolFee), out.lptProtocolFee, "sync: liquidity protocol fee");
        assertEq(st.coverageUtilizationWAD, out.coverageUtilizationWAD, "sync: coverage utilization");
        assertEq(uint8(st.marketState), uint8(out.marketState), "sync: market state");
        assertEq(uint256(st.fixedTermEndTimestamp), out.fixedTermEndTimestamp, "sync: fixed-term end");
        // The pre-op return carries a zero liquidity placeholder: the kernel commits the fresh mark afterwards
        assertEq(st.liquidityUtilizationWAD, 0, "sync: pre-op liquidity utilization placeholder");

        // Conservation at wei precision on production's own outputs: the collateral pool is exactly the sum
        // of the tranche effective NAVs after every sync, coupon fronting and forgiveness included
        assertEq(collateral2, toUint256(st.stEffectiveNAV) + toUint256(st.jtEffectiveNAV), "sync: collateral and effective NAVs conserve exactly");

        // State-machine biconditional on production's own outputs: every PERPETUAL commit erases the IL ledger
        // and FIXED_TERM always carries a live drawdown, so the resolved state and the IL are one predicate
        assertEq(
            uint8(st.marketState) == uint8(RoycoTestMath.MarketState.PERPETUAL),
            toUint256(st.jtImpermanentLoss) == 0,
            "sync: marketState == PERPETUAL iff jtImpermanentLoss == 0"
        );
        // The fixed-flavor fee theorem on production's own outputs: a FIXED_TERM resolution means the coupon
        // outran the gain, so no excess survives to pay a premium or the junior/liquidity fees, but the
        // coupon's senior fee CAN accrue: the coupon is earned even when fully fronted from the buffer
        if (uint8(st.marketState) == uint8(RoycoTestMath.MarketState.FIXED_TERM)) {
            assertEq(toUint256(st.lptLiquidityPremium), 0, "sync: no liquidity premium on a FIXED_TERM resolution");
            assertEq(toUint256(st.jtProtocolFee), 0, "sync: no junior fee on a FIXED_TERM resolution");
            assertEq(toUint256(st.lptProtocolFee), 0, "sync: no liquidity fee on a FIXED_TERM resolution");
        }

        // The committed checkpoint equals the returned state, and the liquidity mark landed
        IRoycoDayAccountant.RoycoDayAccountantState memory sAfter = accountant.getState();
        assertEq(toUint256(sAfter.lastCollateralNAV), out.collateralNAV, "checkpoint: collateral NAV");
        assertEq(toUint256(sAfter.lastSTEffectiveNAV), out.stEffectiveNAV, "checkpoint: senior effective NAV");
        assertEq(toUint256(sAfter.lastJTEffectiveNAV), out.jtEffectiveNAV, "checkpoint: junior effective NAV");
        assertEq(toUint256(sAfter.lastJTImpermanentLoss), out.jtImpermanentLoss, "checkpoint: junior impermanent loss");
        assertEq(toUint256(sAfter.lastLPTRawNAV), _lptRaw2, "checkpoint: committed liquidity mark");
        assertEq(uint8(sAfter.lastMarketState), uint8(out.marketState), "checkpoint: market state");
        assertEq(uint256(sAfter.fixedTermEndTimestamp), out.fixedTermEndTimestamp, "checkpoint: fixed-term end");

        // Dual clock bookkeeping: the coupon clock restamps iff the collateral NAV moved (forgiveness never
        // carries a shortfall into the next window), and the premium accumulator resets with the payment stamp
        // iff the excess cleared the dust gate
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory sFixedAfter = accountant.getRoycoDayFixedRateAccountantState();
        assertEq(
            uint256(sFixedAfter.lastCouponSettlementTimestamp),
            (out.couponSettled ? vm.getBlockTimestamp() : couponClockBefore),
            "clock: the coupon clock restamps exactly on settling syncs"
        );
        if (out.premiumsPaid) {
            assertEq(uint256(sFixedAfter.twLPTYieldShareAccruedWAD), 0, "clock: a paid premium resets the accumulator");
            assertEq(uint256(sFixedAfter.lastPremiumPaymentTimestamp), vm.getBlockTimestamp(), "clock: a paid premium stamps the payment clock");
        } else {
            assertEq(uint256(sFixedAfter.twLPTYieldShareAccruedWAD), twLPT, "clock: an unpaid window keeps the accrued accumulator");
            assertEq(uint256(sFixedAfter.lastPremiumPaymentTimestamp), paymentClockBefore, "clock: an unpaid window keeps the payment clock");
        }
    }

    /**
     * Scenario: two copies of the same market state at the same instant, differing ONLY in the liquidity
     * tranche's committed mark, are put through the identical collateral sync. The liquidity provider tranche
     * is an overlay: its mark drives only the YDM's utilization argument (pinned by the mock here), so every
     * sync output - effective NAVs, impermanent loss, the coupon leg folded into the senior NAV, coverage
     * utilization, market state, premium, fees, and the coupon clock - must be identical across the two
     * copies. If perturbing the pool mark could move the tranche accounting, a swap against the pool could
     * re-price the tranches or the coupon.
     */
    function testFuzz_Sync_LiquidityMarkNeverMovesSeniorOrJuniorAccounting(
        uint256 _stEff0,
        uint256 _jtEff0,
        uint256 _lptRawA,
        uint256 _lptRawB,
        int256 _bps,
        uint256 _warp,
        uint256 _rate,
        uint256 _lptRate
    )
        public
    {
        _stEff0 = bound(_stEff0, 0, MAX_NAV); // full NAV range incl. the empty-tranche edge
        _jtEff0 = bound(_jtEff0, 0, MAX_NAV); // full NAV range incl. the uncovered-market edge
        _lptRawA = bound(_lptRawA, 0, MAX_NAV); // first liquidity mark incl. the no-depth edge
        _lptRawB = bound(_lptRawB, 0, MAX_NAV); // perturbed liquidity mark, unconstrained relative to the first
        _bps = bound(_bps, -10_000, 10_000); // -100% to +100% collateral move
        _warp = bound(_warp, 0, MAX_ELAPSED); // same-block (instantaneous premium branch, the direct lastLPTRawNAV read) to ten years
        _rate = bound(_rate, 0, 1e10); // zero-coupon through ten times the default fixed rate
        _lptRate = bound(_lptRate, 0, WAD); // full YDM output range

        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _defaultParams();
        p.stFixedRatePerSecondWAD = uint64(_rate);
        _deploy(p);
        lptYDM.setRates(_lptRate);
        _seedSymmetric(_stEff0, _jtEff0, _lptRawA);

        vm.warp(vm.getBlockTimestamp() + _warp);
        uint256 collateral1 = _afterMove(_stEff0 + _jtEff0, _bps);

        // Copy A: sync against the seeded liquidity mark
        uint256 snapshotId = vm.snapshotState();
        SyncedAccountingState memory stA = kernel.doPreOp(toNAVUnits(collateral1));
        uint256 couponClockA = _couponWindowStart();

        // Copy B: identical state and instant, but the liquidity mark is re-committed to the perturbed value first
        vm.revertToState(snapshotId);
        kernel.doCommit(toNAVUnits(_lptRawB));
        SyncedAccountingState memory stB = kernel.doPreOp(toNAVUnits(collateral1));

        assertEq(toUint256(stA.stEffectiveNAV), toUint256(stB.stEffectiveNAV), "isolation: senior effective NAV moved with the liquidity mark");
        assertEq(toUint256(stA.jtEffectiveNAV), toUint256(stB.jtEffectiveNAV), "isolation: junior effective NAV moved with the liquidity mark");
        assertEq(toUint256(stA.jtImpermanentLoss), toUint256(stB.jtImpermanentLoss), "isolation: impermanent loss moved with the liquidity mark");
        assertEq(stA.coverageUtilizationWAD, stB.coverageUtilizationWAD, "isolation: coverage utilization moved with the liquidity mark");
        assertEq(uint8(stA.marketState), uint8(stB.marketState), "isolation: market state moved with the liquidity mark");
        assertEq(uint256(stA.fixedTermEndTimestamp), uint256(stB.fixedTermEndTimestamp), "isolation: fixed-term end moved with the liquidity mark");
        assertEq(toUint256(stA.lptLiquidityPremium), toUint256(stB.lptLiquidityPremium), "isolation: liquidity premium moved with the liquidity mark");
        assertEq(toUint256(stA.stProtocolFee), toUint256(stB.stProtocolFee), "isolation: senior fee moved with the liquidity mark");
        assertEq(toUint256(stA.jtProtocolFee), toUint256(stB.jtProtocolFee), "isolation: junior fee moved with the liquidity mark");
        assertEq(toUint256(stA.lptProtocolFee), toUint256(stB.lptProtocolFee), "isolation: liquidity fee moved with the liquidity mark");
        assertEq(couponClockA, _couponWindowStart(), "isolation: the coupon clock moved with the liquidity mark");

        // The state-machine biconditional holds on this sync surface too (the copies are asserted identical above)
        assertEq(
            uint8(stA.marketState) == uint8(RoycoTestMath.MarketState.PERPETUAL),
            toUint256(stA.jtImpermanentLoss) == 0,
            "isolation: marketState == PERPETUAL iff jtImpermanentLoss == 0"
        );
    }

    /**
     * Scenario: any operation's quote and its execution must price identically. For random reachable states
     * (the accrual clocks initialized by the preparatory sync, matching every production market after its
     * genesis pre-op), the preview taken immediately before the pre-op sync in the same block must equal the
     * executed sync byte for byte, across the settlement predicate, the coupon window, the premium branch
     * selection, and the state machine. A second same-block pair after the first execution pins the
     * spent-window and instantaneous-branch parity as well.
     */
    function testFuzz_Sync_PreviewMatchesExecuteOnReachableStates(
        uint256 _stEff0,
        uint256 _jtEff0,
        uint256 _lptRaw0,
        int256 _bps1,
        uint256 _warp1,
        int256 _bps2,
        uint256 _warp2,
        int256 _bps3,
        uint256 _rate,
        uint256 _lptRate
    )
        public
    {
        _stEff0 = bound(_stEff0, 0, MAX_NAV); // full NAV range incl. the empty-tranche edge
        _jtEff0 = bound(_jtEff0, 0, MAX_NAV); // full NAV range incl. the uncovered-market edge
        _lptRaw0 = bound(_lptRaw0, 0, MAX_NAV); // full NAV range incl. the no-depth edge
        _bps1 = bound(_bps1, -10_000, 10_000); // -100% to +100% preparatory collateral move
        _bps2 = bound(_bps2, -10_000, 10_000); // -100% to +100% first measured collateral move
        _bps3 = bound(_bps3, -10_000, 10_000); // -100% to +100% same-block follow-up move (spent-window parity)
        _warp1 = bound(_warp1, 0, MAX_ELAPSED); // same-block to ten years before the preparatory sync
        _warp2 = bound(_warp2, 0, MAX_ELAPSED); // same-block to ten years before the measured pair
        _rate = bound(_rate, 0, 1e10); // zero-coupon through ten times the default fixed rate
        _lptRate = bound(_lptRate, 0, WAD); // full YDM output range, pinned identically for preview and execution

        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _defaultParams();
        p.stFixedRatePerSecondWAD = uint64(_rate);
        _deploy(p);
        // The mock honors the preview contract: the mutating and view yield share reads return the same pinned rate
        lptYDM.setRates(_lptRate);
        _seedSymmetric(_stEff0, _jtEff0, _lptRaw0);

        // Preparatory sync: initialize the accrual clocks, the production genesis pattern (the kernel pre-op
        // syncs before every operation, so no reachable market quotes against uninitialized clocks)
        vm.warp(vm.getBlockTimestamp() + _warp1);
        uint256 collateral1 = _afterMove(_stEff0 + _jtEff0, _bps1);
        kernel.doPreOp(toNAVUnits(collateral1));
        kernel.doCommit(toNAVUnits(_lptRaw0));

        // First pair: quote then execute in the same block
        vm.warp(vm.getBlockTimestamp() + _warp2);
        uint256 collateral2 = _afterMove(collateral1, _bps2);
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(collateral2));
        SyncedAccountingState memory executed = kernel.doPreOp(toNAVUnits(collateral2));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(executed)), "preview: the quote diverged from the execution");

        // Second pair in the very same block: the spent coupon window and a potentially just-reset premium
        // window (the instantaneous branch) must quote identically too
        uint256 collateral3 = _afterMove(collateral2, _bps3);
        previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(collateral3));
        executed = kernel.doPreOp(toNAVUnits(collateral3));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(executed)), "preview: the same-block follow-up quote diverged from the execution");
    }
}
