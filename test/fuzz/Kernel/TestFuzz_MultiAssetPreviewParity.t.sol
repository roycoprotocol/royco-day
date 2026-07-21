// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { LT_LP_ROLE } from "../../../src/factory/Roles.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { MarketFuzzTestBase } from "../../utils/MarketFuzzTestBase.sol";

/**
 * @title TestFuzz_MultiAssetPreviewParity_Kernel
 * @notice Fuzzes same-block preview/execute parity for the two MULTI-ASSET liquidity flows that
 *         TestFuzz_PreviewParity excludes: `depositMultiAsset` and `redeemMultiAsset`. Previously multi-asset
 *         deposit parity was only a ±30bps inequality on the real venue (Test_BalancerHooksAndReinvest) and
 *         redeem parity was a single fixture; on the deterministic mock venue exact parity must hold.
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
        try liquidityTranche.previewDepositMultiAsset(0, quoteLeg) returns (uint256 p) {
            previewed = p;
        } catch {
            vm.stopPrank();
            return; // dust input floors to zero shares (MUST_MINT_NON_ZERO_SHARES); not a parity case
        }
        if (previewed == 0) {
            vm.stopPrank();
            return;
        }
        uint256 minted = liquidityTranche.depositMultiAsset(0, quoteLeg, 0, a);
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
        if (maxStLeg < 1e6) return; // negligible senior capacity this run; the quote-only test covers the venue add
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
        // A dust combined value floors to zero LT shares (a non-mintable input); skip it. Capturing the preview via
        // try/catch means a preview that reverts OR returns zero is skipped, while a preview that returns >0 shares
        // still proceeds to execution — so a genuine preview-over-promises divergence would fail the assertion.
        try liquidityTranche.previewDepositMultiAsset(stLeg, quoteLeg) returns (uint256 p) {
            previewed = p;
        } catch {
            vm.stopPrank();
            return;
        }
        if (previewed == 0) {
            vm.stopPrank();
            return;
        }
        uint256 minted = liquidityTranche.depositMultiAsset(stLeg, quoteLeg, 0, a);
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
        assertGe(maxShares, liquidityTranche.maxRedeem(LT_PROVIDER), "the multi-asset bound must weakly dominate the in-kind bound");
        if (maxShares < 1e6) return; // no liquidity-respecting redemption capacity this run
        uint256 shares = bound(_sharesSeed, 1e6, maxShares); // dust floor avoids a zero-asset payout the accountant rejects

        (AssetClaims memory previewClaims, uint256 previewQuote) = liquidityTranche.previewRedeemMultiAsset(shares);
        vm.prank(LT_PROVIDER);
        (AssetClaims memory claims, uint256 quoteOut) = liquidityTranche.redeemMultiAsset(shares, 0, 0, LT_PROVIDER, LT_PROVIDER);

        assertEq(quoteOut, previewQuote, "multi-asset redeem: quote leg must match the preview");
        assertEq(claims.stAssets, previewClaims.stAssets, "multi-asset redeem: senior-asset leg must match the preview");
        assertEq(claims.jtAssets, previewClaims.jtAssets, "multi-asset redeem: junior-asset leg must match the preview");
        assertEq(claims.ltAssets, previewClaims.ltAssets, "multi-asset redeem: LT-asset leg must match the preview");
        assertEq(claims.stShares, previewClaims.stShares, "multi-asset redeem: senior-share leg must match the preview");
        assertEq(claims.nav, previewClaims.nav, "multi-asset redeem: claim NAV must match the preview");
    }

    /// @dev Seeds a flat market, applies up-only vault yield over a window, and syncs — leaving PERPETUAL state
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
