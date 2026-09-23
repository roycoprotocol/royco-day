// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../../lib/forge-std/src/Test.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/accountant/IRoycoDayAccountant.sol";
import { IRoycoDayFixedRateAccountant } from "../../../src/interfaces/accountant/IRoycoDayFixedRateAccountant.sol";
import { WAD, ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FixedRateAccountantTestBase } from "../../utils/FixedRateAccountantTestBase.sol";

/**
 * @title Test_SyncTrancheAccounting_FixedRateAccountant
 * @notice The fixed rate coupon waterfall's core sync vectors: gain above/at/below the coupon, the flat no-op,
 *         junior-first losses with the coupon fronted from the remaining buffer, the buffer-exhausting wipe,
 *         recovery ordering out of a large IL, the capped-rate (disabled JT) mode, the dust gates on the coupon
 *         and the excess, and coupon forgiveness across settlement windows: every scenario asserted against a
 *         hand-derived literal, the committed checkpoint, NAV conservation, the il > 0 iff FIXED_TERM
 *         biconditional, and preview == execution byte equality at once
 * @dev Every vector seeds in the deploy block (zero elapsed so seeding syncs settle a zero coupon) then warps
 *      +100 seconds, so the settled coupon is exactly _specCoupon(1000e18, 1e9, 100) = 1e14 on the default seed
 * @dev The mock YDM's mutating and preview rates are always matched, since the executed accrual reads yieldShare
 *      and the preview accrual reads previewYieldShare over the same elapsed window
 */
contract Test_SyncTrancheAccounting_FixedRateAccountant is FixedRateAccountantTestBase {
    /// @dev The coupon settled by every default-seed vector: 1000e18 * 1e9 * 100 / 1e18 = 1e14 exactly
    uint256 internal constant COUPON_100S = 1e14;

    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(_defaultParams());
    }

    /// @dev Fully hand-derived expectation for one sync vector, asserted field-by-field by _runSyncVector
    struct ExpectedSync {
        uint256 stEffectiveNAV;
        uint256 jtEffectiveNAV;
        uint256 il;
        uint256 lptPrem;
        uint256 stFee;
        uint256 jtFee;
        uint256 lptFee;
        bool premiumsPaid;
        MarketState marketState;
        uint32 fixedTermEndTimestamp;
    }

    /**
     * @dev Scenario runner: previews then executes the identical sync, asserts preview == execution
     * byte-for-byte (the one allowed both-sides-production assertion), asserts every returned field against the
     * hand-derived expectation, then re-reads the committed checkpoint and asserts exact NAV conservation plus
     * returned-vs-persisted equality and the il > 0 iff FIXED_TERM biconditional
     *
     * Also asserts the two fixed-flavor clocks: the coupon settlement timestamp restamps exactly when the sync
     * observed a collateral NAV movement, and the premiumsPaid side effects (accumulator reset plus premium
     * payment stamp) land iff the pre-carve excess cleared the dust gate
     */
    function _runSyncVector(uint256 _collateralNew, ExpectedSync memory _e) internal {
        IRoycoDayAccountant.RoycoDayAccountantState memory pre = accountant.getState();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory preFixed = accountant.getRoycoDayFixedRateAccountantState();
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(_collateralNew));
        // The committed sync must return the exact hand-derived resulting state (the sync event lives on the kernel,
        // which is mocked here, so the state pin binds to the accountant's return value)
        SyncedAccountingState memory executed = kernel.doPreOp(toNAVUnits(_collateralNew));
        assertEq(
            keccak256(abi.encode(executed)),
            keccak256(abi.encode(_expectedSyncedState(pre, _collateralNew, _e))),
            "vector: executed state must match the hand-derived state exactly"
        );
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(executed)), "vector: preview must match execution exactly");

        assertEq(uint8(executed.marketState), uint8(_e.marketState), "vector: market state");
        assertEq(toUint256(executed.collateralNAV), _collateralNew, "vector: collateral NAV passthrough");
        assertEq(toUint256(executed.lptRawNAV), 0, "vector: lt raw NAV placeholder");
        assertEq(toUint256(executed.stEffectiveNAV), _e.stEffectiveNAV, "vector: st effective NAV");
        assertEq(toUint256(executed.jtEffectiveNAV), _e.jtEffectiveNAV, "vector: jt effective NAV");
        assertEq(toUint256(executed.jtImpermanentLoss), _e.il, "vector: jt impermanent loss");
        assertEq(toUint256(executed.lptLiquidityPremium), _e.lptPrem, "vector: lt liquidity premium");
        assertEq(toUint256(executed.stProtocolFee), _e.stFee, "vector: st protocol fee");
        assertEq(toUint256(executed.jtProtocolFee), _e.jtFee, "vector: jt protocol fee");
        assertEq(toUint256(executed.lptProtocolFee), _e.lptFee, "vector: lt protocol fee");
        assertEq(
            executed.coverageUtilizationWAD, _specCoverageUtilization(_collateralNew, pre.minCoverageWAD, _e.jtEffectiveNAV), "vector: coverage utilization"
        );
        assertEq(executed.liquidityUtilizationWAD, 0, "vector: liquidity utilization placeholder");
        assertEq(executed.fixedTermEndTimestamp, _e.fixedTermEndTimestamp, "vector: fixed term end timestamp");

        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastCollateralNAV), toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), "vector: committed NAV conservation");
        assertEq(toUint256(s.lastSTEffectiveNAV), _e.stEffectiveNAV, "vector: committed st effective NAV");
        assertEq(toUint256(s.lastJTEffectiveNAV), _e.jtEffectiveNAV, "vector: committed jt effective NAV");
        assertEq(toUint256(s.lastJTImpermanentLoss), _e.il, "vector: committed il");
        assertEq(uint8(s.lastMarketState), uint8(_e.marketState), "vector: committed market state");
        assertEq(s.fixedTermEndTimestamp, _e.fixedTermEndTimestamp, "vector: committed fixed term end");
        // The state-machine biconditional: a perpetual commit never carries a drawdown and a term always does
        assertEq(s.lastMarketState == MarketState.PERPETUAL, toUint256(s.lastJTImpermanentLoss) == 0, "vector: il > 0 iff FIXED_TERM");

        // The settlement predicate: only a NAV movement settles the coupon and restamps the accrual window's clock,
        // a flat sync leaves the window running so no coupon is double-collected and none is skipped
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory postFixed = accountant.getRoycoDayFixedRateAccountantState();
        bool settled = _collateralNew != toUint256(pre.lastCollateralNAV);
        assertEq(
            uint256(postFixed.lastCouponSettlementTimestamp),
            settled ? vm.getBlockTimestamp() : preFixed.lastCouponSettlementTimestamp,
            "vector: coupon settlement clock"
        );

        // premiumsPaid side effects: reset the accumulator and stamp the payment timestamp, otherwise the
        // post-accrual accumulator persists and the payment window keeps running
        if (_e.premiumsPaid) {
            assertEq(uint256(postFixed.twLPTYieldShareAccruedWAD), 0, "vector: lt accumulator reset on premium payment");
            assertEq(uint256(postFixed.lastPremiumPaymentTimestamp), vm.getBlockTimestamp(), "vector: premium payment stamped");
        } else {
            assertEq(uint256(postFixed.twLPTYieldShareAccruedWAD), _expectedAccruedTW(preFixed), "vector: lt accumulator persists unpaid");
            assertEq(uint256(postFixed.lastPremiumPaymentTimestamp), preFixed.lastPremiumPaymentTimestamp, "vector: premium payment stamp unchanged");
        }
    }

    /**
     * @dev Assembles the full SyncedAccountingState the sync must return, from the hand-derived expectation plus
     * the pre-sync config fields. The lt raw NAV and liquidity utilization are zero placeholders on the pre-op
     * path (the kernel commits the fresh LPT mark after the sync)
     */
    function _expectedSyncedState(
        IRoycoDayAccountant.RoycoDayAccountantState memory _pre,
        uint256 _collateralNew,
        ExpectedSync memory _e
    )
        internal
        pure
        returns (SyncedAccountingState memory st)
    {
        st.marketState = _e.marketState;
        st.collateralNAV = toNAVUnits(_collateralNew);
        st.lptRawNAV = ZERO_NAV_UNITS;
        st.stEffectiveNAV = toNAVUnits(_e.stEffectiveNAV);
        st.jtEffectiveNAV = toNAVUnits(_e.jtEffectiveNAV);
        st.jtImpermanentLoss = toNAVUnits(_e.il);
        st.lptLiquidityPremium = toNAVUnits(_e.lptPrem);
        st.stProtocolFee = toNAVUnits(_e.stFee);
        st.jtProtocolFee = toNAVUnits(_e.jtFee);
        st.lptProtocolFee = toNAVUnits(_e.lptFee);
        st.coverageUtilizationWAD = _specCoverageUtilization(_collateralNew, _pre.minCoverageWAD, _e.jtEffectiveNAV);
        st.liquidityUtilizationWAD = 0;
        st.fixedTermEndTimestamp = _e.fixedTermEndTimestamp;
        st.minCoverageWAD = _pre.minCoverageWAD;
        st.coverageLiquidationUtilizationWAD = _pre.coverageLiquidationUtilizationWAD;
        st.minLiquidityWAD = _pre.minLiquidityWAD;
    }

    /**
     * @dev Test-side accrual mirror for the unpaid branch: the stored accumulator plus one capped mutating-rate
     * window, exactly what _accrueLPTYieldShare adds before the waterfall consumes it
     */
    function _expectedAccruedTW(IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory _preFixed) internal view returns (uint256 tw) {
        tw = _preFixed.twLPTYieldShareAccruedWAD;
        if (_preFixed.lastYieldShareAccrualTimestamp != 0 && vm.getBlockTimestamp() > _preFixed.lastYieldShareAccrualTimestamp) {
            uint256 rate = lptYDM.yieldShareReturn();
            if (rate > _preFixed.maxLPTYieldShareWAD) rate = _preFixed.maxLPTYieldShareWAD;
            tw += rate * (vm.getBlockTimestamp() - _preFixed.lastYieldShareAccrualTimestamp);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                            REGIME SEED HELPERS
    //////////////////////////////////////////////////////////////////////*/

    /// @dev No-IL regime seed with the mutating rate matched to the preview rate, so the executed tw accrual over
    /// the warp equals the previewed one: 0.05e18 per second, capped by maxLPT 0.1e18 so the cap is inert
    function _seedNoILMatchedRates() internal {
        _seedNoIL();
        lptYDM.setRates(0.05e18);
    }

    /// @dev Large-IL regime seed with matched rates (the seeding loss sync already initialized the accrual clock)
    function _seedLargeILMatchedRates() internal {
        _seedLargeIL();
        lptYDM.setRates(0.05e18);
    }

    /// @dev Capped-rate (disabled JT) regime: maxLPT = WAD and a 100% yield share so the whole excess is the
    /// liquidity premium, seeded with zero junior capital and the accrual clock initialized in the deploy block
    function _seedCappedRateMode() internal {
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _defaultParams();
        p.maxLPTYieldShareWAD = uint64(WAD);
        _deploy(p);
        _seedState(1000e18, 0, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(uint256(1000e18)));
        lptYDM.setRates(1e18);
    }

    /// @dev Dust-gate regime: dust tolerance exactly one 100-second coupon over the default flat seed
    function _seedCouponSizedDust() internal {
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _defaultParams();
        p.standardParams.dustTolerance = toNAVUnits(COUPON_100S);
        _deploy(p);
        _seedAndInitAccrual();
        lptYDM.setRates(0.05e18);
    }

    /// @dev Forgiveness regime: a 5e13 sliver of junior capital under a 1e14 coupon, so one window's coupon
    /// overruns the gain plus the whole buffer and the overrun must be forgiven
    function _seedSliverJT() internal {
        _seedState(1000e18, 5e13, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(uint256(1000e18 + 5e13)));
        lptYDM.setRates(0.05e18);
    }

    /*----------------------------------------------------------------------
                GAIN VECTORS — checkpoint 1200e18, coupon 1e14
    ----------------------------------------------------------------------*/

    /*
     * Checkpoint collateral 1200e18, stEffectiveNAV 1000e18, jtEffectiveNAV 200e18, il 0, zero dust, PERPETUAL.
     * After the +100s warp the coupon due on a settling sync is 1000e18 * 1e9 * 100 / 1e18 = 1e14 exactly.
     * With matched rates 0.05e18 the executed accrual is tw = 0.05e18 * 100 = 5e18 over a 100 second premium
     * window, so the LPT slice of any excess is excess * 5e18 / (100 * 1e18) = excess / 20.
     */

    /**
     * Sync scenario (gain 20e18 > coupon): coupon off the top, LPT slice carved from the excess, JT keeps the complement
     * Derivation: coupon = 1e14 from the gain (stFee = floor(1e14 * 0.1) = 1e13), excess = 20e18 - 1e14 =
     * 19999900000000000000 > dust 0 so premiumsPaid. tw slice = floor(19999900000000000000 * 5e18 / 100e18) =
     * 999995000000000000 (exact division), lptFee = 99999500000000000. JT complement = 19999900000000000000 -
     * 999995000000000000 = 18999905000000000000, jtFee = 1899990500000000000.
     * stEffectiveNAV = 1000e18 + 1e14 + 999995000000000000, jtEffectiveNAV = 200e18 + 18999905000000000000,
     * conservation: their sum is 1220e18 exactly. il 0 keeps PERPETUAL, accumulator resets and the stamp lands
     */
    function test_Sync_GainAboveCoupon_ExcessDistributed() public {
        _seedNoILMatchedRates();
        vm.warp(vm.getBlockTimestamp() + 100);
        // Literal anchor for the independent coupon helper: the default rate over 100 seconds on 1000e18 is 1e14
        assertEq(_specCoupon(SEED_ST_EFF, DEFAULT_ST_FIXED_RATE_PER_SECOND_WAD, 100), COUPON_100S, "anchor: coupon expectation");
        _runSyncVector(
            1220e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 1e14 + 999_995_000_000_000_000,
                jtEffectiveNAV: 200e18 + 18_999_905_000_000_000_000,
                il: 0,
                lptPrem: 999_995_000_000_000_000,
                stFee: 1e13,
                jtFee: 1_899_990_500_000_000_000,
                lptFee: 99_999_500_000_000_000,
                premiumsPaid: true,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (gain == coupon exactly): the gain is consumed whole by the coupon, no excess exists
     * Derivation: gain = 1e14 = coupon due, couponFromGain = 1e14, couponFromJT = 0, stFee = 1e13.
     * stEffectiveNAV = 1000e18 + 1e14, jtEffectiveNAV = 200e18 flat, no premium, no jt/lpt fees, premiumsPaid
     * false so the accrued tw 5e18 persists and the premium stamp holds. il 0 keeps PERPETUAL
     */
    function test_Sync_GainEqualsCoupon_NoExcess() public {
        _seedNoILMatchedRates();
        vm.warp(vm.getBlockTimestamp() + 100);
        _runSyncVector(
            1200e18 + 1e14,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 1e14,
                jtEffectiveNAV: 200e18,
                il: 0,
                lptPrem: 0,
                stFee: 1e13,
                jtFee: 0,
                lptFee: 0,
                premiumsPaid: false,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (gain 4e13 < coupon): the shortfall is fronted from JT, booked as IL, and locks the market
     * Derivation: couponFromGain = 4e13, couponFromJT = min(1e14 - 4e13, 200e18) = 6e13, couponPaid = 1e14,
     * stFee = 1e13. stEffectiveNAV = 1000e18 + 1e14, jtEffectiveNAV = 200e18 - 6e13, il = 6e13.
     * il 6e13 > dust 0 locks FIXED_TERM (end = now + duration): coupon drag alone opens the observation window
     */
    function test_Sync_GainBelowCoupon_ShortfallFrontedLocksFixedTerm() public {
        _seedNoILMatchedRates();
        vm.warp(vm.getBlockTimestamp() + 100);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermCommenced(uint32(vm.getBlockTimestamp() + DEFAULT_FIXED_TERM_DURATION_SECONDS));
        _runSyncVector(
            1200e18 + 4e13,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 1e14,
                jtEffectiveNAV: 200e18 - 6e13,
                il: 6e13,
                lptPrem: 0,
                stFee: 1e13,
                jtFee: 0,
                lptFee: 0,
                premiumsPaid: false,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(vm.getBlockTimestamp() + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /*----------------------------------------------------------------------
                FLAT VECTORS — the settlement predicate
    ----------------------------------------------------------------------*/

    /**
     * Sync scenario (flat NAV after +100s): a flat pre-op settles nothing, no coupon, no fees, clock untouched
     * Derivation: _collateralNAV == lastCollateralNAV so stCouponDue = 0 by the settlement predicate, the
     * waterfall never runs: every NAV field re-commits the checkpoint and the coupon window keeps accruing
     * (the runner asserts the settlement clock did not restamp)
     */
    function test_Sync_FlatNAV_NothingSettles() public {
        _seedNoILMatchedRates();
        vm.warp(vm.getBlockTimestamp() + 100);
        _runSyncVector(
            1200e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 200e18,
                il: 0,
                lptPrem: 0,
                stFee: 0,
                jtFee: 0,
                lptFee: 0,
                premiumsPaid: false,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (flat sync mid-window, then a settling gain): the window accrues across the flat sync
     * Derivation: the flat sync at +100 settles nothing and leaves the clock at the seed block, so the settling
     * sync at +200 owes the full 200 second coupon = 1000e18 * 1e9 * 200 / 1e18 = 2e14. A gain of exactly 2e14
     * is consumed whole by it: stEffectiveNAV = 1000e18 + 2e14, stFee = floor(2e14 * 0.1) = 2e13, JT flat.
     * The accrued tw persists at 0.05e18 * 200 = 10e18 since no excess cleared the dust gate
     */
    function test_Sync_FlatSyncKeepsWindowAccruing() public {
        _seedNoILMatchedRates();
        vm.warp(vm.getBlockTimestamp() + 100);
        kernel.doPreOp(toNAVUnits(uint256(1200e18)));
        vm.warp(vm.getBlockTimestamp() + 100);
        assertEq(_specCoupon(SEED_ST_EFF, DEFAULT_ST_FIXED_RATE_PER_SECOND_WAD, 200), 2e14, "anchor: 200 second coupon expectation");
        _runSyncVector(
            1200e18 + 2e14,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 2e14,
                jtEffectiveNAV: 200e18,
                il: 0,
                lptPrem: 0,
                stFee: 2e13,
                jtFee: 0,
                lptFee: 0,
                premiumsPaid: false,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /*----------------------------------------------------------------------
                LOSS VECTORS — junior-first, then the coupon fronted
    ----------------------------------------------------------------------*/

    /**
     * Sync scenario (loss 50e18, covered): the loss lands junior-first as IL, then the coupon is fronted from
     * what remains of the buffer and booked as IL too
     * Derivation: loss 50e18 <= jt buffer 200e18 so jtEffectiveNAV drops to 150e18 with il = 50e18 and
     * stEffectiveNAV untouched by the loss. Coupon then fronted: couponPaid = min(1e14, 150e18) = 1e14,
     * stFee = 1e13, jtEffectiveNAV = 150e18 - 1e14, il = 50e18 + 1e14, stEffectiveNAV = 1000e18 + 1e14
     * (checkpoint + coupon). Total IL = loss + coupon since the buffer covers both. FIXED_TERM entry
     */
    function test_Sync_Loss_JuniorFirstThenCouponFronted() public {
        _seedNoILMatchedRates();
        vm.warp(vm.getBlockTimestamp() + 100);
        _runSyncVector(
            1150e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 1e14,
                jtEffectiveNAV: 150e18 - 1e14,
                il: 50e18 + 1e14,
                lptPrem: 0,
                stFee: 1e13,
                jtFee: 0,
                lptFee: 0,
                premiumsPaid: false,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(vm.getBlockTimestamp() + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (loss leaving a 5e13 sliver of buffer): the coupon collects the remaining buffer only, the
     * rest is forgiven, and the resulting wipe forces PERPETUAL with the IL erased
     * Derivation: loss = 200e18 - 5e13, absorbed junior-first in full: jtEffectiveNAV = 5e13,
     * il = 200e18 - 5e13, stEffectiveNAV unchanged. Coupon fronted: couponPaid = min(1e14, 5e13) = 5e13
     * (half the 1e14 due, the unfunded half is forgiven), stFee = floor(5e13 * 0.1) = 5e12,
     * jtEffectiveNAV = 0, il = 200e18, stEffectiveNAV = 1000e18 + 5e13.
     * jtEffectiveNAV == 0 forces the perpetual commit: il 200e18 erased (reset event), end cleared
     */
    function test_Sync_LossLeavesSliverBuffer_CouponCappedByBufferThenWipe() public {
        _seedNoILMatchedRates();
        vm.warp(vm.getBlockTimestamp() + 100);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(200e18)));
        _runSyncVector(
            1000e18 + 5e13,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 5e13,
                jtEffectiveNAV: 0,
                il: 0,
                lptPrem: 0,
                stFee: 5e12,
                jtFee: 0,
                lptFee: 0,
                premiumsPaid: false,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (loss 300e18 exhausting the buffer): the residual loss lands on ST, the coupon is fully
     * forgiven, and the wipe forces PERPETUAL with the IL erased
     * Derivation: loss 300e18 > jt buffer 200e18: jtEffectiveNAV = 0 with il = 200e18, residual 100e18 hits
     * ST so stEffectiveNAV = 900e18. Coupon: couponPaid = min(1e14, 0) = 0, nothing collected, no stFee,
     * the whole 1e14 is forgiven (the clock still restamps, pinned by the forgiveness vector below).
     * jtEffectiveNAV == 0 forces the perpetual commit: il 200e18 erased (reset event), end cleared
     */
    function test_Sync_LossExhaustsBuffer_ResidualToSeniorCouponForgiven() public {
        _seedNoILMatchedRates();
        vm.warp(vm.getBlockTimestamp() + 100);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(200e18)));
        _runSyncVector(
            900e18,
            ExpectedSync({
                stEffectiveNAV: 900e18,
                jtEffectiveNAV: 0,
                il: 0,
                lptPrem: 0,
                stFee: 0,
                jtFee: 0,
                lptFee: 0,
                premiumsPaid: false,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /*----------------------------------------------------------------------
                RECOVERY VECTORS — LOSS > COUPON > RESTORATION > EXCESS
    ----------------------------------------------------------------------*/

    /*
     * Checkpoint collateral 1200e18, stEffectiveNAV 1000e18, jtEffectiveNAV 200e18, il 100e18, zero dust,
     * FIXED_TERM with the end stamped in the seed block. The gain waterfall settles the coupon first, then
     * repays the IL, then distributes the excess, so the fee legs pin the ordering numerically: the senior fee
     * bases on the coupon alone, the restoration is never fee'd, and the jt/lpt fees base on the excess alone.
     */

    /**
     * Sync scenario (gain 60e18, large IL, partial recovery): coupon before restoration, no excess reached
     * Derivation: couponFromGain = 1e14 (stFee = 1e13), remaining gain = 60e18 - 1e14 = 59999900000000000000
     * repays IL: il = 100e18 - 59999900000000000000 = 40e18 + 1e14, jtEffectiveNAV = 200e18 +
     * 59999900000000000000, stEffectiveNAV = 1000e18 + 1e14, gain exhausted so no excess and no premium.
     * il stays above dust: FIXED_TERM persists with the ORIGINAL end (never restamped mid-term)
     */
    function test_Sync_LargeIL_PartialRecovery_CouponBeforeRestoration() public {
        _seedLargeILMatchedRates();
        uint32 end0 = accountant.getState().fixedTermEndTimestamp;
        vm.warp(vm.getBlockTimestamp() + 100);
        _runSyncVector(
            1260e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 1e14,
                jtEffectiveNAV: 200e18 + 59_999_900_000_000_000_000,
                il: 40e18 + 1e14,
                lptPrem: 0,
                stFee: 1e13,
                jtFee: 0,
                lptFee: 0,
                premiumsPaid: false,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: end0
            })
        );
    }

    /**
     * Sync scenario (gain 110e18, large IL, full recovery): the gain splits exactly coupon + IL + excess, the
     * priority ordering pinned numerically by the fee bases
     * Derivation: gain 110e18 = coupon 1e14 + IL repayment 100e18 + excess 9999900000000000000.
     * Coupon first: stFee = 1e13, stEffectiveNAV = 1000e18 + 1e14. Restoration next, never fee'd: il = 0,
     * jtEffectiveNAV = 300e18. Excess last: premiumsPaid, tw slice = floor(9999900000000000000 * 5e18 / 100e18)
     * = 499995000000000000, lptFee = 49999500000000000, complement = 9499905000000000000,
     * jtFee = 949990500000000000. stEffectiveNAV = 1000e18 + 1e14 + 499995000000000000,
     * jtEffectiveNAV = 300e18 + 9499905000000000000, conservation: their sum is 1310e18 exactly.
     * il 0 resolves the term: PERPETUAL commit, FixedTermEnded, end cleared, accumulator resets
     */
    function test_Sync_LargeIL_FullRecovery_CouponThenRepaymentThenExcess() public {
        _seedLargeILMatchedRates();
        vm.warp(vm.getBlockTimestamp() + 100);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        _runSyncVector(
            1310e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 1e14 + 499_995_000_000_000_000,
                jtEffectiveNAV: 300e18 + 9_499_905_000_000_000_000,
                il: 0,
                lptPrem: 499_995_000_000_000_000,
                stFee: 1e13,
                jtFee: 949_990_500_000_000_000,
                lptFee: 49_999_500_000_000_000,
                premiumsPaid: true,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (gain 100e18 == il exactly, large IL): the coupon-as-IL interlock at the zero crossing.
     * The gain exactly repays ALL prior impermanent loss, then the same sync's coupon is fully fronted from
     * the restored buffer, so il touches zero mid-waterfall and re-books before the commit: the state machine
     * keys on the COMMITTED il, so the market stays FIXED_TERM with the ORIGINAL end despite full principal
     * restoration, and no term or reset event fires
     * Derivation (code order): repayment = min(100e18, 100e18) = 100e18, il -> 0, jtEffectiveNAV -> 300e18,
     * gain -> 0. couponDue = 1e14: couponFromGain = 0, couponFromJT = min(1e14, 300e18) = 1e14, stFee = 1e13.
     * stEffectiveNAV = 1000e18 + 1e14, jtEffectiveNAV = 300e18 - 1e14, il = 1e14, no excess so premiumsPaid
     * false and the 5e18 accrued window persists. Conservation: their sum is 1300e18 exactly. Committed
     * il = 1e14 > dust keeps FIXED_TERM with the seeded end unchanged.
     * Order equivalence cross-check, pinning the ruled repayment-before-coupon choice at its sharpest point:
     * coupon first would take couponFromGain = 1e14, then the remaining 100e18 - 1e14 repays il to 1e14 and
     * jtEffectiveNAV = 200e18 + (100e18 - 1e14) = 300e18 - 1e14, byte-identical outputs
     */
    function test_Sync_LargeIL_GainExactlyRepaysIL_FrontedCouponKeepsLockAndOriginalEnd() public {
        _seedLargeILMatchedRates();
        uint32 end0 = accountant.getState().fixedTermEndTimestamp;
        vm.warp(vm.getBlockTimestamp() + 100);
        vm.recordLogs();
        _runSyncVector(
            1300e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 1e14,
                jtEffectiveNAV: 300e18 - 1e14,
                il: 1e14,
                lptPrem: 0,
                stFee: 1e13,
                jtFee: 0,
                lptFee: 0,
                premiumsPaid: false,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: end0
            })
        );

        // The mid-waterfall zero crossing leaks no transition: no term event and no reset event fired
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 0, "zero crossing: no FixedTermEnded");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 0, "zero crossing: no FixedTermCommenced");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.JuniorTrancheImpermanentLossReset.selector), 0, "zero crossing: no impermanent loss reset");
        // The unpaid premium window survives the coupon-only settlement: 0.05e18 x 100 seconds accrued
        assertEq(uint256(accountant.getRoycoDayFixedRateAccountantState().twLPTYieldShareAccruedWAD), 5e18, "zero crossing: the accrued window persists");
    }

    /*----------------------------------------------------------------------
                CAPPED-RATE MODE — jtEffectiveNAV 0, maxLPT = WAD
    ----------------------------------------------------------------------*/

    /**
     * Sync scenario (gain 10e18, disabled JT): the coupon is paid from the gain only and the entire excess
     * becomes the LPT liquidity premium, added to stEffectiveNAV, with JT staying at zero
     * Derivation: checkpoint collateral 1000e18, stEffectiveNAV 1000e18, jtEffectiveNAV 0, maxLPT = WAD and a
     * 100% yield share so tw = 1e18 * 100 = 100e18 over the 100 second window. Coupon 1e14 from the gain
     * (couponFromJT = min(0, 0) = 0), stFee = 1e13. Excess = 10e18 - 1e14 = 9999900000000000000: slice =
     * floor(9999900000000000000 * 100e18 / (100 * 1e18)) = 9999900000000000000 = the whole excess, so the
     * complement is zero and no jt fee leg exists. lptFee = floor(9999900000000000000 * 0.1) =
     * 999990000000000000. stEffectiveNAV = 1000e18 + 1e14 + 9999900000000000000 = 1010e18 exact,
     * jtEffectiveNAV = 0. jtEffectiveNAV == 0 keeps the perpetual commit, coverage utilization saturates
     */
    function test_Sync_CappedRateMode_ExcessBecomesLiquidityPremium() public {
        _seedCappedRateMode();
        vm.warp(vm.getBlockTimestamp() + 100);
        _runSyncVector(
            1010e18,
            ExpectedSync({
                stEffectiveNAV: 1010e18,
                jtEffectiveNAV: 0,
                il: 0,
                lptPrem: 9_999_900_000_000_000_000,
                stFee: 1e13,
                jtFee: 0,
                lptFee: 999_990_000_000_000_000,
                premiumsPaid: true,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /*----------------------------------------------------------------------
                DUST GATES — dust tolerance 1e14 (one 100 second coupon)
    ----------------------------------------------------------------------*/

    /**
     * Sync scenario (coupon within dust): a coupon at most the dust tolerance takes no senior protocol fee
     * Derivation: dust 1e14, gain = 1e14 consumed whole by the coupon, couponPaid = 1e14 <= dust so the strict
     * > gate skips the fee: stFee = 0. stEffectiveNAV = 1000e18 + 1e14, JT flat, no excess, PERPETUAL
     */
    function test_Sync_DustGate_CouponWithinDustTakesNoSeniorFee() public {
        _seedCouponSizedDust();
        vm.warp(vm.getBlockTimestamp() + 100);
        _runSyncVector(
            1200e18 + 1e14,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 1e14,
                jtEffectiveNAV: 200e18,
                il: 0,
                lptPrem: 0,
                stFee: 0,
                jtFee: 0,
                lptFee: 0,
                premiumsPaid: false,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (excess within dust): the slice is still carved but premiumsPaid stays false, so no jt/lpt
     * fees accrue, the accumulator persists, and the premium stamp holds
     * Derivation: dust 1e14, gain = 1.5e14: coupon 1e14 (<= dust so stFee = 0), excess 5e13 <= dust so
     * premiumsPaid false. The tw slice is still carved: floor(5e13 * 5e18 / 100e18) = 2.5e12 with lptFee = 0,
     * complement 4.75e13 to JT with jtFee = 0. stEffectiveNAV = 1000e18 + 1e14 + 2.5e12,
     * jtEffectiveNAV = 200e18 + 4.75e13, conservation: their sum is 1200e18 + 1.5e14. PERPETUAL, tw 5e18 persists
     */
    function test_Sync_DustGate_ExcessWithinDustPaysNoPremiumFees() public {
        _seedCouponSizedDust();
        vm.warp(vm.getBlockTimestamp() + 100);
        _runSyncVector(
            1200e18 + 15e13,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 1e14 + 2.5e12,
                jtEffectiveNAV: 200e18 + 4.75e13,
                il: 0,
                lptPrem: 2.5e12,
                stFee: 0,
                jtFee: 0,
                lptFee: 0,
                premiumsPaid: false,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /*----------------------------------------------------------------------
                FORGIVENESS ACROSS WINDOWS
    ----------------------------------------------------------------------*/

    /**
     * Sync scenario (two windows, sliver JT): the coupon the first window could not fund never reappears
     * Window 1 derivation (checkpoint collateral 1000e18 + 5e13, stEffectiveNAV 1000e18, jtEffectiveNAV 5e13):
     * coupon due 1e14, gain 1e13: couponFromGain = 1e13, couponFromJT = min(9e13, 5e13) = 5e13, couponPaid =
     * 6e13 (> dust 0 so stFee = 6e12), forgiven = 4e13. jtEffectiveNAV = 0 with il 5e13, so the wipe forces
     * the perpetual commit and erases the IL (reset event). stEffectiveNAV = 1000e18 + 6e13.
     * Window 2 derivation: the new window's coupon bases on the fresh checkpoint and elapsed alone:
     * (1000e18 + 6e13) * 1e9 * 100 / 1e18 = 1e14 + 6e6 = 100000006000000, NOT plus the forgiven 4e13.
     * Gain 10e18: couponFromGain = 100000006000000 (couponFromJT = 0, buffer empty), stFee = 10000000600000.
     * Excess = 10e18 - 100000006000000 = 9999899999994000000 > dust so premiumsPaid: the premium window is the
     * 200 seconds since the seed, tw = 0.05e18 * 200 = 10e18 (accrued 5e18 at each sync), slice =
     * floor(9999899999994000000 * 10e18 / 200e18) = 499994999999700000 (exact division), lptFee =
     * 49999499999970000. Complement = 9499904999994300000 to the wiped JT (it still collects), jtFee =
     * 949990499999430000. stEffectiveNAV = 1000e18 + 6e13 + 100000006000000 + 499994999999700000,
     * conservation: their sum is 1010e18 + 6e13 exactly
     */
    function test_Sync_ForgivenCouponDoesNotReappearNextWindow() public {
        _seedSliverJT();
        vm.warp(vm.getBlockTimestamp() + 100);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(5e13)));
        _runSyncVector(
            1000e18 + 6e13,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 6e13,
                jtEffectiveNAV: 0,
                il: 0,
                lptPrem: 0,
                stFee: 6e12,
                jtFee: 0,
                lptFee: 0,
                premiumsPaid: false,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );

        vm.warp(vm.getBlockTimestamp() + 100);
        // Literal anchor: the fresh window owes the fresh checkpoint's 100 second coupon only
        assertEq(_specCoupon(1000e18 + 6e13, DEFAULT_ST_FIXED_RATE_PER_SECOND_WAD, 100), 100_000_006_000_000, "anchor: fresh window coupon expectation");
        _runSyncVector(
            1010e18 + 6e13,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 6e13 + 100_000_006_000_000 + 499_994_999_999_700_000,
                jtEffectiveNAV: 9_499_904_999_994_300_000,
                il: 0,
                lptPrem: 499_994_999_999_700_000,
                stFee: 10_000_000_600_000,
                jtFee: 949_990_499_999_430_000,
                lptFee: 49_999_499_999_970_000,
                premiumsPaid: true,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }
}
