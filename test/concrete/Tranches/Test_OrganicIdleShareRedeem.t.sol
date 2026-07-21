// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title Test_OrganicIdleShareRedeem
 * @notice An organic in-kind LT redemption is a valid op shape yet reverts LIQUIDITY_REQUIREMENT_VIOLATED, not on the
 *         op-shape check. The same perpetual premium accrual that stages the idle pile also drives the market
 *         liquidity-deficient, and a deficient market blocks every LT redemption. The whole state is reached through
 *         public functions, no manual storage seeding or direct doPostOp calls (the companion coverage in
 *         Test_FeeAndLiquidityPremium builds the same shape with the mock-kernel doPostOp).
 * @dev How the organic state is reached:
 *      1. Venue slippage is armed (setVenueSlippageMode) so the reinvestment gate deterministically defers on
 *         every sync, the liquidity premium accrues as staged idle ST shares (kernel `ltOwnedSeniorTrancheShares`)
 *         and NEVER deploys into BPT, so the pooled BPT count (`ltOwnedYieldBearingAssets`) is frozen at the seed.
 *      2. Senior yield is accrued and synced repeatedly. Each sync stages more idle premium (the NET premium after
 *         the LT protocol fee is carved off). A sync mints NO liquidity-tranche shares, so the LT SUPPLY stays frozen
 *         at the seed and tracks the frozen BPT count exactly, while the idle ST-share pile grows without bound.
 *      3. Once `idle >= ltSupply` (so a 1-share idle slice is >= 1 wei), redeeming a single LT share in-kind takes a
 *         proportional BPT slice plus its idle premium slice, a valid redemption shape (a redemption never grows the
 *         LT's deployed raw NAV). The senior effective NAV grew while the pooled depth stayed frozen, so liquidity
 *         utilization has drifted above its limit, and the post-op liquidity requirement rejects the redemption. The
 *         redeemer's premium is not stranded, it waits until the market re-liquifies.
 */
contract Test_OrganicIdleShareRedeem is DayMarketTestBase {
    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        // Seed the market (JT first, then ST with its auto-seeded minimal LT depth).
        _seedMarket(1000 * stUnit, 500 * stUnit);
        // Arm persistent venue slippage so every reinvestment defers: the premium stages as idle ST shares and
        // the pooled BPT count stays frozen from here on.
        setVenueSlippageMode(true);
    }

    function _ltSupply() internal view returns (uint256) {
        return liquidityTranche.totalSupply();
    }

    function _bptCount() internal view returns (uint256) {
        return toUint256(kernel.getState().ltOwnedYieldBearingAssets);
    }

    function _idleShares() internal view returns (uint256) {
        return kernel.getState().ltOwnedSeniorTrancheShares;
    }

    function test_inKindLtRedeem_idlePremiumOverhang_revertsLiquidityRequirement_organic() public {
        // Accrue senior yield and sync until the idle premium pile overtakes the frozen LT supply. A sync mints no LT
        // shares, so supply stays pinned to the frozen BPT count. Big up-only yields keep the market PERPETUAL and make
        // the LDM pay a large premium.
        uint256 supply;
        uint256 bpt;
        uint256 idle;
        bool reached;
        for (uint256 i = 0; i < 20; ++i) {
            applySTPnL(5000); // +50% senior yield this window
            _warpAndRefreshFeed(7 days);
            syncVenuePrices();
            _sync();

            supply = _ltSupply();
            bpt = _bptCount();
            idle = _idleShares();
            // A sync mints no LT shares, so the supply never inflates above the frozen BPT count.
            assertEq(supply, bpt, "no sync mints LT shares, so supply tracks the frozen BPT count");
            // Target state: a single-share idle slice is at least 1 wei (idle >= supply).
            if (idle >= supply) {
                reached = true;
                break;
            }
        }

        assertTrue(reached, "organic accrual must reach idle >= ltSupply == bptCount");

        // The premium never deployed: the BPT count is exactly the frozen seed depth, all premium is staged idle.
        assertGt(idle, 0, "the staged idle premium ST shares must be positive");

        // Mirror the in-kind redeem's floored slices for a 1-wei LT-share redemption (TrancheClaimsLogic._scaleAssetClaims).
        // The LT fee no longer mints LT shares, so supply == bpt and a 1-share BPT slice is a positive 1 wei, while the
        // idle slice is at least 1 wei because idle >= supply.
        uint256 bptSlice = (bpt * 1) / supply; // == 1 because bpt == supply
        uint256 idleSlice = (idle * 1) / supply; // >= 1 because idle >= supply
        assertEq(bptSlice, 1, "the proportional BPT slice is a positive 1 wei");
        assertGe(idleSlice, 1, "the proportional idle ST-share slice must be positive");

        // Cross-check against the real redeem quote: previewRedeem executes the actual redemption path, so in this
        // liquidity-deficient market it bubbles the exact liquidity-gate revert the execution below hits. The preview
        // agrees with exec that the shape is valid but the gate blocks it, no quote exists for a blocked redemption.
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        liquidityTranche.previewRedeem(1);

        assertGe(liquidityTranche.balanceOf(LT_PROVIDER), 1, "the redeemer must hold the LT share it redeems");

        // Redeeming that single LT share in-kind reverts, but not on the op-shape invariant. The redemption pulls a
        // proportional BPT slice and its idle premium slice, a valid shape (a redemption never grows the LT's deployed
        // raw NAV), so it reaches the liquidity requirement, which the perpetual premium accrual has already driven past
        // its limit: senior effective NAV climbed while the pooled depth stayed frozen. A liquidity-deficient market
        // blocks every LT redemption, so the premium waits until the market re-liquifies rather than being stranded by
        // the shape check.
        vm.prank(LT_PROVIDER);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        liquidityTranche.redeem(1, LT_PROVIDER, LT_PROVIDER);
    }
}
