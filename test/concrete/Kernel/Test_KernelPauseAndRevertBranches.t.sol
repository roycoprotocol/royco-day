// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { stdError } from "../../../lib/forge-std/src/Test.sol";
import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { LT_LP_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_KernelPauseAndRevertBranches
 * @notice Always-running pins for the kernel-layer `whenNotPaused` gate across every synced entrypoint, plus the
 *         `_validateYieldShareConfig` uint64-sum overflow edge. The tranche holds no pause of its own, so the kernel
 *         is the market's single pause authority: a paused kernel must brick every deposit, redemption, sync,
 *         reinvest, and tranche token movement (each routes into a `whenNotPaused` kernel entrypoint or the
 *         `whenNotPaused` balance-update hook), must zero every max view without reverting it, and must revert every
 *         price-bearing read so integrators never consume a stale mark mid-incident.
 */
contract Test_KernelPauseAndRevertBranches is DayMarketTestBase {
    uint256 internal constant ST_SEED_WHOLE = 100;
    uint256 internal constant JT_SEED_WHOLE = 30;

    uint256 internal collateralUnit;
    uint256 internal quoteUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        collateralUnit = 10 ** uint256(cell.collateralAsset.decimals);
        quoteUnit = 10 ** uint256(cell.quoteAsset.decimals);
        _seedMarket(ST_SEED_WHOLE * collateralUnit, JT_SEED_WHOLE * collateralUnit);
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
        stJtVault.mintShares(ST_PROVIDER, collateralUnit);
        vm.prank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), collateralUnit);
        _pauseKernel();
        vm.prank(ST_PROVIDER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.deposit(toTrancheUnits(collateralUnit), ST_PROVIDER);
    }

    function test_PausedKernel_bricksJTDeposit() public {
        stJtVault.mintShares(JT_PROVIDER, collateralUnit);
        vm.prank(JT_PROVIDER);
        stJtVault.approve(address(juniorTranche), collateralUnit);
        _pauseKernel();
        vm.prank(JT_PROVIDER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        juniorTranche.deposit(toTrancheUnits(collateralUnit), JT_PROVIDER);
    }

    function test_PausedKernel_bricksInKindLTDeposit() public {
        address a = makeAddr("P_LT_INKIND");
        accessManager.grantRole(LT_LP_ROLE, a, 0);
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
        accessManager.grantRole(LT_LP_ROLE, a, 0);
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
    // Token movements: paused kernel bricks transfers through the balance-update hook
    // ---------------------------------------------------------------------

    /// @notice A paused kernel bricks plain tranche share transfers, which route through the kernel's whenNotPaused hook
    function test_PausedKernel_bricksTransfer() public {
        _pauseKernel();
        vm.prank(ST_PROVIDER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.transfer(makeAddr("TRANSFER_RECIPIENT"), 1e18);
    }

    // ---------------------------------------------------------------------
    // Read surface under a paused kernel: max views return zero, price-bearing reads revert
    // ---------------------------------------------------------------------

    /**
     * @notice A paused kernel zeroes every max view WITHOUT reverting it, preserving the ERC4626 contract that a max
     *         function returns 0 when the operation is disabled
     * @dev The max helpers short-circuit on the kernel's paused flag and return zero before reaching the whenNotPaused
     *      sync, so an integrator sizing a deposit or redemption learns it is impossible without eating a revert
     */
    function test_PausedKernel_MaxViewsReturnZeroWithoutReverting() public {
        // A live LT position so the multi-asset maximum is nonzero before the pause, isolating the pause as the cause
        _seedLT(5e18, 0, 5 * quoteUnit);
        _sync();
        assertGt(seniorTranche.maxRedeem(ST_PROVIDER), 0, "senior redemption capacity must be live before the pause");
        assertGt(liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER), 0, "the multi-asset maximum must be live before the pause");

        _pauseKernel();

        assertEq(toUint256(seniorTranche.maxDeposit(ST_PROVIDER)), 0, "a paused kernel must zero senior deposit capacity");
        assertEq(seniorTranche.maxRedeem(ST_PROVIDER), 0, "a paused kernel must zero senior redemption capacity");
        assertEq(toUint256(juniorTranche.maxDeposit(JT_PROVIDER)), 0, "a paused kernel must zero junior deposit capacity");
        assertEq(juniorTranche.maxRedeem(JT_PROVIDER), 0, "a paused kernel must zero junior redemption capacity");
        assertEq(toUint256(liquidityTranche.maxDeposit(LT_PROVIDER)), 0, "a paused kernel must zero liquidity deposit capacity");
        assertEq(liquidityTranche.maxRedeem(LT_PROVIDER), 0, "a paused kernel must zero liquidity in-kind redemption capacity");
        assertEq(liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER), 0, "a paused kernel must zero the multi-asset redemption maximum");
    }

    /**
     * @notice A paused kernel reverts every price-bearing read so an integrator can never consume a stale or faulty
     *         mark while the market is halted for a mispricing or other incident
     * @dev In-kind previews simulate the real whenNotPaused kernel deposit and redeem entrypoints, so the pause
     *      bubbles out of them exactly as it would out of execution. Conversions and multi-asset previews route
     *      through the kernel's whenNotPaused previewSyncTrancheAccounting, and the senior share rate the venue
     *      prices against is itself whenNotPaused, so the pool cannot trade on a paused mark
     */
    function test_PausedKernel_PriceBearingReadsRevert() public {
        _pauseKernel();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.previewDeposit(toTrancheUnits(1e18));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.previewRedeem(1e18);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.convertToAssets(1e18);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.convertToShares(toTrancheUnits(1e18));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        liquidityTranche.previewDepositMultiAsset(1e18, quoteUnit);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        liquidityTranche.previewRedeemMultiAsset(1e18);
        // The senior share rate the Balancer pool prices its senior leg against also reverts under the pause
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        kernel.getRate();
    }

    // ---------------------------------------------------------------------
    // The tranche enforces no pause of its own: the kernel is the sole pause authority
    // ---------------------------------------------------------------------

    /**
     * @notice A tranche-level pause is inert: it sets the tranche's own flag (bound for parity with the other
     *         Constants, mirroring the accountant) but gates nothing, because every tranche operation and token
     *         movement is gated on the kernel's pause. Only pausing the kernel freezes the tranche
     * @dev An operator who reaches for a tranche pause changes nothing, so the market's single pause authority is the
     *      kernel: this pins that a tranche flag is inert while a kernel pause is enforced on the same flow
     */
    function test_TranchePauseIsInert_KernelIsSolePauseAuthority() public {
        address recipient = makeAddr("INERT_PAUSE_RECIPIENT");

        // Pausing the senior tranche sets its own flag but does not gate its operations
        vm.prank(PAUSER);
        IRoycoAuth(address(seniorTranche)).pause();
        assertTrue(PausableUpgradeable(address(seniorTranche)).paused(), "the tranche pause sets the tranche's own flag");

        // A transfer still lands: the tranche flag enforces nothing
        vm.prank(ST_PROVIDER);
        seniorTranche.transfer(recipient, 1e18);
        assertEq(seniorTranche.balanceOf(recipient), 1e18, "a tranche-level pause must not gate transfers");

        // Only the kernel pause freezes the same flow
        _pauseKernel();
        vm.prank(ST_PROVIDER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        seniorTranche.transfer(recipient, 1e18);
    }

    // ---------------------------------------------------------------------
    // Recovery: unpausing restores flow
    // ---------------------------------------------------------------------

    function test_UnpauseRestoresFlow() public {
        _pauseKernel();
        vm.prank(UNPAUSER);
        kernel.unpause();
        stJtVault.mintShares(ST_PROVIDER, collateralUnit);
        vm.startPrank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), collateralUnit);
        seniorTranche.deposit(toTrancheUnits(collateralUnit), ST_PROVIDER); // no revert
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

    /// @dev A sum that overflows uint64 panics (0x11) in the checked `_maxJT + _maxLT` addition before the named
    ///      INVALID_MAX_YIELD_SHARE_CONFIG can be raised, so the arithmetic panic is the observed revert.
    function test_MaxYieldShareSum_OverflowingUint64_PanicsBeforeNamedError() public {
        vm.prank(ACCOUNTANT_ADMIN);
        vm.expectRevert(stdError.arithmeticError);
        accountant.setMaxYieldShares(type(uint64).max, 1);
    }
}
