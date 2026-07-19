// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { AssetClaims, SyncedAccountingState, TrancheType } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_PreviewSyncLTClaimsNavParity
 * @notice Pins the preview/execution parity of the LIQUIDITY branch of previewSyncTrancheAccounting: the returned
 *         claims struct must be internally consistent, valuing its own (post-mint patched) stShares at the same
 *         post-mint senior pair the execution path's storage-derived claims would use — claims.nav must equal
 *         ltRawNAV plus the value of claims.stShares at (stEffectiveNAV / post-mint ST supply)
 * @dev The post-mint ST supply is read from the SENIOR branch of the same preview (its totalTrancheShares return),
 *      and the share valuation goes through ValuationLogic._convertToValue — the exact primitive the execution
 *      path's claims derivation resolves through — so the expected value is production math, not a reimplementation
 */
contract Test_PreviewSyncLTClaimsNavParity is DayMarketTestBase {
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        // ST 100e18 / JT 30e18 vault shares plus the base's auto-seeded quote-only LT depth
        _seedMarket(100e18, 30e18);
    }

    /// @dev The parity assertion: claims.nav == ltRawNAV + value(claims.stShares @ stEffectiveNAV / post-mint ST supply)
    function _assertLTClaimsNavMatchesPostMintPair(string memory _ctx) internal {
        (SyncedAccountingState memory state, AssetClaims memory ltClaims,) = kernel.previewSyncTrancheAccounting(TrancheType.LIQUIDITY);
        // The SENIOR branch's totalTrancheShares is the post-mint ST supply (premium + ST fee shares included)
        (,, uint256 stSupplyAfterMints) = kernel.previewSyncTrancheAccounting(TrancheType.SENIOR);

        uint256 expectedNav = toUint256(state.ltRawNAV)
            + toUint256(ValuationLogic._convertToValue(ltClaims.stShares, stSupplyAfterMints, state.stEffectiveNAV, Math.Rounding.Floor));
        assertEq(
            toUint256(ltClaims.nav), expectedNav, string.concat(_ctx, ": preview LT claims.nav must value its post-mint stShares at the post-mint senior pair")
        );
    }

    /**
     * @notice With no pending accrual the parity holds trivially: no premium or fee shares are pending, the
     *         post-mint pair equals the storage pair, and claims.nav == ltRawNAV (+ any staged share value)
     */
    function test_PreviewLTClaimsNav_MatchesPostMintPair_NoPendingAccrual() public {
        _assertLTClaimsNavMatchesPostMintPair("flat market");
    }

    /**
     * @notice With a PENDING premium accrual (unsynced ST gain + elapsed time), the preview patches claims.stShares
     *         to the post-mint count (storage count plus this sync's premium shares), so claims.nav must value that
     *         same post-mint count at the post-mint senior supply — exactly what the execution path's claims
     *         derivation reads from storage after the real mints
     * @dev At the divergence: the un-patched nav is computed from the PRE-mint (storage stShares, pre-mint ST supply)
     *      pair at line 88's derivation, so it misses the just-accrued premium value entirely (storage stShares is
     *      zero here) while claims.stShares reports the pending premium shares
     */
    function test_PreviewLTClaimsNav_MatchesPostMintPair_PendingPremiumAccrual() public {
        // Accrue a pending premium: +100% ST PnL over a 1-day window, previewed WITHOUT syncing
        applySTPnL(10_000);
        _warpAndRefreshFeed(1 days);

        // Sanity: the previewed sync must actually be paying a liquidity premium for this vector to bite
        (SyncedAccountingState memory state, AssetClaims memory ltClaims,) = kernel.previewSyncTrancheAccounting(TrancheType.LIQUIDITY);
        assertGt(toUint256(state.ltLiquidityPremium), 0, "the previewed sync must accrue a liquidity premium");
        assertGt(ltClaims.stShares, 0, "the preview must patch stShares to the post-mint premium share count");

        _assertLTClaimsNavMatchesPostMintPair("pending premium accrual");
    }

    /**
     * @notice The consumer-surface pin: an in-kind LT previewRedeem quoted across a PENDING premium accrual must
     *         match the claims the actual redeem settles, leg for leg — including the nav leg, which scales the
     *         preview's LT effective NAV and therefore diverged before the post-mint-pair fix
     * @dev Venue slippage is armed so the redeem's pre-op sync stages the premium instead of deploying it,
     *      keeping the LT composition (BPT depth + idle senior shares) identical between the preview instant and
     *      the redeem's post-mint state, which is what makes leg-by-leg equality the correct expectation
     * @dev The PnL and redeem sizes are kept small so the post-redemption liquidity requirement stays satisfied
     */
    function test_PreviewRedeem_MatchesRedeem_AcrossPendingPremiumAccrual() public {
        // Stage-only premium path: the single-sided deploy always fails its slippage gate
        setVenueSlippageMode(true);

        // Accrue a pending premium: +10% ST PnL over a 1-day window, NOT synced before the preview
        applySTPnL(1000);
        _warpAndRefreshFeed(1 days);

        // Sanity: a premium must actually be pending
        (SyncedAccountingState memory state,,) = kernel.previewSyncTrancheAccounting(TrancheType.LIQUIDITY);
        assertGt(toUint256(state.ltLiquidityPremium), 0, "the previewed sync must accrue a liquidity premium");

        // Quote a small in-kind redemption with the accrual still pending, then execute it
        uint256 shares = liquidityTranche.balanceOf(LT_PROVIDER) / 20;
        AssetClaims memory quoted = liquidityTranche.previewRedeem(shares);

        vm.prank(LT_PROVIDER);
        AssetClaims memory settled = liquidityTranche.redeem(shares, LT_PROVIDER, LT_PROVIDER);

        assertEq(toUint256(quoted.ltAssets), toUint256(settled.ltAssets), "quoted vs settled: ltAssets (BPT slice)");
        assertEq(quoted.stShares, settled.stShares, "quoted vs settled: stShares (idle premium slice)");
        assertEq(toUint256(quoted.stAssets), toUint256(settled.stAssets), "quoted vs settled: stAssets");
        assertEq(toUint256(quoted.jtAssets), toUint256(settled.jtAssets), "quoted vs settled: jtAssets");
        assertEq(toUint256(quoted.nav), toUint256(settled.nav), "quoted vs settled: nav (the leg the stale pre-mint pair broke)");
    }
}
