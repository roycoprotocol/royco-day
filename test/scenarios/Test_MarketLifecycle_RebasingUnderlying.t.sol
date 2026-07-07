// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { MarketState, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { toUint256 } from "../../src/libraries/Units.sol";
import { FixtureCell } from "../utils/FixtureTypes.sol";
import { cellH } from "../utils/TokenConfigs.sol";
import { Test_MarketLifecycleBase } from "./Test_MarketLifecycleBase.t.sol";

/**
 * @title Test_MarketLifecycle_RebasingUnderlying_NonStandardTokens
 * @notice Market lifecycle on a rebasing ST/JT vault underlying (balance reads scale by a settable index),
 *         over the baseline 4626(18,18) shares and 6-decimal quote
 * @dev The inherited lifecycle's exact constants hold unchanged: the rebase index starts at 1.0 and no lifecycle
 *      flow moves it, and even a moved index cannot reach a tranche mark because the market custodies the 4626
 *      SHARE, whose assets-per-share rate moves only via the explicit PnL feed. Rebase-driven yield therefore
 *      models as a rate move (applySTPnL), never as a silent balance drift
 * @dev Nightly-only concrete, matched by the shared NonStandardTokens contract-name suffix
 *      (forge test --match-contract NonStandardTokens)
 */
contract Test_MarketLifecycle_RebasingUnderlying_NonStandardTokens is Test_MarketLifecycleBase {
    function _tokenShape() internal pure override returns (FixtureCell memory) {
        return cellH();
    }

    /**
     * @dev Hand derivation for this shape: one whole ST asset = 1e18 share-wei, at initialRateWAD 1.0 that
     *      converts to 1e18 underlying-wei = 1.0 whole 18-decimal underlying, and the 1.0 oracle price maps one
     *      whole underlying to exactly 1e18 NAV wei. The rebase index sits at 1.0 and scales nothing here
     */
    function _expectedSTUnitNAV() internal pure override returns (uint256) {
        return 1e18;
    }

    /**
     * @notice A live underlying rebase scales wallet balances but drifts every tranche mark by EXACTLY zero,
     *         even through a full tranche accounting sync a day later
     * @dev Seeds the canonical market, snapshots every mark, rebases the underlying +10% and proves the index
     *      really fired at the wallet layer while every market mark stayed byte-identical. Then warps a day and
     *      syncs: the sync must book zero senior gain, zero premium, and zero fees — the derived drift bound is
     *      exactly zero, not a tolerance. Why it matters: the kernel custodies 4626 shares priced by an explicit
     *      rate, so an underlying index move the vault has not folded into its rate must be invisible to NAV,
     *      and rebase yield must be driven through the rate feed (applySTPnL), never leak in sideways
     */
    function test_RebasingUnderlying_scalesWalletBalancesButNeverAnyTrancheMark() public {
        _seedDefault();
        uint256 stNavBefore = toUint256(seniorTranche.totalAssets().nav);
        uint256 jtNavBefore = toUint256(juniorTranche.totalAssets().nav);
        uint256 ltNavBefore = toUint256(liquidityTranche.getRawNAV());

        // The rebase flag is live: 100 whole underlying minted at index 1.0 (100e18 internal shares) must read
        // 100e18 x 1.1e18 / 1e18 = 110e18 after a +10% index move
        address holder = makeAddr("REBASE_PROBE");
        stJtUnderlying.mint(holder, 100e18);
        stJtUnderlying.setRebaseFactorWAD(1.1e18);
        assertEq(stJtUnderlying.balanceOf(holder), 110e18, "the armed rebase index must scale wallet balance reads");

        // No tranche mark may move: the kernel holds vault SHARES and the share rate is still exactly 1.0
        assertEq(toUint256(seniorTranche.totalAssets().nav), stNavBefore, "an underlying rebase must not move the senior mark");
        assertEq(toUint256(juniorTranche.totalAssets().nav), jtNavBefore, "an underlying rebase must not move the junior mark");
        assertEq(toUint256(liquidityTranche.getRawNAV()), ltNavBefore, "an underlying rebase must not move the LT depth mark");

        // Drift bound through a full sync is exactly zero: a day passes with the rebase armed, and the sync must
        // read the seeded marks byte-identically (stRaw = stEff = 100e18, jtRaw = jtEff = 30e18) with zero gain,
        // so zero premium and zero fees accrue despite the non-empty premium accrual window
        _warpAndRefreshFeed(1 days);
        SyncedAccountingState memory state = _sync();
        assertEq(toUint256(state.stRawNAV), 100e18, "post-rebase sync: stRawNAV must still be 100 whole shares x 1.0 x 1.0");
        assertEq(toUint256(state.jtRawNAV), 30e18, "post-rebase sync: jtRawNAV must still be 30 whole shares x 1.0 x 1.0");
        assertEq(toUint256(state.stEffectiveNAV), 100e18, "post-rebase sync: stEff must be unchanged (zero gain to split)");
        assertEq(toUint256(state.jtEffectiveNAV), 30e18, "post-rebase sync: jtEff must be unchanged (zero gain to split)");
        assertEq(toUint256(state.ltLiquidityPremium), 0, "post-rebase sync: zero senior gain must pay zero liquidity premium");
        assertEq(toUint256(state.stProtocolFee), 0, "post-rebase sync: zero gain must take zero ST fee");
        assertEq(toUint256(state.jtProtocolFee), 0, "post-rebase sync: zero gain must take zero JT fee");
        assertEq(toUint256(state.ltProtocolFee), 0, "post-rebase sync: zero premium must take zero LT fee");
        assertEq(toUint256(state.ltRawNAV), SEEDED_LT_RAW_NAV, "post-rebase sync: the committed LT depth must be the seeded 26e18");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "post-rebase sync: a zero-drift sync must stay PERPETUAL");
    }
}
