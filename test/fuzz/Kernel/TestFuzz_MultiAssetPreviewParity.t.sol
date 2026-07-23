// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { LT_LP_ROLE } from "../../../src/factory/Roles.sol";
import { AssetClaims, MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { MarketFuzzTestBase } from "../../utils/MarketFuzzTestBase.sol";

/**
 * @title TestFuzz_MultiAssetPreviewParity_Kernel
 * @notice Fuzzes same-block preview/execute parity for the two MULTI-ASSET liquidity flows that
 *         TestFuzz_PreviewParity excludes: `depositMultiAsset` and `redeemMultiAsset`. Previously multi-asset
 *         deposit parity was only a ±30bps inequality on the real venue (Test_BalancerHooksAndReinvest) and
 *         redeem parity was a single fixture, on the deterministic mock venue exact parity must hold.
 * @dev Each preview is taken immediately before its execution in the same block, so any divergence in the
 *      multi-asset pricing path (senior-share mint sizing, venue add/remove, claim scaling) fails loudly.
 */
contract TestFuzz_MultiAssetPreviewParity_Kernel is MarketFuzzTestBase {
    using Math for uint256;

    function testFuzz_QuoteOnlyMultiAssetDeposit_PreviewMatchesExecution(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _vaultBps,
        uint256 _elapsed,
        uint256 _quoteSeed
    )
        public
    {
        _setupEvolvedMarket(_stSeed, _jtSeed, _vaultBps, _elapsed);
        uint256 quoteLeg = bound(_quoteSeed, 1, 1e12); // 1 quote wei up to 1e12 quote wei
        address a = makeAddr("MA_QUOTE");
        accessManager.grantRole(LT_LP_ROLE, a, 0);
        quoteToken.mint(a, quoteLeg);
        vm.startPrank(a);
        quoteToken.approve(address(liquidityTranche), quoteLeg);
        uint256 previewed;
        try liquidityTranche.previewDepositMultiAsset(0, quoteLeg) returns (uint256 p, uint256) {
            previewed = p;
        } catch {
            vm.stopPrank();
            return; // dust input floors to zero shares (MUST_MINT_NON_ZERO_SHARES), not a parity case
        }
        if (previewed == 0) {
            vm.stopPrank();
            return;
        }
        (uint256 minted,) = liquidityTranche.depositMultiAsset(0, quoteLeg, 0, a);
        vm.stopPrank();
        assertEq(minted, previewed, "quote-only multi-asset deposit must mint exactly the previewed shares");
    }

    function testFuzz_BalancedMultiAssetDeposit_PreviewMatchesExecution(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _vaultBps,
        uint256 _elapsed,
        uint256 _stSeed2,
        uint256 _quoteSeed
    )
        public
    {
        uint256 st = _setupEvolvedMarket(_stSeed, _jtSeed, _vaultBps, _elapsed);
        // Bound the senior leg by the live plain-ST max (conservative: the multi-asset op also adds quote depth,
        // so it can never breach the liquidity gate harder than a bare ST deposit of the same size). Use a
        // substantial fraction of capacity (per the repo's dust-floor convention in TestFuzz_PreviewParity) so the
        // ST leg is always well above the zero-share mint boundary that a 1-wei leg hits in a large pool.
        uint256 maxStLeg = toUint256(seniorTranche.maxDeposit(ST_PROVIDER));
        if (maxStLeg < 1e6) return; // negligible senior capacity this run, the quote-only test covers the venue add
        uint256 stLeg = bound(_stSeed2, maxStLeg / 2, maxStLeg);
        uint256 quoteLeg = bound(_quoteSeed, 1, Math.max(1, st / QUOTE_TO_NAV_SCALE / 10));
        address a = makeAddr("MA_BALANCED");
        accessManager.grantRole(LT_LP_ROLE, a, 0);
        stJtVault.mintShares(a, stLeg);
        quoteToken.mint(a, quoteLeg);
        vm.startPrank(a);
        stJtVault.approve(address(liquidityTranche), stLeg);
        quoteToken.approve(address(liquidityTranche), quoteLeg);
        uint256 previewed;
        // A dust combined value floors to zero LT shares (a non-mintable input), skip it. Capturing the preview via
        // try/catch means a preview that reverts OR returns zero is skipped, while a preview that returns >0 shares
        // still proceeds to execution, so a genuine preview-over-promises divergence would fail the assertion.
        try liquidityTranche.previewDepositMultiAsset(stLeg, quoteLeg) returns (uint256 p, uint256) {
            previewed = p;
        } catch {
            vm.stopPrank();
            return;
        }
        if (previewed == 0) {
            vm.stopPrank();
            return;
        }
        (uint256 minted,) = liquidityTranche.depositMultiAsset(stLeg, quoteLeg, 0, a);
        vm.stopPrank();
        assertEq(minted, previewed, "balanced multi-asset deposit must mint exactly the previewed shares");
    }

    function testFuzz_MultiAssetRedeem_PreviewMatchesExecution(
        uint256 _stSeed,
        uint256 _jtSeed,
        uint256 _vaultBps,
        uint256 _elapsed,
        uint256 _sharesSeed
    )
        public
    {
        _setupEvolvedMarket(_stSeed, _jtSeed, _vaultBps, _elapsed);
        // Size by the multi-asset bound so the sweep also exercises the wedge past the in-kind maximum,
        // and pin the bounds' dominance across every evolved market the fuzzer constructs
        uint256 maxShares = liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER);
        // Exact dominance: both bounds price through the same virtual-shares primitive (floor((S+1e6)*W/(claimNAV+1)))
        // over identical (claimNAV, supply) inputs, and the multi-asset withdrawable NAV weakly exceeds the in-kind
        // NAV (zero relief leaves them equal, senior-share relief only lifts the multi bound), so the dominance holds
        // share for share with no offset slack
        assertGe(maxShares, liquidityTranche.maxRedeem(LT_PROVIDER), "the multi-asset bound must weakly dominate the in-kind bound");
        if (maxShares < 1e6) return; // no liquidity-respecting redemption capacity this run
        uint256 shares = bound(_sharesSeed, 1e6, maxShares); // dust floor avoids a zero-asset payout the accountant rejects

        (AssetClaims memory previewClaims, uint256 previewQuote) = liquidityTranche.previewRedeemMultiAsset(shares);
        vm.prank(LT_PROVIDER);
        (AssetClaims memory claims, uint256 quoteOut) = liquidityTranche.redeemMultiAsset(shares, 0, 0, LT_PROVIDER, LT_PROVIDER);

        assertEq(quoteOut, previewQuote, "multi-asset redeem: quote leg must match the preview");
        assertEq(claims.collateralAssets, previewClaims.collateralAssets, "multi-asset redeem: collateral leg must match the preview");
        assertEq(claims.ltAssets, previewClaims.ltAssets, "multi-asset redeem: LT-asset leg must match the preview");
        assertEq(claims.stShares, previewClaims.stShares, "multi-asset redeem: senior-share leg must match the preview");
        assertEq(claims.nav, previewClaims.nav, "multi-asset redeem: claim NAV must match the preview");
    }

    /**
     * Scenario: a fuzzed covered drawdown breaches the liquidation threshold (which forces the market PERPETUAL),
     * arming the ST self-liquidation bonus. The multi-asset redemption preview must then match the bonus-boosted
     * execution exactly on all five claim legs plus the quote leg. In ltRedeemMultiAsset the bonus lands on the
     * claims immediately before the preview's early return, so a regression reordering those two lines would
     * silently under-quote every bonus-regime preview while exec stays correct, this arm is the multi-asset
     * analog of the dedicated senior in-kind bonus-parity fuzz. A small pre-drawdown collateral-leg deposit puts
     * senior shares in the pool so the removal's venue leg withdraws shares the bonus rides on. The drawdown band
     * [-20.8%, -22.5%] at the 30% junior ratio (plus the 0.5% ST leg) always breaches the liquidation threshold
     * without exhausting the junior buffer (exhaustion sits at -22.99%), mirroring the senior arm's band.
     */
    function testFuzz_RedeemMultiAssetPreviewParity_LiquidationBonusRegime(uint256 _stSeed, uint256 _drawdownBps, uint256 _sharesSeed) public {
        uint256 st = bound(_stSeed, 1e18, 1e26); // uniform over 8 orders of magnitude of senior seed size
        uint256 drawdownBps = bound(_drawdownBps, 2080, 2250); // always past the liquidation threshold, buffer never exhausted
        _seedFlatMarket(st, st * 3 / 10, 0);

        // A collateral-leg deposit worth 0.5% of the senior seed puts senior shares in the quote-only pool, so
        // the later removal's venue leg withdraws senior shares for the bonus to boost
        uint256 stLeg = st / 200;
        stJtVault.mintShares(LT_PROVIDER, stLeg);
        vm.startPrank(LT_PROVIDER);
        stJtVault.approve(address(liquidityTranche), stLeg);
        liquidityTranche.depositMultiAsset(stLeg, 0, 0, LT_PROVIDER);
        vm.stopPrank();

        applySTPnL(-int256(drawdownBps));
        syncVenuePrices();
        SyncedAccountingState memory state = _sync();
        assertGe(state.coverageUtilizationWAD, state.coverageLiquidationUtilizationWAD, "the drawdown must breach the liquidation coverage threshold");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "a liquidation breach forces the market PERPETUAL so redemptions stay open");

        uint256 maxShares = liquidityTranche.maxRedeemMultiAsset(LT_PROVIDER);
        if (maxShares < 1e6) return; // no liquidity-respecting redemption capacity this run
        // A substantial slice keeps the proportional removal's senior-share leg above the floor-to-zero boundary,
        // so the bonus always rides on nonzero claims and the parity is never vacuous
        uint256 shares = bound(_sharesSeed, Math.max(1e6, maxShares / 2), maxShares);

        (AssetClaims memory previewClaims, uint256 previewQuote) = liquidityTranche.previewRedeemMultiAsset(shares);
        assertTrue(toUint256(previewClaims.nav) != 0, "the bonus-regime quote must carry a nonzero senior-share redemption claim");
        vm.prank(LT_PROVIDER);
        (AssetClaims memory claims, uint256 quoteOut) = liquidityTranche.redeemMultiAsset(shares, 0, 0, LT_PROVIDER, LT_PROVIDER);

        assertEq(quoteOut, previewQuote, "bonus-regime multi-asset redeem: quote leg must match the preview");
        assertEq(claims.collateralAssets, previewClaims.collateralAssets, "bonus-regime multi-asset redeem: collateral leg must match the preview");
        assertEq(claims.ltAssets, previewClaims.ltAssets, "bonus-regime multi-asset redeem: LT-asset leg must match the preview");
        assertEq(claims.stShares, previewClaims.stShares, "bonus-regime multi-asset redeem: senior-share leg must match the preview");
        assertEq(claims.nav, previewClaims.nav, "bonus-regime multi-asset redeem: claim NAV must match the preview");
    }

    /// @dev Seeds a flat market, applies up-only vault yield over a window, and syncs, leaving PERPETUAL state
    ///      with the premium deployed and every fee minted. Returns the senior seed size.
    function _setupEvolvedMarket(uint256 _stSeed, uint256 _jtSeed, uint256 _vaultBps, uint256 _elapsed) internal returns (uint256 st) {
        st = bound(_stSeed, 1e18, 1e26);
        uint256 jt = bound(_jtSeed, st / 2, 2 * st);
        uint256 vb = bound(_vaultBps, 0, 10_000);
        uint256 elapsed = bound(_elapsed, 1 hours, 365 days);
        _seedFlatMarket(st, jt, st.mulDiv(3, 20) / QUOTE_TO_NAV_SCALE + 1);
        applySTPnL(int256(vb));
        _warpAndRefreshFeed(elapsed);
        syncVenuePrices();
        _sync();
    }
}
