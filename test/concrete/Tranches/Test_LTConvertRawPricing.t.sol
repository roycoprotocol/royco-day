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
 * @title Test_LTConvertRawPricing_Tranches
 * @notice Pins the LT's split valuation surfaces: the external `convertToShares`/`convertToAssets` exchange rate is
 *         BPT-only (the raw NAV, excluding the claimable idle liquidity-premium senior shares), while `preview*` and
 *         deposit/redeem execution stay idle-inclusive (the idle slice is really paid in-kind on redemption).
 * @dev The motivation is composability: a staged premium deploys into BPT at a slippage haircut, so an idle-inclusive
 *      quoted price would DIP at deploy — an integrator like a Pendle SY wrapper (whose exchangeRate must never
 *      decrease) or a Morpho collateral oracle would observe a falling share price for a value-neutral internal
 *      operation. The BPT-only rate only rises as value lands in the pool. Honest bound on "up-only": the deploy
 *      event itself always raises the raw price (BPT is credited, no LT shares mint); at the accrual sync the raw
 *      price is exactly flat when the LT yield-share fee is zero, and can dip by at most the fee-share dilution when
 *      it is nonzero (the fee's LT shares mint before the premium value lands in the pool), recovering at deploy.
 */
contract Test_LTConvertRawPricing_Tranches is DayMarketTestBase {
    /// @dev Whole ST/JT vault shares seeded. Coverage after seed: (100 + 50) x 0.2 / 50 = 0.6 <= 1
    uint256 internal constant ST_SEED = 100e18;
    uint256 internal constant JT_SEED = 50e18;

    /// @dev The quote-only LT seed used by the zero-min-liquidity markets: 5e18 BPT against 5 whole 6-dec quote
    ///      keeps NAV-per-BPT at exactly 1.0
    uint256 internal constant LT_SEED_BPT = 5e18;
    uint256 internal constant LT_SEED_QUOTE = 5e6;

    // =============================
    // The split: convert* is BPT-only, preview* is idle-inclusive
    // =============================

    /**
     * @notice While an idle premium is staged, convertToAssets prices on the BPT leg alone (zero senior-share claim)
     *         and previewRedeem prices the same shares strictly higher, including the pro-rata idle slice
     * @dev Every expectation is recomputed independently from the oracle, vault, and ledger primitives:
     *      raw = floor(TVL x ownedBpt / bptSupply), idleValue = floor(stEff x idle / stSupply), eff = raw + idleValue
     */
    function test_ConvertToAssets_BptOnlyWhilePremiumStaged_PreviewRedeemKeepsIdleLeg() public {
        _deployMarket(cellA(), defaultParams());
        _seedMarket(ST_SEED, JT_SEED);
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        // Independent recomputation of both NAV bases from primitives (same block as the accrual sync, so the
        // preview the views run internally resolves to exactly this committed state)
        uint256 supply = liquidityTranche.totalSupply();
        uint256 rawNAV = _independentRawNAV();
        uint256 idleValue = Math.mulDiv(toUint256(accountant.getState().lastSTEffectiveNAV), idleShares, seniorTranche.totalSupply(), Math.Rounding.Floor);
        uint256 effNAV = rawNAV + idleValue;
        assertGt(idleValue, 0, "arrange: the staged premium must carry nonzero value for the split to be observable");

        // The convert surface: BPT-only claims for a third of the supply
        uint256 shares = supply / 3;
        AssetClaims memory conv = liquidityTranche.convertToAssets(shares);
        assertEq(conv.stShares, 0, "convertToAssets must report no senior-share claim (the idle leg is excluded)");
        assertEq(toUint256(conv.nav), Math.mulDiv(rawNAV, shares, supply, Math.Rounding.Floor), "convertToAssets NAV must be the pro-rata slice of the BPT-only raw NAV");
        assertEq(
            toUint256(conv.ltAssets),
            Math.mulDiv(toUint256(kernel.getState().ltOwnedYieldBearingAssets), shares, supply, Math.Rounding.Floor),
            "convertToAssets must still report the pro-rata BPT claim"
        );

        // The preview surface: idle-inclusive claims for the SAME shares, strictly richer
        AssetClaims memory prev = liquidityTranche.previewRedeem(shares);
        assertEq(prev.stShares, Math.mulDiv(idleShares, shares, supply, Math.Rounding.Floor), "previewRedeem must report the pro-rata idle senior-share slice");
        assertGt(prev.stShares, 0, "arrange: the previewed idle slice must be nonzero");
        assertEq(toUint256(prev.nav), Math.mulDiv(effNAV, shares, supply, Math.Rounding.Floor), "previewRedeem NAV must be the pro-rata slice of the idle-inclusive effective NAV");
        assertGt(toUint256(prev.nav), toUint256(conv.nav), "the redemption quote must be strictly richer than the BPT-only exchange rate while premium is staged");

        // The inverse surface: convertToShares divides by the raw NAV, so a BPT quotes MORE shares than
        // previewDeposit (which prices at the richer effective NAV) while premium is staged
        uint256 bptIn = 1e18;
        uint256 bptValue = Math.mulDiv(bptOracle.computeTVL(), bptIn, balancerVault.totalSupply(address(bpt)), Math.Rounding.Floor);
        uint256 convShares = liquidityTranche.convertToShares(toTrancheUnits(bptIn));
        uint256 previewShares = liquidityTranche.previewDeposit(toTrancheUnits(bptIn));
        assertEq(convShares, Math.mulDiv(supply, bptValue, rawNAV, Math.Rounding.Floor), "convertToShares must quote against the BPT-only raw NAV");
        assertEq(previewShares, Math.mulDiv(supply, bptValue, effNAV, Math.Rounding.Floor), "previewDeposit must quote against the idle-inclusive effective NAV");
        assertGt(convShares, previewShares, "the raw-NAV denominator is strictly smaller, so convertToShares must quote strictly more shares");
    }

    /**
     * @notice Redemption EXECUTION stays idle-inclusive: while premium is staged, redeeming pays the pro-rata BPT
     *         slice AND the pro-rata idle senior-share slice, exactly matching previewRedeem — not the BPT-only
     *         convert quote
     * @dev Zero-min-liquidity market so no liquidity gate constrains the exit; every slice is derived from the
     *      pre-redeem ledgers as floor(shares x leg / totalSupply)
     */
    function test_RedeemExecution_StillPaysIdleSlice_MatchingPreviewNotConvert() public {
        _deployZeroMinLiquidityMarketWithPremium();
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        uint256 supply = liquidityTranche.totalSupply();
        uint256 ownedBpt = toUint256(kernel.getState().ltOwnedYieldBearingAssets);
        uint256 shares = liquidityTranche.balanceOf(LT_PROVIDER) / 2;
        uint256 expectedBptSlice = Math.mulDiv(shares, ownedBpt, supply, Math.Rounding.Floor);
        uint256 expectedIdleSlice = Math.mulDiv(shares, idleShares, supply, Math.Rounding.Floor);
        assertGt(expectedIdleSlice, 0, "arrange: the redeemed idle slice must be nonzero");

        // The convert quote for the same shares excludes the idle leg entirely — the executed redemption must NOT
        // match it while premium is staged
        AssetClaims memory conv = liquidityTranche.convertToAssets(shares);
        AssetClaims memory prev = liquidityTranche.previewRedeem(shares);

        vm.prank(LT_PROVIDER);
        AssetClaims memory claims = liquidityTranche.redeem(shares, LT_PROVIDER, LT_PROVIDER);

        // Execution == preview (idle-inclusive), on every leg
        assertEq(keccak256(abi.encode(claims)), keccak256(abi.encode(prev)), "executed redemption must equal previewRedeem on every claim leg");
        assertEq(toUint256(claims.ltAssets), expectedBptSlice, "the redemption must pay exactly the pro-rata BPT slice");
        assertEq(claims.stShares, expectedIdleSlice, "the redemption must pay exactly the pro-rata idle senior-share slice");
        assertEq(seniorTranche.balanceOf(LT_PROVIDER), expectedIdleSlice, "the redeemer must hold exactly its idle senior-share slice");

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
     * @dev All four protocol fees are zeroed so no LT fee shares mint at the accrual sync: the raw price is then
     *      provably flat at stage (same BPT, same supply). The deploy is pinned to the reinvestment gate's exact
     *      floor, minOut = ceil(fairBPT x (WAD - maxSlippage) / WAD), so the haircut the old pricing would have
     *      realized is exactly the configured 10 bps of the staged value
     */
    function test_ConvertPrice_MonotoneAcrossPremiumLifecycle_OldEffectivePricingWouldDip() public {
        _deployZeroFeeMarketWithPremium();
        _seedMarket(ST_SEED, JT_SEED);
        _sync();

        uint256 probe = 1e18; // price-per-share probe: the NAV claim of a fixed 1e18-share block
        uint256 p0 = toUint256(liquidityTranche.convertToAssets(probe).nav);
        assertGt(p0, 0, "arrange: the seeded market must quote a nonzero price");

        // Stage: the +10% senior gain mints the premium as idle senior shares; the armed venue slippage defers the
        // inline reinvestment. Zero fees => zero LT share mints => the BPT-only price is EXACTLY flat
        uint256 idleShares = _accrueIdlePremiumSeniorShares();
        uint256 p1 = toUint256(liquidityTranche.convertToAssets(probe).nav);
        assertEq(p1, p0, "the BPT-only price must be exactly flat at the accrual sync (no BPT moved, no shares minted)");

        // The OLD idle-inclusive price at stage, recomputed by hand: raw + idleValue over the same supply
        uint256 supply = liquidityTranche.totalSupply();
        uint256 rawNAV = _independentRawNAV();
        uint256 idleValue = Math.mulDiv(toUint256(accountant.getState().lastSTEffectiveNAV), idleShares, seniorTranche.totalSupply(), Math.Rounding.Floor);
        uint256 effPriceAtStage = Math.mulDiv(rawNAV + idleValue, probe, supply, Math.Rounding.Floor);
        assertGt(effPriceAtStage, p1, "arrange: the idle-inclusive price must sit strictly above the BPT-only price while staged");

        // Deploy at the gate's exact floor: a 10 bps haircut on the staged value (the worst deploy the gate admits)
        uint256 fairBPT = Math.mulDiv(balancerVault.totalSupply(address(bpt)), idleValue, bptOracle.computeTVL(), Math.Rounding.Floor);
        uint256 minOut = Math.mulDiv(fairBPT, WAD - defaultParams().maxReinvestmentSlippageWAD, WAD, Math.Rounding.Ceil);
        setVenueSlippageMode(false);
        balancerVault.setNextBptOutOverride(minOut);
        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN);
        kernel.reinvestLiquidityPremium(type(uint256).max);
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, 0, "arrange: the entire idle pile must have deployed");

        // The BPT-only price strictly rises at deploy (BPT credited, no LT shares minted), exactly to the
        // recomputed post-deploy raw NAV per share
        uint256 p2 = toUint256(liquidityTranche.convertToAssets(probe).nav);
        assertEq(p2, Math.mulDiv(_independentRawNAV(), probe, supply, Math.Rounding.Floor), "the post-deploy price must equal the recomputed BPT-only raw NAV per share");
        assertGt(p2, p1, "the BPT-only price must strictly rise when the staged premium lands as pool depth");

        // The documented dip this change removes: with the idle pile gone, the idle-inclusive price collapses onto
        // the BPT-only price, and the haircut makes it strictly LOWER than it was while staged — the old convert
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
        assertEq(kernel.getState().ltOwnedSeniorTrancheShares, 0, "arrange: nothing may be staged");

        uint256 shares = liquidityTranche.totalSupply() / 4;
        AssetClaims memory conv = liquidityTranche.convertToAssets(shares);
        AssetClaims memory prev = liquidityTranche.previewRedeem(shares);
        assertEq(keccak256(abi.encode(conv)), keccak256(abi.encode(prev)), "convertToAssets must equal previewRedeem on every leg when nothing is staged");

        assertEq(
            liquidityTranche.convertToShares(toTrancheUnits(1e18)),
            liquidityTranche.previewDeposit(toTrancheUnits(1e18)),
            "convertToShares must equal previewDeposit when nothing is staged"
        );
    }

    /**
     * @notice With the pool-depth mark at zero but idle premium outstanding, the convert surface floors to zero on
     *         every leg while previewRedeem still carries the claimable idle slice
     * @dev The BPT-only rate is a conservative floor: a worthless pool mark quotes a worthless share even though a
     *      redemption would still deliver the idle senior shares (the same key drives the maxRedeem behavior in
     *      test_LTMaxRedeem_UnderreportsZeroOnIdleOnlyNAV_WhileFullBalanceRedeemsMultiAsset)
     */
    function test_Convert_FloorsToZeroOnZeroPoolMark_PreviewStillCarriesIdleLeg() public {
        _deployZeroMinLiquidityMarketWithPremium();
        uint256 idleShares = _accrueIdlePremiumSeniorShares();

        // Mark the entire pool worthless through the oracle: raw NAV reads zero, the idle leg stays claimable
        bptOracle.setTVL(0);
        bptOracle.setMode(MockBPTOracle.Mode.MANUAL);

        uint256 supply = liquidityTranche.totalSupply();
        uint256 shares = supply / 2;
        AssetClaims memory conv = liquidityTranche.convertToAssets(shares);
        assertEq(toUint256(conv.nav), 0, "the BPT-only price must floor to zero on a zero pool mark");
        assertEq(toUint256(conv.ltAssets), 0, "no BPT claim can be reported against a zero pool mark");
        assertEq(conv.stShares, 0, "the convert surface never reports the idle leg");

        // A BPT is worth zero NAV against a zero mark, so it quotes zero shares (no division by the zero raw NAV:
        // the zero-value numerator short-circuits the dilution convention)
        assertEq(liquidityTranche.convertToShares(toTrancheUnits(1e18)), 0, "a worthless BPT must quote zero shares");

        // The redemption quote still carries the idle slice: the claimable leg is priced and deliverable
        AssetClaims memory prev = liquidityTranche.previewRedeem(shares);
        assertEq(prev.stShares, Math.mulDiv(idleShares, shares, supply, Math.Rounding.Floor), "previewRedeem must still report the pro-rata idle slice");
        assertGt(toUint256(prev.nav), 0, "the redemption quote must still price the idle leg");
    }

    // =============================
    // Helpers
    // =============================

    /// @dev The independently recomputed BPT-only raw NAV: floor(TVL x ownedBpt / bptSupply) from the oracle and
    ///      vault primitives, never from the production quoter
    function _independentRawNAV() internal view returns (uint256) {
        return Math.mulDiv(
            bptOracle.computeTVL(), toUint256(kernel.getState().ltOwnedYieldBearingAssets), balancerVault.totalSupply(address(bpt)), Math.Rounding.Floor
        );
    }

    /// @dev Default-param market minus every protocol fee, premium enabled: isolates the lifecycle monotonicity from
    ///      fee-share dilution (see the contract natspec for the honest bound under nonzero fees)
    function _deployZeroFeeMarketWithPremium() internal {
        MarketParamsConfig memory p = defaultParams();
        p.stProtocolFeeWAD = 0;
        p.jtProtocolFeeWAD = 0;
        p.jtYieldShareProtocolFeeWAD = 0;
        p.ltYieldShareProtocolFeeWAD = 0;
        _deployMarket(cellA(), p);
    }

    /// @dev Zero-min-liquidity market with the LT premium re-enabled, seeded ST/JT plus a quote-only LT depth at
    ///      NAV-per-BPT exactly 1.0 (mirrors Test_TrancheViewEdges' setup)
    function _deployZeroMinLiquidityMarketWithPremium() internal {
        MarketParamsConfig memory p = zeroLiquidityParams();
        p.maxLTYieldShareWAD = 0.3e18;
        p.ltCurve = [uint64(0.02e18), uint64(0.1e18), uint64(0.3e18)];
        _deployMarket(cellA(), p);
        _seedMarket(ST_SEED, JT_SEED);
        _seedLT(LT_SEED_BPT, 0, LT_SEED_QUOTE);
    }

    /// @dev Accrues a nonzero idle liquidity premium: arms venue slippage so the +10% senior gain's premium mints as
    ///      senior shares to the LT while the gated reinvestment defers. Slippage stays armed so a later operation's
    ///      sync cannot deploy the pile mid-test
    function _accrueIdlePremiumSeniorShares() internal returns (uint256 idleShares) {
        setVenueSlippageMode(true);
        applySTPnL(1000);
        _sync();
        idleShares = kernel.getState().ltOwnedSeniorTrancheShares;
        assertTrue(idleShares != 0, "the gain must have left a nonzero idle liquidity premium senior share pile");
    }
}
