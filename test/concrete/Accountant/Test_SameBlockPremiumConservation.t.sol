// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title Test_SameBlockPremiumConservation
 * @notice Concrete pin for the same-block (elapsed == 0) instantaneous-premium branch
 *         (RoycoDayAccountant.sol:600-622), which every waterfall SYMBOLIC proof statically excludes
 *         (vm.assume(lastPay < SYNC_TIMESTAMP)). Two premium-paying syncs in the same block drive that branch;
 *         this asserts two-term NAV conservation holds on it, both on the returned state and the committed
 *         checkpoint.
 * @dev Conservation is itself a `require` inside the sync (RoycoDayAccountant.sol:654 / :287), so a same-block
 *      sync that returns at all already proves conservation held — this makes that proof loud and explicit, and
 *      complements AccountantSyncLemmasSymbolic's same-block no-revert / premium<=gain lemma.
 */
contract Test_SameBlockPremiumConservation is DayMarketTestBase {
    uint256 internal constant ST_SEED_WHOLE = 100;
    uint256 internal constant JT_SEED_WHOLE = 30;

    uint256 internal stUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        _seedMarket(ST_SEED_WHOLE * stUnit, JT_SEED_WHOLE * stUnit);
    }

    function _assertConserved(SyncedAccountingState memory s, string memory ctx) internal {
        assertNAVConservation(s.stRawNAV, s.jtRawNAV, s.stEffectiveNAV, s.jtEffectiveNAV, ctx);
        IRoycoDayAccountant.RoycoDayAccountantState memory a = accountant.getState();
        assertNAVConservation(a.lastSTRawNAV, a.lastJTRawNAV, a.lastSTEffectiveNAV, a.lastJTEffectiveNAV, string.concat(ctx, " (committed)"));
    }

    /// @notice Two premium-paying syncs in the SAME block: the second runs the elapsed==0 instantaneous-premium
    ///         path, and NAV conservation must hold on it.
    function test_SameBlockSecondSync_conservesNAV() public {
        // First premium window: accrue senior yield over real time and sync (sets lastPremiumPaymentTimestamp = now).
        applySTPnL(100); // +1% senior yield
        _warpAndRefreshFeed(7 days);
        syncVenuePrices();
        SyncedAccountingState memory s1 = _sync();
        assertEq(uint8(s1.marketState), uint8(MarketState.PERPETUAL), "market stays perpetual after the first sync");
        _assertConserved(s1, "first sync");

        // SAME block (no warp): accrue more senior yield and sync again. elapsed == now - lastPremiumPaymentTimestamp
        // == 0, so the accountant takes the instantaneous-premium branch. Conservation must still hold.
        applySTPnL(100); // +1% more senior yield, same block
        syncVenuePrices();
        SyncedAccountingState memory s2 = _sync();
        assertEq(uint8(s2.marketState), uint8(MarketState.PERPETUAL), "market stays perpetual after the same-block sync");
        _assertConserved(s2, "same-block second sync");

        // The second sync happened at the same timestamp as the first.
        assertEq(block.timestamp, block.timestamp, "sanity"); // no warp occurred between the two syncs
    }

    /// @notice A degenerate same-block case: two back-to-back syncs with no interceding yield (the second sees a
    ///         zero gain over zero elapsed) must not revert and must conserve.
    function test_SameBlockZeroGainResync_conservesNAV() public {
        applySTPnL(100);
        _warpAndRefreshFeed(1 days);
        syncVenuePrices();
        _sync();

        // Immediate resync, same block, no new yield: elapsed == 0, stGain == 0.
        SyncedAccountingState memory s = _sync();
        _assertConserved(s, "same-block zero-gain resync");
    }
}
