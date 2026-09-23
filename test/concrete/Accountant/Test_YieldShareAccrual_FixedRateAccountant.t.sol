// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IYDM } from "../../../src/interfaces/IYDM.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/accountant/IRoycoDayAccountant.sol";
import { IRoycoDayFixedRateAccountant } from "../../../src/interfaces/accountant/IRoycoDayFixedRateAccountant.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FixedRateAccountantTestBase } from "../../utils/FixedRateAccountantTestBase.sol";

/**
 * @title Test_YieldShareAccrual_FixedRateAccountant
 * @notice The LPT-only time-weighted yield-share accrual bookkeeping: first-sync clock initialization, the
 *         same-block no-op, capped accrual, the YDM consultation arguments, the accrual event, the preview
 *         twin's purity, the premium payment window reset, unpaid-window persistence across exact-coupon
 *         settlements, and the same-block instantaneous fallback inside the excess split
 */
contract Test_YieldShareAccrual_FixedRateAccountant is FixedRateAccountantTestBase {
    function setUp() public {
        _deploy(_defaultParams());
    }

    /// the first-ever accrual initializes both timestamps, leaves the accumulator at zero, never calls the YDM, and emits no accrual event
    function test_Accrual_firstSyncInitializesTimestampsWithoutYDMCall() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        lptYDM.setYieldShareReturn(0.05e18);
        vm.warp(vm.getBlockTimestamp() + 123);
        vm.recordLogs();
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory sFixed = accountant.getRoycoDayFixedRateAccountantState();
        assertEq(sFixed.lastYieldShareAccrualTimestamp, uint32(vm.getBlockTimestamp()), "accrual timestamp initialized");
        assertEq(sFixed.lastPremiumPaymentTimestamp, uint32(vm.getBlockTimestamp()), "premium payment timestamp initialized");
        assertEq(sFixed.twLPTYieldShareAccruedWAD, 0, "lt accumulator untouched");
        assertEq(lptYDM.yieldShareCallCount(), 0, "lt ydm not consulted on first accrual");
        assertEq(
            _countAccountantLogs(vm.getRecordedLogs(), IRoycoDayFixedRateAccountant.LPTYieldShareAccrued.selector),
            0,
            "no accrual event on the lazy initialization"
        );
    }

    /**
     * the accrual adds min(yieldShare, maxLPT) * elapsed to the accumulator and emits the accrual event with exact args
     * Derivation: lt rate 0.04e18 < max 0.1e18 so raw, twLPT = 0.04e18 * 3600 = 144e18
     */
    function test_Accrual_accruesTimeWeightedShareBelowCap() public {
        _seedAndInitAccrual();
        // Snapshot the stamped clock from storage, a raw vm.getBlockTimestamp() read is unsafe across warp under via-ir timestamp caching
        uint256 t0 = accountant.getRoycoDayFixedRateAccountantState().lastPremiumPaymentTimestamp;
        lptYDM.setYieldShareReturn(0.04e18);
        vm.warp(vm.getBlockTimestamp() + 3600);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayFixedRateAccountant.LPTYieldShareAccrued(0.04e18, 144e18);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory sFixed = accountant.getRoycoDayFixedRateAccountantState();
        assertEq(sFixed.twLPTYieldShareAccruedWAD, uint128(uint256(0.04e18) * 3600), "lt accrues its raw sub-cap rate");
        assertEq(sFixed.lastYieldShareAccrualTimestamp, uint32(vm.getBlockTimestamp()), "accrual timestamp advanced");
        assertEq(sFixed.lastPremiumPaymentTimestamp, uint32(t0), "flat sync pays no premium so the payment clock holds");
    }

    /**
     * the cap binds: a YDM output above maxLPTYieldShareWAD accrues at the cap
     * Derivation: lt rate 0.5e18 > max 0.1e18 so capped, twLPT = 0.1e18 * 500 = 50e18
     */
    function test_Accrual_capBindsAboveMaxLPTYieldShare() public {
        _seedAndInitAccrual();
        lptYDM.setYieldShareReturn(0.5e18);
        vm.warp(vm.getBlockTimestamp() + 500);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayFixedRateAccountant.LPTYieldShareAccrued(0.1e18, 50e18);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        assertEq(
            accountant.getRoycoDayFixedRateAccountantState().twLPTYieldShareAccruedWAD, uint128(uint256(0.1e18) * 500), "lt rate capped at maxLPTYieldShareWAD"
        );
    }

    /// the accumulator compounds across windows when no premium is paid in between
    /// twLPT = 0.06e18 * 1000 + 0.02e18 * 250 = 65e18
    function test_Accrual_accumulatesAcrossWindowsWithoutPremiumPayment() public {
        _seedAndInitAccrual();
        lptYDM.setYieldShareReturn(0.06e18);
        vm.warp(vm.getBlockTimestamp() + 1000);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        lptYDM.setYieldShareReturn(0.02e18);
        vm.warp(vm.getBlockTimestamp() + 250);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        assertEq(
            accountant.getRoycoDayFixedRateAccountantState().twLPTYieldShareAccruedWAD,
            uint128(uint256(0.06e18) * 1000 + uint256(0.02e18) * 250),
            "lt accumulator compounds"
        );
    }

    /// a same-block re-accrual is a no-op: the YDM is not called and the accumulator, timestamp, and event stream are unchanged
    function test_Accrual_sameBlockReaccrualIsNoop() public {
        _seedAndInitAccrual();
        lptYDM.setYieldShareReturn(0.05e18);
        vm.warp(vm.getBlockTimestamp() + 1000);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        uint256 lptCalls = lptYDM.yieldShareCallCount();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory beforeFixed = accountant.getRoycoDayFixedRateAccountantState();
        vm.recordLogs();
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory afterFixed = accountant.getRoycoDayFixedRateAccountantState();
        assertEq(lptYDM.yieldShareCallCount(), lptCalls, "lt ydm not re-consulted in the same block");
        assertEq(afterFixed.twLPTYieldShareAccruedWAD, beforeFixed.twLPTYieldShareAccruedWAD, "lt accumulator unchanged");
        assertEq(afterFixed.lastYieldShareAccrualTimestamp, beforeFixed.lastYieldShareAccrualTimestamp, "accrual timestamp unchanged");
        assertEq(
            _countAccountantLogs(vm.getRecordedLogs(), IRoycoDayFixedRateAccountant.LPTYieldShareAccrued.selector),
            0,
            "no accrual event on the same-block no-op"
        );
    }

    /// the YDM is consulted with the last market state and the liquidity utilization computed from the last-committed checkpoints
    function test_Accrual_ydmCalledWithLastCheckpointArgs() public {
        _seedAndInitAccrual();
        vm.warp(vm.getBlockTimestamp() + 60);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        assertEq(lptYDM.yieldShareCallCount(), 1, "exactly one mutating consultation");
        assertEq(uint8(lptYDM.lastYieldShareMarketState()), uint8(MarketState.PERPETUAL), "lt ydm sees the last market state");
        assertEq(
            lptYDM.lastYieldShareUtilizationWAD(),
            _specLiquidityUtilization(SEED_ST_EFF, DEFAULT_MIN_LIQUIDITY_WAD, SEED_LPT_RAW),
            "lt ydm sees the checkpoint liquidity utilization"
        );
        assertEq(lptYDM.lastYieldShareUtilizationWAD(), SEED_LIQUIDITY_UTILIZATION_WAD, "checkpoint liquidity utilization is the seed constant");
    }

    /**
     * in a FIXED_TERM market the accrual passes FIXED_TERM and the committed-checkpoint liquidity utilization
     * Seed: FIXED_TERM checkpoint (collateral 1200e18, stEff 1000e18, jtEff 200e18, il 100e18, lptRaw 80e18)
     * Derivation: liquidityUtilization = ceil(1000e18 * 0.05e18 / 80e18) = 0.625e18 (exact division so ceil == floor)
     */
    function test_Accrual_ydmSeesFixedTermStateAndCheckpointUtilization() public {
        _seedState(1000e18, 200e18, 100e18, 80e18, MarketState.FIXED_TERM);
        vm.warp(vm.getBlockTimestamp() + 3600);
        kernel.doPreOp(toNAVUnits(uint256(1200e18)));
        assertEq(uint8(lptYDM.lastYieldShareMarketState()), uint8(MarketState.FIXED_TERM), "lt ydm sees FIXED_TERM");
        assertEq(
            lptYDM.lastYieldShareUtilizationWAD(),
            _specLiquidityUtilization(1000e18, DEFAULT_MIN_LIQUIDITY_WAD, 80e18),
            "liquidity utilization from the committed checkpoint"
        );
        assertEq(lptYDM.lastYieldShareUtilizationWAD(), 0.625e18, "checkpoint liquidity utilization exact");
    }

    /// the mutating accrual calls yieldShare while the preview twin calls previewYieldShare and writes nothing
    function test_Accrual_mutatingCallsYieldShareAndPreviewIsPure() public {
        _seedAndInitAccrual();
        lptYDM.setRates(0.03e18);
        vm.warp(vm.getBlockTimestamp() + 250);
        bytes32 preHash = _stateHash();
        vm.expectCall(address(lptYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.PERPETUAL, SEED_LIQUIDITY_UTILIZATION_WAD)));
        accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL));
        assertEq(_stateHash(), preHash, "preview must not mutate storage");
        assertEq(lptYDM.yieldShareCallCount(), 0, "preview must not call the mutating yieldShare");
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        assertEq(lptYDM.yieldShareCallCount(), 1, "mutating accrual calls yieldShare on the lt ydm");
    }

    /**
     * a gain sync with excess above dust pays the time-weighted liquidity premium, resets the accumulator, and
     * stamps lastPremiumPaymentTimestamp
     * Derivation with rate 0.05e18 over 1000s (tw = 50e18) and a 100e18 collateral gain:
     *   couponDue = floor(1000e18 * 1e9 * 1000 / 1e18) = 1e15, paid fully from the gain (no JT fronting so il stays 0)
     *   stProtocolFee = floor(1e15 * 0.1e18 / 1e18) = 1e14
     *   excess = 100e18 - 1e15 = 99_999_000_000_000_000_000 > dust 0 so premiums pay
     *   lptLiquidityPremium = floor(99_999e15 * 50e18 / (1000 * 1e18)) = 4_999_950_000_000_000_000
     *   lptProtocolFee = floor(lptPrem * 0.1e18 / 1e18) = 499_995_000_000_000_000
     *   jt complement = 99_999e15 - lptPrem = 94_999_050_000_000_000_000
     *   jtProtocolFee = floor(complement * 0.1e18 / 1e18) = 9_499_905_000_000_000_000
     *   jtEffectiveNAV = 200e18 + 94_999_050_000_000_000_000 = 294_999_050_000_000_000_000
     *   stEffectiveNAV = 1000e18 + 1e15 + lptPrem = 1_005_000_950_000_000_000_000
     *   conservation: stEff + jtEff = 1300e18 = SEED_COLLATERAL + 100e18 exact
     */
    function test_Accrual_premiumPaymentResetsAccumulatorAndStampsPaymentClock() public {
        _seedAndInitAccrual();
        lptYDM.setRates(0.05e18);
        vm.warp(vm.getBlockTimestamp() + 1000);

        // Same-block preview twin first, executed second, must agree byte for byte
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 100e18));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayFixedRateAccountant.LPTYieldShareAccrued(0.05e18, 50e18);
        SyncedAccountingState memory executed = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 100e18));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(executed)), "preview must match execution exactly");

        assertEq(toUint256(executed.stEffectiveNAV), 1_005_000_950_000_000_000_000, "st books the coupon plus the lt premium");
        assertEq(toUint256(executed.jtEffectiveNAV), 294_999_050_000_000_000_000, "jt keeps the complement of the excess");
        assertEq(toUint256(executed.lptLiquidityPremium), 4_999_950_000_000_000_000, "time-weighted lt premium");
        assertEq(toUint256(executed.stProtocolFee), 100_000_000_000_000, "st fee on the coupon");
        assertEq(toUint256(executed.jtProtocolFee), 9_499_905_000_000_000_000, "jt fee on the complement");
        assertEq(toUint256(executed.lptProtocolFee), 499_995_000_000_000_000, "lt fee on the premium");
        assertEq(toUint256(executed.jtImpermanentLoss), 0, "no jt fronting so no il");
        assertEq(uint8(executed.marketState), uint8(MarketState.PERPETUAL), "il 0 iff PERPETUAL biconditional");

        // The committed checkpoint matches the returned state and conserves the collateral
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastCollateralNAV), SEED_COLLATERAL + 100e18, "collateral checkpoint");
        assertEq(toUint256(s.lastSTEffectiveNAV), 1_005_000_950_000_000_000_000, "st checkpoint");
        assertEq(toUint256(s.lastJTEffectiveNAV), 294_999_050_000_000_000_000, "jt checkpoint");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "il checkpoint");
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), SEED_COLLATERAL + 100e18, "conservation");

        // The payment consumed the window: accumulator reset, payment clock stamped, coupon clock restamped by the NAV movement
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory sFixed = accountant.getRoycoDayFixedRateAccountantState();
        assertEq(sFixed.twLPTYieldShareAccruedWAD, 0, "lt window consumed by the payment");
        assertEq(sFixed.lastPremiumPaymentTimestamp, uint32(vm.getBlockTimestamp()), "payment stamped this block");
        assertEq(sFixed.lastYieldShareAccrualTimestamp, uint32(vm.getBlockTimestamp()), "accrual timestamp advanced");
        assertEq(_couponWindowStart(), vm.getBlockTimestamp(), "settling sync restamps the coupon clock");
    }

    /**
     * a heterogeneous-rate accumulator prices the premium as the time-weighted AVERAGE through a payment:
     * two accrual windows at different YDM rates sum into one accumulator, and the paying sync divides that
     * sum by the whole payment window, so the slice discriminates the average from either endpoint rate
     * Derivation: window one accrues 0.06e18 x 1000 = 60e18, window two accrues 0.02e18 x 250 = 5e18, tw = 65e18
     * over the 1250 second payment window (the flat sync neither paid nor restamped anything). The paying sync
     * settles the 1250 second coupon 1000e18 x 1e9 x 1250 / 1e18 = 1.25e15 from the gain (stFee = 1.25e14) and
     * carves the premium from the 100e18 excess: slice = floor(100e18 x 65e18 / (1250 x 1e18)) = 5.2e18 exactly,
     * the 0.052e18 average rate. Last-rate pricing would give 2e18 and first-rate 6e18, so the vector
     * discriminates all three. lptFee = 0.52e18, complement = 94.8e18 to JT, jtFee = 9.48e18.
     * stEffectiveNAV = 1000e18 + 1.25e15 + 5.2e18, jtEffectiveNAV = 294.8e18, conservation sum = 1300e18 + 1.25e15
     */
    function test_Accrual_multiRateWindowsPriceTimeWeightedAverageThroughPayment() public {
        _seedAndInitAccrual();
        lptYDM.setRates(0.06e18);
        vm.warp(vm.getBlockTimestamp() + 1000);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        lptYDM.setRates(0.02e18);
        vm.warp(vm.getBlockTimestamp() + 250);

        // Same-block preview twin first, executed second, must agree byte for byte
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 1.25e15 + 100e18));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayFixedRateAccountant.LPTYieldShareAccrued(0.02e18, 65e18);
        SyncedAccountingState memory executed = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 1.25e15 + 100e18));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(executed)), "preview must match execution exactly");

        assertEq(toUint256(executed.stEffectiveNAV), 1_005_201_250_000_000_000_000, "st books the coupon plus the average-priced premium");
        assertEq(toUint256(executed.jtEffectiveNAV), 294_800_000_000_000_000_000, "jt keeps the complement of the excess");
        assertEq(toUint256(executed.lptLiquidityPremium), 5.2e18, "the premium prices the time-weighted average rate");
        assertEq(toUint256(executed.stProtocolFee), 1.25e14, "st fee on the 1250 second coupon");
        assertEq(toUint256(executed.jtProtocolFee), 9.48e18, "jt fee on the complement");
        assertEq(toUint256(executed.lptProtocolFee), 0.52e18, "lt fee on the premium");
        assertEq(toUint256(executed.jtImpermanentLoss), 0, "no jt fronting so no il");
        assertEq(uint8(executed.marketState), uint8(MarketState.PERPETUAL), "il 0 iff PERPETUAL biconditional");

        // The committed checkpoint matches the returned state and conserves the collateral
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV), 1_005_201_250_000_000_000_000, "st checkpoint");
        assertEq(toUint256(s.lastJTEffectiveNAV), 294_800_000_000_000_000_000, "jt checkpoint");
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), SEED_COLLATERAL + 1.25e15 + 100e18, "conservation");

        // The payment consumed the heterogeneous window whole: accumulator reset, both clocks stamped
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory sFixed = accountant.getRoycoDayFixedRateAccountantState();
        assertEq(sFixed.twLPTYieldShareAccruedWAD, 0, "the summed window is consumed by the payment");
        assertEq(sFixed.lastPremiumPaymentTimestamp, uint32(vm.getBlockTimestamp()), "payment stamped this block");
        assertEq(_couponWindowStart(), vm.getBlockTimestamp(), "settling sync restamps the coupon clock");
    }

    /**
     * an unpaid window persists across settlements without excess: two settling syncs whose gain equals the
     * coupon exactly leave no excess, so the accumulator compounds and the payment clock never stamps
     * Derivation at rate 0.04e18:
     *   settlement one at +500s: coupon1 = floor(1000e18 * 1e9 * 500 / 1e18) = 5e14, gain = 5e14 exactly, so the
     *   excess step never runs: twLPT = 0.04e18 * 500 = 20e18, stFee1 = floor(5e14 * 0.1e18 / 1e18) = 5e13,
     *   stEff = 1_000_000_500_000_000_000_000, jtEff stays 200e18
     *   settlement two at +300s more: coupon2 = floor(1_000_000_500_000_000_000_000 * 1e9 * 300 / 1e18)
     *     = floor(3.00000015e32 / 1e18) = 300_000_150_000_000 (exact, no floor loss)
     *   gain = coupon2 exactly again: twLPT = 20e18 + 0.04e18 * 300 = 32e18, stFee2 = 30_000_015_000_000,
     *   stEff = 1_000_000_800_000_150_000_000, jtEff stays 200e18
     */
    function test_Accrual_unpaidWindowPersistsAcrossExactCouponSettlements() public {
        _seedAndInitAccrual();
        // Snapshot the stamped clock from storage, a raw vm.getBlockTimestamp() read is unsafe across warp under via-ir timestamp caching
        uint256 t0 = accountant.getRoycoDayFixedRateAccountantState().lastPremiumPaymentTimestamp;
        lptYDM.setRates(0.04e18);

        // Settlement one: gain == coupon so the whole movement funds the coupon and no premium pays
        vm.warp(vm.getBlockTimestamp() + 500);
        uint256 coupon1 = _specCoupon(SEED_ST_EFF, DEFAULT_ST_FIXED_RATE_PER_SECOND_WAD, 500);
        assertEq(coupon1, 5e14, "coupon one derivation");
        SyncedAccountingState memory first = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + coupon1));
        assertEq(toUint256(first.stEffectiveNAV), 1_000_000_500_000_000_000_000, "st folds in coupon one");
        assertEq(toUint256(first.jtEffectiveNAV), SEED_JT_EFF, "jt untouched by an exact-coupon gain");
        assertEq(toUint256(first.lptLiquidityPremium), 0, "no excess so no lt premium");
        assertEq(toUint256(first.stProtocolFee), 5e13, "st fee on coupon one");
        assertEq(toUint256(first.jtProtocolFee), 0, "no excess so no jt fee");
        assertEq(toUint256(first.lptProtocolFee), 0, "no excess so no lt fee");
        assertEq(toUint256(first.jtImpermanentLoss), 0, "coupon fully gain-funded so no il");
        assertEq(uint8(first.marketState), uint8(MarketState.PERPETUAL), "il 0 iff PERPETUAL biconditional");
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory sFixed = accountant.getRoycoDayFixedRateAccountantState();
        assertEq(sFixed.twLPTYieldShareAccruedWAD, uint128(uint256(0.04e18) * 500), "lt window persists through settlement one");
        assertEq(sFixed.lastPremiumPaymentTimestamp, uint32(t0), "payment clock holds through settlement one");
        assertEq(_couponWindowStart(), vm.getBlockTimestamp(), "settlement one restamps the coupon clock");

        // Settlement two: same exact-coupon shape on the enlarged base, preview parity checked in-block
        vm.warp(vm.getBlockTimestamp() + 300);
        uint256 coupon2 = _specCoupon(1_000_000_500_000_000_000_000, DEFAULT_ST_FIXED_RATE_PER_SECOND_WAD, 300);
        assertEq(coupon2, 300_000_150_000_000, "coupon two derivation");
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + coupon1 + coupon2));
        SyncedAccountingState memory second = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + coupon1 + coupon2));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(second)), "preview must match execution exactly");
        assertEq(toUint256(second.stEffectiveNAV), 1_000_000_800_000_150_000_000, "st folds in coupon two");
        assertEq(toUint256(second.jtEffectiveNAV), SEED_JT_EFF, "jt untouched again");
        assertEq(toUint256(second.stProtocolFee), 30_000_015_000_000, "st fee on coupon two");
        assertEq(toUint256(second.stEffectiveNAV) + toUint256(second.jtEffectiveNAV), SEED_COLLATERAL + coupon1 + coupon2, "conservation");

        // The unpaid window carried through both settlements
        sFixed = accountant.getRoycoDayFixedRateAccountantState();
        assertEq(sFixed.twLPTYieldShareAccruedWAD, uint128(uint256(0.04e18) * 800), "lt window compounds across both settlements");
        assertEq(sFixed.lastPremiumPaymentTimestamp, uint32(t0), "payment clock never stamped without excess");
    }

    /**
     * a first-sync gain takes the instantaneous fallback: the lazy initialization stamps the payment clock to
     * now inside the same call, so the excess split prices the lt slice off previewYieldShare over a forced 1s
     * Derivation with a 100e18 collateral gain and preview rate 0.05e18 (below the 0.1e18 cap):
     *   couponDue = 0 (the coupon window opened at initialization in this same block, zero elapsed)
     *   lptLiquidityPremium = floor(100e18 * 0.05e18 / (1 * 1e18)) = 5e18
     *   lptProtocolFee = floor(5e18 * 0.1e18 / 1e18) = 0.5e18, jt complement = 95e18, jtProtocolFee = 9.5e18
     *   jtEffectiveNAV = 200e18 + 95e18 = 295e18, stEffectiveNAV = 1000e18 + 5e18 = 1005e18
     */
    function test_Accrual_firstSyncGainPaysInstantaneousLiquidityPremium() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        lptYDM.setPreviewYieldShareReturn(0.05e18);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 100e18));
        assertEq(toUint256(state.lptLiquidityPremium), 5e18, "lt premium paid via the instantaneous branch");
        assertEq(toUint256(state.jtEffectiveNAV), 295e18, "jt keeps the complement");
        assertEq(toUint256(state.stEffectiveNAV), 1005e18, "st retains the lt premium as a senior claim");
        assertEq(toUint256(state.stProtocolFee), 0, "zero-elapsed coupon so no st fee");
        assertEq(toUint256(state.lptProtocolFee), 0.5e18, "lt fee on the instantaneous premium");
        assertEq(toUint256(state.jtProtocolFee), 9.5e18, "jt fee on the complement");
        assertEq(lptYDM.yieldShareCallCount(), 0, "the instantaneous branch reads previewYieldShare, never yieldShare");
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory sFixed = accountant.getRoycoDayFixedRateAccountantState();
        assertEq(sFixed.twLPTYieldShareAccruedWAD, 0, "accumulator stays zero, the payment consumed nothing");
        assertEq(sFixed.lastPremiumPaymentTimestamp, uint32(vm.getBlockTimestamp()), "payment stamped in the initializing block");
    }

    /**
     * a second gain sync in the same block as a premium payment re-enters the excess split with a zero window,
     * so the lt slice prices off the instantaneous previewYieldShare capped at maxLPT over a forced 1s
     * Derivation: the first sync is the premium payment vector above (rate 0.05e18, tw 50e18, +100e18 gain),
     * landing stEff 1_005_000_950_000_000_000_000 and jtEff 294_999_050_000_000_000_000 with both the payment
     * and coupon clocks stamped to now. The second +50e18 gain in the same block:
     *   couponDue = 0 (coupon clock stamped this block, zero elapsed)
     *   preview rate 0.5e18 > max 0.1e18 so the fallback caps: tw = 0.1e18, elapsed forced to 1
     *   lptLiquidityPremium = floor(50e18 * 0.1e18 / (1 * 1e18)) = 5e18
     *   lptProtocolFee = 0.5e18, jt complement = 45e18, jtProtocolFee = 4.5e18
     *   jtEffectiveNAV = 294_999_050_000_000_000_000 + 45e18 = 339_999_050_000_000_000_000
     *   stEffectiveNAV = 1_005_000_950_000_000_000_000 + 5e18 = 1_010_000_950_000_000_000_000
     *   conservation: stEff + jtEff = 1350e18 exact
     */
    function test_Accrual_sameBlockGainAfterPaymentUsesInstantaneousFallbackCapped() public {
        _seedAndInitAccrual();
        lptYDM.setRates(0.05e18);
        vm.warp(vm.getBlockTimestamp() + 1000);

        // First sync pays the time-weighted premium and stamps the payment clock this block
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 100e18));
        assertEq(accountant.getRoycoDayFixedRateAccountantState().twLPTYieldShareAccruedWAD, 0, "window consumed by the first payment");

        // Second sync in the same block: an above-cap preview rate proves the fallback caps at maxLPT
        lptYDM.setPreviewYieldShareReturn(0.5e18);
        vm.recordLogs();
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 150e18));
        SyncedAccountingState memory second = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 150e18));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(second)), "preview must match execution exactly");
        assertEq(toUint256(second.lptLiquidityPremium), 5e18, "lt premium capped at maxLPT over the forced 1s");
        assertEq(toUint256(second.jtEffectiveNAV), 339_999_050_000_000_000_000, "jt keeps the complement of gain two");
        assertEq(toUint256(second.stEffectiveNAV), 1_010_000_950_000_000_000_000, "st retains the second lt premium");
        assertEq(toUint256(second.stProtocolFee), 0, "zero-elapsed coupon so no st fee");
        assertEq(toUint256(second.lptProtocolFee), 0.5e18, "lt fee on the capped premium");
        assertEq(toUint256(second.jtProtocolFee), 4.5e18, "jt fee on the complement");
        assertEq(toUint256(second.jtImpermanentLoss), 0, "no fronting so no il");
        assertEq(uint8(second.marketState), uint8(MarketState.PERPETUAL), "il 0 iff PERPETUAL biconditional");
        assertEq(toUint256(second.stEffectiveNAV) + toUint256(second.jtEffectiveNAV), SEED_COLLATERAL + 150e18, "conservation across both syncs");
        assertEq(lptYDM.yieldShareCallCount(), 1, "the same-block fallback never re-drives the mutating yieldShare");
        assertEq(
            _countAccountantLogs(vm.getRecordedLogs(), IRoycoDayFixedRateAccountant.LPTYieldShareAccrued.selector),
            0,
            "no accrual event on the same-block re-entry"
        );
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory sFixed = accountant.getRoycoDayFixedRateAccountantState();
        assertEq(sFixed.twLPTYieldShareAccruedWAD, 0, "lt window still empty, nothing replayed");
        assertEq(sFixed.lastPremiumPaymentTimestamp, uint32(vm.getBlockTimestamp()), "payment stamp unchanged in the same block");
    }
}
