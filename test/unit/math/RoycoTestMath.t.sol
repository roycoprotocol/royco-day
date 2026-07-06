// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";

/**
 * @title RoycoTestMathTest
 * @notice Self-validation golden vectors for the independent expected-value library. Every expected value is
 *         a hand-derived literal with the arithmetic shown in a comment, so a regression in the mirror is
 *         caught here before it can silently agree with a production bug.
 * @dev Boundary set per formula: 0, 1 wei, max realistic (1e30), exact thresholds, zero-supply and zero-NAV
 *      edges. No sign-only asserts, no early returns.
 */
contract RoycoTestMathTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_NAV = 1e30;

    // Shared waterfall-vector conventions: T0 base timestamp and the 7-day fixed-term duration.
    uint256 private constant T0 = 1_700_000_000;
    uint256 private constant DURATION = 604_800;

    /*//////////////////////////////////////////////////////////////////////////
                                attribute
    //////////////////////////////////////////////////////////////////////////*/

    /// Zero delta attributes nothing regardless of claim shape.
    function test_Attribute_zeroDelta_returnsZero() public pure {
        assertEq(RoycoTestMath.attribute(0, 5e18, 10e18), 0, "zero delta");
        assertEq(RoycoTestMath.attribute(0, 0, 0), 0, "zero delta with empty market");
    }

    /// Zero claim attributes nothing in either direction.
    function test_Attribute_zeroClaim_returnsZero() public pure {
        assertEq(RoycoTestMath.attribute(1e18, 0, 10e18), 0, "gain, zero claim");
        assertEq(RoycoTestMath.attribute(-1e18, 0, 10e18), 0, "loss, zero claim");
    }

    /// Positive delta floors: attribute(+7, claim 1, lastRaw 3) = ⌊7·1/3⌋ = ⌊2.333…⌋ = 2.
    function test_Attribute_positiveDelta_floorsMagnitude() public pure {
        assertEq(RoycoTestMath.attribute(7, 1, 3), 2, "floor(7*1/3) = 2");
    }

    /// Negative delta floors the MAGNITUDE then re-applies the sign (toward zero, never away):
    /// attribute(-7, claim 2, lastRaw 3) = -⌊7·2/3⌋ = -⌊4.666…⌋ = -4 (not -5).
    function test_Attribute_negativeDelta_floorsMagnitudeThenReappliesSign() public pure {
        assertEq(RoycoTestMath.attribute(-7, 2, 3), -4, "-floor(7*2/3) = -4");
    }

    /// A full claim (claim == lastRaw) attributes the whole delta exactly, both signs.
    function test_Attribute_fullClaim_exact() public pure {
        assertEq(RoycoTestMath.attribute(-123_456_789, 1e18, 1e18), -123_456_789, "full claim on loss");
        assertEq(RoycoTestMath.attribute(987_654_321, 55e18, 55e18), 987_654_321, "full claim on gain");
    }

    /// 1-wei boundary: ⌊1·1/1e30⌋ = 0 and -⌊(1e30-1)·1/1e30⌋ = 0 (dust vanishes to the complement).
    function test_Attribute_oneWeiDelta_floorsToZero() public pure {
        assertEq(RoycoTestMath.attribute(1, 1, 1e30), 0, "floor(1*1/1e30) = 0");
        assertEq(RoycoTestMath.attribute(-1, 1e30 - 1, 1e30), 0, "-floor(1*(1e30-1)/1e30) = 0");
    }

    /// Max realistic NAV boundary (1e30): ⌊1e30·7e29/1e30⌋ = 7e29 exact, and the full-claim loss at scale.
    function test_Attribute_maxRealistic() public pure {
        assertEq(RoycoTestMath.attribute(int256(MAX_NAV), 7e29, MAX_NAV), 7e29, "floor(1e30*7e29/1e30) = 7e29");
        assertEq(RoycoTestMath.attribute(-int256(MAX_NAV), MAX_NAV, MAX_NAV), -int256(MAX_NAV), "full-claim loss at scale");
    }

    /// The two-way split floors each part so the rounding residual favors the complementary tranche:
    /// delta 7 over lastRaw 3 split as claims {1, 2}: ⌊7/3⌋ = 2 and ⌊14/3⌋ = 4, sum 6 = delta − 1.
    function test_Attribute_complementarySplit_residualDustDropped() public pure {
        int256 stPart = RoycoTestMath.attribute(7, 1, 3);
        int256 jtPart = RoycoTestMath.attribute(7, 2, 3);
        assertEq(stPart, 2, "floor(7*1/3) = 2");
        assertEq(jtPart, 4, "floor(7*2/3) = 4");
        assertEq(stPart + jtPart, 6, "split sums to delta - 1 (1 wei of floor residual)");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                covUtil
    //////////////////////////////////////////////////////////////////////////*/

    /// minCov == 0 means no requirement: utilization is 0 whatever the NAVs.
    function test_CovUtil_zeroMinCoverage_returnsZero() public pure {
        assertEq(RoycoTestMath.covUtil(1e18, 1e18, true, 0, 5e17), 0, "no coverage requirement");
    }

    /// Zero exposure returns 0. With jtCoinvested == false the JT raw NAV is excluded from exposure entirely.
    function test_CovUtil_zeroExposure_returnsZero() public pure {
        assertEq(RoycoTestMath.covUtil(0, 0, true, 1e17, 1e18), 0, "empty market");
        assertEq(RoycoTestMath.covUtil(0, 5e18, false, 1e17, 1e18), 0, "jtRaw excluded when not co-invested");
    }

    /// Zero edges take precedence over the infinite edge (both minCov == 0 and exposure == 0 vs jtEff == 0).
    function test_CovUtil_zeroEdgePrecedence_overInfiniteEdge() public pure {
        assertEq(RoycoTestMath.covUtil(0, 0, true, 1e17, 0), 0, "zero exposure wins over zero jtEff");
        assertEq(RoycoTestMath.covUtil(1e18, 0, false, 0, 0), 0, "zero minCov wins over zero jtEff");
    }

    /// Positive requirement against zero JT effective NAV is infinite utilization.
    function test_CovUtil_zeroJtEff_returnsMax() public pure {
        assertEq(RoycoTestMath.covUtil(1e18, 0, false, 1e17, 0), type(uint256).max, "uncovered exposure");
    }

    /// Exact WAD threshold, clean division: ⌈(100e18 + 50e18)·1e17 / 15e18⌉ = ⌈1.5e37/1.5e19⌉ = 1e18 exactly.
    function test_CovUtil_exactWadBoundary_cleanDivision() public pure {
        assertEq(RoycoTestMath.covUtil(100e18, 50e18, true, 1e17, 15e18), 1e18, "covU == WAD exactly");
    }

    /// Ceil engaged: ⌈10·1e17 / 3⌉ = ⌈1e18/3⌉ = ⌈333333333333333333.33…⌉ = 333333333333333334.
    function test_CovUtil_ceilRounding_favorsSenior() public pure {
        assertEq(RoycoTestMath.covUtil(10, 0, false, 1e17, 3), 333_333_333_333_333_334, "ceil(1e18/3)");
    }

    /// Beta off vs on: same NAVs as the WAD-boundary vector but jtCoinvested == false drops jtRaw from the
    /// numerator: ⌈100e18·1e17 / 15e18⌉ = ⌈1e37/1.5e19⌉ = ⌈666666666666666666.66…⌉ = 666666666666666667.
    function test_CovUtil_coinvestmentBeta_excludesJtRaw() public pure {
        assertEq(RoycoTestMath.covUtil(100e18, 50e18, false, 1e17, 15e18), 666_666_666_666_666_667, "ceil(1e37/1.5e19)");
    }

    /// Max realistic: ⌈(1e30 + 1e30)·1e18 / 1⌉ = 2e48 exact (no overflow through mulDiv).
    function test_CovUtil_maxRealistic() public pure {
        assertEq(RoycoTestMath.covUtil(MAX_NAV, MAX_NAV, true, WAD, 1), 2e48, "2e30 * 1e18 / 1");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                liqUtil
    //////////////////////////////////////////////////////////////////////////*/

    /// No senior value means nothing to provide liquidity for.
    function test_LiqUtil_zeroStEff_returnsZero() public pure {
        assertEq(RoycoTestMath.liqUtil(0, 1e17, 1e18), 0, "no senior value");
    }

    /// No liquidity requirement means zero utilization whatever the depth.
    function test_LiqUtil_zeroMinLiquidity_returnsZero() public pure {
        assertEq(RoycoTestMath.liqUtil(1e18, 0, 5), 0, "no requirement");
    }

    /// Positive requirement against zero pool depth is infinite utilization.
    function test_LiqUtil_zeroLtRaw_returnsMax() public pure {
        assertEq(RoycoTestMath.liqUtil(1e18, 1e17, 0), type(uint256).max, "zero depth");
    }

    /// Zero edges take precedence over the infinite edge.
    function test_LiqUtil_zeroEdgePrecedence_overInfiniteEdge() public pure {
        assertEq(RoycoTestMath.liqUtil(0, 1e17, 0), 0, "zero stEff wins over zero ltRaw");
        assertEq(RoycoTestMath.liqUtil(5, 0, 0), 0, "zero minLiq wins over zero ltRaw");
    }

    /// Exact WAD threshold, clean division: ⌈1000e18·5e16 / 50e18⌉ = ⌈5e37/5e19⌉ = 1e18 exactly.
    function test_LiqUtil_exactWadBoundary_cleanDivision() public pure {
        assertEq(RoycoTestMath.liqUtil(1000e18, 5e16, 50e18), 1e18, "liqU == WAD exactly");
    }

    /// Ceil engaged: ⌈10·1e17 / 3⌉ = ⌈1e18/3⌉ = 333333333333333334.
    function test_LiqUtil_ceilRounding_favorsSenior() public pure {
        assertEq(RoycoTestMath.liqUtil(10, 1e17, 3), 333_333_333_333_333_334, "ceil(1e18/3)");
    }

    /// 1-wei boundary: ⌈1·1 / 1e30⌉ = ⌈1e-30⌉ = 1, the ceil bias never reads a positive requirement as zero.
    function test_LiqUtil_oneWei_ceilsToOne() public pure {
        assertEq(RoycoTestMath.liqUtil(1, 1, 1e30), 1, "ceil of any positive quotient is >= 1");
    }

    /// Max realistic, exact division: ⌈1e30·(1e18−1) / 1e30⌉ = 1e18 − 1 = 999999999999999999.
    function test_LiqUtil_maxRealistic() public pure {
        assertEq(RoycoTestMath.liqUtil(MAX_NAV, WAD - 1, MAX_NAV), 999_999_999_999_999_999, "(1e30*(1e18-1))/1e30 exact");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                sharesFor
    //////////////////////////////////////////////////////////////////////////*/

    /// First mint (supply == 0) is 1:1 with the contributed value, totalValue ignored. Historical pins run at
    /// residual 0 (the clamp-disabled reduction: identical literals to the pre-clamp F9).
    function test_SharesFor_zeroSupply_mintsOneToOne() public pure {
        assertEq(RoycoTestMath.sharesFor(123e18, 0, 0), 123e18, "first depositor 1:1");
        assertEq(RoycoTestMath.sharesFor(5, 999, 0), 5, "totalValue ignored at zero supply");
    }

    /// Live supply over zero NAV pins the denominator to 1 wei: ⌊7·3/1⌋ = 21.
    function test_SharesFor_zeroTotalValue_usesOneWeiDenominator() public pure {
        assertEq(RoycoTestMath.sharesFor(3, 0, 7), 21, "floor(7*3/1) = 21");
    }

    /// Floor engaged: ⌊5·3/7⌋ = ⌊15/7⌋ = ⌊2.142…⌋ = 2 (dust stays with existing holders).
    function test_SharesFor_floorRounding_favorsExistingHolders() public pure {
        assertEq(RoycoTestMath.sharesFor(3, 7, 5), 2, "floor(15/7) = 2");
    }

    /// Clean division: ⌊200e18·10e18 / 100e18⌋ = 20e18.
    function test_SharesFor_cleanDivision() public pure {
        assertEq(RoycoTestMath.sharesFor(10e18, 100e18, 200e18), 20e18, "floor(200e18*10e18/100e18)");
    }

    /// Zero value mints zero shares against a live market.
    function test_SharesFor_zeroValue_returnsZero() public pure {
        assertEq(RoycoTestMath.sharesFor(0, 100, 50), 0, "nothing in, nothing out");
    }

    /// 1-wei boundaries: ⌊1e30·1/1e30⌋ = 1 at par, ⌊1·1/1e30⌋ = 0 when the pot dwarfs the supply.
    function test_SharesFor_oneWeiBoundaries() public pure {
        assertEq(RoycoTestMath.sharesFor(1, 1e30, 1e30), 1, "floor(1e30*1/1e30) = 1");
        assertEq(RoycoTestMath.sharesFor(1, 1e30, 1), 0, "floor(1*1/1e30) = 0");
    }

    /// Max realistic at par: ⌊1e30·1e30/1e30⌋ = 1e30.
    function test_SharesFor_maxRealistic() public pure {
        assertEq(RoycoTestMath.sharesFor(MAX_NAV, MAX_NAV, MAX_NAV), MAX_NAV, "par at scale");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            the mint-dilution clamp
    //////////////////////////////////////////////////////////////////////////*/

    /// Bind boundary, exact (continuity): at d = 1e18, S = 1e18, ε = 1e6 the bind threshold is
    ///   threshold = ⌊d·(WAD−ε)/ε⌋ = 1e18 · 999_999_999_999 = 1e30 − 1e18   ((WAD−ε)/ε is the exact integer 1e12−1)
    /// At v = threshold the bind test is exactly at equality (⌈v·ε/(WAD−ε)⌉ = 1e18 = d, not >), so the mint is
    /// fair-priced: ⌊1e18·(1e30−1e18)/1e18⌋ = 1e30 − 1e18 — which EQUALS the cap ⌊1e18·(WAD−ε)/ε⌋, so the clamp
    /// is continuous at the boundary.
    function test_SharesFor_clampBindBoundary_fairEqualsCapExactly() public pure {
        uint256 threshold = 1e30 - 1e18;
        assertEq(RoycoTestMath.sharesFor(threshold, 1e18, 1e18), threshold, "at the boundary the fair mint equals the cap");
    }

    /// Bind boundary + 1 wei: v = threshold + 1 trips the bind (⌈v·ε/(WAD−ε)⌉ = 1e18 + 1 > d) and returns the
    /// cap = 1e30 − 1e18 — the same output as the boundary itself (the clamp plateaus, it does not jump).
    function test_SharesFor_clampBindBoundaryPlusOne_returnsSameCap() public pure {
        assertEq(RoycoTestMath.sharesFor(1e30 - 1e18 + 1, 1e18, 1e18), 1e30 - 1e18, "one wei past the boundary mints the identical cap");
    }

    /// Zero-NAV composition min(S·v, cap): the 1-wei branch stays unclamped for small values
    /// (bind iff ⌈3·1e6/(1e18−1e6)⌉ = 1 > 1 is false ⇒ ⌊7·3/1⌋ = 21 unchanged), and clamps for large ones
    /// (v = 1e12: ⌈1e12·1e6/(1e18−1e6)⌉ = 2 > 1 ⇒ cap = ⌊7·(1e18−1e6)/1e6⌋ = 7·(1e12−1) = 6_999_999_999_993).
    function test_SharesFor_clampOverZeroNAV_composesWithOneWeiDenominator() public pure {
        assertEq(RoycoTestMath.sharesFor(3, 0, 7), 21, "small dilution mint stays fair-priced");
        assertEq(RoycoTestMath.sharesFor(1e12, 0, 7), 6_999_999_999_993, "large dilution mint clamps to 7*(1e12-1)");
    }

    /// Bootstrap exemption: supply == 0 mints 1:1 no matter how large the value — a first mint dilutes
    /// nobody, so the clamp has nothing to protect (1e40 over a live supply would bind hard).
    function test_SharesFor_clampBootstrapExemption() public pure {
        assertEq(RoycoTestMath.sharesFor(1e40, 0, 0), 1e40, "bootstrap mints 1:1, exempt from the clamp");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                valueFor
    //////////////////////////////////////////////////////////////////////////*/

    /// Zero supply values everything at 0 (no holders to owe).
    function test_ValueFor_zeroSupply_returnsZero() public pure {
        assertEq(RoycoTestMath.valueFor(5, 100, 0), 0, "zero supply");
    }

    /// Floor engaged: ⌊7·2/3⌋ = ⌊4.666…⌋ = 4 (dust stays with remaining holders).
    function test_ValueFor_floorRounding_favorsRemainingHolders() public pure {
        assertEq(RoycoTestMath.valueFor(2, 7, 3), 4, "floor(14/3) = 4");
    }

    /// Full supply redeems the whole pot exactly: ⌊7·3/3⌋ = 7.
    function test_ValueFor_fullSupply_exact() public pure {
        assertEq(RoycoTestMath.valueFor(3, 7, 3), 7, "full exit takes everything");
    }

    /// Zero shares are worth zero, and a live supply over zero NAV is worth zero.
    function test_ValueFor_zeroShares_andZeroNav_returnZero() public pure {
        assertEq(RoycoTestMath.valueFor(0, 1e30, 5), 0, "zero shares");
        assertEq(RoycoTestMath.valueFor(3, 0, 7), 0, "supply > 0 with NAV == 0");
    }

    /// 1-wei and max-realistic boundaries at par: ⌊1e30·1/1e30⌋ = 1 and ⌊1e30·1e30/1e30⌋ = 1e30.
    function test_ValueFor_boundaries() public pure {
        assertEq(RoycoTestMath.valueFor(1, 1e30, 1e30), 1, "1 wei share at par");
        assertEq(RoycoTestMath.valueFor(MAX_NAV, MAX_NAV, MAX_NAV), MAX_NAV, "par at scale");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                carveOut
    //////////////////////////////////////////////////////////////////////////*/

    /// Clean division:
    ///   retained      = 1050e18 − 30e18 − 20e18 = 1000e18
    ///   premiumShares = ⌊1000e18·30e18/1000e18⌋ = 30e18
    ///   feeShares     = ⌊1000e18·20e18/1000e18⌋ = 20e18
    ///   supplyAfter   = 1000e18 + 30e18 + 20e18 = 1050e18
    function test_CarveOut_cleanDivision() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.carveOut(1050e18, 30e18, 20e18, 1000e18);
        assertEq(premiumShares, 30e18, "premium shares exact");
        assertEq(feeShares, 20e18, "fee shares exact");
        assertEq(supplyAfter, 1050e18, "supply after both mints");
    }

    /// Floor engaged (wei scale):
    ///   retained      = 10 − 3 − 2 = 5
    ///   premiumShares = ⌊3·3/5⌋ = ⌊9/5⌋ = ⌊1.8⌋ = 1
    ///   feeShares     = ⌊3·2/5⌋ = ⌊6/5⌋ = ⌊1.2⌋ = 1
    ///   supplyAfter   = 3 + 1 + 1 = 5
    function test_CarveOut_floorRounding_favorsPreExistingST() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.carveOut(10, 3, 2, 3);
        assertEq(premiumShares, 1, "floor(9/5) = 1");
        assertEq(feeShares, 1, "floor(6/5) = 1");
        assertEq(supplyAfter, 5, "3 + 1 + 1");
    }

    /// Degenerate carve-out consuming all of stEff routes through sharesFor's 1-wei denominator:
    ///   retained = 10 − 7 − 3 = 0 ⇒ denom 1: premiumShares = ⌊100·7/1⌋ = 700, feeShares = ⌊100·3/1⌋ = 300.
    function test_CarveOut_retainedZero_oneWeiDenominator() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.carveOut(10, 7, 3, 100);
        assertEq(premiumShares, 700, "floor(100*7/1) = 700");
        assertEq(feeShares, 300, "floor(100*3/1) = 300");
        assertEq(supplyAfter, 1100, "100 + 700 + 300");
    }

    /// Pre-sync supply 0 routes through sharesFor's first-mint branch: both legs mint 1:1 with their value,
    /// exempt from the dilution clamp (a bootstrap mint dilutes nobody).
    ///   retained = 100 − 30 − 20 = 50 is ignored at zero supply: premiumShares = 30, feeShares = 20.
    function test_CarveOut_zeroPreSupply_mintsOneToOne() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.carveOut(100, 30, 20, 0);
        assertEq(premiumShares, 30, "first-mint 1:1 premium leg");
        assertEq(feeShares, 20, "first-mint 1:1 fee leg");
        assertEq(supplyAfter, 50, "0 + 30 + 20");
    }

    /// Zero premium and fee mint nothing and leave the supply untouched.
    function test_CarveOut_zeroPremiumAndFee_noMint() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.carveOut(100, 0, 0, 77);
        assertEq(premiumShares, 0, "no premium");
        assertEq(feeShares, 0, "no fee");
        assertEq(supplyAfter, 77, "supply unchanged");
    }

    /// Max realistic, clean (clamp inert: 5e29·1e6 ≤ 5e29·(1e18−1e6) at the protocol residual):
    /// retained = 1e30 − 5e29 = 5e29, premiumShares = ⌊1e30·5e29/5e29⌋ = 1e30,
    /// supplyAfter = 1e30 + 1e30 = 2e30 (a 100%-of-retained premium doubles the supply).
    function test_CarveOut_maxRealistic() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.carveOut(1e30, 5e29, 0, 1e30);
        assertEq(premiumShares, 1e30, "floor(1e30*5e29/5e29) = 1e30");
        assertEq(feeShares, 0, "no fee");
        assertEq(supplyAfter, 2e30, "1e30 + 1e30");
    }

    /// Degenerate carve-out under the clamp (the V2.2 shape at mirror level): retained = 0 pins the 1-wei
    /// denominator, both legs bind (⌈4e18·1e6/(1e18−1e6)⌉ > 1 at the protocol residual), and each clamps to
    /// cap = ⌊1e18·(1e18−1e6)/1e6⌋ = 999_999_999_999e18 — the per-mint residual guarantee.
    function test_CarveOut_retainedZero_clampsBothLegsToCap() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.carveOut(10e18, 4e18, 6e18, 1e18);
        assertEq(premiumShares, 999_999_999_999e18, "premium leg clamps to the cap");
        assertEq(feeShares, 999_999_999_999e18, "fee leg clamps to the same cap");
        assertEq(supplyAfter, 1e18 + 2 * 999_999_999_999e18, "supply identity across two capped mints");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                scaleClaims
    //////////////////////////////////////////////////////////////////////////*/

    /// All five fields floor independently at shares 2 of 3:
    ///   ⌊10·2/3⌋ = ⌊6.67⌋ = 6, ⌊7·2/3⌋ = ⌊4.67⌋ = 4, ⌊5·2/3⌋ = ⌊3.33⌋ = 3, ⌊3·2/3⌋ = 2, ⌊11·2/3⌋ = ⌊7.33⌋ = 7.
    function test_ScaleClaims_allFiveFieldsFloored() public pure {
        RoycoTestMath.Claims memory total = RoycoTestMath.Claims({ stAssets: 10, jtAssets: 7, ltAssets: 5, stShares: 3, nav: 11 });
        RoycoTestMath.Claims memory scaled = RoycoTestMath.scaleClaims(total, 2, 3);
        assertEq(scaled.stAssets, 6, "floor(20/3) = 6");
        assertEq(scaled.jtAssets, 4, "floor(14/3) = 4");
        assertEq(scaled.ltAssets, 3, "floor(10/3) = 3");
        assertEq(scaled.stShares, 2, "floor(6/3) = 2");
        assertEq(scaled.nav, 7, "floor(22/3) = 7");
    }

    /// Full shares (shares == totalShares) is the identity on every field.
    function test_ScaleClaims_fullShares_identity() public pure {
        RoycoTestMath.Claims memory total = RoycoTestMath.Claims({ stAssets: 1e18, jtAssets: 2e18, ltAssets: 3e18, stShares: 4e18, nav: 5e18 });
        RoycoTestMath.Claims memory scaled = RoycoTestMath.scaleClaims(total, 5, 5);
        assertEq(scaled.stAssets, 1e18, "identity stAssets");
        assertEq(scaled.jtAssets, 2e18, "identity jtAssets");
        assertEq(scaled.ltAssets, 3e18, "identity ltAssets");
        assertEq(scaled.stShares, 4e18, "identity stShares");
        assertEq(scaled.nav, 5e18, "identity nav");
    }

    /// Zero shares scale every field to zero.
    function test_ScaleClaims_zeroShares_allZero() public pure {
        RoycoTestMath.Claims memory total = RoycoTestMath.Claims({ stAssets: 1e30, jtAssets: 1e30, ltAssets: 1e30, stShares: 1e30, nav: 1e30 });
        RoycoTestMath.Claims memory scaled = RoycoTestMath.scaleClaims(total, 0, 1e30);
        assertEq(scaled.stAssets, 0, "zero slice stAssets");
        assertEq(scaled.jtAssets, 0, "zero slice jtAssets");
        assertEq(scaled.ltAssets, 0, "zero slice ltAssets");
        assertEq(scaled.stShares, 0, "zero slice stShares");
        assertEq(scaled.nav, 0, "zero slice nav");
    }

    /// Max realistic with a 1-wei slice: each field ⌊1e30·1/1e30⌋ = 1.
    function test_ScaleClaims_maxRealistic_oneWeiSlice() public pure {
        RoycoTestMath.Claims memory total = RoycoTestMath.Claims({ stAssets: 1e30, jtAssets: 1e30, ltAssets: 1e30, stShares: 1e30, nav: 1e30 });
        RoycoTestMath.Claims memory scaled = RoycoTestMath.scaleClaims(total, 1, 1e30);
        assertEq(scaled.stAssets, 1, "floor(1e30/1e30) = 1");
        assertEq(scaled.jtAssets, 1, "floor(1e30/1e30) = 1");
        assertEq(scaled.ltAssets, 1, "floor(1e30/1e30) = 1");
        assertEq(scaled.stShares, 1, "floor(1e30/1e30) = 1");
        assertEq(scaled.nav, 1, "floor(1e30/1e30) = 1");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ltEffNav
    //////////////////////////////////////////////////////////////////////////*/

    /// No idle shares: effective NAV is the pool leg alone.
    function test_LtEffNav_noIdleShares_equalsLtRaw() public pure {
        assertEq(RoycoTestMath.ltEffNav(100e18, 0, 500e18, 1000e18), 100e18, "pure BPT state");
    }

    /// Clean idle valuation: 100e18 + ⌊10e18·2000e18/1000e18⌋ = 100e18 + 20e18 = 120e18.
    function test_LtEffNav_cleanIdleValuation() public pure {
        assertEq(RoycoTestMath.ltEffNav(100e18, 10e18, 2000e18, 1000e18), 120e18, "ltRaw + idle leg");
    }

    /// Floor on the idle leg: 5 + ⌊3·7/2⌋ = 5 + ⌊10.5⌋ = 5 + 10 = 15.
    function test_LtEffNav_floorRounding_favorsPoolLeg() public pure {
        assertEq(RoycoTestMath.ltEffNav(5, 3, 7, 2), 15, "5 + floor(21/2) = 15");
    }

    /// Zero ST supply values the idle leg at 0 (the valueFor edge): effective NAV falls back to ltRaw.
    function test_LtEffNav_zeroStSupply_idleLegIsZero() public pure {
        assertEq(RoycoTestMath.ltEffNav(42, 999, 1e18, 0), 42, "idle leg zero at zero supply");
    }

    /// Zero pool leg with staged premium only: 0 + ⌊3·7/2⌋ = 10.
    function test_LtEffNav_zeroLtRaw_idleLegOnly() public pure {
        assertEq(RoycoTestMath.ltEffNav(0, 3, 7, 2), 10, "floor(21/2) = 10");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                staticYdm
    //////////////////////////////////////////////////////////////////////////*/

    // Reference curve for the vectors below: y0 = 1e16 (1%), yTarget = 1e17 (10%), yFull = 1e18 (100%),
    // targetU = 8e17 (80%).
    //   Lower slope = ⌊(1e17 − 1e16)·1e18 / 8e17⌋ = ⌊9e34 / 8e17⌋ = 112500000000000000 (exact division).
    //   Upper slope = ⌊(1e18 − 1e17)·1e18 / (1e18 − 8e17)⌋ = ⌊9e35 / 2e17⌋ = 4500000000000000000 (exact).

    /// At u = 0 the curve returns its intercept: 1e16 + ⌊112500000000000000·0/1e18⌋ = 1e16.
    function test_StaticYdm_zeroUtilization_returnsY0() public pure {
        assertEq(RoycoTestMath.staticYdm(0, 1e16, 1e17, 1e18, 8e17), 1e16, "y(0) = y0");
    }

    /// At u == targetU the exact point value yTarget is returned with no interpolation.
    function test_StaticYdm_atTarget_returnsYTargetExactly() public pure {
        assertEq(RoycoTestMath.staticYdm(8e17, 1e16, 1e17, 1e18, 8e17), 1e17, "y(target) = yTarget");
    }

    /// Below target: 1e16 + ⌊112500000000000000·4e17/1e18⌋ = 1e16 + 45000000000000000 = 55000000000000000.
    function test_StaticYdm_belowTarget_lowerSegment() public pure {
        assertEq(RoycoTestMath.staticYdm(4e17, 1e16, 1e17, 1e18, 8e17), 55_000_000_000_000_000, "y(0.4) = 5.5%");
    }

    /// Above target: 1e17 + ⌊4500000000000000000·(9e17−8e17)/1e18⌋ = 1e17 + 45e16 = 550000000000000000.
    function test_StaticYdm_aboveTarget_upperSegment() public pure {
        assertEq(RoycoTestMath.staticYdm(9e17, 1e16, 1e17, 1e18, 8e17), 550_000_000_000_000_000, "y(0.9) = 55%");
    }

    /// At full utilization: 1e17 + ⌊4500000000000000000·2e17/1e18⌋ = 1e17 + 9e17 = 1e18 = yFull.
    function test_StaticYdm_fullUtilization_returnsYFull() public pure {
        assertEq(RoycoTestMath.staticYdm(1e18, 1e16, 1e17, 1e18, 8e17), 1e18, "y(WAD) = yFull");
    }

    /// Utilization above WAD is capped to WAD before evaluation: y(2.5e18) == y(1e18) = 1e18.
    function test_StaticYdm_utilizationAboveWad_capped() public pure {
        assertEq(RoycoTestMath.staticYdm(25e17, 1e16, 1e17, 1e18, 8e17), 1e18, "u capped at WAD");
    }

    /// Result capped at WAD: curve (0, 5e17, 2e18) with target 5e17 at u = 1e18 interpolates to
    /// 5e17 + ⌊⌊1.5e18·1e18/5e17⌋·5e17/1e18⌋ = 5e17 + ⌊3e18·5e17/1e18⌋ = 5e17 + 1.5e18 = 2e18, capped to 1e18.
    function test_StaticYdm_resultCappedAtWad() public pure {
        assertEq(RoycoTestMath.staticYdm(1e18, 0, 5e17, 2e18, 5e17), 1e18, "result capped at WAD");
    }

    /// The exact-point return is also capped: yTarget = 2e18 at u == targetU returns min(2e18, WAD) = 1e18.
    function test_StaticYdm_exactPointCappedAtWad() public pure {
        assertEq(RoycoTestMath.staticYdm(5e17, 0, 2e18, 3e18, 5e17), 1e18, "point value capped at WAD");
    }

    /// Double-floor artifact pinned (stored-slope shape): curve (0, 1, 9) with target 3 at u = 2.
    /// slope = ⌊1·1e18/3⌋ = 333333333333333333, y = 0 + ⌊333333333333333333·2/1e18⌋ = ⌊0.666…⌋ = 0.
    function test_StaticYdm_doubleFloorArtifact_pinned() public pure {
        assertEq(RoycoTestMath.staticYdm(2, 0, 1, 9, 3), 0, "double floor loses the wei by design");
    }

    /// targetU == 0 degenerates the lower segment: u = 0 hits the exact point (yTarget = 7), and u = WAD
    /// evaluates the upper segment 7 + ⌊⌊2·1e18/1e18⌋·1e18/1e18⌋ = 7 + 2 = 9.
    function test_StaticYdm_zeroTarget_usesUpperSegment() public pure {
        assertEq(RoycoTestMath.staticYdm(0, 5, 7, 9, 0), 7, "u == target == 0 returns yTarget");
        assertEq(RoycoTestMath.staticYdm(1e18, 5, 7, 9, 0), 9, "upper segment spans the whole domain");
    }

    /// targetU == WAD degenerates the upper segment: capped u == targetU returns yTarget, yFull unreachable.
    function test_StaticYdm_targetAtWad_lowerSegmentCoversDomain() public pure {
        assertEq(RoycoTestMath.staticYdm(1e18, 1e16, 1e17, 999e18, 1e18), 1e17, "u capped to WAD == target");
        // Below the target the lower segment interpolates: slope = ⌊9e16·1e18/1e18⌋ = 9e16,
        // y(5e17) = 1e16 + ⌊9e16·5e17/1e18⌋ = 1e16 + 4.5e16 = 5.5e16.
        assertEq(RoycoTestMath.staticYdm(5e17, 1e16, 1e17, 999e18, 1e18), 55_000_000_000_000_000, "lower segment midpoint");
    }

    /// A flat curve returns the constant everywhere (both slopes are 0).
    function test_StaticYdm_flatCurve_constant() public pure {
        assertEq(RoycoTestMath.staticYdm(3e17, 3e16, 3e16, 3e16, 8e17), 3e16, "flat below target");
        assertEq(RoycoTestMath.staticYdm(9e17, 3e16, 3e16, 3e16, 8e17), 3e16, "flat above target");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            WATERFALL — helpers
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Builds a WaterfallIn under the shared vector conventions: minCoverage 0.1e18, liquidation
     * threshold 1.1e18, minLiquidity 0.05e18, all four fee rates 0.1e18, jtCoinvested false, fixed-term
     * duration 7 days, ltRawNew 100e18, sync at T0 on the instantaneous branch (elapsed 0) with pinned
     * preview rates jt 0.1e18 / lt 0.05e18 and caps jt 0.2e18 / lt 0.1e18.
     */
    function _cellIn(
        uint256 stRawLast,
        uint256 jtRawLast,
        uint256 stEffLast,
        uint256 jtEffLast,
        uint256 il,
        RoycoTestMath.MarketState stateLast,
        uint256 endLast,
        uint256 dust,
        uint256 stRawNew,
        uint256 jtRawNew
    )
        private
        pure
        returns (RoycoTestMath.WaterfallIn memory in_)
    {
        in_.stRawLast = stRawLast;
        in_.jtRawLast = jtRawLast;
        in_.stEffLast = stEffLast;
        in_.jtEffLast = jtEffLast;
        in_.jtCoverageILLast = il;
        in_.marketStateLast = stateLast;
        in_.fixedTermEndLast = endLast;
        in_.stRawDelta = int256(stRawNew) - int256(stRawLast);
        in_.jtRawDelta = int256(jtRawNew) - int256(jtRawLast);
        in_.ltRawNew = 100e18;
        in_.jtTwYieldShareAccrual = 0;
        in_.ltTwYieldShareAccrual = 0;
        in_.elapsedSincePremiumPayment = 0;
        in_.jtInstYieldShareWAD = 0.1e18;
        in_.ltInstYieldShareWAD = 0.05e18;
        in_.maxJTYieldShareWAD = 0.2e18;
        in_.maxLTYieldShareWAD = 0.1e18;
        in_.stProtocolFeeWAD = 0.1e18;
        in_.jtProtocolFeeWAD = 0.1e18;
        in_.jtYieldShareProtocolFeeWAD = 0.1e18;
        in_.ltYieldShareProtocolFeeWAD = 0.1e18;
        in_.nowTimestamp = T0;
        in_.fixedTermDuration = DURATION;
        in_.minCoverageWAD = 0.1e18;
        in_.jtCoinvested = false;
        in_.coverageLiquidationUtilizationWAD = 1.1e18;
        in_.effectiveDust = dust;
        in_.minLiquidityWAD = 0.05e18;
    }

    /// Field-exact comparison of a computed WaterfallOut against a hand-built expected literal.
    function _assertWaterfall(RoycoTestMath.WaterfallOut memory actual, RoycoTestMath.WaterfallOut memory expected) private pure {
        assertEq(actual.stRaw, expected.stRaw, "stRaw");
        assertEq(actual.jtRaw, expected.jtRaw, "jtRaw");
        assertEq(actual.ltRaw, expected.ltRaw, "ltRaw");
        assertEq(actual.stEff, expected.stEff, "stEff");
        assertEq(actual.jtEff, expected.jtEff, "jtEff");
        assertEq(actual.jtCoverageIL, expected.jtCoverageIL, "jtCoverageIL");
        assertEq(actual.jtRiskPremium, expected.jtRiskPremium, "jtRiskPremium");
        assertEq(actual.ltLiquidityPremium, expected.ltLiquidityPremium, "ltLiquidityPremium");
        assertEq(actual.stProtocolFee, expected.stProtocolFee, "stProtocolFee");
        assertEq(actual.jtProtocolFee, expected.jtProtocolFee, "jtProtocolFee");
        assertEq(actual.ltProtocolFee, expected.ltProtocolFee, "ltProtocolFee");
        assertEq(actual.coverageUtilizationWAD, expected.coverageUtilizationWAD, "coverageUtilizationWAD");
        assertEq(actual.liquidityUtilizationWAD, expected.liquidityUtilizationWAD, "liquidityUtilizationWAD");
        assertEq(uint256(actual.marketState), uint256(expected.marketState), "marketState");
        assertEq(actual.fixedTermEnd, expected.fixedTermEnd, "fixedTermEnd");
        assertEq(actual.premiumsPaid, expected.premiumsPaid, "premiumsPaid");
        assertEq(actual.ilErased, expected.ilErased, "ilErased");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        WATERFALL — golden vectors
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Both tranches gain in the same sync, so the JT fee takes both parts (own gain plus risk premium) and
     * the premiums resolve through the instantaneous branch. Pins the full up-path fee and premium plumbing.
     * Checkpoint (stRaw/jtRaw/stEff/jtEff): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Sync (1050e18, 220e18).
     *   JT leg: jtNetGain 20e18 > dust 0 ⇒ provisional jtFee = ⌊20e18·0.1⌋ = 2e18, jtEff = 220e18.
     *   ST gain leg: stGain 50e18, no IL. premiumsPaid (50e18 > 0). Instantaneous (elapsed forced 1):
     *     jtPrem = ⌊50e18·0.1e18/(1·1e18)⌋ = 5e18, ltPrem = ⌊50e18·0.05e18/1e18⌋ = 2.5e18 (7.5e18 <= 50e18 ok).
     *     jtFee += ⌊5e18·0.1⌋ = 0.5e18 ⇒ 2.5e18 total, jtEff = 225e18, ltFee = ⌊2.5e18·0.1⌋ = 0.25e18.
     *     Residual 50e18 − 5e18 − 2.5e18 = 42.5e18 ⇒ stFee = 4.25e18, stEff = 1000e18 + 42.5e18 + 2.5e18 = 1045e18.
     *   Conservation 1050 + 220 = 1045 + 225 (e18). IL 0 ⇒ PERPETUAL.
     *   covUtil = ⌈1050e18·0.1e18/225e18⌉ = ⌈0.46666…e18⌉ = 466666666666666667.
     *   liqUtil = ⌈1045e18·0.05e18/100e18⌉ = 5.225e17 exact.
     */
    function test_Waterfall_W9_gainGain_bothJtFeeParts_instantaneousPremium() public pure {
        RoycoTestMath.WaterfallIn memory in_ = _cellIn(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 1050e18, 220e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 1050e18;
        expected.jtRaw = 220e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1045e18;
        expected.jtEff = 225e18;
        expected.jtCoverageIL = 0;
        expected.jtRiskPremium = 5e18;
        expected.ltLiquidityPremium = 2.5e18;
        expected.stProtocolFee = 4.25e18;
        expected.jtProtocolFee = 2.5e18;
        expected.ltProtocolFee = 0.25e18;
        expected.coverageUtilizationWAD = 466_666_666_666_666_667;
        expected.liquidityUtilizationWAD = 522_500_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.fixedTermEnd = 0;
        expected.premiumsPaid = true;
        expected.ilErased = 0;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * ST loses while JT gains: coverage draws from the post-gain JT buffer and the JT fee is recomputed on the
     * net, so a fee never books on gain that coverage immediately consumed.
     * Checkpoint (stRaw/jtRaw/stEff/jtEff): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Sync (950e18, 220e18).
     *   JT leg: gain 20e18 ⇒ provisional fee 2e18, jtEff 220e18.
     *   ST loss leg: stLoss 50e18, coverage = min(50e18, 220e18) = 50e18. Recompute: jtNetGain = sat(20e18 − 50e18) = 0
     *   <= dust ⇒ jtFee = 0. jtEff = 170e18, IL = 50e18, stEff unchanged 1000e18.
     *   IL 50e18 > dust 0 ⇒ FIXED_TERM entry from PERPETUAL: end = T0 + D, fees zeroed (only jtFee was live).
     *   covUtil = ⌈950e18·0.1e18/170e18⌉ = ⌈558823529411764705.88⌉ = 558823529411764706.
     *   liqUtil = ⌈1000e18·0.05e18/100e18⌉ = 5e17.
     */
    function test_Waterfall_W3_stLossJtGain_coverageAndFeeRecompute_ftEntry() public pure {
        RoycoTestMath.WaterfallIn memory in_ = _cellIn(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 950e18, 220e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 950e18;
        expected.jtRaw = 220e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1000e18;
        expected.jtEff = 170e18;
        expected.jtCoverageIL = 50e18;
        expected.coverageUtilizationWAD = 558_823_529_411_764_706;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEnd = T0 + DURATION;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * A JT-only gain in a PERPETUAL commit keeps its fee: fee zeroing belongs to FIXED_TERM commits only,
     * so this pins that a healthy market never drops an earned fee.
     * Checkpoint (stRaw/jtRaw/stEff/jtEff): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Sync (1000e18, 220e18): jtNetGain 20e18 ⇒ jtFee 2e18, jtEff 220e18, no ST leg.
     * IL 0 ⇒ PERPETUAL. covUtil = ⌈1000e18·0.1e18/220e18⌉ = ⌈454545454545454545.45⌉ = 454545454545454546.
     */
    function test_Waterfall_W6_jtOnlyGain_feeSurvivesPerpetual() public pure {
        RoycoTestMath.WaterfallIn memory in_ = _cellIn(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 1000e18, 220e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 1000e18;
        expected.jtRaw = 220e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1000e18;
        expected.jtEff = 220e18;
        expected.jtProtocolFee = 2e18;
        expected.coverageUtilizationWAD = 454_545_454_545_454_546;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * A loss past JT exhaustion wipes the junior buffer out, which forces PERPETUAL and erases the IL: an
     * uncovered loss can never land the market in FIXED_TERM, because the wipeout disjunct always fires first.
     * Checkpoint (stRaw/jtRaw/stEff/jtEff): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Sync (700e18, 200e18): stLoss 300e18, coverage = min(300e18, 200e18) = 200e18 ⇒ jtEff 0,
     * IL 200e18, residual 100e18 ⇒ stEff 900e18. covUtil = uint256 max (jtEff 0 against exposure 700e18),
     * which also satisfies the liquidation disjunct. Forced PERPETUAL: ilErased = 200e18, IL = 0, end 0.
     * Conservation 700 + 200 = 900 + 0. liqUtil = ⌈900e18·0.05e18/100e18⌉ = 4.5e17.
     */
    function test_Waterfall_W55_lossPastJtExhaustion_wipeoutErasesIL() public pure {
        RoycoTestMath.WaterfallIn memory in_ = _cellIn(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 700e18, 200e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 700e18;
        expected.jtRaw = 200e18;
        expected.ltRaw = 100e18;
        expected.stEff = 900e18;
        expected.jtEff = 0;
        expected.jtCoverageIL = 0;
        expected.coverageUtilizationWAD = type(uint256).max;
        expected.liquidityUtilizationWAD = 450_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.ilErased = 200e18;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * Exhaustion exactly at the boundary: the loss is fully covered but the junior buffer empties to zero,
     * so senior keeps its full effective NAV while the wipeout disjunct still fires. Distinguishes the
     * covered-boundary case from the residual-loss wipeout above.
     * Checkpoint (stRaw/jtRaw/stEff/jtEff): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Sync (800e18, 200e18): stLoss 200e18 == jtEff ⇒ coverage 200e18, jtEff 0, residual 0,
     * stEff intact at 1000e18, IL 200e18 ⇒ wipeout disjunct ⇒ PERPETUAL, IL erased.
     */
    function test_Waterfall_W56_exhaustionAtBoundary_stEffIntact() public pure {
        RoycoTestMath.WaterfallIn memory in_ = _cellIn(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 800e18, 200e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 800e18;
        expected.jtRaw = 200e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1000e18;
        expected.jtEff = 0;
        expected.coverageUtilizationWAD = type(uint256).max;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.ilErased = 200e18;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * A flat sync (zero deltas) on a FIXED_TERM market whose IL has already cleared exits back to PERPETUAL:
     * the pure state-machine transition, with no waterfall leg running and nothing erased.
     * Checkpoint: stRaw 1000e18−1, jtRaw 100e18, stEff 1000e18, jtEff 100e18−1 (a 1-wei cross-claim), IL 0,
     * dust 0, FIXED_TERM, end T0+D. Zero deltas run no waterfall legs. IL == 0 with initial FIXED_TERM ⇒
     * PERPETUAL, end deleted, no IL erased.
     * covUtil = ⌈(1000e18−1)·0.1e18/(100e18−1)⌉ = 1000000000000000001 (remainder 9e17 forces
     * the ceil past the exact 1e18). liqUtil = 5e17.
     */
    function test_Waterfall_W14_flatSync_exitsFixedTerm() public pure {
        RoycoTestMath.WaterfallIn memory in_ =
            _cellIn(1000e18 - 1, 100e18, 1000e18, 100e18 - 1, 0, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 1000e18 - 1, 100e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 1000e18 - 1;
        expected.jtRaw = 100e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1000e18;
        expected.jtEff = 100e18 - 1;
        expected.coverageUtilizationWAD = 1_000_000_000_000_000_001;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.fixedTermEnd = 0;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * A gain carrying a +1 wei attribution floor exits FIXED_TERM with premiums and fees intact, pinning
     * that the exit commit does not zero fees the way a FIXED_TERM commit does.
     * Checkpoint: stRaw 1000e18−1, jtRaw 100e18, stEff 1000e18, jtEff 100e18−1 (1-wei cross-claim:
     * stClaimOnJT = 1), IL 0, dust 0, FIXED_TERM, end T0+D. Sync (1050e18, 80e18):
     *   dST = +(50e18+1) attributes 1:1 (stClaimOnST = stRawLast), the JT-delta attribution to ST floors to 0
     *   (⌊20e18·1/100e18⌋ = 0) ⇒ deltaSTEff = 50e18+1, deltaJTEff = −20e18 ⇒ jtEff = 80e18−1.
     *   stGain 50e18+1: jtPrem = ⌊(50e18+1)·0.1⌋ = 5e18, ltPrem = ⌊(50e18+1)·0.05⌋ = 2.5e18,
     *   jtFee = 0.5e18, ltFee = 0.25e18, residual 42.5e18+1 ⇒ stFee = ⌊(42.5e18+1)·0.1⌋ = 4.25e18,
     *   stEff = 1000e18 + (42.5e18+1) + 2.5e18 = 1045e18+1, jtEff = (80e18−1) + 5e18 = 85e18−1.
     *   Conservation 1050e18 + 80e18 = (1045e18+1) + (85e18−1). IL 0 ⇒ PERPETUAL exit (premiums imply PERPETUAL).
     *   covUtil = ⌈1050e18·0.1e18/(85e18−1)⌉ = 1235294117647058824. liqUtil = ⌈(1045e18+1)/2000⌉ = 522500000000000001.
     */
    function test_Waterfall_gainPlusOneWeiFloors_exitsFixedTerm() public pure {
        RoycoTestMath.WaterfallIn memory in_ =
            _cellIn(1000e18 - 1, 100e18, 1000e18, 100e18 - 1, 0, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 1050e18, 80e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 1050e18;
        expected.jtRaw = 80e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1045e18 + 1;
        expected.jtEff = 85e18 - 1;
        expected.jtRiskPremium = 5e18;
        expected.ltLiquidityPremium = 2.5e18;
        expected.stProtocolFee = 4.25e18;
        expected.jtProtocolFee = 0.5e18;
        expected.ltProtocolFee = 0.25e18;
        expected.coverageUtilizationWAD = 1_235_294_117_647_058_824;
        expected.liquidityUtilizationWAD = 522_500_000_000_000_001;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * A gain first recovers the dust-sized IL in full, then pays premiums whose inputs carry awkward −5 wei
     * offsets, pinning every floor in the premium chain at once.
     * Checkpoint: 1000e18/200e18/(1000e18+5)/(200e18−5), IL 5, effectiveDust 7, PERPETUAL. Sync (1050e18, 180e18):
     *   Attribution: stClaimOnJT = 5 floors out of the JT delta (⌊20e18·5/200e18⌋ = 0) ⇒ deltaSTEff = +50e18,
     *   deltaJTEff = −20e18 ⇒ jtEff = 180e18−5.
     *   IL recovery: rec = min(50e18, 5) = 5 ⇒ IL 0, jtEff 180e18, stGain = 50e18−5.
     *   Premium block: premiumsPaid (> 7). jtPrem = ⌊(50e18−5)·0.1⌋ = 5e18−1, ltPrem = ⌊(50e18−5)·0.05⌋ = 2.5e18−1,
     *   jtFee = ⌊(5e18−1)·0.1⌋ = 0.5e18−1, ltFee = 0.25e18−1, residual (50e18−5)−(5e18−1)−(2.5e18−1) = 42.5e18−3,
     *   stFee = ⌊(42.5e18−3)·0.1⌋ = 4.25e18−1, stEff = (1000e18+5) + (42.5e18−3) + (2.5e18−1) = 1045e18+1,
     *   jtEff = 180e18 + (5e18−1) = 185e18−1. Conservation 1050+180 = (1045e18+1)+(185e18−1). IL 0 ⇒ PERPETUAL.
     *   covUtil = ⌈1050e18·0.1e18/(185e18−1)⌉ = 567567567567567568. liqUtil = ⌈(1045e18+1)/2000⌉ = 522500000000000001.
     */
    function test_Waterfall_W25_dustIL_recoveryThenAwkwardPremiumFloors() public pure {
        RoycoTestMath.WaterfallIn memory in_ = _cellIn(1000e18, 200e18, 1000e18 + 5, 200e18 - 5, 5, RoycoTestMath.MarketState.PERPETUAL, 0, 7, 1050e18, 180e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 1050e18;
        expected.jtRaw = 180e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1045e18 + 1;
        expected.jtEff = 185e18 - 1;
        expected.jtRiskPremium = 5e18 - 1;
        expected.ltLiquidityPremium = 2.5e18 - 1;
        expected.stProtocolFee = 4.25e18 - 1;
        expected.jtProtocolFee = 0.5e18 - 1;
        expected.ltProtocolFee = 0.25e18 - 1;
        expected.coverageUtilizationWAD = 567_567_567_567_567_568;
        expected.liquidityUtilizationWAD = 522_500_000_000_000_001;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * Dust-IL FIXED_TERM stickiness, the pure case: with zero deltas and an IL of 5 wei inside the dust
     * tolerance of 7, an initially FIXED_TERM market stays FIXED_TERM with its ORIGINAL end — dust-sized IL
     * never silently releases a term.
     * Checkpoint: stRaw 1000e18−5, jtRaw 200e18, stEff 1000e18, jtEff 200e18−5, IL 5, dust 7, FIXED_TERM,
     * end T0+D. covUtil = ⌈(1000e18−5)·0.1e18/(200e18−5)⌉ = 500000000000000001 (the −5 offsets leave a
     * fractional part).
     */
    function test_Waterfall_W32_dustIL_fixedTermStickiness() public pure {
        RoycoTestMath.WaterfallIn memory in_ =
            _cellIn(1000e18 - 5, 200e18, 1000e18, 200e18 - 5, 5, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 7, 1000e18 - 5, 200e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 1000e18 - 5;
        expected.jtRaw = 200e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1000e18;
        expected.jtEff = 200e18 - 5;
        expected.jtCoverageIL = 5;
        expected.coverageUtilizationWAD = 500_000_000_000_000_001;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEnd = T0 + DURATION;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * The sticky FIXED_TERM branch zeroes a LIVE JT fee: a JT gain books its provisional fee, but the commit
     * lands in the dust-IL sticky state, which zeroes fees like any FIXED_TERM commit. The gain NAV itself is
     * kept, only the fee is dropped.
     * Checkpoint: stRaw 1000e18−5, jtRaw 200e18, stEff 1000e18, jtEff 200e18−5, IL 5, dust 7, FIXED_TERM,
     * end T0+D. Sync (1000e18−5, 220e18): the JT-delta attribution to ST floors to 0 (⌊20e18·5/200e18⌋ = 0)
     * so deltaJTEff = +20e18 > dust 7 ⇒ provisional jtFee 2e18, jtEff = 220e18−5. No ST move ⇒ IL stays 5 ⇒
     * sticky FIXED_TERM zeroes the fee.
     * covUtil = ⌈(1000e18−5)·0.1e18/(220e18−5)⌉ = 454545454545454546.
     */
    function test_Waterfall_W33_stickyBranch_zeroesLiveJtFee() public pure {
        RoycoTestMath.WaterfallIn memory in_ =
            _cellIn(1000e18 - 5, 200e18, 1000e18, 200e18 - 5, 5, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 7, 1000e18 - 5, 220e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 1000e18 - 5;
        expected.jtRaw = 220e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1000e18;
        expected.jtEff = 220e18 - 5;
        expected.jtCoverageIL = 5;
        expected.jtProtocolFee = 0;
        expected.coverageUtilizationWAD = 454_545_454_545_454_546;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEnd = T0 + DURATION;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * A flat sync tips PERPETUAL into FIXED_TERM purely because the persisted IL now exceeds the (shrunk)
     * dust tolerance: the state machine re-evaluates carried IL on every commit, not only on new losses.
     * Checkpoint: 1000e18/200e18/(1000e18+5)/(200e18−5), IL 5, effectiveDust 0, PERPETUAL.
     * Zero deltas, post-waterfall IL 5 > dust 0, no forced disjunct ⇒ FIXED_TERM entry from PERPETUAL with
     * end = T0 + D. covUtil = ⌈1000e18·0.1e18/(200e18−5)⌉ = 500000000000000001.
     * liqUtil = ⌈(1000e18+5)/2000⌉ = 500000000000000001.
     */
    function test_Waterfall_W41_flatSync_tipsPerpetualToFixedTerm() public pure {
        RoycoTestMath.WaterfallIn memory in_ = _cellIn(1000e18, 200e18, 1000e18 + 5, 200e18 - 5, 5, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 1000e18, 200e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 1000e18;
        expected.jtRaw = 200e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1000e18 + 5;
        expected.jtEff = 200e18 - 5;
        expected.jtCoverageIL = 5;
        expected.coverageUtilizationWAD = 500_000_000_000_000_001;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_001;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEnd = T0 + DURATION;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * Cross-claim state: after prior coverage, ST holds a claim on JT raw, so a JT-only loss bleeds into ST
     * through that claim and is immediately re-covered from the remaining JT buffer — the IL grows by exactly
     * the re-covered amount while stEff never moves.
     * Checkpoint: 900e18/300e18/1000e18/200e18, IL 100e18, dust 0, FIXED_TERM, end T0+D.
     * Sync (900e18, 280e18) with k = ⌊20e18·100e18/300e18⌋ = 6666666666666666666:
     *   deltaSTEff = −k, deltaJTEff = −20e18 + k = −13333333333333333334.
     *   JT leg: jtEff = 200e18 − 13333333333333333334 = 186666666666666666666.
     *   ST loss leg: coverage = k ⇒ jtEff = 180e18 exact, IL = 100e18 + k = 106666666666666666666, stEff unchanged.
     *   Conservation 900 + 280 = 1000 + 180. FIXED_TERM stays, end kept.
     *   covUtil = ⌈900e18·0.1e18/180e18⌉ = 5e17 exact.
     */
    function test_Waterfall_crossClaim_jtLossBleedsIntoSTAndIsRecovered() public pure {
        RoycoTestMath.WaterfallIn memory in_ =
            _cellIn(900e18, 300e18, 1000e18, 200e18, 100e18, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 900e18, 280e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 900e18;
        expected.jtRaw = 280e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1000e18;
        expected.jtEff = 180e18;
        expected.jtCoverageIL = 106_666_666_666_666_666_666;
        expected.coverageUtilizationWAD = 500_000_000_000_000_000;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEnd = T0 + DURATION;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * A gain fully consumed by partial IL recovery: every wei of senior gain repays coverage debt, so the
     * premium block never runs and the premium accumulators do not reset.
     * Checkpoint: 900e18/300e18/1000e18/200e18, IL 100e18, dust 0, FIXED_TERM, end T0+D.
     * Sync (950e18, 280e18) with k = ⌊20e18·100e18/300e18⌋ = 6666666666666666666:
     *   deltaSTEff = 50e18 − k = 43333333333333333334, deltaJTEff = 30e18 − deltaSTEff = −13333333333333333334.
     *   JT leg loss ⇒ jtEff 186666666666666666666. IL recovery: rec = min(gain, 100e18) = gain ⇒
     *   IL = 100e18 − 43333333333333333334 = 56666666666666666666, jtEff = 230e18 exact, stGain = 0 ⇒ premium
     *   block skipped, premiumsPaid false. stEff 1000e18. FIXED_TERM stays, end kept.
     *   covUtil = ⌈950e18·0.1e18/230e18⌉ = ⌈413043478260869565.2⌉ = 413043478260869566.
     */
    function test_Waterfall_gainFullyConsumedByPartialRecovery() public pure {
        RoycoTestMath.WaterfallIn memory in_ =
            _cellIn(900e18, 300e18, 1000e18, 200e18, 100e18, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 950e18, 280e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 950e18;
        expected.jtRaw = 280e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1000e18;
        expected.jtEff = 230e18;
        expected.jtCoverageIL = 56_666_666_666_666_666_666;
        expected.coverageUtilizationWAD = 413_043_478_260_869_566;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEnd = T0 + DURATION;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * A gain exactly equal to the IL sits on the recovery boundary: recovery consumes all of it, no premiums
     * pay, premiumsPaid stays false, and the now-IL-free market exits FIXED_TERM.
     * Checkpoint: 900e18/300e18/1000e18/200e18, IL 100e18, dust 0, FIXED_TERM, end T0+D.
     * Sync (1000e18, 300e18): rec = min(100e18, 100e18) = 100e18 ⇒ IL 0, jtEff 300e18, stGain 0 ⇒ premium
     * block skipped. IL 0 with initial FIXED_TERM ⇒ PERPETUAL, end 0.
     * covUtil = ⌈1000e18·0.1e18/300e18⌉ = 333333333333333334.
     */
    function test_Waterfall_gainExactlyEqualsIL_noPremiums() public pure {
        RoycoTestMath.WaterfallIn memory in_ =
            _cellIn(900e18, 300e18, 1000e18, 200e18, 100e18, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 1000e18, 300e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 1000e18;
        expected.jtRaw = 300e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1000e18;
        expected.jtEff = 300e18;
        expected.coverageUtilizationWAD = 333_333_333_333_333_334;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * A gain of IL + 1 wei: premiumsPaid fires TRUE while every premium and fee floors to 0, pinning that
     * even a 1-wei paid sync resets the premium accumulators (the premiumsPaid observable).
     * Checkpoint: 900e18/300e18/1000e18/200e18, IL 100e18, dust 0, FIXED_TERM, end T0+D.
     * Sync (1000e18+1, 300e18): rec = 100e18 ⇒ IL 0, stGain = 1 > dust 0 ⇒ premiumsPaid.
     * jtPrem = ⌊1·0.1⌋ = 0, ltPrem = 0, stFee = ⌊1·0.1⌋ = 0. stEff = 1000e18+1, jtEff = 300e18, PERPETUAL.
     * covUtil = ⌈(1000e18+1)·0.1e18/300e18⌉ = 333333333333333334. liqUtil = ⌈(1000e18+1)/2000⌉ = 500000000000000001.
     */
    function test_Waterfall_gainILPlusOneWei_premiumsPaidWithZeroPremiums() public pure {
        RoycoTestMath.WaterfallIn memory in_ =
            _cellIn(900e18, 300e18, 1000e18, 200e18, 100e18, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 1000e18 + 1, 300e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 1000e18 + 1;
        expected.jtRaw = 300e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1000e18 + 1;
        expected.jtEff = 300e18;
        expected.coverageUtilizationWAD = 333_333_333_333_333_334;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_001;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * The time-weighted premium branch produces the same premiums as an instantaneous sync at the same rates:
     * a 1-day window whose accruals encode the identical constant rates must land identical outputs, and the
     * instantaneous inputs are set hostile (uint256 max) to pin that the time-weighted path ignores them.
     * Checkpoint (stRaw/jtRaw/stEff/jtEff): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Warp 1 day: elapsed = 86400, twJT = 0.1e18·86400 = 8640e18, twLT = 0.05e18·86400 = 4320e18.
     * Sync (1050e18, 200e18): jtPrem = ⌊50e18·8640e18/(86400·1e18)⌋ = 5e18, ltPrem = 2.5e18, jtFee 0.5e18,
     * ltFee 0.25e18, residual 42.5e18 ⇒ stFee 4.25e18, stEff 1045e18, jtEff 205e18, PERPETUAL.
     * covUtil = ⌈1050e18·0.1e18/205e18⌉ = ⌈512195121951219512.19⌉ = 512195121951219513.
     */
    function test_Waterfall_W59_timeWeightedTwin_instInputsIgnored() public pure {
        RoycoTestMath.WaterfallIn memory in_ = _cellIn(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 1050e18, 200e18);
        in_.elapsedSincePremiumPayment = 86_400;
        in_.jtTwYieldShareAccrual = 8640e18;
        in_.ltTwYieldShareAccrual = 4320e18;
        in_.jtInstYieldShareWAD = type(uint256).max;
        in_.ltInstYieldShareWAD = type(uint256).max;
        in_.nowTimestamp = T0 + 86_400;
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 1050e18;
        expected.jtRaw = 200e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1045e18;
        expected.jtEff = 205e18;
        expected.jtRiskPremium = 5e18;
        expected.ltLiquidityPremium = 2.5e18;
        expected.stProtocolFee = 4.25e18;
        expected.jtProtocolFee = 0.5e18;
        expected.ltProtocolFee = 0.25e18;
        expected.coverageUtilizationWAD = 512_195_121_951_219_513;
        expected.liquidityUtilizationWAD = 522_500_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * Time-weighted averaging over a premium window whose rate changed mid-window: two half-day accrual
     * windows at different JT rates must average to the exact blended premium over the FULL window.
     * Checkpoint (stRaw/jtRaw/stEff/jtEff): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Accruals 0.1e18·43200 + 0.2e18·43200 = 12960e18 (the second window's 0.5e18 rate was capped to 0.2e18
     * at accrual, so the input already carries the cap), twLT = 0.05e18·86400 = 4320e18, elapsed = 86400.
     * Sync (1050e18, 200e18): jtPrem = ⌊50e18·12960e18/(86400·1e18)⌋ = ⌊50e18·0.15⌋ = 7.5e18, ltPrem = 2.5e18,
     * jtFee 0.75e18, ltFee 0.25e18, residual 40e18 ⇒ stFee 4e18, stEff = 1000e18 + 40e18 + 2.5e18 = 1042.5e18,
     * jtEff = 207.5e18. Conservation 1050 + 200 = 1042.5 + 207.5. PERPETUAL.
     * covUtil = ⌈1050e18·0.1e18/207.5e18⌉ = ⌈506024096385542168.67⌉ = 506024096385542169.
     * liqUtil = 1042.5e18/2000 = 521250000000000000 exact.
     */
    function test_Waterfall_W60_twoWindowTwAveraging() public pure {
        RoycoTestMath.WaterfallIn memory in_ = _cellIn(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 1050e18, 200e18);
        in_.elapsedSincePremiumPayment = 86_400;
        in_.jtTwYieldShareAccrual = 12_960e18;
        in_.ltTwYieldShareAccrual = 4320e18;
        in_.nowTimestamp = T0 + 86_400;
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 1050e18;
        expected.jtRaw = 200e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1042.5e18;
        expected.jtEff = 207.5e18;
        expected.jtRiskPremium = 7.5e18;
        expected.ltLiquidityPremium = 2.5e18;
        expected.stProtocolFee = 4e18;
        expected.jtProtocolFee = 0.75e18;
        expected.ltProtocolFee = 0.25e18;
        expected.coverageUtilizationWAD = 506_024_096_385_542_169;
        expected.liquidityUtilizationWAD = 521_250_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * The instantaneous-branch cap: a hostile preview yield share (uint256 max) is clamped to
     * maxJTYieldShareWAD before it can price a premium, so a misbehaving yield model cannot drain the gain.
     * Checkpoint (stRaw/jtRaw/stEff/jtEff): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Sync (1050e18, 200e18) with jtInst = uint256 max, maxJT = 0.2e18:
     * jtPrem = ⌊50e18·0.2e18/1e18⌋ = 10e18, ltPrem = 2.5e18 (lt preview 0.05e18 below its cap), jtFee 1e18,
     * ltFee 0.25e18, residual 37.5e18 ⇒ stFee 3.75e18, stEff = 1000e18 + 37.5e18 + 2.5e18 = 1040e18,
     * jtEff = 210e18. Conservation 1050 + 200 = 1040 + 210. covUtil = ⌈1050e18·0.1e18/210e18⌉ = 5e17 exact.
     */
    function test_Waterfall_instantaneousHostilePreview_cappedAtMaxYieldShare() public pure {
        RoycoTestMath.WaterfallIn memory in_ = _cellIn(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 1050e18, 200e18);
        in_.jtInstYieldShareWAD = type(uint256).max;
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 1050e18;
        expected.jtRaw = 200e18;
        expected.ltRaw = 100e18;
        expected.stEff = 1040e18;
        expected.jtEff = 210e18;
        expected.jtRiskPremium = 10e18;
        expected.ltLiquidityPremium = 2.5e18;
        expected.stProtocolFee = 3.75e18;
        expected.jtProtocolFee = 1e18;
        expected.ltProtocolFee = 0.25e18;
        expected.coverageUtilizationWAD = 500_000_000_000_000_000;
        expected.liquidityUtilizationWAD = 520_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * Zero-lastSTRaw attribution special case, live-ST arm: stRawLast == 0 with stEffLast > 0
     * routes the whole senior delta to ST. Checkpoint: stRaw 0, jtRaw 100e18, stEff 50e18, jtEff 50e18
     * (post-coverage cross-claim, IL 50e18), FIXED_TERM. Sync (10e18, 100e18): deltaSTEff = +10e18,
     * deltaJTEff = 0, rec = min(10e18, 50e18) = 10e18 ⇒ IL 40e18, jtEff 60e18, stGain 0 (no premium block).
     * Conservation 10 + 100 = 50 + 60. IL > 0 ⇒ FIXED_TERM stays, end kept.
     * covUtil = ⌈10e18·0.1e18/60e18⌉ = ⌈16666666666666666.67⌉ = 16666666666666667.
     * liqUtil = ⌈50e18·0.05e18/100e18⌉ = 2.5e16.
     */
    function test_Waterfall_zeroLastSTRaw_routesDeltaToSTWhenStEffPositive() public pure {
        RoycoTestMath.WaterfallIn memory in_ = _cellIn(0, 100e18, 50e18, 50e18, 50e18, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 10e18, 100e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 10e18;
        expected.jtRaw = 100e18;
        expected.ltRaw = 100e18;
        expected.stEff = 50e18;
        expected.jtEff = 60e18;
        expected.jtCoverageIL = 40e18;
        expected.coverageUtilizationWAD = 16_666_666_666_666_667;
        expected.liquidityUtilizationWAD = 25_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEnd = T0 + DURATION;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /**
     * Zero-lastSTRaw attribution special case, dead-ST arm: stRawLast == 0 with stEffLast == 0 routes the
     * senior delta to JT (the residual falls through deltaJTEff). Checkpoint: 0/100e18/0/100e18, IL 0,
     * PERPETUAL. Sync (10e18, 100e18): deltaSTEff = 0, deltaJTEff = +10e18 > dust ⇒ jtFee 1e18, jtEff 110e18.
     * Conservation 10 + 100 = 0 + 110. covUtil = ⌈10e18·0.1e18/110e18⌉ = ⌈9090909090909090.9⌉ = 9090909090909091.
     * liqUtil = 0 (the stEff zero edge propagates through the waterfall).
     */
    function test_Waterfall_zeroLastSTRaw_routesDeltaToJTWhenStEffZero() public pure {
        RoycoTestMath.WaterfallIn memory in_ = _cellIn(0, 100e18, 0, 100e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 10e18, 100e18);
        RoycoTestMath.WaterfallOut memory expected;
        expected.stRaw = 10e18;
        expected.jtRaw = 100e18;
        expected.ltRaw = 100e18;
        expected.stEff = 0;
        expected.jtEff = 110e18;
        expected.jtProtocolFee = 1e18;
        expected.coverageUtilizationWAD = 9_090_909_090_909_091;
        expected.liquidityUtilizationWAD = 0;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        _assertWaterfall(RoycoTestMath.waterfall(in_), expected);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                maxSTDeposit
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Coverage-binding: covLeg = ⌊200e18·1e18/1e17⌋ − (0 + 0 + 1000e18 + 0) = 2000e18 − 1000e18 = 1000e18.
     * liqLeg = ⌊1000e18·1e18/5e16⌋ − 1000e18 = 20000e18 − 1000e18 = 19000e18. min = 1000e18.
     */
    function test_MaxSTDeposit_coverageBinding() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 200e18, 1000e18, 200e18, 1000e18, false, 1e17, 5e16, 0, 0), 1000e18, "coverage leg binds");
    }

    /// Liquidity-binding twin: liqLeg = ⌊60e18·1e18/5e16⌋ − 1000e18 = 1200e18 − 1000e18 = 200e18 < covLeg 1000e18.
    function test_MaxSTDeposit_liquidityBinding() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 200e18, 1000e18, 200e18, 60e18, false, 1e17, 5e16, 0, 0), 200e18, "liquidity leg binds");
    }

    /// A zero requirement disables its leg: minCov 0 leaves only the liquidity leg (200e18), minLiq 0 only the
    /// coverage leg (1000e18), and both zero return uint256 max.
    function test_MaxSTDeposit_zeroRequirements_disableLegs() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 200e18, 1000e18, 200e18, 60e18, false, 0, 5e16, 0, 0), 200e18, "no coverage leg");
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 200e18, 1000e18, 200e18, 60e18, false, 1e17, 0, 0, 0), 1000e18, "no liquidity leg");
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 200e18, 1000e18, 200e18, 60e18, false, 0, 0, 0, 0), type(uint256).max, "no legs");
    }

    /**
     * Dust slack with co-investment: covLeg = ⌊200e18·1e18/1e17⌋ − (jtRaw 200e18 + jtDust 4
     * + stRaw 1000e18 + stDust 3) = 2000e18 − 1200e18 − 7 = 800e18 − 7. The jtDust term applies regardless of
     * co-investment, verified by the non-coinvested twin: 2000e18 − (0 + 4 + 1000e18 + 3) = 1000e18 − 7.
     */
    function test_MaxSTDeposit_dustSlack_bothTolerances() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 200e18, 1000e18, 200e18, 1000e18, true, 1e17, 0, 3, 4), 800e18 - 7, "coinvested slack");
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 200e18, 1000e18, 200e18, 1000e18, false, 1e17, 0, 3, 4), 1000e18 - 7, "jtDust applies anyway");
    }

    /// Saturation: covered value 500e18 below the existing exposure 1000e18 saturates the leg to 0.
    function test_MaxSTDeposit_saturatesToZero() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 200e18, 1000e18, 50e18, 1000e18, false, 1e17, 0, 0, 0), 0, "no capacity left");
    }

    /// Floor on both inversions at wei scale: covLeg = ⌊1·1e18/3e17⌋ − 1 = 3 − 1 = 2, and the liquidity twin
    /// liqLeg = ⌊1·1e18/3e17⌋ − 1 = 2.
    function test_MaxSTDeposit_floorOnInversions_weiScale() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1, 0, 0, 1, 0, false, 3e17, 0, 0, 0), 2, "floor(1e18/3e17) = 3 minus stRaw 1");
        assertEq(RoycoTestMath.maxSTDeposit(0, 0, 1, 0, 1, false, 0, 3e17, 0, 0), 2, "floor(1e18/3e17) = 3 minus stEff 1");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                maxJTWithdrawal
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Self-backed nominal with the +2 wei fudge visible in the output.
     * State 1000e18/200e18/1000e18/200e18, not coinvested, minCov 1e17, dust 0:
     *   required = ⌈1000e18·1e17/1e18⌉ = 100e18, surplus = 200e18 − (100e18 + 0 + 0 + 2) = 100e18 − 2.
     *   Claims: jtClaimOnST = 0, jtClaimOnJT = 200e18 ⇒ stFrac 0, jtFrac 1e18.
     *   retention = 1e18 − ⌊1e17·0/1e18⌋ = 1e18 ⇒ totalClaimable = 100e18 − 2 ⇒ (stW, jtW) = (0, 100e18 − 2).
     */
    function test_MaxJTWithdrawal_selfBacked_plusTwoWeiFudge() public pure {
        (uint256 stW, uint256 jtW) = RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 1000e18, 200e18, false, 1e17, 0, 0);
        assertEq(stW, 0, "no cross claim");
        assertEq(jtW, 100e18 - 2, "surplus minus the 2 wei fudge");
    }

    /**
     * Fudge boundary: with jtEff exactly required + 2 the surplus saturates to 0 and the closed
     * form returns (0, 0), while one more wei of buffer yields exactly 1 wei withdrawable.
     *   required = ⌈1000e18·1e17/1e18⌉ = 100e18, jtEff = 100e18 + 2 ⇒ surplus 0, jtEff = 100e18 + 3 ⇒ surplus 1,
     *   retention 1e18 ⇒ totalClaimable = 1 ⇒ jtW = ⌊1·1e18/1e18⌋ = 1.
     */
    function test_MaxJTWithdrawal_fudgeBoundary() public pure {
        (uint256 stW0, uint256 jtW0) = RoycoTestMath.maxJTWithdrawal(1000e18, 100e18 + 2, 1000e18, 100e18 + 2, false, 1e17, 0, 0);
        assertEq(stW0, 0, "fudge consumes the surplus, stW");
        assertEq(jtW0, 0, "fudge consumes the surplus, jtW");
        (uint256 stW1, uint256 jtW1) = RoycoTestMath.maxJTWithdrawal(1000e18, 100e18 + 3, 1000e18, 100e18 + 3, false, 1e17, 0, 0);
        assertEq(stW1, 0, "still no cross claim");
        assertEq(jtW1, 1, "one wei past the fudge is withdrawable");
    }

    /**
     * Co-invested retention: exposure = 1200e18 ⇒ required 120e18, surplus = 200e18 − 120e18 − 2 = 80e18 − 2.
     * jtFrac = 1e18 counts toward retention when co-invested: retention = 1e18 − ⌊1e17·1e18/1e18⌋ = 9e17.
     * totalClaimable = ⌊(80e18 − 2)·1e18/9e17⌋ = ⌊799999999999999999980/9⌋ = 88888888888888888886 = jtW.
     */
    function test_MaxJTWithdrawal_coinvested_retentionDenominator() public pure {
        (uint256 stW, uint256 jtW) = RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 1000e18, 200e18, true, 1e17, 0, 0);
        assertEq(stW, 0, "no cross claim");
        assertEq(jtW, 88_888_888_888_888_888_886, "surplus grossed up by 10/9 retention");
    }

    /**
     * Cross-claim split: state 1000e18/200e18/950e18/250e18 (JT holds a 50e18 premium claim on ST).
     *   jtClaimOnST = 50e18, jtClaimOnJT = 200e18, total 250e18 ⇒ stFrac 2e17, jtFrac 8e17 (both exact).
     *   required = 100e18, surplus = 250e18 − 100e18 − 2 = 150e18 − 2.
     *   retention = 1e18 − ⌊1e17·2e17/1e18⌋ = 98e16 (not coinvested, only stFrac counts).
     *   totalClaimable = ⌊(150e18 − 2)·1e18/98e16⌋ = ⌊14999999999999999999800/98⌋ = 153061224489795918365.
     *   stW = ⌊·2e17/1e18⌋ = 30612244897959183673, jtW = ⌊·8e17/1e18⌋ = 122448979591836734692.
     */
    function test_MaxJTWithdrawal_crossClaimSplit() public pure {
        (uint256 stW, uint256 jtW) = RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 950e18, 250e18, false, 1e17, 0, 0);
        assertEq(stW, 30_612_244_897_959_183_673, "ST-sourced slice, floored");
        assertEq(jtW, 122_448_979_591_836_734_692, "JT-sourced slice, floored");
    }

    /**
     * Zero-total-claims early-out: jtEff 5 fully inside jtRaw 10 while ST claims the whole jtRaw
     * (stClaimOnJT = sat(stEff − stRaw) = 10 = jtRaw) leaves both JT claims at 0, so even a positive surplus
     * (minCov 0 ⇒ required 0, surplus = sat(5 − 2) = 3) returns (0, 0). Non-conserving guard probe by design.
     */
    function test_MaxJTWithdrawal_zeroTotalClaims_returnsZero() public pure {
        (uint256 stW, uint256 jtW) = RoycoTestMath.maxJTWithdrawal(100e18, 10, 100e18 + 10, 5, false, 0, 0, 0);
        assertEq(stW, 0, "guard stW");
        assertEq(jtW, 0, "guard jtW");
    }

    /// Zero-surplus early-out: required = ⌈1000e18·3e17/1e18⌉ = 300e18 exceeds jtEff 200e18 entirely.
    function test_MaxJTWithdrawal_requiredExceedsBuffer_returnsZero() public pure {
        (uint256 stW, uint256 jtW) = RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 1000e18, 200e18, false, 3e17, 0, 0);
        assertEq(stW, 0, "no surplus stW");
        assertEq(jtW, 0, "no surplus jtW");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                maxLTWithdrawal
    //////////////////////////////////////////////////////////////////////////*/

    /// Nominal: required = ⌈1000e18·5e16/1e18⌉ = 50e18 exact, withdrawable = 100e18 − 50e18 = 50e18.
    function test_MaxLTWithdrawal_nominal() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 5e16, 0, 5e17, 1.1e18), 50e18, "half the pool is surplus");
    }

    /// Ceil on the required depth: stEff 1000e18+1 ⇒ required = ⌈50e18 + 0.05⌉ = 50e18 + 1 ⇒ 50e18 − 1.
    function test_MaxLTWithdrawal_ceilInnerRounding() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18 + 1, 5e16, 0, 5e17, 1.1e18), 50e18 - 1, "ceil bites one wei");
    }

    /// The stDust slack subtracts on top of the required depth: 100e18 − (50e18 + 3) = 50e18 − 3.
    function test_MaxLTWithdrawal_stDustSlack() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 5e16, 3, 5e17, 1.1e18), 50e18 - 3, "dust slack");
    }

    /// minLiq == 0 bypasses the gate entirely: the whole ltRaw is withdrawable.
    function test_MaxLTWithdrawal_zeroMinLiquidity_fullLtRaw() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 0, 0, 5e17, 1.1e18), 100e18, "no liquidity requirement");
    }

    /// Liquidation breach at the EXACT threshold bypasses (the comparison is >=): full ltRaw.
    function test_MaxLTWithdrawal_liquidationBreachExactThreshold_fullLtRaw() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 5e16, 0, 1.1e18, 1.1e18), 100e18, "exact threshold bypasses");
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 5e16, 0, 1.1e18 - 1, 1.1e18), 50e18, "one wei below gates");
    }

    /// Saturation: required 50e18 above the pool depth 40e18 saturates to 0.
    function test_MaxLTWithdrawal_saturatesToZero() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(40e18, 1000e18, 5e16, 0, 5e17, 1.1e18), 0, "under-provisioned pool");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                selfLiqBonus
    //////////////////////////////////////////////////////////////////////////*/

    /// Builds a SelfLiqBonusIn with the shared reference state: stRaw 1000e18, jtRaw 100e18, jtEff 140e18
    /// (jtClaimOnST = 40e18), covUtil at the 1.1e18 liquidation threshold, bonus rate 5e17.
    function _bonusIn(uint256 userNav, uint256 weighted, bool coinvested) private pure returns (RoycoTestMath.SelfLiqBonusIn memory in_) {
        in_.stRaw = 1000e18;
        in_.jtRaw = 100e18;
        in_.jtEff = 140e18;
        in_.jtCoinvested = coinvested;
        in_.coverageUtilizationWAD = 1.1e18;
        in_.coverageLiquidationUtilizationWAD = 1.1e18;
        in_.bonusWAD = 5e17;
        in_.userClaimNAV = userNav;
        in_.stUserWeightedClaimNAV = weighted;
    }

    /// Below the liquidation threshold (strict <) there is no bonus whatever the claim sizes.
    function test_SelfLiqBonus_belowThreshold_returnsZero() public pure {
        RoycoTestMath.SelfLiqBonusIn memory in_ = _bonusIn(200e18, 200e18, false);
        in_.coverageUtilizationWAD = 1.1e18 - 1;
        assertEq(RoycoTestMath.selfLiqBonus(in_), 0, "inactive below the threshold");
    }

    /**
     * Active at the EXACT threshold (the gate is covUtil >= liqThreshold), U-neutral max binding in
     * case 1: desired = ⌊200e18·5e17/1e18⌋ = 100e18, jtEff = 140e18,
     * case1 = ⌊200e18·140e18/(1000e18 − 140e18)⌋ = ⌊28000e36/860e18⌋ = 32558139534883720930 <= jtClaimOnST
     * 40e18 ⇒ maxNeutral = case1 ⇒ bonus = min(100e18, 140e18, 32558139534883720930).
     */
    function test_SelfLiqBonus_atThresholdExactly_case1STSourced() public pure {
        assertEq(RoycoTestMath.selfLiqBonus(_bonusIn(200e18, 200e18, false)), 32_558_139_534_883_720_930, "case 1 floors 28000/860");
    }

    /**
     * Case 2, not co-invested: weighted 300e18 pushes case1 = ⌊42000e36/860e18⌋ = 48837209302325581395
     * past jtClaimOnST 40e18 ⇒ case2 = ⌊(300e18 + 40e18)·140e18/1000e18⌋ = 47.6e18.
     * desired 150e18 and jtEff 140e18 do not bind ⇒ bonus = 47.6e18.
     */
    function test_SelfLiqBonus_case2_crossesIntoSelfClaim_notCoinvested() public pure {
        assertEq(RoycoTestMath.selfLiqBonus(_bonusIn(300e18, 300e18, false)), 47.6e18, "case 2 with the ST-source adjustment");
    }

    /**
     * Case 2, co-invested (the twin of the vector above): exposure = 1100e18 ⇒ case1 = ⌊300e18·140e18/960e18⌋ = 43.75e18 exact,
     * above jtClaimOnST 40e18 ⇒ case2 = ⌊300e18·140e18/(1100e18 − 140e18)⌋ = 43.75e18 (no ST-source adjustment
     * and the jtEff-reduced denominator when co-invested) ⇒ bonus = 43.75e18.
     */
    function test_SelfLiqBonus_case2_coinvested() public pure {
        assertEq(RoycoTestMath.selfLiqBonus(_bonusIn(300e18, 300e18, true)), 43.75e18, "coinvested case 2");
    }

    /// The desired term binds when the rate is small: ⌊200e18·1e15/1e18⌋ = 0.2e18 below both other terms.
    function test_SelfLiqBonus_desiredBinds() public pure {
        RoycoTestMath.SelfLiqBonusIn memory in_ = _bonusIn(200e18, 200e18, false);
        in_.bonusWAD = 1e15;
        assertEq(RoycoTestMath.selfLiqBonus(in_), 0.2e18, "floor(200e18*1e15/1e18)");
    }

    /**
     * The jtEff term binds: stRaw 100e18, jtRaw 20e18, jtEff 60e18 (jtClaimOnST 40e18), weighted 70e18:
     * case1 = ⌊70e18·60e18/(100e18 − 60e18)⌋ = 105e18 > jtClaimOnST 40e18 ⇒
     * case2 = ⌊(70e18 + 40e18)·60e18/100e18⌋ = 66e18, desired = ⌊130e18·5e17/1e18⌋ = 65e18 ⇒
     * bonus = min(65e18, 60e18, 66e18) = 60e18, capped by the remaining JT buffer.
     */
    function test_SelfLiqBonus_jtEffBinds() public pure {
        RoycoTestMath.SelfLiqBonusIn memory in_ = _bonusIn(130e18, 70e18, false);
        in_.stRaw = 100e18;
        in_.jtRaw = 20e18;
        in_.jtEff = 60e18;
        assertEq(RoycoTestMath.selfLiqBonus(in_), 60e18, "capped by the remaining JT buffer");
    }

    /// Early-outs: jtEff == 0 and a zero weighted claim both zero the U-neutral max and hence the bonus.
    function test_SelfLiqBonus_zeroJtEff_andZeroWeightedClaim_returnZero() public pure {
        RoycoTestMath.SelfLiqBonusIn memory zeroJt = _bonusIn(200e18, 200e18, false);
        zeroJt.jtEff = 0;
        assertEq(RoycoTestMath.selfLiqBonus(zeroJt), 0, "no JT capital to source");
        assertEq(RoycoTestMath.selfLiqBonus(_bonusIn(200e18, 0, false)), 0, "no weighted exposure claim");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                adaptiveYdm
    //////////////////////////////////////////////////////////////////////////*/

    /// Builds an AdaptiveYdmIn with the shared reference curve: target 8e17, start 1e17, FD_T 5e16, FP_T 1e17,
    /// clamps [1e14, 1e18] (the production 1bp floor and WAD ceiling), maxSpeed 1e12, PERPETUAL.
    function _ydmIn(uint256 u, uint256 elapsed) private pure returns (RoycoTestMath.AdaptiveYdmIn memory in_) {
        in_.utilizationWAD = u;
        in_.targetUtilizationWAD = 8e17;
        in_.startYieldShareAtTargetWAD = 1e17;
        in_.elapsedSeconds = elapsed;
        in_.discountToTargetAtZeroUtilWAD = 5e16;
        in_.premiumToTargetAtFullUtilWAD = 1e17;
        in_.maxAdaptationSpeedWAD = 1e12;
        in_.minYieldShareAtTargetWAD = 1e14;
        in_.maxYieldShareAtTargetWAD = 1e18;
        in_.perpetual = true;
    }

    /// At u == targetU the normalized delta is 0: no adaptation (speed 0), no spread, output == start on both legs.
    function test_AdaptiveYdm_atTarget_returnsStartOnBothLegs() public pure {
        RoycoTestMath.AdaptiveYdmOut memory out = RoycoTestMath.adaptiveYdm(_ydmIn(8e17, 1000));
        assertEq(out.yieldShareWAD, 1e17, "y(target) = start");
        assertEq(out.endYieldShareAtTargetWAD, 1e17, "curve unmoved at target");
    }

    /// elapsed == 0 gives linear adaptation 0 (expWad(0) = 1e18 exactly): the curve holds and only the fixed
    /// spread applies. At u = WAD: normDelta = 1e18 ⇒ y = start + FP_T = 1e17 + 1e17 = 2e17, end = start.
    function test_AdaptiveYdm_zeroElapsed_spreadOnly_fullUtil() public pure {
        RoycoTestMath.AdaptiveYdmOut memory out = RoycoTestMath.adaptiveYdm(_ydmIn(1e18, 0));
        assertEq(out.yieldShareWAD, 2e17, "start + FP_T");
        assertEq(out.endYieldShareAtTargetWAD, 1e17, "no adaptation at zero elapsed");
    }

    /// At u = 0 with elapsed 0 the discount side applies: normDelta = −1e18 ⇒ y = start − FD_T = 5e16.
    function test_AdaptiveYdm_zeroElapsed_spreadOnly_zeroUtil() public pure {
        RoycoTestMath.AdaptiveYdmOut memory out = RoycoTestMath.adaptiveYdm(_ydmIn(0, 0));
        assertEq(out.yieldShareWAD, 5e16, "start - FD_T");
        assertEq(out.endYieldShareAtTargetWAD, 1e17, "no adaptation at zero elapsed");
    }

    /// Outside PERPETUAL the curve never adapts regardless of elapsed: same outputs as the zero-elapsed vector.
    function test_AdaptiveYdm_notPerpetual_curveFrozen() public pure {
        RoycoTestMath.AdaptiveYdmIn memory in_ = _ydmIn(1e18, 1e9);
        in_.perpetual = false;
        RoycoTestMath.AdaptiveYdmOut memory out = RoycoTestMath.adaptiveYdm(in_);
        assertEq(out.yieldShareWAD, 2e17, "spread only while frozen");
        assertEq(out.endYieldShareAtTargetWAD, 1e17, "no adaptation outside PERPETUAL");
    }

    /**
     * Positive adaptation clamps: u = WAD, speed 1e12, elapsed 1e9 ⇒ linear = 1e21, clamped to
     * MAX_LINEAR_ADAPTATION_WAD before expWad, so both the end and the midpoint (5e20, also above the clamp)
     * saturate at maxYieldShareAtTarget = 1e18. Start 5e17 ⇒ trapezoid avg = (5e17 + 1e18 + 2·1e18)/4 =
     * 875000000000000000, y = avg + FP_T 1e17 = 975000000000000000.
     */
    function test_AdaptiveYdm_positiveClamp_trapezoidAveragesMax() public pure {
        RoycoTestMath.AdaptiveYdmIn memory in_ = _ydmIn(1e18, 1e9);
        in_.startYieldShareAtTargetWAD = 5e17;
        RoycoTestMath.AdaptiveYdmOut memory out = RoycoTestMath.adaptiveYdm(in_);
        assertEq(out.endYieldShareAtTargetWAD, 1e18, "end clamped to max");
        assertEq(out.yieldShareWAD, 975_000_000_000_000_000, "(5e17 + 3e18)/4 + 1e17");
    }

    /**
     * Negative adaptation decays to the floor: u = 0, speed 1e12, elapsed 1e9 ⇒ linear = −1e21, deep below
     * expWad's zero threshold, so end and midpoint both clamp to minYieldShareAtTarget = 1e14. Start 1e18 ⇒
     * avg = (1e18 + 1e14 + 2·1e14)/4 = 250075000000000000, y = avg − FD_T 5e16 = 200075000000000000.
     */
    function test_AdaptiveYdm_negativeClamp_decaysToMinFloor() public pure {
        RoycoTestMath.AdaptiveYdmIn memory in_ = _ydmIn(0, 1e9);
        in_.startYieldShareAtTargetWAD = 1e18;
        RoycoTestMath.AdaptiveYdmOut memory out = RoycoTestMath.adaptiveYdm(in_);
        assertEq(out.endYieldShareAtTargetWAD, 1e14, "end clamped to the 1bp floor");
        assertEq(out.yieldShareWAD, 200_075_000_000_000_000, "(1e18 + 3e14)/4 - 5e16");
    }

    /// Utilization above WAD is capped before evaluation: u = 2e18 behaves exactly like u = 1e18.
    function test_AdaptiveYdm_utilizationAboveWad_capped() public pure {
        RoycoTestMath.AdaptiveYdmOut memory out = RoycoTestMath.adaptiveYdm(_ydmIn(2e18, 0));
        assertEq(out.yieldShareWAD, 2e17, "capped u = WAD");
        assertEq(out.endYieldShareAtTargetWAD, 1e17, "no adaptation at zero elapsed");
    }

    /**
     * Signed divisions truncate toward zero (not floor): u = 1e17, target 3e17 ⇒
     * normDelta = (−2e17·1e18)/3e17 = −666666666666666666 (truncated from −...666.67), and the adjustment
     * (−666666666666666666·3e16)/1e18 = −19999999999999999 (truncated from −...999.98), so
     * y = 1e17 − 19999999999999999 = 80000000000000001 (a floor division would give 8e16 exactly).
     */
    function test_AdaptiveYdm_signedDivisions_truncateTowardZero() public pure {
        RoycoTestMath.AdaptiveYdmIn memory in_ = _ydmIn(1e17, 0);
        in_.targetUtilizationWAD = 3e17;
        in_.discountToTargetAtZeroUtilWAD = 3e16;
        RoycoTestMath.AdaptiveYdmOut memory out = RoycoTestMath.adaptiveYdm(in_);
        assertEq(out.yieldShareWAD, 80_000_000_000_000_001, "double truncation keeps 1 wei");
        assertEq(out.endYieldShareAtTargetWAD, 1e17, "no adaptation at zero elapsed");
    }

    /// The curve output clamps to [0, WAD]: a discount below zero returns 0 and a premium above WAD returns WAD.
    function test_AdaptiveYdm_outputClampedToZeroAndWad() public pure {
        RoycoTestMath.AdaptiveYdmIn memory low = _ydmIn(0, 0);
        low.startYieldShareAtTargetWAD = 1e14;
        assertEq(RoycoTestMath.adaptiveYdm(low).yieldShareWAD, 0, "1e14 - 5e16 clamps to 0");
        RoycoTestMath.AdaptiveYdmIn memory high = _ydmIn(1e18, 0);
        high.startYieldShareAtTargetWAD = 1e18;
        high.premiumToTargetAtFullUtilWAD = 5e17;
        assertEq(RoycoTestMath.adaptiveYdm(high).yieldShareWAD, 1e18, "1e18 + 5e17 clamps to WAD");
    }
}
