// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/accountant/IRoycoDayAccountant.sol";
import { IRoycoDayFixedRateAccountant } from "../../../src/interfaces/accountant/IRoycoDayFixedRateAccountant.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { MarketState, Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { FixedRateAccountantTestBase } from "../../utils/FixedRateAccountantTestBase.sol";

/**
 * @title Test_CouponSettlement_FixedRateAccountant
 * @notice The coupon settlement predicate and window clock: a flat sync neither settles nor restamps, a
 *         moving sync settles and restamps, the window opens at initialization and accumulates across flat
 *         syncs and post-ops, rate changes reprice the entire in-flight window, mid-window senior flows
 *         forfeit or backdate the coupon as documented residuals, and a same-block second settle pays zero
 * @dev Warps target absolute offsets from a single `start` read via vm.getBlockTimestamp: TIMESTAMP is
 *      transaction-invariant to the via-ir optimizer, so direct block.timestamp reads get CSE-folded across
 *      vm.warp (stale re-reads, no-op warps) or rematerialized at their use sites (post-warp values leaking
 *      into pre-warp captures), while the cheatcode call is opaque to both passes
 */
contract Test_CouponSettlement_FixedRateAccountant is FixedRateAccountantTestBase {
    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(_defaultParams());
    }

    /// a flat-NAV pre-op sync settles nothing and leaves the coupon clock untouched, so the window keeps accruing
    function test_Settlement_flatSyncNeitherSettlesNorRestampsClock() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 100);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_EFF, "no coupon folded on a flat sync");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF, "junior untouched on a flat sync");
        assertEq(toUint256(state.stProtocolFee), 0, "no coupon fee on a flat sync");
        assertEq(accountant.getRoycoDayFixedRateAccountantState().lastCouponSettlementTimestamp, uint32(start), "clock not restamped by a flat sync");
        assertEq(toUint256(accountant.getState().lastSTEffectiveNAV), SEED_ST_EFF, "committed senior checkpoint unchanged");
    }

    /**
     * a moving-NAV pre-op sync settles the coupon and restamps the clock to now
     * Derivation with a +10e18 gain after 200s at the default rate 1e9 on stEff 1000e18:
     *   couponDue = floor(1000e18 * (1e9 * 200) / 1e18) = 2e14 exact, fully funded from the gain
     *   stProtocolFee = floor(2e14 * 0.1e18 / 1e18) = 2e13
     *   stEffectiveNAV = 1000e18 + 2e14 = 1_000_000_200_000_000_000_000
     *   excess = 10e18 - 2e14 = 9_999_800_000_000_000_000, all junior-bound (lt rates 0 so no premium)
     *   jtProtocolFee = floor(9_999_800_000_000_000_000 * 0.1e18 / 1e18) = 999_980_000_000_000_000
     *   jtEffectiveNAV = 200e18 + 9_999_800_000_000_000_000 = 209_999_800_000_000_000_000
     */
    function test_Settlement_movingSyncSettlesAndRestampsClock() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 200);
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 10e18));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 10e18));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(state)), "preview must match execution exactly");
        assertEq(toUint256(state.stEffectiveNAV), 1_000_000_200_000_000_000_000, "coupon folded into the senior claim");
        assertEq(toUint256(state.jtEffectiveNAV), 209_999_800_000_000_000_000, "junior keeps the excess above the coupon");
        assertEq(toUint256(state.stProtocolFee), 2e13, "coupon fee floored on the coupon paid");
        assertEq(toUint256(state.jtProtocolFee), 999_980_000_000_000_000, "jt yield share fee floored on the excess");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV), 1_000_000_200_000_000_000_000, "committed senior checkpoint");
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), SEED_COLLATERAL + 10e18, "conservation on the settle");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "no il on a gain-funded coupon");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "zero il keeps the market perpetual");
        assertEq(accountant.getRoycoDayFixedRateAccountantState().lastCouponSettlementTimestamp, uint32(start + 200), "clock restamped by the settling sync");
    }

    /**
     * the window accumulates across flat syncs: warp 100, flat sync, warp 100, the settle pays a 200s coupon
     * Derivation: the intervening flat sync neither settles nor restamps, so the settling sync measures the
     * full window from the seed block
     *   coupon = floor(1000e18 * (1e9 * 200) / 1e18) = 2e14, stEffectiveNAV = 1_000_000_200_000_000_000_000
     *   excess = 10e18 - 2e14, jtEffectiveNAV = 209_999_800_000_000_000_000
     */
    function test_Settlement_windowAccumulatesAcrossFlatSyncs() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 100);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        assertEq(_couponWindowStart(), start, "flat sync leaves the window open");
        vm.warp(start + 200);
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 10e18));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 10e18));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(state)), "preview must match execution exactly");
        assertEq(toUint256(state.stEffectiveNAV), 1_000_000_200_000_000_000_000, "coupon covers the full 200s window");
        assertEq(toUint256(state.jtEffectiveNAV), 209_999_800_000_000_000_000, "junior keeps the excess above the 200s coupon");
        assertEq(_couponWindowStart(), start + 200, "clock restamped only by the settling sync");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), SEED_COLLATERAL + 10e18, "conservation on the settle");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "no il on a gain-funded coupon");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "zero il keeps the market perpetual");
    }

    /**
     * the coupon window opens at initialization: seeding is same-block as the deploy, so the first settle pays
     * the coupon over the whole span since the seed block, not since any first sync
     * Derivation with a +10e18 gain after 500s at the default rate 1e9 on stEff 1000e18:
     *   coupon = floor(1000e18 * (1e9 * 500) / 1e18) = 5e14, stEffectiveNAV = 1_000_000_500_000_000_000_000
     *   excess = 10e18 - 5e14 = 9_999_500_000_000_000_000, jtEffectiveNAV = 209_999_500_000_000_000_000
     *   stProtocolFee = floor(5e14 * 0.1e18 / 1e18) = 5e13
     */
    function test_Settlement_windowOpensAtInitialize() public {
        uint256 start = vm.getBlockTimestamp();
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        assertEq(_couponWindowStart(), start, "window opened at initialization, before any sync");
        vm.warp(start + 500);
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 10e18));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 10e18));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(state)), "preview must match execution exactly");
        assertEq(toUint256(state.stEffectiveNAV), 1_000_000_500_000_000_000_000, "coupon covers the time since the seed block");
        assertEq(toUint256(state.jtEffectiveNAV), 209_999_500_000_000_000_000, "junior keeps the excess above the 500s coupon");
        assertEq(toUint256(state.stProtocolFee), 5e13, "coupon fee floored on the 500s coupon");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), SEED_COLLATERAL + 10e18, "conservation on the settle");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "no il on a gain-funded coupon");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "zero il keeps the market perpetual");
    }

    /**
     * post-op syncs never settle nor restamp: ST and JT deposits move lastCollateralNAV and LPT flows move the
     * liquidity mark, yet the clock and the open window survive them all
     * Derivation for the closing settle: the deposits landed stEff 1100e18 and jtEff 250e18 (collateral 1350e18),
     * the window ran 300s uninterrupted from the seed block, so with a +10e18 gain
     *   coupon = floor(1100e18 * (1e9 * 300) / 1e18) = 3.3e14, stEffectiveNAV = 1_100_000_330_000_000_000_000
     *   excess = 10e18 - 3.3e14 = 9_999_670_000_000_000_000, jtEffectiveNAV = 259_999_670_000_000_000_000
     */
    function test_Settlement_postOpsLeaveClockAndWindowIntact() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 150);
        // ST deposit moves lastCollateralNAV up by 100e18, the clock must not move
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 100e18), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(_couponWindowStart(), start, "st deposit leaves the clock intact");
        // JT deposit moves lastCollateralNAV up by 50e18, the clock must not move
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 150e18), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(_couponWindowStart(), start, "jt deposit leaves the clock intact");
        // LPT flows move the liquidity mark only, the clock must not move
        kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 150e18), toNAVUnits(SEED_LPT_RAW + 20e18), ZERO_NAV_UNITS);
        assertEq(_couponWindowStart(), start, "lpt deposit leaves the clock intact");
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_COLLATERAL + 150e18), toNAVUnits(SEED_LPT_RAW + 15e18), ZERO_NAV_UNITS);
        assertEq(_couponWindowStart(), start, "lpt redemption leaves the clock intact");
        // The closing settle proves the window itself survived: elapsed measures from the seed block, not any post-op
        vm.warp(start + 300);
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 160e18));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 160e18));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(state)), "preview must match execution exactly");
        assertEq(toUint256(state.stEffectiveNAV), 1_100_000_330_000_000_000_000, "coupon pays the full 300s window on the post-deposit base");
        assertEq(toUint256(state.jtEffectiveNAV), 259_999_670_000_000_000_000, "junior keeps the excess above the coupon");
        assertEq(_couponWindowStart(), start + 300, "clock restamped only by the settling sync");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), SEED_COLLATERAL + 160e18, "conservation on the settle");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "no il on a gain-funded coupon");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "zero il keeps the market perpetual");
    }

    /**
     * a rate change right after a settlement prices the next window at the new rate exactly, compounding on the
     * senior claim the settlement just folded the old-rate coupon into
     * Derivation: settle a +10e18 gain at 100s under the default rate 1e9
     *   coupon1 = floor(1000e18 * (1e9 * 100) / 1e18) = 1e14, stEff1 = 1_000_000_100_000_000_000_000
     *   jtEff1 = 200e18 + (10e18 - 1e14) = 209_999_900_000_000_000_000
     * then double the rate to 2e9 in the same block (window elapsed 0, nothing to reprice) and settle a second
     * +10e18 gain 200s later
     *   coupon2 = floor(stEff1 * (2e9 * 200) / 1e18) = floor(1_000_000_100_000_000_000_000 * 4e11 / 1e18) = 400_000_040_000_000
     *   stEff2 = stEff1 + coupon2 = 1_000_000_500_000_040_000_000
     *   jtEff2 = jtEff1 + (10e18 - coupon2) = 219_999_499_999_960_000_000
     *   stProtocolFee2 = floor(coupon2 * 0.1e18 / 1e18) = 40_000_004_000_000
     */
    function test_Settlement_rateChangeAfterSettlementPricesNextWindowAtNewRate() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 100);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 10e18));
        assertEq(toUint256(accountant.getState().lastSTEffectiveNAV), 1_000_000_100_000_000_000_000, "old-rate coupon folded by the settlement");
        // Same-block rate change: the kernel is in NONE mode so the modifier syncs are no-ops, the window just restamped anyway
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayFixedRateAccountant.SeniorTrancheFixedRateUpdated(uint64(2e9));
        accountant.setSeniorTrancheFixedRate(uint64(2e9));
        vm.warp(start + 300);
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 20e18));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 20e18));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(state)), "preview must match execution exactly");
        assertEq(toUint256(state.stEffectiveNAV), 1_000_000_500_000_040_000_000, "next window pays the new rate on the compounded base");
        assertEq(toUint256(state.jtEffectiveNAV), 219_999_499_999_960_000_000, "junior keeps the excess above the new-rate coupon");
        assertEq(toUint256(state.stProtocolFee), 40_000_004_000_000, "coupon fee floored on the new-rate coupon");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), SEED_COLLATERAL + 20e18, "conservation across both settles");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "no il on gain-funded coupons");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "zero il keeps the market perpetual");
    }

    /**
     * a mid-window rate change reprices the ENTIRE in-flight window: with a NONE-mode kernel the modifier syncs
     * settle nothing, the clock stays at the seed block, and the eventual settle pays the whole window at the
     * new rate (the documented retroactivity, pinned here as expected behavior)
     * Derivation: the rate moves 1e9 -> 3e9 at 300s into the window, the settle lands at 500s with a +10e18 gain
     *   coupon = floor(1000e18 * (3e9 * 500) / 1e18) = 1_500_000_000_000_000 (a blend would have paid
     *   1e9 * 300 + 3e9 * 200 = 9e11 rate-seconds, ie. 9e14, asserted away by the exact 1.5e15)
     *   stEffectiveNAV = 1_000_001_500_000_000_000_000
     *   excess = 10e18 - 1.5e15 = 9_998_500_000_000_000_000, jtEffectiveNAV = 209_998_500_000_000_000_000
     *   stProtocolFee = floor(1.5e15 * 0.1e18 / 1e18) = 1.5e14
     */
    function test_Settlement_rateChangeMidWindowRepricesWholeWindow() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 300);
        // NONE-mode kernel: the modifier's bracketing syncs run no pre-op, so no pending movement settles here
        accountant.setSeniorTrancheFixedRate(uint64(3e9));
        assertEq(_couponWindowStart(), start, "rate change alone neither settles nor restamps");
        vm.warp(start + 500);
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 10e18));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 10e18));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(state)), "preview must match execution exactly");
        assertEq(toUint256(state.stEffectiveNAV), 1_000_001_500_000_000_000_000, "whole 500s window pays the new rate");
        assertEq(toUint256(state.jtEffectiveNAV), 209_998_500_000_000_000_000, "junior keeps the excess above the repriced coupon");
        assertEq(toUint256(state.stProtocolFee), 1.5e14, "coupon fee floored on the repriced coupon");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), SEED_COLLATERAL + 10e18, "conservation on the settle");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "no il on a gain-funded coupon");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "zero il keeps the market perpetual");
    }

    /**
     * a mid-window ST redemption forfeits the exiting capital's coupon: the settle pays the FULL window on the
     * remaining base only, the emergent forfeiture with no machinery
     * Derivation: half the senior (500e18) exits at 250s via post-op, the settle lands at 500s with a +10e18 gain
     * on the 700e18 checkpoint
     *   coupon = floor(500e18 * (1e9 * 500) / 1e18) = 2.5e14, half the base times the full window
     *   stEffectiveNAV = 500e18 + 2.5e14 = 500_000_250_000_000_000_000
     *   excess = 10e18 - 2.5e14 = 9_999_750_000_000_000_000, jtEffectiveNAV = 209_999_750_000_000_000_000
     */
    function test_Settlement_midWindowSTRedemptionForfeitsExitedCoupon() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 250);
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_COLLATERAL - 500e18), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(_couponWindowStart(), start, "redemption leaves the clock intact");
        assertEq(toUint256(accountant.getState().lastSTEffectiveNAV), 500e18, "half the senior base exited");
        vm.warp(start + 500);
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL - 500e18 + 10e18));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL - 500e18 + 10e18));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(state)), "preview must match execution exactly");
        assertEq(toUint256(state.stEffectiveNAV), 500_000_250_000_000_000_000, "coupon pays half the base times the full window");
        assertEq(toUint256(state.jtEffectiveNAV), 209_999_750_000_000_000_000, "junior never charged for the exited capital");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), SEED_COLLATERAL - 500e18 + 10e18, "conservation on the settle");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "no il on a gain-funded coupon");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "zero il keeps the market perpetual");
    }

    /**
     * a mid-window ST deposit backdates the coupon onto the enlarged base: the settle pays the FULL window on
     * the doubled base, the documented residual at JT's expense (gated markets prevent it)
     * Derivation: another 1000e18 of senior enters at 250s via post-op, the settle lands at 500s with a +10e18
     * gain on the 2200e18 checkpoint
     *   coupon = floor(2000e18 * (1e9 * 500) / 1e18) = 1e15, the doubled base times the full window
     *   stEffectiveNAV = 2000e18 + 1e15 = 2_000_001_000_000_000_000_000
     *   excess = 10e18 - 1e15 = 9_999_000_000_000_000_000, jtEffectiveNAV = 209_999_000_000_000_000_000
     */
    function test_Settlement_midWindowSTDepositBackdatesCoupon() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 250);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_COLLATERAL + 1000e18), toNAVUnits(SEED_LPT_RAW), ZERO_NAV_UNITS);
        assertEq(_couponWindowStart(), start, "deposit leaves the clock intact");
        assertEq(toUint256(accountant.getState().lastSTEffectiveNAV), 2000e18, "the senior base doubled mid-window");
        vm.warp(start + 500);
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 1000e18 + 10e18));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 1000e18 + 10e18));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(state)), "preview must match execution exactly");
        assertEq(toUint256(state.stEffectiveNAV), 2_000_001_000_000_000_000_000, "coupon pays the doubled base times the full window");
        assertEq(toUint256(state.jtEffectiveNAV), 209_999_000_000_000_000_000, "junior funds the backdated coupon from its excess");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), SEED_COLLATERAL + 1010e18, "conservation on the settle");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "no il on a gain-funded coupon");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "zero il keeps the market perpetual");
    }

    /**
     * a second settling sync in the same block pays zero additional coupon: the first settle restamped the
     * clock to now, so the second sync's elapsed is 0 and its NAV movement flows to the junior alone
     * Derivation: the first settle at 400s with a +10e18 gain pays
     *   coupon1 = floor(1000e18 * (1e9 * 400) / 1e18) = 4e14, stEff1 = 1_000_000_400_000_000_000_000
     *   jtEff1 = 200e18 + (10e18 - 4e14) = 209_999_600_000_000_000_000
     * the same-block second settle with another +10e18 gain pays
     *   coupon2 = floor(stEff1 * (1e9 * 0) / 1e18) = 0, so stEff2 = stEff1 and the whole gain is junior-bound
     *   jtEff2 = jtEff1 + 10e18 = 219_999_600_000_000_000_000
     *   stProtocolFee2 = 0 (no coupon paid), jtProtocolFee2 = floor(10e18 * 0.1e18 / 1e18) = 1e18
     */
    function test_Settlement_sameBlockSecondSettlePaysZeroCoupon() public {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 400);
        SyncedAccountingState memory first = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 10e18));
        assertEq(toUint256(first.stEffectiveNAV), 1_000_000_400_000_000_000_000, "first settle folds the 400s coupon");
        assertEq(_couponWindowStart(), start + 400, "first settle restamped the clock to now");
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_COLLATERAL + 20e18));
        SyncedAccountingState memory second = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 20e18));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(second)), "preview must match execution exactly");
        assertEq(toUint256(second.stEffectiveNAV), 1_000_000_400_000_000_000_000, "zero additional coupon in the same block");
        assertEq(toUint256(second.jtEffectiveNAV), 219_999_600_000_000_000_000, "the second gain is junior-bound entirely");
        assertEq(toUint256(second.stProtocolFee), 0, "no coupon fee without a coupon");
        assertEq(toUint256(second.jtProtocolFee), 1e18, "jt yield share fee on the whole second gain");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), SEED_COLLATERAL + 20e18, "conservation across both settles");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "no il on gain-funded coupons");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "zero il keeps the market perpetual");
    }
}
