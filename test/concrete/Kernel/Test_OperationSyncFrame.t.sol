// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../../lib/forge-std/src/Vm.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_OperationSyncFrame
 * @notice Pins the exact accounting-sync event count per operation and the reinvestment tail's position inside
 *         the operation's price frame: the tail must consume the frame's cached senior share rate (a cache hit)
 *         and deploy the idle premium pile WITHOUT any additional sync, which is exactly what the kernel's
 *         modifier order guarantees (withPriceCache OUTERMOST, wrapping withLiquidityPremiumReinvestment, so the
 *         tail runs before the frame clears its caches)
 * @dev The load-bearing failure this suite must catch: if the modifiers are reordered the tail runs outside the
 *      cleared price frame, cache-misses the senior share rate, and resyncs
 *      (AccountingSyncLogic.reinvestLiquidityPremium syncs ONLY on a cache miss), emitting an extra
 *      PreOpTrancheAccountingSynced after the operation's final post-op, which fails both the exact counts and
 *      the last-sync-is-a-post-op pin below
 */
contract Test_OperationSyncFrame is DayMarketTestBase {
    /// @dev One whole quote token in its native decimals (this market's quote asset uses 6 decimals, so 1e6)
    uint256 internal QUOTE_UNIT;

    /// @dev The same genuinely-binding fixture as the multi-asset boundary suite: real two-leg pool depth so a
    ///      multi-asset redemption runs both its LPT and ST legs
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        QUOTE_UNIT = 10 ** uint256(cell.quoteAsset.decimals);
        _seedMarket(100_000e18, 30_000e18);
        _seedLPT(10_000e18, 2000e18, 8000 * QUOTE_UNIT);
        _sync();
    }

    // =============================
    // Fixture helpers
    // =============================

    /// @dev Stages an idle premium pile with the reinvest gate OPEN: punitive venue slippage blocks deployment
    ///      while a realized senior gain mints the premium into the idle ledger, then the slippage is disarmed so
    ///      the next operation's tail deploys through the open gate
    function _stageIdlePremiumWithOpenGate() internal {
        setVenueSlippageMode(true);
        _warpAndRefreshFeed(1 days);
        applySTPnL(200);
        _sync();
        require(kernel.getState().lptOwnedSeniorTrancheShares != 0, "setup: expected the liquidity premium to sit as idle senior shares");
        setVenueSlippageMode(false);
    }

    /// @dev Tallies the operation's kernel-emitted sync frame from the recorded logs: the pre-op and post-op sync
    ///      counts, the reinvestment tail count, whether the chronologically last sync event is a post-op, and
    ///      whether the reinvestment fired after every sync event
    function _tallySyncFrame(Vm.Log[] memory _logs)
        internal
        view
        returns (uint256 preOps, uint256 postOps, uint256 reinvests, bool lastSyncIsPostOp, bool reinvestAfterAllSyncs)
    {
        bool sawSync;
        uint256 lastSyncIndex;
        bytes32 lastSyncTopic;
        bool sawReinvest;
        uint256 lastReinvestIndex;
        for (uint256 i = 0; i < _logs.length; i++) {
            if (_logs[i].emitter != address(kernel)) continue;
            bytes32 topic = _logs[i].topics[0];
            if (topic == IRoycoDayKernel.PreOpTrancheAccountingSynced.selector) preOps++;
            else if (topic == IRoycoDayKernel.PostOpTrancheAccountingSynced.selector) postOps++;
            else if (topic == IRoycoDayKernel.LiquidityPremiumReinvested.selector) reinvests++;
            else continue;
            if (topic == IRoycoDayKernel.LiquidityPremiumReinvested.selector) {
                (sawReinvest, lastReinvestIndex) = (true, i);
            } else {
                (sawSync, lastSyncIndex, lastSyncTopic) = (true, i, topic);
            }
        }
        lastSyncIsPostOp = sawSync && lastSyncTopic == IRoycoDayKernel.PostOpTrancheAccountingSynced.selector;
        reinvestAfterAllSyncs = sawReinvest && sawSync && lastReinvestIndex > lastSyncIndex;
    }

    // =============================
    // The per-operation sync frame pins
    // =============================

    /// @notice An in-kind ST deposit runs exactly one pre-op and one post-op sync, and its settled tail deploys
    ///         the staged idle premium pile with NO additional sync: LiquidityPremiumReinvested is the
    ///         operation's final accounting signal, emitted after the last post-op with no sync in between
    /// @dev Derived from the flow structure: the single-leg deposit is one DepositLogic.inkindDeposit frame, one
    ///      preOpSyncTrancheAccountingFor and one postOpSyncTrancheAccounting, then the tail values the pile at
    ///      the ST_SHARE_PRICE the post-op cached inside the still-open price frame (a cache hit, so no resync)
    function test_InKindSTDeposit_SyncFrame_ExactCountsAndSyncFreeReinvestTail() public {
        _stageIdlePremiumWithOpenGate();

        uint256 stAssets = 1000e18;
        assertGe(toUint256(seniorTranche.maxDeposit(ST_PROVIDER)), stAssets, "the fixture must leave senior deposit capacity");
        stJtVault.mintShares(ST_PROVIDER, stAssets);
        vm.prank(ST_PROVIDER);
        stJtVault.approve(address(seniorTranche), stAssets);

        vm.recordLogs();
        vm.prank(ST_PROVIDER);
        seniorTranche.deposit(toTrancheUnits(stAssets), ST_PROVIDER);

        (uint256 preOps, uint256 postOps, uint256 reinvests, bool lastSyncIsPostOp, bool reinvestAfterAllSyncs) = _tallySyncFrame(vm.getRecordedLogs());
        assertEq(preOps, 1, "an in-kind ST deposit must run exactly one pre-op sync");
        assertEq(postOps, 1, "an in-kind ST deposit must run exactly one post-op sync");
        assertEq(reinvests, 1, "the settled tail must deploy the staged pile exactly once");
        assertTrue(lastSyncIsPostOp, "the operation's final sync must be its post-op, the tail must not resync");
        assertTrue(reinvestAfterAllSyncs, "the reinvestment tail must fire after the final post-op with no sync in between");
        assertEq(kernel.getState().lptOwnedSeniorTrancheShares, 0, "the open gate must have deployed the entire pile");
    }

    /// @notice A multi-asset LPT redemption runs exactly two pre-op and two post-op syncs (one frame per composed
    ///         leg), and its settled tail deploys the remaining idle premium pile with NO additional sync after
    ///         the final post-op
    /// @dev Derived from the flow structure: RedemptionLogic.lptRedeemMultiAsset composes two inkindRedeem legs
    ///      (the LPT leg, then the ST leg redeeming the withdrawn and idle premium shares), each one pre-op plus
    ///      one post-op frame, while the venue removal between them syncs nothing. The tail then hits the
    ///      ST_SHARE_PRICE the ST leg's post-op cached, so it deploys without a resync
    function test_MultiAssetRedeem_SyncFrame_ExactCountsAndSyncFreeReinvestTail() public {
        _stageIdlePremiumWithOpenGate();
        uint256 shares = liquidityProviderTranche.balanceOf(LPT_PROVIDER) / 4;

        vm.recordLogs();
        vm.prank(LPT_PROVIDER);
        liquidityProviderTranche.redeemMultiAsset(shares, 0, 0, LPT_PROVIDER, LPT_PROVIDER);

        (uint256 preOps, uint256 postOps, uint256 reinvests, bool lastSyncIsPostOp, bool reinvestAfterAllSyncs) = _tallySyncFrame(vm.getRecordedLogs());
        assertEq(preOps, 2, "a multi-asset redemption must run exactly two pre-op syncs, one per composed leg");
        assertEq(postOps, 2, "a multi-asset redemption must run exactly two post-op syncs, one per composed leg");
        assertEq(reinvests, 1, "the settled tail must deploy the remaining pile exactly once for the operation");
        assertTrue(lastSyncIsPostOp, "the operation's final sync must be the ST leg's post-op, the tail must not resync");
        assertTrue(reinvestAfterAllSyncs, "the reinvestment tail must fire after the final post-op with no sync in between");
        assertEq(kernel.getState().lptOwnedSeniorTrancheShares, 0, "the open gate must have deployed the entire remaining pile");
    }
}
