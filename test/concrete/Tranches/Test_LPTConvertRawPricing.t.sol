// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";
import { MarketParamsConfig } from "../../utils/FixtureTypes.sol";
import { defaultParams, zeroLiquidityParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_LPTConvertRawPricing_Tranches
 * @notice Pins the LPT's split valuation surfaces: the external `convertToShares`/`convertToAssets` exchange rate is
 *         BPT-only (the raw NAV, excluding the claimable idle liquidity-premium senior shares), while `preview*` and
 *         deposit/redeem execution stay idle-inclusive (the idle slice is really paid in-kind on redemption).
 * @dev The motivation is composability: a staged premium deploys into BPT at a slippage haircut, so an idle-inclusive
 *      quoted price would DIP at deploy, an integrator like a Pendle SY wrapper (whose exchangeRate must never
 *      decrease) or a Morpho collateral oracle would observe a falling share price for a value-neutral internal
 *      operation. The BPT-only rate only rises as value lands in the pool. Honest bound on "up-only": the deploy
 *      event itself always raises the raw price (BPT is credited, no LPT shares mint); at the accrual sync the raw
 *      price is exactly flat when the LPT yield-share fee is zero, and can dip by at most the fee-share dilution when
 *      it is nonzero (the fee's LPT shares mint before the premium value lands in the pool), recovering at deploy.
 */
contract Test_LPTConvertRawPricing_Tranches is DayMarketTestBase {
    /// @dev Whole ST/JT vault shares seeded. Coverage after seed: (100 + 50) x 0.2 / 50 = 0.6 <= 1
    uint256 internal constant ST_SEED = 100e18;
    uint256 internal constant JT_SEED = 50e18;

    /// @dev The quote-only LPT seed used by the zero-min-liquidity markets: 5e18 BPT against 5 whole 6-dec quote
    ///      keeps NAV-per-BPT at exactly 1.0
    uint256 internal constant LPT_SEED_BPT = 5e18;
    uint256 internal constant LPT_SEED_QUOTE = 5e6;

    // =============================
    // The split: convert* is BPT-only, preview* is idle-inclusive
    // =============================

    /**
     * @notice While an idle premium is staged, convertToAssets prices on the BPT leg alone (zero senior-share claim)
     *         and previewRedeem prices the same shares strictly higher, including the pro-rata idle slice
     * @dev Every expectation is recomputed independently from the oracle, vault, and ledger primitives:
     *      raw = floor(TVL x ownedBpt / bptSupply), idleValue = floor((stEff + 1) x idle / (stSupply + 1e6)) (the
     *      virtual-shares/value offset the share<->value conversion now carries), eff = raw + idleValue
     */
    function test_ConvertToAssets_BptOnlyWhilePremiumStaged_PreviewRedeemKeepsIdleLeg() public {
        _deployMarket(cellA(), defaultParams());
        _seedMarket(ST_SEED, JT_SEED);
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        // Independent recomputation of both NAV bases from primitives (same block as the accrual sync, so the
        // preview the views run internally resolves to exactly this committed state)
        uint256 supply = liquidityProviderTranche.totalSupply();
        uint256 rawNAV = _independentRawNAV();
        uint256 idleValue =
            Math.mulDiv(toUint256(accountant.getState().lastSTEffectiveNAV) + 1, idleShares, seniorTranche.totalSupply() + 1e6, Math.Rounding.Floor);
        uint256 effNAV = rawNAV + idleValue;
        assertGt(idleValue, 0, "arrange: the staged premium must carry nonzero value for the split to be observable");

        // The convert surface: BPT-only claims for a sixteenth of the supply. The slice stays small because
        // previewRedeem executes the real redemption path, so the simulated exit must clear the 5% liquidity floor:
        // required 0.05 x stEff 107e18 = 5.35e18 against the 6e18 depth leaves under 11% of the depth redeemable
        uint256 shares = supply / 16;
        AssetClaims memory conv = liquidityProviderTranche.convertToAssets(shares);
        assertEq(conv.stShares, 0, "convertToAssets must report no senior-share claim (the idle leg is excluded)");
        assertEq(
            toUint256(conv.nav),
            Math.mulDiv(rawNAV, shares, supply + 1e6, Math.Rounding.Floor),
            "convertToAssets NAV must be the pro-rata slice of the BPT-only raw NAV"
        );
        assertEq(
            toUint256(conv.lptAssets),
            Math.mulDiv(toUint256(kernel.getState().totalLPTAssets), shares, supply + 1e6, Math.Rounding.Floor),
            "convertToAssets must still report the pro-rata BPT claim"
        );

        // The preview surface: idle-inclusive claims for the SAME shares, strictly richer
        AssetClaims memory prev = liquidityProviderTranche.previewRedeem(shares);
        assertEq(
            prev.stShares, Math.mulDiv(idleShares, shares, supply + 1e6, Math.Rounding.Floor), "previewRedeem must report the pro-rata idle senior-share slice"
        );
        assertGt(prev.stShares, 0, "arrange: the previewed idle slice must be nonzero");
        assertEq(
            toUint256(prev.nav),
            Math.mulDiv(effNAV, shares, supply + 1e6, Math.Rounding.Floor),
            "previewRedeem NAV must be the pro-rata slice of the idle-inclusive effective NAV"
        );
        assertGt(
            toUint256(prev.nav), toUint256(conv.nav), "the redemption quote must be strictly richer than the BPT-only exchange rate while premium is staged"
        );

        // The inverse surface: convertToShares divides by the raw NAV, so a BPT quotes MORE shares than
        // previewDeposit (which prices at the richer effective NAV) while premium is staged
        uint256 bptIn = 1e18;
        uint256 bptValue = Math.mulDiv(bptOracle.computeTVL(), bptIn, balancerVault.totalSupply(address(bpt)), Math.Rounding.Floor);
        uint256 convShares = liquidityProviderTranche.convertToShares(toTrancheUnits(bptIn));
        uint256 previewShares = liquidityProviderTranche.previewDeposit(toTrancheUnits(bptIn));
        assertEq(convShares, Math.mulDiv(supply + 1e6, bptValue, rawNAV + 1, Math.Rounding.Floor), "convertToShares must quote against the BPT-only raw NAV");
        assertEq(
            previewShares,
            Math.mulDiv(supply + 1e6, bptValue, effNAV + 1, Math.Rounding.Floor),
            "previewDeposit must quote against the idle-inclusive effective NAV"
        );
        assertGt(convShares, previewShares, "the raw-NAV denominator is strictly smaller, so convertToShares must quote strictly more shares");
    }

    /**
     * @notice Redemption EXECUTION stays idle-inclusive: while premium is staged, redeeming pays the pro-rata BPT
     *         slice AND the pro-rata idle senior-share slice, exactly matching previewRedeem and not the BPT-only
     *         convert quote
     * @dev Zero-min-liquidity market so no liquidity gate constrains the exit; every slice is derived from the
     *      pre-redeem ledgers as floor(shares x leg / (totalSupply + 1e6)), matching the virtual-shares offset the
     *      claim scaler now carries
     */
    function test_RedeemExecution_StillPaysIdleSlice_MatchingPreviewNotConvert() public {
        _deployZeroMinLiquidityMarketWithPremium();
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        uint256 supply = liquidityProviderTranche.totalSupply();
        uint256 ownedBpt = toUint256(kernel.getState().totalLPTAssets);
        uint256 shares = liquidityProviderTranche.balanceOf(LPT_PROVIDER) / 2;
        uint256 expectedBptSlice = Math.mulDiv(shares, ownedBpt, supply + 1e6, Math.Rounding.Floor);
        uint256 expectedIdleSlice = Math.mulDiv(shares, idleShares, supply + 1e6, Math.Rounding.Floor);
        assertGt(expectedIdleSlice, 0, "arrange: the redeemed idle slice must be nonzero");

        // The convert quote for the same shares excludes the idle leg entirely, the executed redemption must NOT
        // match it while premium is staged
        AssetClaims memory conv = liquidityProviderTranche.convertToAssets(shares);
        AssetClaims memory prev = liquidityProviderTranche.previewRedeem(shares);

        vm.prank(LPT_PROVIDER);
        AssetClaims memory claims = liquidityProviderTranche.redeem(shares, LPT_PROVIDER, LPT_PROVIDER);

        // Execution == preview (idle-inclusive), on every leg
        assertEq(keccak256(abi.encode(claims)), keccak256(abi.encode(prev)), "executed redemption must equal previewRedeem on every claim leg");
        assertEq(toUint256(claims.lptAssets), expectedBptSlice, "the redemption must pay exactly the pro-rata BPT slice");
        assertEq(claims.stShares, expectedIdleSlice, "the redemption must pay exactly the pro-rata idle senior-share slice");
        assertEq(seniorTranche.balanceOf(LPT_PROVIDER), expectedIdleSlice, "the redeemer must hold exactly its idle senior-share slice");

        // Execution != the BPT-only convert quote: the redeemer received strictly more value than the exchange rate
        assertGt(toUint256(claims.nav), toUint256(conv.nav), "the executed redemption must be strictly richer than the BPT-only convert quote");
        assertEq(conv.stShares, 0, "the convert quote must carry no senior-share leg");
    }

    // =============================
    // The motivating property: the quoted price cannot dip at premium deploy
    // =============================

    /**
     * @notice Across the premium lifecycle (seed -> accrual sync stages idle -> gated reinvest deploys at a 10 bps
     *         haircut), the BPT-only convert price is exactly flat at the accrual and strictly rises at deploy,
     *         while the OLD idle-inclusive price would have strictly dropped at deploy
     * @dev All four protocol fees are zeroed so no LPT fee shares mint at the accrual sync: the raw price is then
     *      provably flat at stage (same BPT, same supply). The deploy is pinned to the reinvestment gate's exact
     *      floor, minOut = ceil(fairBPT x (WAD - maxSlippage) / WAD), so the haircut the old pricing would have
     *      realized is exactly the configured 10 bps of the staged value
     */
    function test_ConvertPrice_MonotoneAcrossPremiumLifecycle_OldEffectivePricingWouldDip() public {
        _deployZeroFeeMarketWithPremium();
        _seedMarket(ST_SEED, JT_SEED);
        _sync();

        uint256 probe = 1e18; // price-per-share probe: the NAV claim of a fixed 1e18-share block
        uint256 p0 = toUint256(liquidityProviderTranche.convertToAssets(probe).nav);
        assertGt(p0, 0, "arrange: the seeded market must quote a nonzero price");

        // Stage: the +10% senior gain mints the premium as idle senior shares; the armed venue slippage defers the
        // inline reinvestment. Zero fees => zero LPT share mints => the BPT-only price is EXACTLY flat
        uint256 idleShares = _accrueIdlePremiumSeniorShares();
        uint256 p1 = toUint256(liquidityProviderTranche.convertToAssets(probe).nav);
        assertEq(p1, p0, "the BPT-only price must be exactly flat at the accrual sync (no BPT moved, no shares minted)");

        // The OLD idle-inclusive price at stage, recomputed by hand: raw + idleValue over the same supply
        uint256 supply = liquidityProviderTranche.totalSupply();
        uint256 rawNAV = _independentRawNAV();
        uint256 idleValue =
            Math.mulDiv(toUint256(accountant.getState().lastSTEffectiveNAV) + 1, idleShares, seniorTranche.totalSupply() + 1e6, Math.Rounding.Floor);
        uint256 effPriceAtStage = Math.mulDiv(rawNAV + idleValue, probe, supply + 1e6, Math.Rounding.Floor);
        assertGt(effPriceAtStage, p1, "arrange: the idle-inclusive price must sit strictly above the BPT-only price while staged");

        // Deploy at the gate's exact floor: a 10 bps haircut on the staged value (the worst deploy the gate admits)
        uint256 fairBPT = Math.mulDiv(balancerVault.totalSupply(address(bpt)), idleValue, bptOracle.computeTVL(), Math.Rounding.Floor);
        uint256 minOut = Math.mulDiv(fairBPT, WAD - defaultParams().maxReinvestmentSlippageWAD, WAD, Math.Rounding.Ceil);
        setVenueSlippageMode(false);
        balancerVault.setNextBptOutOverride(minOut);
        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN);
        kernel.reinvestLiquidityPremium(type(uint256).max);
        assertEq(kernel.getState().lptOwnedSeniorTrancheShares, 0, "arrange: the entire idle pile must have deployed");

        // The BPT-only price strictly rises at deploy (BPT credited, no LPT shares minted), exactly to the
        // recomputed post-deploy raw NAV per share
        uint256 p2 = toUint256(liquidityProviderTranche.convertToAssets(probe).nav);
        // convertToAssets prices the LPT nav as the offset-aware pro-rata slice of the BPT-only raw NAV:
        // floor(rawNAV * probe / (supply + VIRTUAL_SHARES)). The recomputation must carry the +1e6 offset.
        assertEq(
            p2,
            Math.mulDiv(_independentRawNAV(), probe, supply + 1e6, Math.Rounding.Floor),
            "the post-deploy price must equal the recomputed BPT-only raw NAV per share"
        );
        assertGt(p2, p1, "the BPT-only price must strictly rise when the staged premium lands as pool depth");

        // The documented dip this change removes: with the idle pile gone, the idle-inclusive price collapses onto
        // the BPT-only price, and the haircut makes it strictly LOWER than it was while staged, the old convert
        // surface would have quoted a falling share price for a value-neutral internal deploy
        assertLt(p2, effPriceAtStage, "the OLD idle-inclusive pricing would have strictly dropped at deploy (the 10 bps haircut)");
    }

    // =============================
    // Coincidence and zero edges
    // =============================

    /**
     * @notice With nothing staged, the two surfaces coincide exactly: convertToAssets == previewRedeem on every
     *         claim leg and convertToShares == previewDeposit
     */
    function test_ConvertAndPreview_CoincideExactly_WhenNoPremiumStaged() public {
        _deployMarket(cellA(), defaultParams());
        _seedMarket(ST_SEED, JT_SEED);
        _sync();
        assertEq(kernel.getState().lptOwnedSeniorTrancheShares, 0, "arrange: nothing may be staged");

        // An eighth of the supply keeps the simulated exit above the 5% liquidity floor (previewRedeem executes the
        // real redemption path): redeeming 0.75e18 of the 6e18 depth leaves 5.25e18 >= required 0.05 x 100e18 = 5e18
        uint256 shares = liquidityProviderTranche.totalSupply() / 8;
        AssetClaims memory conv = liquidityProviderTranche.convertToAssets(shares);
        AssetClaims memory prev = liquidityProviderTranche.previewRedeem(shares);
        assertEq(keccak256(abi.encode(conv)), keccak256(abi.encode(prev)), "convertToAssets must equal previewRedeem on every leg when nothing is staged");

        assertEq(
            liquidityProviderTranche.convertToShares(toTrancheUnits(1e18)),
            liquidityProviderTranche.previewDeposit(toTrancheUnits(1e18)),
            "convertToShares must equal previewDeposit when nothing is staged"
        );
    }

    /**
     * @notice With the pool-depth mark at zero but idle premium outstanding, the convert surface floors to zero on
     *         every leg while previewRedeem still carries the claimable idle slice
     * @dev The BPT-only rate is a conservative floor: a worthless pool mark quotes a worthless share even though a
     *      redemption would still deliver the idle senior shares (the same key drives the maxRedeem behavior in
     *      test_LPTMaxRedeem_UnderreportsZeroOnIdleOnlyNAV_WhileFullBalanceRedeemsMultiAsset)
     */
    function test_Convert_FloorsToZeroOnZeroPoolMark_PreviewStillCarriesIdleLeg() public {
        _deployZeroMinLiquidityMarketWithPremium();
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        // Mark the entire pool worthless through the oracle: raw NAV reads zero, the idle leg stays claimable
        bptOracle.setTVL(0);
        bptOracle.setMode(MockBPTOracle.Mode.MANUAL);

        uint256 supply = liquidityProviderTranche.totalSupply();
        uint256 shares = supply / 2;
        AssetClaims memory conv = liquidityProviderTranche.convertToAssets(shares);
        assertEq(toUint256(conv.nav), 0, "the BPT-only price must floor to zero on a zero pool mark");
        assertEq(toUint256(conv.lptAssets), 0, "no BPT claim can be reported against a zero pool mark");
        assertEq(conv.stShares, 0, "the convert surface never reports the idle leg");

        // A BPT is worth zero NAV against a zero mark, so it quotes zero shares (no division by the zero raw NAV:
        // the zero-value numerator short-circuits the dilution convention)
        assertEq(liquidityProviderTranche.convertToShares(toTrancheUnits(1e18)), 0, "a worthless BPT must quote zero shares");

        // The redemption quote still carries the idle slice: the claimable leg is priced and deliverable
        AssetClaims memory prev = liquidityProviderTranche.previewRedeem(shares);
        assertEq(prev.stShares, Math.mulDiv(idleShares, shares, supply + 1e6, Math.Rounding.Floor), "previewRedeem must still report the pro-rata idle slice");
        assertGt(toUint256(prev.nav), 0, "the redemption quote must still price the idle leg");
    }

    // =============================
    // Helpers
    // =============================

    /// @dev The independently recomputed BPT-only raw NAV: floor(TVL x ownedBpt / bptSupply) from the oracle and
    ///      vault primitives, never from the production quoter
    function _independentRawNAV() internal view returns (uint256) {
        return Math.mulDiv(bptOracle.computeTVL(), toUint256(kernel.getState().totalLPTAssets), balancerVault.totalSupply(address(bpt)), Math.Rounding.Floor);
    }

    /// @dev Default-param market minus every protocol fee, premium enabled: isolates the lifecycle monotonicity from
    ///      fee-share dilution (see the contract natspec for the honest bound under nonzero fees)
    function _deployZeroFeeMarketWithPremium() internal {
        MarketParamsConfig memory p = defaultParams();
        p.stProtocolFeeWAD = 0;
        p.jtProtocolFeeWAD = 0;
        p.jtYieldShareProtocolFeeWAD = 0;
        p.lptYieldShareProtocolFeeWAD = 0;
        _deployMarket(cellA(), p);
    }

    /// @dev Zero-min-liquidity market with the LPT premium re-enabled, seeded ST/JT plus a quote-only LPT depth at
    ///      NAV-per-BPT exactly 1.0 (mirrors Test_TrancheViewEdges' setup)
    function _deployZeroMinLiquidityMarketWithPremium() internal {
        MarketParamsConfig memory p = zeroLiquidityParams();
        p.maxLPTYieldShareWAD = 0.3e18;
        p.lptCurve = [uint64(0.02e18), uint64(0.1e18), uint64(0.3e18)];
        _deployMarket(cellA(), p);
        _seedMarket(ST_SEED, JT_SEED);
        _seedLPT(LPT_SEED_BPT, 0, LPT_SEED_QUOTE);
    }

    /// @dev Accrues a nonzero idle liquidity premium: arms venue slippage so the +10% senior gain's premium mints as
    ///      senior shares to the LPT while the gated reinvestment defers. Slippage stays armed so a later operation's
    ///      sync cannot deploy the pile mid-test
    function _accrueIdlePremiumSeniorShares() internal returns (uint256 idleShares) {
        setVenueSlippageMode(true);
        applySTPnL(1000);
        _sync();
        idleShares = kernel.getState().lptOwnedSeniorTrancheShares;
        assertTrue(idleShares != 0, "the gain must have left a nonzero idle liquidity premium senior share pile");
    }
}
