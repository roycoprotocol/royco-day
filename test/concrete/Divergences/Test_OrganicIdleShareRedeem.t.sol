// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { Operation } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title Test_Divergence3OrganicIdleShareRedeem
 * @notice Reproduces Divergence 3 (in-kind LT redemption reverts when the BPT slice floors to zero while the idle
 *         premium ST-share slice is positive) reaching the triggering state ENTIRELY through public functions —
 *         no manual storage seeding or direct doPostOp calls (the existing pin in Test_FeeAndLiquidityPremium
 *         builds the state with the mock-kernel doPostOp).
 * @dev How the organic state is reached:
 *      1. Venue slippage is armed (setVenueSlippageMode) so the reinvestment gate deterministically defers on
 *         every sync — the liquidity premium accrues as staged idle ST shares (kernel `ltOwnedSeniorTrancheShares`)
 *         and NEVER deploys into BPT, so the pooled BPT count (`ltOwnedYieldBearingAssets`) is frozen at the seed.
 *      2. Senior yield is accrued and synced repeatedly. Each sync stages more idle premium AND mints a small LT
 *         protocol-fee share tranche against the (idle-inflated) LT effective NAV, so the LT share SUPPLY grows
 *         above the frozen BPT count while the idle ST-share pile grows even faster.
 *      3. Once `bptCount < ltSupply` (so a 1-share BPT slice floors to zero) and `idle >= ltSupply` (so a 1-share
 *         idle slice is >= 1 wei), redeeming a single LT share in-kind has deltaLTRawNAV == 0 and
 *         totalSTAndJTRedemptionNAV == 0 — the LT_REDEEM op-shape require (RoycoDayAccountant.sol:263) reverts,
 *         even though the redeemer was owed a positive slice of staged premium.
 */
contract Test_Divergence3OrganicIdleShareRedeem is DayMarketTestBase {
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

    function test_DIVERGENCE_3_organic_zeroBPTSliceWithIdleShares_revertsThroughPublicFlows() public {
        // Accrue senior yield and sync until the idle premium pile and the LT-fee-diluted supply overtake the
        // frozen BPT count. Big up-only yields keep the market PERPETUAL and make the LDM pay a large premium.
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
            // Target state: a single-share BPT slice floors to zero (bpt < supply) while a single-share idle
            // slice is at least 1 wei (idle >= supply).
            if (bpt < supply && idle >= supply) {
                reached = true;
                break;
            }
        }

        assertTrue(reached, "organic accrual must reach bptCount < ltSupply <= idle");

        // The premium never deployed: the BPT count is exactly the frozen seed depth, all premium is staged idle.
        assertGt(idle, 0, "the staged idle premium ST shares must be positive");

        // Mirror the in-kind redeem's floored slices for a 1-wei LT-share redemption (TrancheClaimsLogic._scaleAssetClaims).
        uint256 bptSlice = (bpt * 1) / supply; // floors to 0 because bpt < supply
        uint256 idleSlice = (idle * 1) / supply; // >= 1 because idle >= supply
        assertEq(bptSlice, 0, "the proportional BPT slice must floor to zero");
        assertGe(idleSlice, 1, "the proportional idle ST-share slice must be positive");
        assertGe(liquidityTranche.balanceOf(LT_PROVIDER), 1, "the redeemer must hold the LT share it redeems");

        // Redeeming that single LT share in-kind reverts: the op moves no marked NAV (zero BPT delta, zero
        // ST/JT redemption), so the LT_REDEEM op-shape invariant rejects it — the staged premium is stranded on
        // the in-kind path, exactly as Divergence 3 documents.
        vm.prank(LT_PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_REDEEM));
        liquidityTranche.redeem(1, LT_PROVIDER, LT_PROVIDER);
    }
}
