// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { VIRTUAL_SHARES } from "../../../src/libraries/Constants.sol";
import { Operation } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";

/**
 * @title Test_OrganicIdleShareRedeem
 * @notice An organic in-kind LPT redemption whose BPT slice floors to zero (idle-premium-only) is NOT a valid op
 *         shape: the LPT_REDEMPTION guard is strict deltaLPTRawNAV < 0, and a redemption that moves no deployed BPT
 *         leaves deltaLPTRawNAV == 0, so the op-shape check reverts INVALID_POST_OP_STATE(LPT_REDEMPTION) BEFORE the
 *         liquidity requirement is ever reached. The whole state is reached through public functions, no manual
 *         storage seeding or direct doPostOp calls (the companion coverage in Test_FeeAndLiquidityPremium builds the
 *         same shape with the mock-kernel doPostOp).
 * @dev How the organic state is reached:
 *      1. Venue slippage is armed (setVenueSlippageMode) so the reinvestment gate deterministically defers on
 *         every sync, the liquidity premium accrues as staged idle ST shares (kernel `lptOwnedSeniorTrancheShares`)
 *         and NEVER deploys into BPT, so the pooled BPT count (`totalLPTAssets`) is frozen at the seed.
 *      2. Senior yield is accrued and synced repeatedly. Each sync stages more idle premium (the NET premium after
 *         the LPT protocol fee is carved off). A sync mints NO liquidity-provider-tranche shares, so the LPT SUPPLY stays frozen
 *         at the seed and tracks the frozen BPT count exactly, while the idle ST-share pile grows without bound.
 *      3. Once `idle >= lptSupply + VIRTUAL_SHARES` (so a 1-share idle slice is >= 1 wei against the effective
 *         supply), redeeming a single LPT share in-kind takes only its idle premium slice: the 1-share BPT slice
 *         floors to zero under the virtual-shares offset, so the redemption moves no deployed BPT and its
 *         deltaLPTRawNAV is exactly zero. The strict op-shape guard (deltaLPTRawNAV < 0) rejects that zero-delta
 *         shape and reverts INVALID_POST_OP_STATE(LPT_REDEMPTION) before the liquidity requirement is evaluated.
 */
contract Test_OrganicIdleShareRedeem is DayMarketTestBase {
    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.collateralAsset.decimals);
        // Seed the market (JT first, then ST with its auto-seeded minimal LPT depth).
        _seedMarket(1000 * stUnit, 500 * stUnit);
        // Arm persistent venue slippage so every reinvestment defers: the premium stages as idle ST shares and
        // the pooled BPT count stays frozen from here on.
        setVenueSlippageMode(true);
    }

    function _lptSupply() internal view returns (uint256) {
        return liquidityProviderTranche.totalSupply();
    }

    function _bptCount() internal view returns (uint256) {
        return toUint256(kernel.getState().totalLPTAssets);
    }

    function _idleShares() internal view returns (uint256) {
        return kernel.getState().lptOwnedSeniorTrancheShares;
    }

    function test_inKindLptRedeem_idlePremiumOverhang_revertsInvalidPostOpState_organic() public {
        // Accrue senior yield and sync until the idle premium pile overtakes the frozen LPT supply. A sync mints no LPT
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

            supply = _lptSupply();
            bpt = _bptCount();
            idle = _idleShares();
            // A sync mints no LPT shares, so the supply never inflates above the frozen BPT count.
            assertEq(supply, bpt, "no sync mints LPT shares, so supply tracks the frozen BPT count");
            // Target state: a single-share idle slice is at least 1 wei against the effective supply
            // (idle >= supply + VIRTUAL_SHARES, the _scaleAssetClaims denominator).
            if (idle >= supply + VIRTUAL_SHARES) {
                reached = true;
                break;
            }
        }

        assertTrue(reached, "organic accrual must reach idle >= lptSupply + VIRTUAL_SHARES");

        // The premium never deployed: the BPT count is exactly the frozen seed depth, all premium is staged idle.
        assertGt(idle, 0, "the staged idle premium ST shares must be positive");

        // Mirror the in-kind redeem's floored slices for a 1-wei LPT-share redemption: _scaleAssetClaims scales every
        // leg over the EFFECTIVE supply (supply + VIRTUAL_SHARES). With bpt == supply the 1-share BPT slice floors to
        // zero under the offset, while the idle slice is at least 1 wei because idle >= supply + VIRTUAL_SHARES, so
        // the redemption's shape is carried by the idle premium leg alone.
        uint256 bptSlice = (bpt * 1) / (supply + VIRTUAL_SHARES); // == 0 because bpt == supply < supply + VIRTUAL_SHARES
        uint256 idleSlice = (idle * 1) / (supply + VIRTUAL_SHARES); // >= 1 because idle >= supply + VIRTUAL_SHARES
        assertEq(bptSlice, 0, "the 1-share BPT slice floors to zero against the effective supply");
        assertGe(idleSlice, 1, "the proportional idle ST-share slice must be positive");

        // Cross-check against the real redeem quote: previewRedeem executes the actual redemption path, so it bubbles
        // the exact op-shape revert the execution below hits. With the BPT slice floored to zero the redemption's
        // deltaLPTRawNAV is zero, which the strict op-shape guard rejects, no quote exists for a rejected shape.
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_REDEMPTION));
        liquidityProviderTranche.previewRedeem(1);

        assertGe(liquidityProviderTranche.balanceOf(LPT_PROVIDER), 1, "the redeemer must hold the LPT share it redeems");

        // Redeeming that single LPT share in-kind reverts on the op-shape invariant, BEFORE any liquidity check. The
        // redemption pulls only its idle premium slice (the BPT leg floors to zero), so it moves no deployed BPT and
        // its deltaLPTRawNAV is exactly zero. The LPT_REDEMPTION guard is strict deltaLPTRawNAV < 0, so a zero-delta
        // idle-premium-only redemption is not a valid shape and reverts INVALID_POST_OP_STATE(LPT_REDEMPTION) before
        // the liquidity requirement is ever evaluated.
        vm.prank(LPT_PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LPT_REDEMPTION));
        liquidityProviderTranche.redeem(1, LPT_PROVIDER, LPT_PROVIDER);
    }
}
