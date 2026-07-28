// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { WAD, ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { MarketParamsConfig, defaultParams, zeroLiquidityParams } from "../../utils/MarketParams.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_WithSyncedAccountingGuard
 * @notice The withSyncedAccounting config guard, pinned from its expected behavior: a parameter change must never push
 *         a healthy market into breach, never deepen an existing breach, and never arm the liquidation regime, while
 *         every improving change and every in-bounds change stays admissible, so an admin can always steer a market
 *         toward health but never away from it
 * @dev Every expectation is derived from live synced state through RoycoTestMath's utilization mirrors, never from the
 *      modifier's branches. Breaches are staged through PnL, the only way the market is meant to enter one
 */
contract Test_WithSyncedAccountingGuard is DayMarketTestBase {
    uint256 internal QUOTE_UNIT;

    /// @dev Zero fixed-term duration so covered drawdowns stay PERPETUAL and the breach staging never trips the term gate
    function setUp() public {
        MarketParamsConfig memory params = defaultParams();
        params.fixedTermDurationSeconds = 0;
        _deployMarket(cellA(), params);
        QUOTE_UNIT = 10 ** uint256(cell.quoteAsset.decimals);
        _seedMarket(100_000e18, 30_000e18);
        _seedLPT(10_000e18, 2000e18, 8000 * QUOTE_UNIT);
        _sync();
    }

    // =============================
    // Staging helpers (breaches arrive through PnL, never through configuration)
    // =============================

    /// @dev Applies collateral losses until coverage utilization breaches 100% while staying below the liquidation threshold
    function _breachCoverage() internal returns (SyncedAccountingState memory state) {
        for (uint256 i = 0; i < 30; ++i) {
            applySTPnL(-200);
            state = _sync();
            if (state.coverageUtilizationWAD > WAD) {
                assertLt(state.coverageUtilizationWAD, state.coverageLiquidationUtilizationWAD, "staging must stop short of the liquidation threshold");
                return state;
            }
        }
        fail("_breachCoverage: coverage utilization never breached");
    }

    /// @dev Applies collateral losses until the liquidation regime arms (coverage utilization at or past the threshold)
    function _armLiquidation() internal returns (SyncedAccountingState memory state) {
        for (uint256 i = 0; i < 60; ++i) {
            applySTPnL(-500);
            state = _sync();
            if (state.jtEffectiveNAV == ZERO_NAV_UNITS) break;
            if (state.coverageUtilizationWAD >= state.coverageLiquidationUtilizationWAD) return state;
        }
        fail("_armLiquidation: liquidation threshold never reached with a live junior buffer");
    }

    /// @dev The largest minCoverage keeping ceil(collateralNAV x minCoverage / jtEffectiveNAV) at or below WAD
    function _maxSafeMinCoverage(SyncedAccountingState memory _state) internal pure returns (uint64) {
        return uint64(Math.mulDiv(toUint256(_state.jtEffectiveNAV), WAD, toUint256(_state.collateralNAV), Math.Rounding.Floor));
    }

    // =============================
    // Coverage requirement
    // =============================

    /// @notice The guard is bounds-or-better, not never-worsen: a tightening that worsens utilization but keeps the
    ///         market within 100% coverage utilization must be admissible
    function test_CoverageConfig_worseningWithinBoundsIsAllowed() public {
        SyncedAccountingState memory pre = _sync();
        uint64 tightened = _maxSafeMinCoverage(pre);
        assertGt(tightened, uint64(accountant.getState().minCoverageWAD), "arrange: the tightened requirement must worsen utilization");

        vm.prank(ACCOUNTANT_ADMIN);
        accountant.setMinCoverage(tightened);

        SyncedAccountingState memory post = _sync();
        assertEq(uint256(accountant.getState().minCoverageWAD), uint256(tightened), "the in-bounds tightening must persist");
        assertGt(post.coverageUtilizationWAD, pre.coverageUtilizationWAD, "utilization must have worsened, pinning that worsening alone is not gated");
        assertLe(post.coverageUtilizationWAD, WAD, "the worsened utilization must remain within bounds");
    }

    /// @notice A parameter change must never push a healthy market into coverage breach, and the rejected configuration
    ///         must leave no trace
    function test_CoverageConfig_breachingAHealthyMarketReverts() public {
        SyncedAccountingState memory pre = _sync();
        uint64 breaching = _maxSafeMinCoverage(pre) + 0.01e18;
        assertGt(
            RoycoTestMath.computeCoverageUtilization(toUint256(pre.collateralNAV), breaching, toUint256(pre.jtEffectiveNAV)),
            WAD,
            "arrange: the derived post-change utilization must breach"
        );
        uint256 storedBefore = accountant.getState().minCoverageWAD;

        vm.prank(ACCOUNTANT_ADMIN);
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        accountant.setMinCoverage(breaching);

        assertEq(accountant.getState().minCoverageWAD, storedBefore, "a rejected configuration must never persist");
    }

    /// @notice On a market already in coverage breach, an improving change must pass and a worsening one must not, so
    ///         the admin can always steer toward health but never deepen the breach
    function test_CoverageConfig_breachedMarket_improvingAllowedWorseningReverts() public {
        SyncedAccountingState memory breached = _breachCoverage();
        uint64 current = uint64(accountant.getState().minCoverageWAD);

        // Worsening: any tightening raises utilization that is already past 100%
        vm.prank(ACCOUNTANT_ADMIN);
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        accountant.setMinCoverage(current + 0.01e18);

        // Improving: halving the requirement halves utilization, the recovery lever must stay available mid-breach
        vm.prank(ACCOUNTANT_ADMIN);
        accountant.setMinCoverage(current / 2);
        SyncedAccountingState memory post = _sync();
        assertEq(uint256(accountant.getState().minCoverageWAD), uint256(current / 2), "the improving change must persist");
        assertLt(post.coverageUtilizationWAD, breached.coverageUtilizationWAD, "the improving change must reduce utilization");
    }

    // =============================
    // Liquidation threshold
    // =============================

    /// @notice A threshold change must never arm the liquidation regime by itself: the regime arms at utilization AT
    ///         the threshold, so a threshold set to or below live utilization is rejected and one strictly above passes
    function test_LiquidationThreshold_cannotArmTheRegimeByConfiguration() public {
        SyncedAccountingState memory breached = _breachCoverage();
        uint256 liveUtil = breached.coverageUtilizationWAD;

        // At live utilization: util >= threshold would hold, the regime would arm the moment the setter returned
        vm.prank(ACCOUNTANT_ADMIN);
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        accountant.setLiquidationCoverageUtilization(liveUtil);

        // One above live utilization: lowering the threshold toward utilization is legitimate right up to touching it
        vm.prank(ACCOUNTANT_ADMIN);
        accountant.setLiquidationCoverageUtilization(liveUtil + 1);
        SyncedAccountingState memory post = _sync();
        assertEq(accountant.getState().coverageLiquidationUtilizationWAD, liveUtil + 1, "the disarmed threshold must persist");
        assertLt(post.coverageUtilizationWAD, post.coverageLiquidationUtilizationWAD, "the regime must not be armed by the change");
    }

    /// @notice On a market whose liquidation regime armed through losses, unrelated configuration stays operable, the
    ///         threshold can only move to disarm, and disarming by raising it above live utilization works
    function test_LiquidationThreshold_liquidatingMarket_unrelatedSettersPassAndOnlyDisarmMoves() public {
        SyncedAccountingState memory armed = _armLiquidation();
        uint256 liveUtil = armed.coverageUtilizationWAD;

        // Unrelated configuration must stay operable mid-liquidation: an untouched threshold never gates other setters
        vm.prank(MARKET_OPS_ADMIN);
        accountant.setDustTolerance(toNAVUnits(uint256(2)));
        assertEq(toUint256(accountant.getState().dustTolerance), 2, "an unrelated setter must remain operable while liquidating");

        // Re-pointing the threshold to another armed value changes nothing and must be rejected
        vm.prank(ACCOUNTANT_ADMIN);
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        accountant.setLiquidationCoverageUtilization(liveUtil - 0.1e18);

        // Raising the threshold above live utilization disarms the regime, the one legitimate threshold move here
        vm.prank(ACCOUNTANT_ADMIN);
        accountant.setLiquidationCoverageUtilization(liveUtil + 0.1e18);
        SyncedAccountingState memory post = _sync();
        assertLt(post.coverageUtilizationWAD, post.coverageLiquidationUtilizationWAD, "raising the threshold above live utilization must disarm");
    }

    // =============================
    // Liquidity requirement
    // =============================

    /// @notice The liquidity requirement mirrors the coverage rule: an in-bounds tightening passes and one that would
    ///         breach the market's own depth is rejected without a trace
    function test_LiquidityConfig_breachingReverts_boundedWorseningAllowed() public {
        SyncedAccountingState memory pre = _sync();

        // In-bounds tightening: derived post-change utilization stays at or below 100%
        uint64 bounded = 0.09e18;
        assertLe(
            RoycoTestMath.computeLiquidityUtilization(toUint256(pre.stEffectiveNAV), bounded, toUint256(pre.lptRawNAV)),
            WAD,
            "arrange: the bounded tightening must stay within the depth"
        );
        vm.prank(ACCOUNTANT_ADMIN);
        accountant.setMinLiquidity(bounded);
        assertEq(uint256(accountant.getState().minLiquidityWAD), uint256(bounded), "the in-bounds tightening must persist");

        // Breaching tightening: the requirement would exceed the live market-making depth
        uint64 breaching = 0.15e18;
        assertGt(
            RoycoTestMath.computeLiquidityUtilization(toUint256(pre.stEffectiveNAV), breaching, toUint256(pre.lptRawNAV)),
            WAD,
            "arrange: the derived post-change utilization must breach"
        );
        vm.prank(ACCOUNTANT_ADMIN);
        vm.expectRevert(IRoycoDayAccountant.INVALID_LIQUIDITY_CONFIG.selector);
        accountant.setMinLiquidity(breaching);
        assertEq(uint256(accountant.getState().minLiquidityWAD), uint256(bounded), "a rejected configuration must never persist");
    }

    /// @notice On a market whose depth collapsed under its requirement, loosening must pass and tightening must not
    function test_LiquidityConfig_breachedLiquidity_improvingAllowedWorseningReverts() public {
        SyncedAccountingState memory breached;
        for (uint256 i = 0; i < 20; ++i) {
            applyLPTPnL(-3000);
            breached = _sync();
            if (breached.liquidityUtilizationWAD > WAD) break;
        }
        assertGt(breached.liquidityUtilizationWAD, WAD, "arrange: the venue losses must breach the liquidity requirement");
        uint64 current = uint64(accountant.getState().minLiquidityWAD);

        vm.prank(ACCOUNTANT_ADMIN);
        vm.expectRevert(IRoycoDayAccountant.INVALID_LIQUIDITY_CONFIG.selector);
        accountant.setMinLiquidity(current + 0.01e18);

        vm.prank(ACCOUNTANT_ADMIN);
        accountant.setMinLiquidity(current / 2);
        SyncedAccountingState memory post = _sync();
        assertEq(uint256(accountant.getState().minLiquidityWAD), uint256(current / 2), "the improving change must persist");
        assertLt(post.liquidityUtilizationWAD, breached.liquidityUtilizationWAD, "the improving change must reduce utilization");
    }
}

/**
 * @title Test_WithSyncedAccountingGuard_ZeroLiquidity
 * @notice The guard on a market with no market-making depth: arming a liquidity requirement against zero depth would
 *         put the market into instant breach, so the requirement can only be armed after the depth exists
 */
contract Test_WithSyncedAccountingGuard_ZeroLiquidity is DayMarketTestBase {
    function setUp() public {
        _deployMarket(cellA(), zeroLiquidityParams());
        _seedMarket(100_000e18, 30_000e18);
        _sync();
    }

    /// @notice Arming a liquidity requirement on an empty venue must be rejected: utilization would jump from the
    ///         requirement-free zero straight to the empty-depth sentinel, an instant breach by configuration
    function test_LiquidityConfig_cannotArmARequirementWithNoDepth() public {
        assertEq(toUint256(accountant.getState().lastLPTRawNAV), 0, "arrange: the market must have no market-making depth");

        vm.prank(ACCOUNTANT_ADMIN);
        vm.expectRevert(IRoycoDayAccountant.INVALID_LIQUIDITY_CONFIG.selector);
        accountant.setMinLiquidity(0.01e18);

        assertEq(uint256(accountant.getState().minLiquidityWAD), 0, "the requirement must remain unarmed");
    }
}
