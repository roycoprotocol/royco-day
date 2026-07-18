// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title Test_RoycoTestMath
 * @notice Self-validation of the independent expected-value library. Every expected value is a hand-derived
 *         literal with the arithmetic shown in a comment, so a regression in the mirror is caught here before
 *         it can silently agree with a production bug. Test names mirror the RoycoTestMath function they check.
 * @dev Boundary set per formula: 0, 1 wei, max realistic (1e30), exact thresholds, zero-supply and zero-NAV
 *      edges. No sign-only asserts, no early returns.
 */
contract Test_RoycoTestMath is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_NAV = 1e30;

    // Shared sync-scenario conventions: T0 base timestamp and the 7-day fixed-term duration.
    uint256 private constant T0 = 1_700_000_000;
    uint256 private constant DURATION = 604_800;

    /*//////////////////////////////////////////////////////////////////////////
                            attributeDeltaToClaimOnRawNAV
    //////////////////////////////////////////////////////////////////////////*/

    /// Zero delta attributes nothing regardless of claim shape.
    function test_AttributeDeltaToClaimOnRawNAV_ZeroDelta_ReturnsZero() public pure {
        assertEq(RoycoTestMath.attributeDeltaToClaimOnRawNAV(0, 5e18, 10e18), 0, "zero delta");
        assertEq(RoycoTestMath.attributeDeltaToClaimOnRawNAV(0, 0, 0), 0, "zero delta with empty market");
    }

    /// Zero claim attributes nothing in either direction.
    function test_AttributeDeltaToClaimOnRawNAV_ZeroClaim_ReturnsZero() public pure {
        assertEq(RoycoTestMath.attributeDeltaToClaimOnRawNAV(1e18, 0, 10e18), 0, "gain, zero claim");
        assertEq(RoycoTestMath.attributeDeltaToClaimOnRawNAV(-1e18, 0, 10e18), 0, "loss, zero claim");
    }

    /// Positive delta floors: attribute(+7, claim 1, lastRaw 3) = ⌊7·1/3⌋ = ⌊2.333…⌋ = 2.
    function test_AttributeDeltaToClaimOnRawNAV_PositiveDelta_FloorsMagnitude() public pure {
        assertEq(RoycoTestMath.attributeDeltaToClaimOnRawNAV(7, 1, 3), 2, "floor(7*1/3) = 2");
    }

    /// Negative delta floors the MAGNITUDE then re-applies the sign (toward zero, never away):
    /// attribute(-7, claim 2, lastRaw 3) = -⌊7·2/3⌋ = -⌊4.666…⌋ = -4 (not -5).
    function test_AttributeDeltaToClaimOnRawNAV_NegativeDelta_FloorsMagnitudeThenReappliesSign() public pure {
        assertEq(RoycoTestMath.attributeDeltaToClaimOnRawNAV(-7, 2, 3), -4, "-floor(7*2/3) = -4");
    }

    /// A full claim (claim == lastRaw) attributes the whole delta exactly, both signs.
    function test_AttributeDeltaToClaimOnRawNAV_FullClaim_Exact() public pure {
        assertEq(RoycoTestMath.attributeDeltaToClaimOnRawNAV(-123_456_789, 1e18, 1e18), -123_456_789, "full claim on loss");
        assertEq(RoycoTestMath.attributeDeltaToClaimOnRawNAV(987_654_321, 55e18, 55e18), 987_654_321, "full claim on gain");
    }

    /// 1-wei boundary: ⌊1·1/1e30⌋ = 0 and -⌊(1e30-1)·1/1e30⌋ = 0 (dust vanishes to the complement).
    function test_AttributeDeltaToClaimOnRawNAV_OneWeiDelta_FloorsToZero() public pure {
        assertEq(RoycoTestMath.attributeDeltaToClaimOnRawNAV(1, 1, 1e30), 0, "floor(1*1/1e30) = 0");
        assertEq(RoycoTestMath.attributeDeltaToClaimOnRawNAV(-1, 1e30 - 1, 1e30), 0, "-floor(1*(1e30-1)/1e30) = 0");
    }

    /// Max realistic NAV boundary (1e30): ⌊1e30·7e29/1e30⌋ = 7e29 exact, and the full-claim loss at scale.
    function test_AttributeDeltaToClaimOnRawNAV_MaxRealistic() public pure {
        assertEq(RoycoTestMath.attributeDeltaToClaimOnRawNAV(int256(MAX_NAV), 7e29, MAX_NAV), 7e29, "floor(1e30*7e29/1e30) = 7e29");
        assertEq(RoycoTestMath.attributeDeltaToClaimOnRawNAV(-int256(MAX_NAV), MAX_NAV, MAX_NAV), -int256(MAX_NAV), "full-claim loss at scale");
    }

    /// The two-way split floors each part so the rounding residual favors the complementary tranche:
    /// delta 7 over lastRaw 3 split as claims {1, 2}: ⌊7/3⌋ = 2 and ⌊14/3⌋ = 4, sum 6 = delta − 1.
    function test_AttributeDeltaToClaimOnRawNAV_ComplementarySplit_ResidualDustDropped() public pure {
        int256 stPart = RoycoTestMath.attributeDeltaToClaimOnRawNAV(7, 1, 3);
        int256 jtPart = RoycoTestMath.attributeDeltaToClaimOnRawNAV(7, 2, 3);
        assertEq(stPart, 2, "floor(7*1/3) = 2");
        assertEq(jtPart, 4, "floor(7*2/3) = 4");
        assertEq(stPart + jtPart, 6, "split sums to delta - 1 (1 wei of floor residual)");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            computeCoverageUtilization
    //////////////////////////////////////////////////////////////////////////*/

    /// minCov == 0 means no requirement: utilization is 0 whatever the NAVs.
    function test_ComputeCoverageUtilization_ZeroMinCoverage_ReturnsZero() public pure {
        assertEq(RoycoTestMath.computeCoverageUtilization(1e18, 1e18, 0, 5e17), 0, "no coverage requirement");
    }

    /// Zero exposure (both raw NAVs zero) returns 0 whatever the requirement.
    function test_ComputeCoverageUtilization_ZeroExposure_ReturnsZero() public pure {
        assertEq(RoycoTestMath.computeCoverageUtilization(0, 0, 1e17, 1e18), 0, "empty market");
    }

    /// Zero edges take precedence over the infinite edge (both minCov == 0 and exposure == 0 vs jtEffectiveNAV == 0).
    function test_ComputeCoverageUtilization_ZeroEdgePrecedence_OverInfiniteEdge() public pure {
        assertEq(RoycoTestMath.computeCoverageUtilization(0, 0, 1e17, 0), 0, "zero exposure wins over zero jtEffectiveNAV");
        assertEq(RoycoTestMath.computeCoverageUtilization(1e18, 0, 0, 0), 0, "zero minCov wins over zero jtEffectiveNAV");
    }

    /// Positive requirement against zero JT effective NAV is infinite utilization.
    function test_ComputeCoverageUtilization_ZeroJtEff_ReturnsMax() public pure {
        assertEq(RoycoTestMath.computeCoverageUtilization(1e18, 0, 1e17, 0), type(uint256).max, "uncovered exposure");
    }

    /// Exact WAD threshold, clean division: ⌈(100e18 + 50e18)·1e17 / 15e18⌉ = ⌈1.5e37/1.5e19⌉ = 1e18 exactly.
    function test_ComputeCoverageUtilization_ExactWadBoundary_CleanDivision() public pure {
        assertEq(RoycoTestMath.computeCoverageUtilization(100e18, 50e18, 1e17, 15e18), 1e18, "coverage utilization == WAD exactly");
    }

    /// Ceil engaged: ⌈10·1e17 / 3⌉ = ⌈1e18/3⌉ = ⌈333333333333333333.33…⌉ = 333333333333333334.
    function test_ComputeCoverageUtilization_CeilRounding_FavorsSenior() public pure {
        assertEq(RoycoTestMath.computeCoverageUtilization(10, 0, 1e17, 3), 333_333_333_333_333_334, "ceil(1e18/3)");
    }

    /// Max realistic: ⌈(1e30 + 1e30)·1e18 / 1⌉ = 2e48 exact (no overflow through mulDiv).
    function test_ComputeCoverageUtilization_MaxRealistic() public pure {
        assertEq(RoycoTestMath.computeCoverageUtilization(MAX_NAV, MAX_NAV, WAD, 1), 2e48, "2e30 * 1e18 / 1");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            computeLiquidityUtilization
    //////////////////////////////////////////////////////////////////////////*/

    /// No senior value means nothing to provide liquidity for.
    function test_ComputeLiquidityUtilization_ZeroStEff_ReturnsZero() public pure {
        assertEq(RoycoTestMath.computeLiquidityUtilization(0, 1e17, 1e18), 0, "no senior value");
    }

    /// No liquidity requirement means zero utilization whatever the depth.
    function test_ComputeLiquidityUtilization_ZeroMinLiquidity_ReturnsZero() public pure {
        assertEq(RoycoTestMath.computeLiquidityUtilization(1e18, 0, 5), 0, "no requirement");
    }

    /// Positive requirement against zero pool depth is infinite utilization.
    function test_ComputeLiquidityUtilization_ZeroLtRaw_ReturnsMax() public pure {
        assertEq(RoycoTestMath.computeLiquidityUtilization(1e18, 1e17, 0), type(uint256).max, "zero depth");
    }

    /// Zero edges take precedence over the infinite edge.
    function test_ComputeLiquidityUtilization_ZeroEdgePrecedence_OverInfiniteEdge() public pure {
        assertEq(RoycoTestMath.computeLiquidityUtilization(0, 1e17, 0), 0, "zero stEffectiveNAV wins over zero ltRawNAV");
        assertEq(RoycoTestMath.computeLiquidityUtilization(5, 0, 0), 0, "zero minLiq wins over zero ltRawNAV");
    }

    /// Exact WAD threshold, clean division: ⌈1000e18·5e16 / 50e18⌉ = ⌈5e37/5e19⌉ = 1e18 exactly.
    function test_ComputeLiquidityUtilization_ExactWadBoundary_CleanDivision() public pure {
        assertEq(RoycoTestMath.computeLiquidityUtilization(1000e18, 5e16, 50e18), 1e18, "liquidity utilization == WAD exactly");
    }

    /// Ceil engaged: ⌈10·1e17 / 3⌉ = ⌈1e18/3⌉ = 333333333333333334.
    function test_ComputeLiquidityUtilization_CeilRounding_FavorsSenior() public pure {
        assertEq(RoycoTestMath.computeLiquidityUtilization(10, 1e17, 3), 333_333_333_333_333_334, "ceil(1e18/3)");
    }

    /// 1-wei boundary: ⌈1·1 / 1e30⌉ = ⌈1e-30⌉ = 1, the ceil bias never reads a positive requirement as zero.
    function test_ComputeLiquidityUtilization_OneWei_CeilsToOne() public pure {
        assertEq(RoycoTestMath.computeLiquidityUtilization(1, 1, 1e30), 1, "ceil of any positive quotient is >= 1");
    }

    /// Max realistic, exact division: ⌈1e30·(1e18−1) / 1e30⌉ = 1e18 − 1 = 999999999999999999.
    function test_ComputeLiquidityUtilization_MaxRealistic() public pure {
        assertEq(RoycoTestMath.computeLiquidityUtilization(MAX_NAV, WAD - 1, MAX_NAV), 999_999_999_999_999_999, "(1e30*(1e18-1))/1e30 exact");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            convertToShares
    //////////////////////////////////////////////////////////////////////////*/

    /// First mint (supply == 0) is 1:1 with the contributed value, totalValue ignored. Historical pins run at
    /// residual 0 (the clamp-disabled reduction: identical literals to the pre-clamp behavior).
    function test_ConvertToShares_ZeroSupply_MintsOneToOne() public pure {
        assertEq(RoycoTestMath.convertToShares(123e18, 0, 0), 123e18, "first depositor 1:1");
        assertEq(RoycoTestMath.convertToShares(5, 999, 0), 5, "totalValue ignored at zero supply");
    }

    /// Live supply over zero NAV pins the denominator to 1 wei: ⌊7·3/1⌋ = 21.
    function test_ConvertToShares_ZeroTotalValue_UsesOneWeiDenominator() public pure {
        assertEq(RoycoTestMath.convertToShares(3, 0, 7), 21, "floor(7*3/1) = 21");
    }

    /// Floor engaged: ⌊5·3/7⌋ = ⌊15/7⌋ = ⌊2.142…⌋ = 2 (dust stays with existing holders).
    function test_ConvertToShares_FloorRounding_FavorsExistingHolders() public pure {
        assertEq(RoycoTestMath.convertToShares(3, 7, 5), 2, "floor(15/7) = 2");
    }

    /// Clean division: ⌊200e18·10e18 / 100e18⌋ = 20e18.
    function test_ConvertToShares_CleanDivision() public pure {
        assertEq(RoycoTestMath.convertToShares(10e18, 100e18, 200e18), 20e18, "floor(200e18*10e18/100e18)");
    }

    /// Zero value mints zero shares against a live market.
    function test_ConvertToShares_ZeroValue_ReturnsZero() public pure {
        assertEq(RoycoTestMath.convertToShares(0, 100, 50), 0, "nothing in, nothing out");
    }

    /// 1-wei boundaries: ⌊1e30·1/1e30⌋ = 1 at par, ⌊1·1/1e30⌋ = 0 when the pot dwarfs the supply.
    function test_ConvertToShares_OneWeiBoundaries() public pure {
        assertEq(RoycoTestMath.convertToShares(1, 1e30, 1e30), 1, "floor(1e30*1/1e30) = 1");
        assertEq(RoycoTestMath.convertToShares(1, 1e30, 1), 0, "floor(1*1/1e30) = 0");
    }

    /// Max realistic at par: ⌊1e30·1e30/1e30⌋ = 1e30.
    function test_ConvertToShares_MaxRealistic() public pure {
        assertEq(RoycoTestMath.convertToShares(MAX_NAV, MAX_NAV, MAX_NAV), MAX_NAV, "par at scale");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            the mint-dilution clamp
    //////////////////////////////////////////////////////////////////////////*/

    /// Bind boundary, exact (continuity): at d = 1e18, S = 1e18, ε = 1e6 the bind threshold is
    ///   threshold = ⌊d·(WAD−ε)/ε⌋ = 1e18 · 999_999_999_999 = 1e30 − 1e18   ((WAD−ε)/ε is the exact integer 1e12−1)
    /// At v = threshold the bind test is exactly at equality (⌈v·ε/(WAD−ε)⌉ = 1e18 = d, not >), so the mint is
    /// fair-priced: ⌊1e18·(1e30−1e18)/1e18⌋ = 1e30 − 1e18 — which EQUALS the cap ⌊1e18·(WAD−ε)/ε⌋, so the clamp
    /// is continuous at the boundary.
    function test_ConvertToShares_ClampBindBoundary_FairEqualsCapExactly() public pure {
        uint256 threshold = 1e30 - 1e18;
        assertEq(RoycoTestMath.convertToShares(threshold, 1e18, 1e18), threshold, "at the boundary the fair mint equals the cap");
    }

    /// Bind boundary + 1 wei: v = threshold + 1 trips the bind (⌈v·ε/(WAD−ε)⌉ = 1e18 + 1 > d) and returns the
    /// cap = 1e30 − 1e18 — the same output as the boundary itself (the clamp plateaus, it does not jump).
    function test_ConvertToShares_ClampBindBoundaryPlusOne_ReturnsSameCap() public pure {
        assertEq(RoycoTestMath.convertToShares(1e30 - 1e18 + 1, 1e18, 1e18), 1e30 - 1e18, "one wei past the boundary mints the identical cap");
    }

    /// Zero-NAV composition min(S·v, cap): the 1-wei branch stays unclamped for small values
    /// (bind iff ⌈3·1e6/(1e18−1e6)⌉ = 1 > 1 is false ⇒ ⌊7·3/1⌋ = 21 unchanged), and clamps for large ones
    /// (v = 1e12: ⌈1e12·1e6/(1e18−1e6)⌉ = 2 > 1 ⇒ cap = ⌊7·(1e18−1e6)/1e6⌋ = 7·(1e12−1) = 6_999_999_999_993).
    function test_ConvertToShares_ClampOverZeroNAV_ComposesWithOneWeiDenominator() public pure {
        assertEq(RoycoTestMath.convertToShares(3, 0, 7), 21, "small dilution mint stays fair-priced");
        assertEq(RoycoTestMath.convertToShares(1e12, 0, 7), 6_999_999_999_993, "large dilution mint clamps to 7*(1e12-1)");
    }

    /// Bootstrap exemption: supply == 0 mints 1:1 no matter how large the value — a first mint dilutes
    /// nobody, so the clamp has nothing to protect (1e40 over a live supply would bind hard).
    function test_ConvertToShares_ClampBootstrapExemption() public pure {
        assertEq(RoycoTestMath.convertToShares(1e40, 0, 0), 1e40, "bootstrap mints 1:1, exempt from the clamp");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            convertToValue
    //////////////////////////////////////////////////////////////////////////*/

    /// Zero supply values everything at 0 (no holders to owe).
    function test_ConvertToValue_ZeroSupply_ReturnsZero() public pure {
        assertEq(RoycoTestMath.convertToValue(5, 100, 0), 0, "zero supply");
    }

    /// Floor engaged: ⌊7·2/3⌋ = ⌊4.666…⌋ = 4 (dust stays with remaining holders).
    function test_ConvertToValue_FloorRounding_FavorsRemainingHolders() public pure {
        assertEq(RoycoTestMath.convertToValue(2, 7, 3), 4, "floor(14/3) = 4");
    }

    /// Full supply redeems the whole pot exactly: ⌊7·3/3⌋ = 7.
    function test_ConvertToValue_FullSupply_Exact() public pure {
        assertEq(RoycoTestMath.convertToValue(3, 7, 3), 7, "full exit takes everything");
    }

    /// Zero shares are worth zero, and a live supply over zero NAV is worth zero.
    function test_ConvertToValue_ZeroShares_AndZeroNav_ReturnZero() public pure {
        assertEq(RoycoTestMath.convertToValue(0, 1e30, 5), 0, "zero shares");
        assertEq(RoycoTestMath.convertToValue(3, 0, 7), 0, "supply > 0 with NAV == 0");
    }

    /// 1-wei and max-realistic boundaries at par: ⌊1e30·1/1e30⌋ = 1 and ⌊1e30·1e30/1e30⌋ = 1e30.
    function test_ConvertToValue_Boundaries() public pure {
        assertEq(RoycoTestMath.convertToValue(1, 1e30, 1e30), 1, "1 wei share at par");
        assertEq(RoycoTestMath.convertToValue(MAX_NAV, MAX_NAV, MAX_NAV), MAX_NAV, "par at scale");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    computeSTFeeAndLiquidityPremiumSharesToMint
    //////////////////////////////////////////////////////////////////////////*/

    /// Clean division:
    ///   retained      = 1050e18 − 30e18 − 20e18 = 1000e18
    ///   premiumShares = ⌊1000e18·30e18/1000e18⌋ = 30e18
    ///   feeShares     = ⌊1000e18·20e18/1000e18⌋ = 20e18
    ///   supplyAfter   = 1000e18 + 30e18 + 20e18 = 1050e18
    function test_ComputeSTFeeAndLiquidityPremiumSharesToMint_CleanDivision() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) =
            RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(1050e18, 30e18, 20e18, 1000e18);
        assertEq(premiumShares, 30e18, "premium shares exact");
        assertEq(feeShares, 20e18, "fee shares exact");
        assertEq(supplyAfter, 1050e18, "supply after both mints");
    }

    /// Floor engaged (wei scale):
    ///   retained      = 10 − 3 − 2 = 5
    ///   premiumShares = ⌊3·3/5⌋ = ⌊9/5⌋ = ⌊1.8⌋ = 1
    ///   feeShares     = ⌊3·2/5⌋ = ⌊6/5⌋ = ⌊1.2⌋ = 1
    ///   supplyAfter   = 3 + 1 + 1 = 5
    function test_ComputeSTFeeAndLiquidityPremiumSharesToMint_FloorRounding_FavorsPreExistingST() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(10, 3, 2, 3);
        assertEq(premiumShares, 1, "floor(9/5) = 1");
        assertEq(feeShares, 1, "floor(6/5) = 1");
        assertEq(supplyAfter, 5, "3 + 1 + 1");
    }

    /// A degenerate mint consuming all of stEffectiveNAV routes through convertToShares's 1-wei denominator:
    ///   retained = 10 − 7 − 3 = 0 ⇒ denom 1: premiumShares = ⌊100·7/1⌋ = 700, feeShares = ⌊100·3/1⌋ = 300.
    function test_ComputeSTFeeAndLiquidityPremiumSharesToMint_RetainedZero_OneWeiDenominator() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(10, 7, 3, 100);
        assertEq(premiumShares, 700, "floor(100*7/1) = 700");
        assertEq(feeShares, 300, "floor(100*3/1) = 300");
        assertEq(supplyAfter, 1100, "100 + 700 + 300");
    }

    /// Pre-sync supply 0 routes through convertToShares' first-mint branch: both legs mint 1:1 with their value,
    /// exempt from the dilution clamp (a bootstrap mint dilutes nobody).
    ///   retained = 100 − 30 − 20 = 50 is ignored at zero supply: premiumShares = 30, feeShares = 20.
    function test_ComputeSTFeeAndLiquidityPremiumSharesToMint_ZeroPreSupply_MintsOneToOne() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(100, 30, 20, 0);
        assertEq(premiumShares, 30, "first-mint 1:1 premium leg");
        assertEq(feeShares, 20, "first-mint 1:1 fee leg");
        assertEq(supplyAfter, 50, "0 + 30 + 20");
    }

    /// Zero premium and fee mint nothing and leave the supply untouched.
    function test_ComputeSTFeeAndLiquidityPremiumSharesToMint_ZeroPremiumAndFee_NoMint() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(100, 0, 0, 77);
        assertEq(premiumShares, 0, "no premium");
        assertEq(feeShares, 0, "no fee");
        assertEq(supplyAfter, 77, "supply unchanged");
    }

    /// Max realistic, clean (clamp inert: 5e29·1e6 ≤ 5e29·(1e18−1e6) at the protocol residual):
    /// retained = 1e30 − 5e29 = 5e29, premiumShares = ⌊1e30·5e29/5e29⌋ = 1e30,
    /// supplyAfter = 1e30 + 1e30 = 2e30 (a 100%-of-retained premium doubles the supply).
    function test_ComputeSTFeeAndLiquidityPremiumSharesToMint_MaxRealistic() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(1e30, 5e29, 0, 1e30);
        assertEq(premiumShares, 1e30, "floor(1e30*5e29/5e29) = 1e30");
        assertEq(feeShares, 0, "no fee");
        assertEq(supplyAfter, 2e30, "1e30 + 1e30");
    }

    /// Degenerate mint under the clamp: retained = 0 pins the 1-wei
    /// denominator, both legs bind (⌈4e18·1e6/(1e18−1e6)⌉ > 1 at the protocol residual), and each clamps to
    /// cap = ⌊1e18·(1e18−1e6)/1e6⌋ = 999_999_999_999e18 — the per-mint residual guarantee.
    function test_ComputeSTFeeAndLiquidityPremiumSharesToMint_RetainedZero_ClampsBothLegsToCap() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(10e18, 4e18, 6e18, 1e18);
        assertEq(premiumShares, 999_999_999_999e18, "premium leg clamps to the cap");
        assertEq(feeShares, 999_999_999_999e18, "fee leg clamps to the same cap");
        assertEq(supplyAfter, 1e18 + 2 * 999_999_999_999e18, "supply identity across two capped mints");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                scaleClaims
    //////////////////////////////////////////////////////////////////////////*/

    /// All five fields floor independently at shares 2 of 3:
    ///   ⌊10·2/3⌋ = ⌊6.67⌋ = 6, ⌊7·2/3⌋ = ⌊4.67⌋ = 4, ⌊5·2/3⌋ = ⌊3.33⌋ = 3, ⌊3·2/3⌋ = 2, ⌊11·2/3⌋ = ⌊7.33⌋ = 7.
    function test_ScaleClaims_AllFiveFieldsFloored() public pure {
        RoycoTestMath.Claims memory total = RoycoTestMath.Claims({ stAssets: 10, jtAssets: 7, ltAssets: 5, stShares: 3, nav: 11 });
        RoycoTestMath.Claims memory scaled = RoycoTestMath.scaleClaims(total, 2, 3);
        assertEq(scaled.stAssets, 6, "floor(20/3) = 6");
        assertEq(scaled.jtAssets, 4, "floor(14/3) = 4");
        assertEq(scaled.ltAssets, 3, "floor(10/3) = 3");
        assertEq(scaled.stShares, 2, "floor(6/3) = 2");
        assertEq(scaled.nav, 7, "floor(22/3) = 7");
    }

    /// Full shares (shares == totalShares) is the identity on every field.
    function test_ScaleClaims_FullShares_Identity() public pure {
        RoycoTestMath.Claims memory total = RoycoTestMath.Claims({ stAssets: 1e18, jtAssets: 2e18, ltAssets: 3e18, stShares: 4e18, nav: 5e18 });
        RoycoTestMath.Claims memory scaled = RoycoTestMath.scaleClaims(total, 5, 5);
        assertEq(scaled.stAssets, 1e18, "identity stAssets");
        assertEq(scaled.jtAssets, 2e18, "identity jtAssets");
        assertEq(scaled.ltAssets, 3e18, "identity ltAssets");
        assertEq(scaled.stShares, 4e18, "identity stShares");
        assertEq(scaled.nav, 5e18, "identity nav");
    }

    /// Zero shares scale every field to zero.
    function test_ScaleClaims_ZeroShares_AllZero() public pure {
        RoycoTestMath.Claims memory total = RoycoTestMath.Claims({ stAssets: 1e30, jtAssets: 1e30, ltAssets: 1e30, stShares: 1e30, nav: 1e30 });
        RoycoTestMath.Claims memory scaled = RoycoTestMath.scaleClaims(total, 0, 1e30);
        assertEq(scaled.stAssets, 0, "zero slice stAssets");
        assertEq(scaled.jtAssets, 0, "zero slice jtAssets");
        assertEq(scaled.ltAssets, 0, "zero slice ltAssets");
        assertEq(scaled.stShares, 0, "zero slice stShares");
        assertEq(scaled.nav, 0, "zero slice nav");
    }

    /// Max realistic with a 1-wei slice: each field ⌊1e30·1/1e30⌋ = 1.
    function test_ScaleClaims_MaxRealistic_OneWeiSlice() public pure {
        RoycoTestMath.Claims memory total = RoycoTestMath.Claims({ stAssets: 1e30, jtAssets: 1e30, ltAssets: 1e30, stShares: 1e30, nav: 1e30 });
        RoycoTestMath.Claims memory scaled = RoycoTestMath.scaleClaims(total, 1, 1e30);
        assertEq(scaled.stAssets, 1, "floor(1e30/1e30) = 1");
        assertEq(scaled.jtAssets, 1, "floor(1e30/1e30) = 1");
        assertEq(scaled.ltAssets, 1, "floor(1e30/1e30) = 1");
        assertEq(scaled.stShares, 1, "floor(1e30/1e30) = 1");
        assertEq(scaled.nav, 1, "floor(1e30/1e30) = 1");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        getLiquidityTrancheEffectiveNAV
    //////////////////////////////////////////////////////////////////////////*/

    /// No idle shares: effective NAV is the pool leg alone.
    function test_GetLiquidityTrancheEffectiveNAV_NoIdleShares_EqualsLtRaw() public pure {
        assertEq(RoycoTestMath.getLiquidityTrancheEffectiveNAV(100e18, 0, 500e18, 1000e18), 100e18, "pure BPT state");
    }

    /// Clean idle valuation: 100e18 + ⌊10e18·2000e18/1000e18⌋ = 100e18 + 20e18 = 120e18.
    function test_GetLiquidityTrancheEffectiveNAV_CleanIdleValuation() public pure {
        assertEq(RoycoTestMath.getLiquidityTrancheEffectiveNAV(100e18, 10e18, 2000e18, 1000e18), 120e18, "ltRawNAV + idle leg");
    }

    /// Floor on the idle leg: 5 + ⌊3·7/2⌋ = 5 + ⌊10.5⌋ = 5 + 10 = 15.
    function test_GetLiquidityTrancheEffectiveNAV_FloorRounding_FavorsPoolLeg() public pure {
        assertEq(RoycoTestMath.getLiquidityTrancheEffectiveNAV(5, 3, 7, 2), 15, "5 + floor(21/2) = 15");
    }

    /// Zero ST supply values the idle leg at 0 (the convertToValue edge): effective NAV falls back to ltRawNAV.
    function test_GetLiquidityTrancheEffectiveNAV_ZeroStSupply_IdleLegIsZero() public pure {
        assertEq(RoycoTestMath.getLiquidityTrancheEffectiveNAV(42, 999, 1e18, 0), 42, "idle leg zero at zero supply");
    }

    /// Zero pool leg with staged premium only: 0 + ⌊3·7/2⌋ = 10.
    function test_GetLiquidityTrancheEffectiveNAV_ZeroLtRaw_IdleLegOnly() public pure {
        assertEq(RoycoTestMath.getLiquidityTrancheEffectiveNAV(0, 3, 7, 2), 10, "floor(21/2) = 10");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            staticCurveYieldShare
    //////////////////////////////////////////////////////////////////////////*/

    // Reference curve for the vectors below: y0 = 1e16 (1%), yTarget = 1e17 (10%), yFull = 1e18 (100%),
    // targetU = 8e17 (80%).
    //   Lower slope = ⌊(1e17 − 1e16)·1e18 / 8e17⌋ = ⌊9e34 / 8e17⌋ = 112500000000000000 (exact division).
    //   Upper slope = ⌊(1e18 − 1e17)·1e18 / (1e18 − 8e17)⌋ = ⌊9e35 / 2e17⌋ = 4500000000000000000 (exact).

    /// At u = 0 the curve returns its intercept: 1e16 + ⌊112500000000000000·0/1e18⌋ = 1e16.
    function test_StaticCurveYieldShare_ZeroUtilization_ReturnsY0() public pure {
        assertEq(RoycoTestMath.staticCurveYieldShare(0, 1e16, 1e17, 1e18, 8e17), 1e16, "y(0) = y0");
    }

    /// At u == targetU the exact point value yTarget is returned with no interpolation.
    function test_StaticCurveYieldShare_AtTarget_ReturnsYTargetExactly() public pure {
        assertEq(RoycoTestMath.staticCurveYieldShare(8e17, 1e16, 1e17, 1e18, 8e17), 1e17, "y(target) = yTarget");
    }

    /// Below target: 1e16 + ⌊112500000000000000·4e17/1e18⌋ = 1e16 + 45000000000000000 = 55000000000000000.
    function test_StaticCurveYieldShare_BelowTarget_LowerSegment() public pure {
        assertEq(RoycoTestMath.staticCurveYieldShare(4e17, 1e16, 1e17, 1e18, 8e17), 55_000_000_000_000_000, "y(0.4) = 5.5%");
    }

    /// Above target: 1e17 + ⌊4500000000000000000·(9e17−8e17)/1e18⌋ = 1e17 + 45e16 = 550000000000000000.
    function test_StaticCurveYieldShare_AboveTarget_UpperSegment() public pure {
        assertEq(RoycoTestMath.staticCurveYieldShare(9e17, 1e16, 1e17, 1e18, 8e17), 550_000_000_000_000_000, "y(0.9) = 55%");
    }

    /// At full utilization: 1e17 + ⌊4500000000000000000·2e17/1e18⌋ = 1e17 + 9e17 = 1e18 = yFull.
    function test_StaticCurveYieldShare_FullUtilization_ReturnsYFull() public pure {
        assertEq(RoycoTestMath.staticCurveYieldShare(1e18, 1e16, 1e17, 1e18, 8e17), 1e18, "y(WAD) = yFull");
    }

    /// Utilization above WAD is capped to WAD before evaluation: y(2.5e18) == y(1e18) = 1e18.
    function test_StaticCurveYieldShare_UtilizationAboveWad_Capped() public pure {
        assertEq(RoycoTestMath.staticCurveYieldShare(25e17, 1e16, 1e17, 1e18, 8e17), 1e18, "u capped at WAD");
    }

    /// Result capped at WAD: curve (0, 5e17, 2e18) with target 5e17 at u = 1e18 interpolates to
    /// 5e17 + ⌊⌊1.5e18·1e18/5e17⌋·5e17/1e18⌋ = 5e17 + ⌊3e18·5e17/1e18⌋ = 5e17 + 1.5e18 = 2e18, capped to 1e18.
    function test_StaticCurveYieldShare_ResultCappedAtWad() public pure {
        assertEq(RoycoTestMath.staticCurveYieldShare(1e18, 0, 5e17, 2e18, 5e17), 1e18, "result capped at WAD");
    }

    /// The exact-point return is also capped: yTarget = 2e18 at u == targetU returns min(2e18, WAD) = 1e18.
    function test_StaticCurveYieldShare_ExactPointCappedAtWad() public pure {
        assertEq(RoycoTestMath.staticCurveYieldShare(5e17, 0, 2e18, 3e18, 5e17), 1e18, "point value capped at WAD");
    }

    /// Double-floor artifact pinned (stored-slope shape): curve (0, 1, 9) with target 3 at u = 2.
    /// slope = ⌊1·1e18/3⌋ = 333333333333333333, y = 0 + ⌊333333333333333333·2/1e18⌋ = ⌊0.666…⌋ = 0.
    function test_StaticCurveYieldShare_DoubleFloorArtifact_Pinned() public pure {
        assertEq(RoycoTestMath.staticCurveYieldShare(2, 0, 1, 9, 3), 0, "double floor loses the wei by design");
    }

    /// targetU == 0 degenerates the lower segment: u = 0 hits the exact point (yTarget = 7), and u = WAD
    /// evaluates the upper segment 7 + ⌊⌊2·1e18/1e18⌋·1e18/1e18⌋ = 7 + 2 = 9.
    function test_StaticCurveYieldShare_ZeroTarget_UsesUpperSegment() public pure {
        assertEq(RoycoTestMath.staticCurveYieldShare(0, 5, 7, 9, 0), 7, "u == target == 0 returns yTarget");
        assertEq(RoycoTestMath.staticCurveYieldShare(1e18, 5, 7, 9, 0), 9, "upper segment spans the whole domain");
    }

    /// targetU == WAD degenerates the upper segment: capped u == targetU returns yTarget, yFull unreachable.
    function test_StaticCurveYieldShare_TargetAtWad_LowerSegmentCoversDomain() public pure {
        assertEq(RoycoTestMath.staticCurveYieldShare(1e18, 1e16, 1e17, 999e18, 1e18), 1e17, "u capped to WAD == target");
        // Below the target the lower segment interpolates: slope = ⌊9e16·1e18/1e18⌋ = 9e16,
        // y(5e17) = 1e16 + ⌊9e16·5e17/1e18⌋ = 1e16 + 4.5e16 = 5.5e16.
        assertEq(RoycoTestMath.staticCurveYieldShare(5e17, 1e16, 1e17, 999e18, 1e18), 55_000_000_000_000_000, "lower segment midpoint");
    }

    /// A flat curve returns the constant everywhere (both slopes are 0).
    function test_StaticCurveYieldShare_FlatCurve_Constant() public pure {
        assertEq(RoycoTestMath.staticCurveYieldShare(3e17, 3e16, 3e16, 3e16, 8e17), 3e16, "flat below target");
        assertEq(RoycoTestMath.staticCurveYieldShare(9e17, 3e16, 3e16, 3e16, 8e17), 3e16, "flat above target");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        syncTrancheAccounting — helpers
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Builds a SyncInputs under the shared scenario conventions: minCoverage 0.1e18, liquidation
     * threshold 1.1e18, minLiquidity 0.05e18, all four fee rates 0.1e18, fixed-term duration 7 days,
     * ltRawNAVNew 100e18, sync at T0 on the instantaneous branch (elapsed 0) with pinned preview
     * rates jt 0.1e18 / lt 0.05e18 and caps jt 0.2e18 / lt 0.1e18.
     */
    function _syncInputs(
        uint256 stRawNAVLast,
        uint256 jtRawNAVLast,
        uint256 stEffectiveNAVLast,
        uint256 jtEffectiveNAVLast,
        uint256 il,
        RoycoTestMath.MarketState stateLast,
        uint256 endLast,
        uint256 dust,
        uint256 stRawNew,
        uint256 jtRawNew
    )
        private
        pure
        returns (RoycoTestMath.SyncInputs memory in_)
    {
        in_.stRawNAVLast = stRawNAVLast;
        in_.jtRawNAVLast = jtRawNAVLast;
        in_.stEffectiveNAVLast = stEffectiveNAVLast;
        in_.jtEffectiveNAVLast = jtEffectiveNAVLast;
        in_.jtCoverageImpermanentLossLast = il;
        in_.marketStateLast = stateLast;
        in_.fixedTermEndTimestampLast = endLast;
        in_.stRawNAVDelta = int256(stRawNew) - int256(stRawNAVLast);
        in_.jtRawNAVDelta = int256(jtRawNew) - int256(jtRawNAVLast);
        in_.ltRawNAVNew = 100e18;
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
        in_.coverageLiquidationUtilizationWAD = 1.1e18;
        in_.effectiveDust = dust;
        in_.minLiquidityWAD = 0.05e18;
    }

    /// Field-exact comparison of a computed SyncOutputs against a hand-built expected literal.
    function _assertSyncOutputs(RoycoTestMath.SyncOutputs memory actual, RoycoTestMath.SyncOutputs memory expected) private pure {
        assertEq(actual.stRawNAV, expected.stRawNAV, "stRawNAV");
        assertEq(actual.jtRawNAV, expected.jtRawNAV, "jtRawNAV");
        assertEq(actual.ltRawNAV, expected.ltRawNAV, "ltRawNAV");
        assertEq(actual.stEffectiveNAV, expected.stEffectiveNAV, "stEffectiveNAV");
        assertEq(actual.jtEffectiveNAV, expected.jtEffectiveNAV, "jtEffectiveNAV");
        assertEq(actual.jtCoverageImpermanentLoss, expected.jtCoverageImpermanentLoss, "jtCoverageImpermanentLoss");
        assertEq(actual.jtRiskPremium, expected.jtRiskPremium, "jtRiskPremium");
        assertEq(actual.ltLiquidityPremium, expected.ltLiquidityPremium, "ltLiquidityPremium");
        assertEq(actual.stProtocolFee, expected.stProtocolFee, "stProtocolFee");
        assertEq(actual.jtProtocolFee, expected.jtProtocolFee, "jtProtocolFee");
        assertEq(actual.ltProtocolFee, expected.ltProtocolFee, "ltProtocolFee");
        assertEq(actual.coverageUtilizationWAD, expected.coverageUtilizationWAD, "coverageUtilizationWAD");
        assertEq(actual.liquidityUtilizationWAD, expected.liquidityUtilizationWAD, "liquidityUtilizationWAD");
        assertEq(uint256(actual.marketState), uint256(expected.marketState), "marketState");
        assertEq(actual.fixedTermEndTimestamp, expected.fixedTermEndTimestamp, "fixedTermEndTimestamp");
        assertEq(actual.premiumsPaid, expected.premiumsPaid, "premiumsPaid");
        assertEq(actual.ilErased, expected.ilErased, "ilErased");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    syncTrancheAccounting — named sync scenarios
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Both tranches gain in the same sync, so the JT fee takes both parts (own gain plus risk premium) and
     * the premiums resolve through the instantaneous branch. Pins the full up-path fee and premium plumbing.
     * Checkpoint (stRawNAV/jtRawNAV/stEffectiveNAV/jtEffectiveNAV): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Sync (1050e18, 220e18).
     *   JT leg: jtNetGain 20e18 > dust 0 ⇒ provisional jtFee = ⌊20e18·0.1⌋ = 2e18, jtEffectiveNAV = 220e18.
     *   ST gain leg: stGain 50e18, no IL. premiumsPaid (50e18 > 0). Instantaneous (elapsed forced 1):
     *     jtPrem = ⌊50e18·0.1e18/(1·1e18)⌋ = 5e18, ltPrem = ⌊50e18·0.05e18/1e18⌋ = 2.5e18 (7.5e18 <= 50e18 ok).
     *     jtFee += ⌊5e18·0.1⌋ = 0.5e18 ⇒ 2.5e18 total, jtEffectiveNAV = 225e18, ltFee = ⌊2.5e18·0.1⌋ = 0.25e18.
     *     Residual 50e18 − 5e18 − 2.5e18 = 42.5e18 ⇒ stFee = 4.25e18, stEffectiveNAV = 1000e18 + 42.5e18 + 2.5e18 = 1045e18.
     *   Conservation 1050 + 220 = 1045 + 225 (e18). IL 0 ⇒ PERPETUAL.
     *   coverageUtilizationWAD = ⌈(1050e18 + 220e18)·0.1e18/225e18⌉ = ⌈0.56444…e18⌉ = 564444444444444445.
     *   liquidityUtilizationWAD = ⌈1045e18·0.05e18/100e18⌉ = 5.225e17 exact.
     */
    function test_SyncTrancheAccounting_GainGain_BothJtFeeParts_InstantaneousPremium() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 1050e18, 220e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 1050e18;
        expected.jtRawNAV = 220e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1045e18;
        expected.jtEffectiveNAV = 225e18;
        expected.jtCoverageImpermanentLoss = 0;
        expected.jtRiskPremium = 5e18;
        expected.ltLiquidityPremium = 2.5e18;
        expected.stProtocolFee = 4.25e18;
        expected.jtProtocolFee = 2.5e18;
        expected.ltProtocolFee = 0.25e18;
        expected.coverageUtilizationWAD = 564_444_444_444_444_445;
        expected.liquidityUtilizationWAD = 522_500_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.fixedTermEndTimestamp = 0;
        expected.premiumsPaid = true;
        expected.ilErased = 0;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * ST loses while JT gains: coverage draws from the post-gain JT buffer and the JT fee is recomputed on the
     * net, so a fee never books on gain that coverage immediately consumed.
     * Checkpoint (stRawNAV/jtRawNAV/stEffectiveNAV/jtEffectiveNAV): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Sync (950e18, 220e18).
     *   JT leg: gain 20e18 ⇒ provisional fee 2e18, jtEffectiveNAV 220e18.
     *   ST loss leg: stLoss 50e18, coverage = min(50e18, 220e18) = 50e18. Recompute: jtNetGain = sat(20e18 − 50e18) = 0
     *   <= dust ⇒ jtFee = 0. jtEffectiveNAV = 170e18, IL = 50e18, stEffectiveNAV unchanged 1000e18.
     *   IL 50e18 > dust 0 ⇒ FIXED_TERM entry from PERPETUAL: end = T0 + D, fees zeroed (only jtFee was live).
     *   coverageUtilizationWAD = ⌈(950e18 + 220e18)·0.1e18/170e18⌉ = ⌈688235294117647058.82⌉ = 688235294117647059.
     *   liquidityUtilizationWAD = ⌈1000e18·0.05e18/100e18⌉ = 5e17.
     */
    function test_SyncTrancheAccounting_StLossJtGain_CoverageAndFeeRecompute_FixedTermEntry() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 950e18, 220e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 950e18;
        expected.jtRawNAV = 220e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18;
        expected.jtEffectiveNAV = 170e18;
        expected.jtCoverageImpermanentLoss = 50e18;
        expected.coverageUtilizationWAD = 688_235_294_117_647_059;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEndTimestamp = T0 + DURATION;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A JT-only gain in a PERPETUAL commit keeps its fee: fee zeroing belongs to FIXED_TERM commits only,
     * so this pins that a healthy market never drops an earned fee.
     * Checkpoint (stRawNAV/jtRawNAV/stEffectiveNAV/jtEffectiveNAV): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Sync (1000e18, 220e18): jtNetGain 20e18 ⇒ jtFee 2e18, jtEffectiveNAV 220e18, no ST leg.
     * IL 0 ⇒ PERPETUAL. coverageUtilizationWAD = ⌈(1000e18 + 220e18)·0.1e18/220e18⌉ = ⌈554545454545454545.45⌉ = 554545454545454546.
     */
    function test_SyncTrancheAccounting_JtOnlyGain_FeeSurvivesPerpetual() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 1000e18, 220e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 1000e18;
        expected.jtRawNAV = 220e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18;
        expected.jtEffectiveNAV = 220e18;
        expected.jtProtocolFee = 2e18;
        expected.coverageUtilizationWAD = 554_545_454_545_454_546;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A loss past JT exhaustion wipes the junior buffer out, which forces PERPETUAL and erases the IL: an
     * uncovered loss can never land the market in FIXED_TERM, because the wipeout disjunct always fires first.
     * Checkpoint (stRawNAV/jtRawNAV/stEffectiveNAV/jtEffectiveNAV): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Sync (700e18, 200e18): stLoss 300e18, coverage = min(300e18, 200e18) = 200e18 ⇒ jtEffectiveNAV 0,
     * IL 200e18, residual 100e18 ⇒ stEffectiveNAV 900e18. coverageUtilizationWAD = uint256 max (jtEffectiveNAV 0 against exposure 900e18),
     * which also satisfies the liquidation disjunct. Forced PERPETUAL: ilErased = 200e18, IL = 0, end 0.
     * Conservation 700 + 200 = 900 + 0. liquidityUtilizationWAD = ⌈900e18·0.05e18/100e18⌉ = 4.5e17.
     */
    function test_SyncTrancheAccounting_LossPastJtExhaustion_WipeoutErasesIL() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 700e18, 200e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 700e18;
        expected.jtRawNAV = 200e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 900e18;
        expected.jtEffectiveNAV = 0;
        expected.jtCoverageImpermanentLoss = 0;
        expected.coverageUtilizationWAD = type(uint256).max;
        expected.liquidityUtilizationWAD = 450_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.ilErased = 200e18;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * Exhaustion exactly at the boundary: the loss is fully covered but the junior buffer empties to zero,
     * so senior keeps its full effective NAV while the wipeout disjunct still fires. Distinguishes the
     * covered-boundary case from the residual-loss wipeout above.
     * Checkpoint (stRawNAV/jtRawNAV/stEffectiveNAV/jtEffectiveNAV): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Sync (800e18, 200e18): stLoss 200e18 == jtEffectiveNAV ⇒ coverage 200e18, jtEffectiveNAV 0, residual 0,
     * stEffectiveNAV intact at 1000e18, IL 200e18 ⇒ wipeout disjunct ⇒ PERPETUAL, IL erased.
     */
    function test_SyncTrancheAccounting_ExhaustionAtBoundary_StEffectiveNAVIntact() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 800e18, 200e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 800e18;
        expected.jtRawNAV = 200e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18;
        expected.jtEffectiveNAV = 0;
        expected.coverageUtilizationWAD = type(uint256).max;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.ilErased = 200e18;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A flat sync (zero deltas) on a FIXED_TERM market whose IL has already cleared exits back to PERPETUAL:
     * the pure state-machine transition, with no sync leg running and nothing erased.
     * Checkpoint: stRawNAV 1000e18−1, jtRawNAV 200e18, stEffectiveNAV 1000e18, jtEffectiveNAV 200e18−1 (a 1-wei cross-claim), IL 0,
     * dust 0, FIXED_TERM, end T0+D. Zero deltas run no sync legs. IL == 0 with initial FIXED_TERM ⇒
     * PERPETUAL, end deleted, no IL erased.
     * coverageUtilizationWAD = ⌈(1200e18−1)·0.1e18/(200e18−1)⌉ = 600000000000000001 (remainder 5e17 forces
     * the ceil past the exact 6e17). liquidityUtilizationWAD = 5e17.
     */
    function test_SyncTrancheAccounting_FlatSync_ExitsFixedTerm() public pure {
        RoycoTestMath.SyncInputs memory in_ =
            _syncInputs(1000e18 - 1, 200e18, 1000e18, 200e18 - 1, 0, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 1000e18 - 1, 200e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 1000e18 - 1;
        expected.jtRawNAV = 200e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18;
        expected.jtEffectiveNAV = 200e18 - 1;
        expected.coverageUtilizationWAD = 600_000_000_000_000_001;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.fixedTermEndTimestamp = 0;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A gain carrying a +1 wei attribution floor exits FIXED_TERM with premiums and fees intact, pinning
     * that the exit commit does not zero fees the way a FIXED_TERM commit does.
     * Checkpoint: stRawNAV 1000e18−1, jtRawNAV 100e18, stEffectiveNAV 1000e18, jtEffectiveNAV 100e18−1 (1-wei cross-claim:
     * stClaimOnJT = 1), IL 0, dust 0, FIXED_TERM, end T0+D. Sync (1050e18, 80e18):
     *   dST = +(50e18+1) attributes 1:1 (stClaimOnST = stRawNAVLast), the JT-delta attribution to ST floors to 0
     *   (⌊20e18·1/100e18⌋ = 0) ⇒ deltaSTEff = 50e18+1, deltaJTEff = −20e18 ⇒ jtEffectiveNAV = 80e18−1.
     *   stGain 50e18+1: jtPrem = ⌊(50e18+1)·0.1⌋ = 5e18, ltPrem = ⌊(50e18+1)·0.05⌋ = 2.5e18,
     *   jtFee = 0.5e18, ltFee = 0.25e18, residual 42.5e18+1 ⇒ stFee = ⌊(42.5e18+1)·0.1⌋ = 4.25e18,
     *   stEffectiveNAV = 1000e18 + (42.5e18+1) + 2.5e18 = 1045e18+1, jtEffectiveNAV = (80e18−1) + 5e18 = 85e18−1.
     *   Conservation 1050e18 + 80e18 = (1045e18+1) + (85e18−1). IL 0 ⇒ PERPETUAL exit (premiums imply PERPETUAL).
     *   coverageUtilizationWAD = ⌈(1050e18 + 80e18)·0.1e18/(85e18−1)⌉ = 1329411764705882353. liquidityUtilizationWAD = ⌈(1045e18+1)/2000⌉ = 522500000000000001.
     */
    function test_SyncTrancheAccounting_GainPlusOneWeiFloors_ExitsFixedTerm() public pure {
        RoycoTestMath.SyncInputs memory in_ =
            _syncInputs(1000e18 - 1, 100e18, 1000e18, 100e18 - 1, 0, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 1050e18, 80e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 1050e18;
        expected.jtRawNAV = 80e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1045e18 + 1;
        expected.jtEffectiveNAV = 85e18 - 1;
        expected.jtRiskPremium = 5e18;
        expected.ltLiquidityPremium = 2.5e18;
        expected.stProtocolFee = 4.25e18;
        expected.jtProtocolFee = 0.5e18;
        expected.ltProtocolFee = 0.25e18;
        expected.coverageUtilizationWAD = 1_329_411_764_705_882_353;
        expected.liquidityUtilizationWAD = 522_500_000_000_000_001;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A gain first recovers the dust-sized IL in full, then pays premiums whose inputs carry awkward −5 wei
     * offsets, pinning every floor in the premium chain at once.
     * Checkpoint: 1000e18/200e18/(1000e18+5)/(200e18−5), IL 5, effectiveDust 7, PERPETUAL. Sync (1050e18, 180e18):
     *   Attribution: stClaimOnJT = 5 floors out of the JT delta (⌊20e18·5/200e18⌋ = 0) ⇒ deltaSTEff = +50e18,
     *   deltaJTEff = −20e18 ⇒ jtEffectiveNAV = 180e18−5.
     *   IL recovery: rec = min(50e18, 5) = 5 ⇒ IL 0, jtEffectiveNAV 180e18, stGain = 50e18−5.
     *   Premium block: premiumsPaid (> 7). jtPrem = ⌊(50e18−5)·0.1⌋ = 5e18−1, ltPrem = ⌊(50e18−5)·0.05⌋ = 2.5e18−1,
     *   jtFee = ⌊(5e18−1)·0.1⌋ = 0.5e18−1, ltFee = 0.25e18−1, residual (50e18−5)−(5e18−1)−(2.5e18−1) = 42.5e18−3,
     *   stFee = ⌊(42.5e18−3)·0.1⌋ = 4.25e18−1, stEffectiveNAV = (1000e18+5) + (42.5e18−3) + (2.5e18−1) = 1045e18+1,
     *   jtEffectiveNAV = 180e18 + (5e18−1) = 185e18−1. Conservation 1050+180 = (1045e18+1)+(185e18−1). IL 0 ⇒ PERPETUAL.
     *   coverageUtilizationWAD = ⌈(1050e18 + 180e18)·0.1e18/(185e18−1)⌉ = 664864864864864865. liquidityUtilizationWAD = ⌈(1045e18+1)/2000⌉ = 522500000000000001.
     */
    function test_SyncTrancheAccounting_DustIL_RecoveryThenAwkwardPremiumFloors() public pure {
        RoycoTestMath.SyncInputs memory in_ =
            _syncInputs(1000e18, 200e18, 1000e18 + 5, 200e18 - 5, 5, RoycoTestMath.MarketState.PERPETUAL, 0, 7, 1050e18, 180e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 1050e18;
        expected.jtRawNAV = 180e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1045e18 + 1;
        expected.jtEffectiveNAV = 185e18 - 1;
        expected.jtRiskPremium = 5e18 - 1;
        expected.ltLiquidityPremium = 2.5e18 - 1;
        expected.stProtocolFee = 4.25e18 - 1;
        expected.jtProtocolFee = 0.5e18 - 1;
        expected.ltProtocolFee = 0.25e18 - 1;
        expected.coverageUtilizationWAD = 664_864_864_864_864_865;
        expected.liquidityUtilizationWAD = 522_500_000_000_000_001;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * Dust-IL FIXED_TERM stickiness, the pure case: with zero deltas and an IL of 5 wei inside the dust
     * tolerance of 7, an initially FIXED_TERM market stays FIXED_TERM with its ORIGINAL end — dust-sized IL
     * never silently releases a term.
     * Checkpoint: stRawNAV 1000e18−5, jtRawNAV 200e18, stEffectiveNAV 1000e18, jtEffectiveNAV 200e18−5, IL 5, dust 7, FIXED_TERM,
     * end T0+D. coverageUtilizationWAD = ⌈(1200e18−5)·0.1e18/(200e18−5)⌉ = 600000000000000001 (the −5 offsets leave a
     * fractional part).
     */
    function test_SyncTrancheAccounting_DustIL_FixedTermStickiness() public pure {
        RoycoTestMath.SyncInputs memory in_ =
            _syncInputs(1000e18 - 5, 200e18, 1000e18, 200e18 - 5, 5, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 7, 1000e18 - 5, 200e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 1000e18 - 5;
        expected.jtRawNAV = 200e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18;
        expected.jtEffectiveNAV = 200e18 - 5;
        expected.jtCoverageImpermanentLoss = 5;
        expected.coverageUtilizationWAD = 600_000_000_000_000_001;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEndTimestamp = T0 + DURATION;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * The sticky FIXED_TERM branch zeroes a LIVE JT fee: a JT gain books its provisional fee, but the commit
     * lands in the dust-IL sticky state, which zeroes fees like any FIXED_TERM commit. The gain NAV itself is
     * kept, only the fee is dropped.
     * Checkpoint: stRawNAV 1000e18−5, jtRawNAV 200e18, stEffectiveNAV 1000e18, jtEffectiveNAV 200e18−5, IL 5, dust 7, FIXED_TERM,
     * end T0+D. Sync (1000e18−5, 220e18): the JT-delta attribution to ST floors to 0 (⌊20e18·5/200e18⌋ = 0)
     * so deltaJTEff = +20e18 > dust 7 ⇒ provisional jtFee 2e18, jtEffectiveNAV = 220e18−5. No ST move ⇒ IL stays 5 ⇒
     * sticky FIXED_TERM zeroes the fee.
     * coverageUtilizationWAD = ⌈(1220e18−5)·0.1e18/(220e18−5)⌉ = 554545454545454546.
     */
    function test_SyncTrancheAccounting_StickyFixedTerm_ZeroesLiveJtFee() public pure {
        RoycoTestMath.SyncInputs memory in_ =
            _syncInputs(1000e18 - 5, 200e18, 1000e18, 200e18 - 5, 5, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 7, 1000e18 - 5, 220e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 1000e18 - 5;
        expected.jtRawNAV = 220e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18;
        expected.jtEffectiveNAV = 220e18 - 5;
        expected.jtCoverageImpermanentLoss = 5;
        expected.jtProtocolFee = 0;
        expected.coverageUtilizationWAD = 554_545_454_545_454_546;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEndTimestamp = T0 + DURATION;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A flat sync tips PERPETUAL into FIXED_TERM purely because the persisted IL now exceeds the (shrunk)
     * dust tolerance: the state machine re-evaluates carried IL on every commit, not only on new losses.
     * Checkpoint: 1000e18/200e18/(1000e18+5)/(200e18−5), IL 5, effectiveDust 0, PERPETUAL.
     * Zero deltas, post-sync IL 5 > dust 0, no forced disjunct ⇒ FIXED_TERM entry from PERPETUAL with
     * end = T0 + D. coverageUtilizationWAD = ⌈1200e18·0.1e18/(200e18−5)⌉ = 600000000000000001.
     * liquidityUtilizationWAD = ⌈(1000e18+5)/2000⌉ = 500000000000000001.
     */
    function test_SyncTrancheAccounting_FlatSync_TipsPerpetualToFixedTerm() public pure {
        RoycoTestMath.SyncInputs memory in_ =
            _syncInputs(1000e18, 200e18, 1000e18 + 5, 200e18 - 5, 5, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 1000e18, 200e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 1000e18;
        expected.jtRawNAV = 200e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18 + 5;
        expected.jtEffectiveNAV = 200e18 - 5;
        expected.jtCoverageImpermanentLoss = 5;
        expected.coverageUtilizationWAD = 600_000_000_000_000_001;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_001;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEndTimestamp = T0 + DURATION;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * Cross-claim state: after prior coverage, ST holds a claim on JT raw, so a JT-only loss bleeds into ST
     * through that claim and is immediately re-covered from the remaining JT buffer — the IL grows by exactly
     * the re-covered amount while stEffectiveNAV never moves.
     * Checkpoint: 900e18/300e18/1000e18/200e18, IL 100e18, dust 0, FIXED_TERM, end T0+D.
     * Sync (900e18, 280e18) with k = ⌊20e18·100e18/300e18⌋ = 6666666666666666666:
     *   deltaSTEff = −k, deltaJTEff = −20e18 + k = −13333333333333333334.
     *   JT leg: jtEffectiveNAV = 200e18 − 13333333333333333334 = 186666666666666666666.
     *   ST loss leg: coverage = k ⇒ jtEffectiveNAV = 180e18 exact, IL = 100e18 + k = 106666666666666666666, stEffectiveNAV unchanged.
     *   Conservation 900 + 280 = 1000 + 180. FIXED_TERM stays, end kept.
     *   coverageUtilizationWAD = ⌈(900e18 + 280e18)·0.1e18/180e18⌉ = ⌈655555555555555555.56⌉ = 655555555555555556.
     */
    function test_SyncTrancheAccounting_CrossClaim_JtLossBleedsIntoSTAndIsRecovered() public pure {
        RoycoTestMath.SyncInputs memory in_ =
            _syncInputs(900e18, 300e18, 1000e18, 200e18, 100e18, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 900e18, 280e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 900e18;
        expected.jtRawNAV = 280e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18;
        expected.jtEffectiveNAV = 180e18;
        expected.jtCoverageImpermanentLoss = 106_666_666_666_666_666_666;
        expected.coverageUtilizationWAD = 655_555_555_555_555_556;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEndTimestamp = T0 + DURATION;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A gain fully consumed by partial IL recovery: every wei of senior gain repays coverage debt, so the
     * premium block never runs and the premium accumulators do not reset.
     * Checkpoint: 900e18/300e18/1000e18/200e18, IL 100e18, dust 0, FIXED_TERM, end T0+D.
     * Sync (950e18, 280e18) with k = ⌊20e18·100e18/300e18⌋ = 6666666666666666666:
     *   deltaSTEff = 50e18 − k = 43333333333333333334, deltaJTEff = 30e18 − deltaSTEff = −13333333333333333334.
     *   JT leg loss ⇒ jtEffectiveNAV 186666666666666666666. IL recovery: rec = min(gain, 100e18) = gain ⇒
     *   IL = 100e18 − 43333333333333333334 = 56666666666666666666, jtEffectiveNAV = 230e18 exact, stGain = 0 ⇒ premium
     *   block skipped, premiumsPaid false. stEffectiveNAV 1000e18. FIXED_TERM stays, end kept.
     *   coverageUtilizationWAD = ⌈(950e18 + 280e18)·0.1e18/230e18⌉ = ⌈534782608695652173.91⌉ = 534782608695652174.
     */
    function test_SyncTrancheAccounting_GainFullyConsumedByPartialRecovery() public pure {
        RoycoTestMath.SyncInputs memory in_ =
            _syncInputs(900e18, 300e18, 1000e18, 200e18, 100e18, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 950e18, 280e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 950e18;
        expected.jtRawNAV = 280e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18;
        expected.jtEffectiveNAV = 230e18;
        expected.jtCoverageImpermanentLoss = 56_666_666_666_666_666_666;
        expected.coverageUtilizationWAD = 534_782_608_695_652_174;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEndTimestamp = T0 + DURATION;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A gain exactly equal to the IL sits on the recovery boundary: recovery consumes all of it, no premiums
     * pay, premiumsPaid stays false, and the now-IL-free market exits FIXED_TERM.
     * Checkpoint: 900e18/300e18/1000e18/200e18, IL 100e18, dust 0, FIXED_TERM, end T0+D.
     * Sync (1000e18, 300e18): rec = min(100e18, 100e18) = 100e18 ⇒ IL 0, jtEffectiveNAV 300e18, stGain 0 ⇒ premium
     * block skipped. IL 0 with initial FIXED_TERM ⇒ PERPETUAL, end 0.
     * coverageUtilizationWAD = ⌈(1000e18 + 300e18)·0.1e18/300e18⌉ = 433333333333333334.
     */
    function test_SyncTrancheAccounting_GainExactlyEqualsIL_NoPremiums() public pure {
        RoycoTestMath.SyncInputs memory in_ =
            _syncInputs(900e18, 300e18, 1000e18, 200e18, 100e18, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 1000e18, 300e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 1000e18;
        expected.jtRawNAV = 300e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18;
        expected.jtEffectiveNAV = 300e18;
        expected.coverageUtilizationWAD = 433_333_333_333_333_334;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A gain of IL + 1 wei: premiumsPaid fires TRUE while every premium and fee floors to 0, pinning that
     * even a 1-wei paid sync resets the premium accumulators (the premiumsPaid observable).
     * Checkpoint: 900e18/300e18/1000e18/200e18, IL 100e18, dust 0, FIXED_TERM, end T0+D.
     * Sync (1000e18+1, 300e18): rec = 100e18 ⇒ IL 0, stGain = 1 > dust 0 ⇒ premiumsPaid.
     * jtPrem = ⌊1·0.1⌋ = 0, ltPrem = 0, stFee = ⌊1·0.1⌋ = 0. stEffectiveNAV = 1000e18+1, jtEffectiveNAV = 300e18, PERPETUAL.
     * coverageUtilizationWAD = ⌈(1300e18+1)·0.1e18/300e18⌉ = 433333333333333334. liquidityUtilizationWAD = ⌈(1000e18+1)/2000⌉ = 500000000000000001.
     */
    function test_SyncTrancheAccounting_GainILPlusOneWei_PremiumsPaidWithZeroPremiums() public pure {
        RoycoTestMath.SyncInputs memory in_ =
            _syncInputs(900e18, 300e18, 1000e18, 200e18, 100e18, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 1000e18 + 1, 300e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 1000e18 + 1;
        expected.jtRawNAV = 300e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18 + 1;
        expected.jtEffectiveNAV = 300e18;
        expected.coverageUtilizationWAD = 433_333_333_333_333_334;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_001;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * The time-weighted premium branch produces the same premiums as an instantaneous sync at the same rates:
     * a 1-day window whose accruals encode the identical constant rates must land identical outputs, and the
     * instantaneous inputs are set hostile (uint256 max) to pin that the time-weighted path ignores them.
     * Checkpoint (stRawNAV/jtRawNAV/stEffectiveNAV/jtEffectiveNAV): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Warp 1 day: elapsed = 86400, twJT = 0.1e18·86400 = 8640e18, twLT = 0.05e18·86400 = 4320e18.
     * Sync (1050e18, 200e18): jtPrem = ⌊50e18·8640e18/(86400·1e18)⌋ = 5e18, ltPrem = 2.5e18, jtFee 0.5e18,
     * ltFee 0.25e18, residual 42.5e18 ⇒ stFee 4.25e18, stEffectiveNAV 1045e18, jtEffectiveNAV 205e18, PERPETUAL.
     * coverageUtilizationWAD = ⌈(1050e18 + 200e18)·0.1e18/205e18⌉ = ⌈609756097560975609.76⌉ = 609756097560975610.
     */
    function test_SyncTrancheAccounting_TimeWeightedMatchesInstantaneous_InstantInputsIgnored() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 1050e18, 200e18);
        in_.elapsedSincePremiumPayment = 86_400;
        in_.jtTwYieldShareAccrual = 8640e18;
        in_.ltTwYieldShareAccrual = 4320e18;
        in_.jtInstYieldShareWAD = type(uint256).max;
        in_.ltInstYieldShareWAD = type(uint256).max;
        in_.nowTimestamp = T0 + 86_400;
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 1050e18;
        expected.jtRawNAV = 200e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1045e18;
        expected.jtEffectiveNAV = 205e18;
        expected.jtRiskPremium = 5e18;
        expected.ltLiquidityPremium = 2.5e18;
        expected.stProtocolFee = 4.25e18;
        expected.jtProtocolFee = 0.5e18;
        expected.ltProtocolFee = 0.25e18;
        expected.coverageUtilizationWAD = 609_756_097_560_975_610;
        expected.liquidityUtilizationWAD = 522_500_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * Time-weighted averaging over a premium window whose rate changed mid-window: two half-day accrual
     * windows at different JT rates must average to the exact blended premium over the FULL window.
     * Checkpoint (stRawNAV/jtRawNAV/stEffectiveNAV/jtEffectiveNAV): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Accruals 0.1e18·43200 + 0.2e18·43200 = 12960e18 (the second window's 0.5e18 rate was capped to 0.2e18
     * at accrual, so the input already carries the cap), twLT = 0.05e18·86400 = 4320e18, elapsed = 86400.
     * Sync (1050e18, 200e18): jtPrem = ⌊50e18·12960e18/(86400·1e18)⌋ = ⌊50e18·0.15⌋ = 7.5e18, ltPrem = 2.5e18,
     * jtFee 0.75e18, ltFee 0.25e18, residual 40e18 ⇒ stFee 4e18, stEffectiveNAV = 1000e18 + 40e18 + 2.5e18 = 1042.5e18,
     * jtEffectiveNAV = 207.5e18. Conservation 1050 + 200 = 1042.5 + 207.5. PERPETUAL.
     * coverageUtilizationWAD = ⌈(1050e18 + 200e18)·0.1e18/207.5e18⌉ = ⌈602409638554216867.47⌉ = 602409638554216868.
     * liquidityUtilizationWAD = 1042.5e18/2000 = 521250000000000000 exact.
     */
    function test_SyncTrancheAccounting_TwoWindowTimeWeightedAveraging() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 1050e18, 200e18);
        in_.elapsedSincePremiumPayment = 86_400;
        in_.jtTwYieldShareAccrual = 12_960e18;
        in_.ltTwYieldShareAccrual = 4320e18;
        in_.nowTimestamp = T0 + 86_400;
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 1050e18;
        expected.jtRawNAV = 200e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1042.5e18;
        expected.jtEffectiveNAV = 207.5e18;
        expected.jtRiskPremium = 7.5e18;
        expected.ltLiquidityPremium = 2.5e18;
        expected.stProtocolFee = 4e18;
        expected.jtProtocolFee = 0.75e18;
        expected.ltProtocolFee = 0.25e18;
        expected.coverageUtilizationWAD = 602_409_638_554_216_868;
        expected.liquidityUtilizationWAD = 521_250_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * The instantaneous-branch cap: a hostile preview yield share (uint256 max) is clamped to
     * maxJTYieldShareWAD before it can price a premium, so a misbehaving yield model cannot drain the gain.
     * Checkpoint (stRawNAV/jtRawNAV/stEffectiveNAV/jtEffectiveNAV): 1000e18/200e18/1000e18/200e18, IL 0, dust 0, PERPETUAL.
     * Sync (1050e18, 200e18) with jtInst = uint256 max, maxJT = 0.2e18:
     * jtPrem = ⌊50e18·0.2e18/1e18⌋ = 10e18, ltPrem = 2.5e18 (lt preview 0.05e18 below its cap), jtFee 1e18,
     * ltFee 0.25e18, residual 37.5e18 ⇒ stFee 3.75e18, stEffectiveNAV = 1000e18 + 37.5e18 + 2.5e18 = 1040e18,
     * jtEffectiveNAV = 210e18. Conservation 1050 + 200 = 1040 + 210. coverageUtilizationWAD = ⌈(1050e18 + 200e18)·0.1e18/210e18⌉ = ⌈595238095238095238.10⌉ = 595238095238095239.
     */
    function test_SyncTrancheAccounting_InstantaneousHostilePreview_CappedAtMaxYieldShare() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 1050e18, 200e18);
        in_.jtInstYieldShareWAD = type(uint256).max;
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 1050e18;
        expected.jtRawNAV = 200e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1040e18;
        expected.jtEffectiveNAV = 210e18;
        expected.jtRiskPremium = 10e18;
        expected.ltLiquidityPremium = 2.5e18;
        expected.stProtocolFee = 3.75e18;
        expected.jtProtocolFee = 1e18;
        expected.ltProtocolFee = 0.25e18;
        expected.coverageUtilizationWAD = 595_238_095_238_095_239;
        expected.liquidityUtilizationWAD = 520_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * Zero-lastSTRaw attribution special case, live-ST arm: stRawNAVLast == 0 with stEffectiveNAVLast > 0
     * routes the whole senior delta to ST. Checkpoint: stRawNAV 0, jtRawNAV 100e18, stEffectiveNAV 50e18, jtEffectiveNAV 50e18
     * (post-coverage cross-claim, IL 50e18), FIXED_TERM. Sync (10e18, 100e18): deltaSTEff = +10e18,
     * deltaJTEff = 0, rec = min(10e18, 50e18) = 10e18 ⇒ IL 40e18, jtEffectiveNAV 60e18, stGain 0 (no premium block).
     * Conservation 10 + 100 = 50 + 60. IL > 0 ⇒ FIXED_TERM stays, end kept.
     * coverageUtilizationWAD = ⌈(10e18 + 100e18)·0.1e18/60e18⌉ = ⌈183333333333333333.33⌉ = 183333333333333334.
     * liquidityUtilizationWAD = ⌈50e18·0.05e18/100e18⌉ = 2.5e16.
     */
    function test_SyncTrancheAccounting_ZeroLastSTRaw_RoutesDeltaToSTWhenStEffPositive() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(0, 100e18, 50e18, 50e18, 50e18, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 10e18, 100e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 10e18;
        expected.jtRawNAV = 100e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 50e18;
        expected.jtEffectiveNAV = 60e18;
        expected.jtCoverageImpermanentLoss = 40e18;
        expected.coverageUtilizationWAD = 183_333_333_333_333_334;
        expected.liquidityUtilizationWAD = 25_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEndTimestamp = T0 + DURATION;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * Zero-lastSTRaw attribution special case, dead-ST arm: stRawNAVLast == 0 with stEffectiveNAVLast == 0 routes the
     * senior delta to JT (the residual falls through deltaJTEff). Checkpoint: 0/100e18/0/100e18, IL 0,
     * PERPETUAL. Sync (10e18, 100e18): deltaSTEff = 0, deltaJTEff = +10e18 > dust ⇒ jtFee 1e18, jtEffectiveNAV 110e18.
     * Conservation 10 + 100 = 0 + 110. coverageUtilizationWAD = ⌈(10e18 + 100e18)·0.1e18/110e18⌉ = 1e17 exact.
     * liquidityUtilizationWAD = 0 (the stEffectiveNAV zero edge propagates through the sync).
     */
    function test_SyncTrancheAccounting_ZeroLastSTRaw_RoutesDeltaToJTWhenStEffZero() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(0, 100e18, 0, 100e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 10e18, 100e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.stRawNAV = 10e18;
        expected.jtRawNAV = 100e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 0;
        expected.jtEffectiveNAV = 110e18;
        expected.jtProtocolFee = 1e18;
        expected.coverageUtilizationWAD = 100_000_000_000_000_000;
        expected.liquidityUtilizationWAD = 0;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                maxSTDeposit
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Coverage-binding: covLeg = ⌊200e18·1e18/1e17⌋ − (200e18 + 0 + 1000e18 + 0) = 2000e18 − 1200e18 = 800e18.
     * liqLeg = ⌊1000e18·1e18/5e16⌋ − 1000e18 = 20000e18 − 1000e18 = 19000e18. min = 800e18.
     */
    function test_MaxSTDeposit_CoverageBinding() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 200e18, 1000e18, 200e18, 1000e18, 1e17, 5e16, 0, 0), 800e18, "coverage leg binds");
    }

    /// Liquidity-binding twin: liqLeg = ⌊60e18·1e18/5e16⌋ − 1000e18 = 1200e18 − 1000e18 = 200e18 < covLeg 800e18.
    function test_MaxSTDeposit_LiquidityBinding() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 200e18, 1000e18, 200e18, 60e18, 1e17, 5e16, 0, 0), 200e18, "liquidity leg binds");
    }

    /// A zero requirement disables its leg: minCov 0 leaves only the liquidity leg (200e18), minLiq 0 only the
    /// coverage leg (800e18), and both zero return uint256 max.
    function test_MaxSTDeposit_ZeroRequirements_DisableLegs() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 200e18, 1000e18, 200e18, 60e18, 0, 5e16, 0, 0), 200e18, "no coverage leg");
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 200e18, 1000e18, 200e18, 60e18, 1e17, 0, 0, 0), 800e18, "no liquidity leg");
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 200e18, 1000e18, 200e18, 60e18, 0, 0, 0, 0), type(uint256).max, "no legs");
    }

    /**
     * Dust slack, both tolerances: covLeg = ⌊200e18·1e18/1e17⌋ − (jtRawNAV 200e18 + jtDust 4
     * + stRawNAV 1000e18 + stDust 3) = 2000e18 − 1200e18 − 7 = 800e18 − 7.
     */
    function test_MaxSTDeposit_DustSlack_BothTolerances() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 200e18, 1000e18, 200e18, 1000e18, 1e17, 0, 3, 4), 800e18 - 7, "both dust terms subtract");
    }

    /// Saturation: covered value 500e18 below the existing exposure 1200e18 saturates the leg to 0.
    function test_MaxSTDeposit_SaturatesToZero() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1000e18, 200e18, 1000e18, 50e18, 1000e18, 1e17, 0, 0, 0), 0, "no capacity left");
    }

    /// Floor on both inversions at wei scale: covLeg = ⌊1·1e18/3e17⌋ − 1 = 3 − 1 = 2, and the liquidity twin
    /// liqLeg = ⌊1·1e18/3e17⌋ − 1 = 2.
    function test_MaxSTDeposit_FloorOnInversions_WeiScale() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1, 0, 0, 1, 0, 3e17, 0, 0, 0), 2, "floor(1e18/3e17) = 3 minus stRawNAV 1");
        assertEq(RoycoTestMath.maxSTDeposit(0, 0, 1, 0, 1, 0, 3e17, 0, 0), 2, "floor(1e18/3e17) = 3 minus stEffectiveNAV 1");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                maxJTWithdrawal
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Self-backed nominal with the retention denominator: exposure = 1200e18 ⇒ required = ⌈(1200e18 + 0 + 0)·1e17/1e18⌉ = 120e18,
     * surplus = sat(200e18 − 120e18) = 80e18 (the dust folds into the requirement before the ceil, no fudge).
     * JT is coinvested, so each withdrawn NAV unit relaxes the requirement by minCoverageWAD and the surplus grosses
     * up by the retention denominator WAD − minCoverageWAD = 9e17:
     * y = ⌊80e18·1e18/9e17⌋ = ⌊800000000000000000000/9⌋ = 88888888888888888888.
     */
    function test_MaxJTWithdrawal_SelfBacked_RetentionDenominator() public pure {
        uint256 jtW = RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 200e18, 1e17, 0, 0);
        assertEq(jtW, 88_888_888_888_888_888_888, "surplus grossed up by 10/9 retention");
    }

    /**
     * Surplus boundary: with jtEffectiveNAV exactly at the requirement the surplus saturates to 0 and the closed
     * form returns 0, while one more wei of buffer yields exactly 1 wei withdrawable.
     *   required = ⌈1200e18·1e17/1e18⌉ = 120e18, jtEffectiveNAV = 120e18 ⇒ surplus 0, jtEffectiveNAV = 120e18 + 1 ⇒ surplus 1,
     *   retention 9e17 ⇒ y = ⌊1·1e18/9e17⌋ = 1.
     */
    function test_MaxJTWithdrawal_SurplusBoundary() public pure {
        uint256 jtW0 = RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 120e18, 1e17, 0, 0);
        assertEq(jtW0, 0, "the requirement consumes the whole buffer");
        uint256 jtW1 = RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 120e18 + 1, 1e17, 0, 0);
        assertEq(jtW1, 1, "one wei past the requirement is withdrawable");
    }

    /**
     * Cross-claim state: jtEffectiveNAV 250e18 exceeds jtRawNAV 200e18 (JT holds a 50e18 premium claim on ST), so the
     * coverage buffer is the full 250e18 effective and the whole surplus grosses up through the single retention factor.
     *   exposure = 1200e18 ⇒ required = ⌈1200e18·1e17/1e18⌉ = 120e18, surplus = sat(250e18 − 120e18) = 130e18.
     *   retention 9e17 ⇒ y = ⌊130e18·1e18/9e17⌋ = ⌊1300000000000000000000/9⌋ = 144444444444444444444.
     */
    function test_MaxJTWithdrawal_CrossClaimState() public pure {
        uint256 jtW = RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 250e18, 1e17, 0, 0);
        assertEq(jtW, 144_444_444_444_444_444_444, "coverage surplus grossed up by 10/9 retention");
    }

    /**
     * Zero minCoverage: no coverage requirement makes required 0 and the retention denominator the full WAD, so the
     * withdrawable equals the whole buffer with no gross-up.
     *   required = ⌈(100e18 + 10)·0/1e18⌉ = 0, surplus = sat(5 − 0) = 5, y = ⌊5·1e18/1e18⌋ = 5.
     */
    function test_MaxJTWithdrawal_ZeroMinCoverage_FullRetentionDenominator() public pure {
        uint256 jtW = RoycoTestMath.maxJTWithdrawal(100e18, 10, 5, 0, 0, 0);
        assertEq(jtW, 5, "zero coverage requirement, withdrawable equals the whole buffer");
    }

    /// Zero-surplus early-out: required = ⌈1200e18·3e17/1e18⌉ = 360e18 exceeds jtEffectiveNAV 200e18 entirely, surplus saturates to 0.
    function test_MaxJTWithdrawal_RequiredExceedsBuffer_ReturnsZero() public pure {
        uint256 jtW = RoycoTestMath.maxJTWithdrawal(1000e18, 200e18, 200e18, 3e17, 0, 0);
        assertEq(jtW, 0, "no surplus");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                maxLTWithdrawal
    //////////////////////////////////////////////////////////////////////////*/

    /// Nominal: required = ⌈1000e18·5e16/1e18⌉ = 50e18 exact, withdrawable = 100e18 − 50e18 = 50e18.
    function test_MaxLTWithdrawal_Nominal() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 5e16, 0, 5e17, 1.1e18), 50e18, "half the pool is surplus");
    }

    /// Ceil on the required depth: stEffectiveNAV 1000e18+1 ⇒ required = ⌈50e18 + 0.05⌉ = 50e18 + 1 ⇒ 50e18 − 1.
    function test_MaxLTWithdrawal_CeilInnerRounding() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18 + 1, 5e16, 0, 5e17, 1.1e18), 50e18 - 1, "ceil bites one wei");
    }

    /// The stDust folds into the senior NAV before μ-scaling: required = ⌈(1000e18 + 3)·0.05⌉ = 50e18 + 1 ⇒ 50e18 − 1.
    function test_MaxLTWithdrawal_StDustSlack() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 5e16, 3, 5e17, 1.1e18), 50e18 - 1, "dust slack");
    }

    /// minLiq == 0 bypasses the gate entirely: the whole ltRawNAV is withdrawable.
    function test_MaxLTWithdrawal_ZeroMinLiquidity_FullLtRaw() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 0, 0, 5e17, 1.1e18), 100e18, "no liquidity requirement");
    }

    /// Liquidation breach at the EXACT threshold bypasses (the comparison is >=): full ltRawNAV.
    function test_MaxLTWithdrawal_LiquidationBreachExactThreshold_FullLtRaw() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 5e16, 0, 1.1e18, 1.1e18), 100e18, "exact threshold bypasses");
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 5e16, 0, 1.1e18 - 1, 1.1e18), 50e18, "one wei below gates");
    }

    /// Saturation: required 50e18 above the pool depth 40e18 saturates to 0.
    function test_MaxLTWithdrawal_SaturatesToZero() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(40e18, 1000e18, 5e16, 0, 5e17, 1.1e18), 0, "under-provisioned pool");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        seniorTrancheSelfLiquidationBonus
    //////////////////////////////////////////////////////////////////////////*/

    /// Builds a SelfLiqBonusIn with the shared reference state: stRawNAV 1000e18, jtRawNAV 100e18, jtEffectiveNAV 140e18,
    /// coverage utilization at the 1.1e18 liquidation threshold, bonus rate 5e17.
    function _bonusIn(uint256 userNav) private pure returns (RoycoTestMath.SeniorTrancheSelfLiquidationBonusInputs memory in_) {
        in_.stRawNAV = 1000e18;
        in_.jtRawNAV = 100e18;
        in_.jtEffectiveNAV = 140e18;
        in_.coverageUtilizationWAD = 1.1e18;
        in_.coverageLiquidationUtilizationWAD = 1.1e18;
        in_.bonusWAD = 5e17;
        in_.userClaimNAV = userNav;
    }

    /// Below the liquidation threshold (strict <) there is no bonus whatever the claim sizes.
    function test_SeniorTrancheSelfLiquidationBonus_BelowThreshold_ReturnsZero() public pure {
        RoycoTestMath.SeniorTrancheSelfLiquidationBonusInputs memory in_ = _bonusIn(200e18);
        in_.coverageUtilizationWAD = 1.1e18 - 1;
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(in_), 0, "inactive below the threshold");
    }

    /**
     * Active at the EXACT threshold (the gate is coverage utilization >= the liquidation threshold), U-neutral
     * max binding: desired = ⌊200e18·5e17/1e18⌋ = 100e18, jtEffectiveNAV = 140e18, exposure = 1100e18 ⇒
     * maxNeutral = ⌊200e18·140e18/(1100e18 − 140e18)⌋ = ⌊28000e36/960e18⌋ = 29166666666666666666 ⇒
     * bonus = min(100e18, 140e18, 29166666666666666666).
     */
    function test_SeniorTrancheSelfLiquidationBonus_AtThresholdExactly_NeutralMaxBinds() public pure {
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_bonusIn(200e18)), 29_166_666_666_666_666_666, "floors 28000/960");
    }

    /**
     * U-neutral max with exact division: userClaimNAV 300e18 over the jtEffectiveNAV-reduced denominator gives
     * maxNeutral = ⌊300e18·140e18/(1100e18 − 140e18)⌋ = 43.75e18 exact.
     * desired 150e18 and jtEffectiveNAV 140e18 do not bind ⇒ bonus = 43.75e18.
     */
    function test_SeniorTrancheSelfLiquidationBonus_NeutralMax_ExactDivision() public pure {
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_bonusIn(300e18)), 43.75e18, "42000e36/960e18 exact");
    }

    /// The desired term binds when the rate is small: ⌊200e18·1e15/1e18⌋ = 0.2e18 below both other terms.
    function test_SeniorTrancheSelfLiquidationBonus_DesiredBinds() public pure {
        RoycoTestMath.SeniorTrancheSelfLiquidationBonusInputs memory in_ = _bonusIn(200e18);
        in_.bonusWAD = 1e15;
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(in_), 0.2e18, "floor(200e18*1e15/1e18)");
    }

    /**
     * The jtEffectiveNAV term binds: stRawNAV 100e18, jtRawNAV 20e18, jtEffectiveNAV 60e18, userClaimNAV 130e18:
     * maxNeutral = ⌊130e18·60e18/(120e18 − 60e18)⌋ = 130e18, desired = ⌊130e18·5e17/1e18⌋ = 65e18 ⇒
     * bonus = min(65e18, 60e18, 130e18) = 60e18, capped by the remaining JT buffer.
     */
    function test_SeniorTrancheSelfLiquidationBonus_JtEffBinds() public pure {
        RoycoTestMath.SeniorTrancheSelfLiquidationBonusInputs memory in_ = _bonusIn(130e18);
        in_.stRawNAV = 100e18;
        in_.jtRawNAV = 20e18;
        in_.jtEffectiveNAV = 60e18;
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(in_), 60e18, "capped by the remaining JT buffer");
    }

    /// Early-outs: jtEffectiveNAV == 0 and a zero user claim both zero the U-neutral max and hence the bonus.
    function test_SeniorTrancheSelfLiquidationBonus_ZeroJtEff_AndZeroUserClaim_ReturnZero() public pure {
        RoycoTestMath.SeniorTrancheSelfLiquidationBonusInputs memory zeroJt = _bonusIn(200e18);
        zeroJt.jtEffectiveNAV = 0;
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(zeroJt), 0, "no JT capital to source");
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_bonusIn(0)), 0, "no user claim to scale");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            adaptiveCurveYieldShare
    //////////////////////////////////////////////////////////////////////////*/

    /// Builds an AdaptiveYdmIn with the shared reference curve: target 8e17, start 1e17, FD_T 5e16, FP_T 1e17,
    /// clamps [1e14, 1e18] (the production 1bp floor and WAD ceiling), boundary speed 1e12, PERPETUAL.
    function _ydmIn(uint256 u, uint256 elapsed) private pure returns (RoycoTestMath.AdaptiveCurveYieldShareInputs memory in_) {
        in_.utilizationWAD = u;
        in_.targetUtilizationWAD = 8e17;
        in_.startYieldShareAtTargetWAD = 1e17;
        in_.elapsedSeconds = elapsed;
        in_.discountToTargetAtZeroUtilWAD = 5e16;
        in_.premiumToTargetAtFullUtilWAD = 1e17;
        in_.adaptationSpeedAtBoundaryWAD = 1e12;
        in_.minYieldShareAtTargetWAD = 1e14;
        in_.maxYieldShareAtTargetWAD = 1e18;
        in_.perpetual = true;
    }

    /// At u == targetU the normalized delta is 0: no adaptation (speed 0), no spread, output == start on both legs.
    function test_AdaptiveCurveYieldShare_AtTarget_ReturnsStartOnBothLegs() public pure {
        RoycoTestMath.AdaptiveCurveYieldShareOutputs memory out = RoycoTestMath.adaptiveCurveYieldShare(_ydmIn(8e17, 1000));
        assertEq(out.yieldShareWAD, 1e17, "y(target) = start");
        assertEq(out.endYieldShareAtTargetWAD, 1e17, "curve unmoved at target");
    }

    /// elapsed == 0 gives linear adaptation 0 (expWad(0) = 1e18 exactly): the curve holds and only the fixed
    /// spread applies. At u = WAD: normDelta = 1e18 ⇒ y = start + FP_T = 1e17 + 1e17 = 2e17, end = start.
    function test_AdaptiveCurveYieldShare_ZeroElapsed_SpreadOnly_FullUtil() public pure {
        RoycoTestMath.AdaptiveCurveYieldShareOutputs memory out = RoycoTestMath.adaptiveCurveYieldShare(_ydmIn(1e18, 0));
        assertEq(out.yieldShareWAD, 2e17, "start + FP_T");
        assertEq(out.endYieldShareAtTargetWAD, 1e17, "no adaptation at zero elapsed");
    }

    /// At u = 0 with elapsed 0 the discount side applies: normDelta = −1e18 ⇒ y = start − FD_T = 5e16.
    function test_AdaptiveCurveYieldShare_ZeroElapsed_SpreadOnly_ZeroUtil() public pure {
        RoycoTestMath.AdaptiveCurveYieldShareOutputs memory out = RoycoTestMath.adaptiveCurveYieldShare(_ydmIn(0, 0));
        assertEq(out.yieldShareWAD, 5e16, "start - FD_T");
        assertEq(out.endYieldShareAtTargetWAD, 1e17, "no adaptation at zero elapsed");
    }

    /// Outside PERPETUAL the curve never adapts regardless of elapsed: same outputs as the zero-elapsed vector.
    function test_AdaptiveCurveYieldShare_NotPerpetual_CurveFrozen() public pure {
        RoycoTestMath.AdaptiveCurveYieldShareInputs memory in_ = _ydmIn(1e18, 1e9);
        in_.perpetual = false;
        RoycoTestMath.AdaptiveCurveYieldShareOutputs memory out = RoycoTestMath.adaptiveCurveYieldShare(in_);
        assertEq(out.yieldShareWAD, 2e17, "spread only while frozen");
        assertEq(out.endYieldShareAtTargetWAD, 1e17, "no adaptation outside PERPETUAL");
    }

    /**
     * Positive adaptation clamps: u = WAD, speed 1e12, elapsed 1e9 ⇒ linear = 1e21, clamped to
     * MAX_LINEAR_ADAPTATION_WAD before expWad, so both the end and the midpoint (5e20, also above the clamp)
     * saturate at maxYieldShareAtTarget = 1e18. Start 5e17 ⇒ trapezoid avg = (5e17 + 1e18 + 2·1e18)/4 =
     * 875000000000000000, y = avg + FP_T 1e17 = 975000000000000000.
     */
    function test_AdaptiveCurveYieldShare_PositiveClamp_TrapezoidAveragesMax() public pure {
        RoycoTestMath.AdaptiveCurveYieldShareInputs memory in_ = _ydmIn(1e18, 1e9);
        in_.startYieldShareAtTargetWAD = 5e17;
        RoycoTestMath.AdaptiveCurveYieldShareOutputs memory out = RoycoTestMath.adaptiveCurveYieldShare(in_);
        assertEq(out.endYieldShareAtTargetWAD, 1e18, "end clamped to max");
        assertEq(out.yieldShareWAD, 975_000_000_000_000_000, "(5e17 + 3e18)/4 + 1e17");
    }

    /**
     * Negative adaptation decays to the floor: u = 0, speed 1e12, elapsed 1e9 ⇒ linear = −1e21, deep below
     * expWad's zero threshold, so end and midpoint both clamp to minYieldShareAtTarget = 1e14. Start 1e18 ⇒
     * avg = (1e18 + 1e14 + 2·1e14)/4 = 250075000000000000, y = avg − FD_T 5e16 = 200075000000000000.
     */
    function test_AdaptiveCurveYieldShare_NegativeClamp_DecaysToMinFloor() public pure {
        RoycoTestMath.AdaptiveCurveYieldShareInputs memory in_ = _ydmIn(0, 1e9);
        in_.startYieldShareAtTargetWAD = 1e18;
        RoycoTestMath.AdaptiveCurveYieldShareOutputs memory out = RoycoTestMath.adaptiveCurveYieldShare(in_);
        assertEq(out.endYieldShareAtTargetWAD, 1e14, "end clamped to the 1bp floor");
        assertEq(out.yieldShareWAD, 200_075_000_000_000_000, "(1e18 + 3e14)/4 - 5e16");
    }

    /// Utilization above WAD is capped before evaluation: u = 2e18 behaves exactly like u = 1e18.
    function test_AdaptiveCurveYieldShare_UtilizationAboveWad_Capped() public pure {
        RoycoTestMath.AdaptiveCurveYieldShareOutputs memory out = RoycoTestMath.adaptiveCurveYieldShare(_ydmIn(2e18, 0));
        assertEq(out.yieldShareWAD, 2e17, "capped u = WAD");
        assertEq(out.endYieldShareAtTargetWAD, 1e17, "no adaptation at zero elapsed");
    }

    /**
     * Signed divisions truncate toward zero (not floor): u = 1e17, target 3e17 ⇒
     * normDelta = (−2e17·1e18)/3e17 = −666666666666666666 (truncated from −...666.67), and the adjustment
     * (−666666666666666666·3e16)/1e18 = −19999999999999999 (truncated from −...999.98), so
     * y = 1e17 − 19999999999999999 = 80000000000000001 (a floor division would give 8e16 exactly).
     */
    function test_AdaptiveCurveYieldShare_SignedDivisions_TruncateTowardZero() public pure {
        RoycoTestMath.AdaptiveCurveYieldShareInputs memory in_ = _ydmIn(1e17, 0);
        in_.targetUtilizationWAD = 3e17;
        in_.discountToTargetAtZeroUtilWAD = 3e16;
        RoycoTestMath.AdaptiveCurveYieldShareOutputs memory out = RoycoTestMath.adaptiveCurveYieldShare(in_);
        assertEq(out.yieldShareWAD, 80_000_000_000_000_001, "double truncation keeps 1 wei");
        assertEq(out.endYieldShareAtTargetWAD, 1e17, "no adaptation at zero elapsed");
    }

    /// The curve output clamps to [0, WAD]: a discount below zero returns 0 and a premium above WAD returns WAD.
    function test_AdaptiveCurveYieldShare_OutputClampedToZeroAndWad() public pure {
        RoycoTestMath.AdaptiveCurveYieldShareInputs memory low = _ydmIn(0, 0);
        low.startYieldShareAtTargetWAD = 1e14;
        assertEq(RoycoTestMath.adaptiveCurveYieldShare(low).yieldShareWAD, 0, "1e14 - 5e16 clamps to 0");
        RoycoTestMath.AdaptiveCurveYieldShareInputs memory high = _ydmIn(1e18, 0);
        high.startYieldShareAtTargetWAD = 1e18;
        high.premiumToTargetAtFullUtilWAD = 5e17;
        assertEq(RoycoTestMath.adaptiveCurveYieldShare(high).yieldShareWAD, 1e18, "1e18 + 5e17 clamps to WAD");
    }
}
