// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { stdError } from "../../../lib/forge-std/src/Test.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { toTrancheUnits } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title Test_KernelPauseAndRevertBranches
 * @notice Always-running pins for the kernel-layer `whenNotPaused` gate across every synced entrypoint, plus the
 *         `_validateYieldShareConfig` uint64-sum overflow edge. A paused kernel must brick every deposit,
 *         redemption, sync, and reinvest — even though the tranche itself is not paused — because each routes into
 *         a `whenNotPaused` kernel entrypoint.
 */
contract Test_KernelPauseAndRevertBranches is DayMarketTestBase {
    uint256 internal constant ST_SEED_WHOLE = 100;
    uint256 internal constant JT_SEED_WHOLE = 30;

    uint256 internal stUnit;
    uint256 internal quoteUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
    }

    function _pauseKernel() internal {
        vm.prank(PAUSER);
        kernel.pause();
    }

    function _mintBptTo(address _to, uint256 _bptAmount, uint256 _quoteLeg) internal {
        quoteToken.mint(address(this), _quoteLeg);
        quoteToken.approve(address(balancerVault), _quoteLeg);
        uint256[2] memory legs;
        legs[1 - stPoolTokenIndex] = _quoteLeg;
        balancerVault.mintPoolTokensTo(address(bpt), _to, _bptAmount, legs);
    }

    // ---------------------------------------------------------------------
    // Deposits: paused kernel bricks every deposit entrypoint
    // ---------------------------------------------------------------------

    function test_PausedKernel_bricksSTDeposit() public {
        stJtVault.mintShares(ST_PROVIDER, stUnit);
        vm.prank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), stUnit);
        _pauseKernel();
        vm.prank(ST_PROVIDER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.deposit(toTrancheUnits(stUnit), ST_PROVIDER);
    }

    function test_PausedKernel_bricksJTDeposit() public {
        stJtVault.mintShares(JT_PROVIDER, stUnit);
        vm.prank(JT_PROVIDER);
        stJtVault.approve(address(juniorTranche), stUnit);
        _pauseKernel();
        vm.prank(JT_PROVIDER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        juniorTranche.deposit(toTrancheUnits(stUnit), JT_PROVIDER);
    }

    function test_PausedKernel_bricksInKindLTDeposit() public {
        address a = makeAddr("P_LT_INKIND");
        uint256 bptAmount = 10e18;
        _mintBptTo(a, bptAmount, 10 * quoteUnit);
        vm.prank(a);
        bpt.approve(address(liquidityTranche), bptAmount);
        _pauseKernel();
        vm.prank(a);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        liquidityTranche.deposit(toTrancheUnits(bptAmount), a);
    }

    function test_PausedKernel_bricksMultiAssetLTDeposit() public {
        address a = makeAddr("P_LT_MULTI");
        quoteToken.mint(a, 10 * quoteUnit);
        vm.prank(a);
        quoteToken.approve(address(liquidityTranche), 10 * quoteUnit);
        _pauseKernel();
        vm.prank(a);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        liquidityTranche.depositMultiAsset(0, 10 * quoteUnit, 0, a);
    }

    // ---------------------------------------------------------------------
    // Redemptions: paused kernel bricks every redemption entrypoint
    // ---------------------------------------------------------------------

    function test_PausedKernel_bricksSTRedeem() public {
        uint256 shares = seniorTranche.balanceOf(ST_PROVIDER) / 10;
        _pauseKernel();
        vm.prank(ST_PROVIDER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.redeem(shares, ST_PROVIDER, ST_PROVIDER);
    }

    function test_PausedKernel_bricksJTRedeem() public {
        uint256 shares = juniorTranche.balanceOf(JT_PROVIDER) / 10;
        _pauseKernel();
        vm.prank(JT_PROVIDER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        juniorTranche.redeem(shares, JT_PROVIDER, JT_PROVIDER);
    }

    function test_PausedKernel_bricksInKindLTRedeem() public {
        uint256 shares = liquidityTranche.balanceOf(LT_PROVIDER) / 2;
        _pauseKernel();
        vm.prank(LT_PROVIDER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        liquidityTranche.redeem(shares, LT_PROVIDER, LT_PROVIDER);
    }

    function test_PausedKernel_bricksMultiAssetLTRedeem() public {
        uint256 shares = liquidityTranche.balanceOf(LT_PROVIDER) / 2;
        _pauseKernel();
        vm.prank(LT_PROVIDER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        liquidityTranche.redeemMultiAsset(shares, 0, 0, LT_PROVIDER, LT_PROVIDER);
    }

    // ---------------------------------------------------------------------
    // Sync + reinvest: paused kernel bricks the sync and the reinvest entrypoint
    // ---------------------------------------------------------------------

    function test_PausedKernel_bricksSync() public {
        _pauseKernel();
        vm.prank(SYNC_OPERATOR);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        kernel.syncTrancheAccounting();
    }

    function test_PausedKernel_bricksReinvest() public {
        _pauseKernel();
        vm.prank(MARKET_OPS_ADMIN);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        kernel.reinvestLiquidityPremium(type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Recovery: unpausing restores flow
    // ---------------------------------------------------------------------

    function test_UnpauseRestoresFlow() public {
        _pauseKernel();
        vm.prank(UNPAUSER);
        kernel.unpause();
        stJtVault.mintShares(ST_PROVIDER, stUnit);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), stUnit);
        seniorTranche.deposit(toTrancheUnits(stUnit), ST_PROVIDER); // no revert
        vm.stopPrank();
        _sync(); // no revert
    }

    // ---------------------------------------------------------------------
    // uint64 yield-share-sum overflow pre-empts INVALID_MAX_YIELD_SHARE_CONFIG
    // ---------------------------------------------------------------------

    /// @dev A sum within uint64 but above WAD is rejected with the intended named error.
    function test_MaxYieldShareSum_aboveWAD_revertsNamedError() public {
        vm.prank(ACCOUNTANT_ADMIN);
        vm.expectRevert(IRoycoDayAccountant.INVALID_MAX_YIELD_SHARE_CONFIG.selector);
        accountant.setMaxYieldShares(0.6e18, 0.4e18 + 1);
    }

    /// @dev A sum that overflows uint64 panics (0x11) in the checked `_maxJT + _maxLT` addition BEFORE the
    ///      intended INVALID_MAX_YIELD_SHARE_CONFIG can be raised — an error-quality edge (documented, unpinned
    ///      until now). Pins current behavior.
    function test_DIVERGENCE_MaxYieldShareSum_overflowsUint64_panicsBeforeNamedError() public {
        vm.prank(ACCOUNTANT_ADMIN);
        vm.expectRevert(stdError.arithmeticError);
        accountant.setMaxYieldShares(type(uint64).max, 1);
    }
}
