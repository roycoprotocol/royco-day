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
                        attributeDeltaToClaimOnCollateralNAV
    //////////////////////////////////////////////////////////////////////////*/

    /// Zero delta attributes nothing regardless of claim shape.
    function test_AttributeDeltaToClaimOnCollateralNAV_ZeroDelta_ReturnsZero() public pure {
        assertEq(RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(0, 5e18, 10e18), 0, "zero delta");
        assertEq(RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(0, 0, 0), 0, "zero delta with empty market");
    }

    /// Zero claim attributes nothing in either direction.
    function test_AttributeDeltaToClaimOnCollateralNAV_ZeroClaim_ReturnsZero() public pure {
        assertEq(RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(1e18, 0, 10e18), 0, "gain, zero claim");
        assertEq(RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(-1e18, 0, 10e18), 0, "loss, zero claim");
    }

    /// Zero lastCollateralNAV attributes nothing in either direction: an empty checkpoint carries no claims,
    /// so a delta against it falls entirely to the JT residual.
    function test_AttributeDeltaToClaimOnCollateralNAV_ZeroLastCollateralNAV_ReturnsZero() public pure {
        assertEq(RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(1e18, 5e18, 0), 0, "gain, empty checkpoint");
        assertEq(RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(-1e18, 5e18, 0), 0, "loss, empty checkpoint");
    }

    /// Positive delta floors: attribute(+7, claim 1, lastCollateral 3) = ⌊7·1/3⌋ = ⌊2.333…⌋ = 2.
    function test_AttributeDeltaToClaimOnCollateralNAV_PositiveDelta_FloorsMagnitude() public pure {
        assertEq(RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(7, 1, 3), 2, "floor(7*1/3) = 2");
    }

    /// Negative delta floors the MAGNITUDE then re-applies the sign (toward zero, never away):
    /// attribute(-7, claim 2, lastCollateral 3) = -⌊7·2/3⌋ = -⌊4.666…⌋ = -4 (not -5).
    function test_AttributeDeltaToClaimOnCollateralNAV_NegativeDelta_FloorsMagnitudeThenReappliesSign() public pure {
        assertEq(RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(-7, 2, 3), -4, "-floor(7*2/3) = -4");
    }

    /// A full claim (claim == lastCollateralNAV) attributes the whole delta exactly, both signs.
    function test_AttributeDeltaToClaimOnCollateralNAV_FullClaim_Exact() public pure {
        assertEq(RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(-123_456_789, 1e18, 1e18), -123_456_789, "full claim on loss");
        assertEq(RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(987_654_321, 55e18, 55e18), 987_654_321, "full claim on gain");
    }

    /// 1-wei boundary: ⌊1·1/1e30⌋ = 0 and -⌊(1e30-1)·1/1e30⌋ = 0 (dust vanishes to the JT residual).
    function test_AttributeDeltaToClaimOnCollateralNAV_OneWeiDelta_FloorsToZero() public pure {
        assertEq(RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(1, 1, 1e30), 0, "floor(1*1/1e30) = 0");
        assertEq(RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(-1, 1e30 - 1, 1e30), 0, "-floor(1*(1e30-1)/1e30) = 0");
    }

    /// Max realistic NAV boundary (1e30): ⌊1e30·7e29/1e30⌋ = 7e29 exact, and the full-claim loss at scale.
    function test_AttributeDeltaToClaimOnCollateralNAV_MaxRealistic() public pure {
        assertEq(RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(int256(MAX_NAV), 7e29, MAX_NAV), 7e29, "floor(1e30*7e29/1e30) = 7e29");
        assertEq(RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(-int256(MAX_NAV), MAX_NAV, MAX_NAV), -int256(MAX_NAV), "full-claim loss at scale");
    }

    /// The split is ST-floored with JT as the residual, so it conserves the delta EXACTLY (no dropped wei):
    /// delta 7 over lastCollateral 3 with stClaim 1: stPart = ⌊7/3⌋ = 2 and jtResidual = 7 − 2 = 5, sum 7.
    /// The floor pushes the fractional wei to JT on gains, both parts share the delta's sign by construction.
    function test_AttributeDeltaToClaimOnCollateralNAV_JTResidual_ConservesDeltaExactly() public pure {
        int256 delta = 7;
        int256 stPart = RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(delta, 1, 3);
        int256 jtResidual = delta - stPart;
        assertEq(stPart, 2, "floor(7*1/3) = 2");
        assertEq(jtResidual, 5, "JT absorbs the floor residual: 7 - 2 = 5");
        assertEq(stPart + jtResidual, delta, "the residual split conserves the delta exactly");

        // Loss side: the magnitude floors toward zero so JT's loss residual is the larger part
        int256 lossDelta = -7;
        int256 stLoss = RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(lossDelta, 1, 3);
        assertEq(stLoss, -2, "-floor(7*1/3) = -2, the floor favors seniors on losses");
        assertEq(lossDelta - stLoss, -5, "JT absorbs the loss residual: -7 + 2 = -5");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            computeCoverageUtilization
    //////////////////////////////////////////////////////////////////////////*/

    /// minCov == 0 means no requirement: utilization is 0 whatever the NAVs.
    function test_ComputeCoverageUtilization_ZeroMinCoverage_ReturnsZero() public pure {
        assertEq(RoycoTestMath.computeCoverageUtilization(2e18, 0, 5e17), 0, "no coverage requirement");
    }

    /// Zero collateral NAV returns 0 whatever the requirement.
    function test_ComputeCoverageUtilization_ZeroCollateralNAV_ReturnsZero() public pure {
        assertEq(RoycoTestMath.computeCoverageUtilization(0, 1e17, 1e18), 0, "empty market");
    }

    /// Zero edges take precedence over the infinite edge (both minCov == 0 and collateralNAV == 0 vs jtEffectiveNAV == 0).
    function test_ComputeCoverageUtilization_ZeroEdgePrecedence_OverInfiniteEdge() public pure {
        assertEq(RoycoTestMath.computeCoverageUtilization(0, 1e17, 0), 0, "zero collateralNAV wins over zero jtEffectiveNAV");
        assertEq(RoycoTestMath.computeCoverageUtilization(1e18, 0, 0), 0, "zero minCov wins over zero jtEffectiveNAV");
    }

    /// Positive requirement against zero JT effective NAV is infinite utilization.
    function test_ComputeCoverageUtilization_ZeroJtEff_ReturnsMax() public pure {
        assertEq(RoycoTestMath.computeCoverageUtilization(1e18, 1e17, 0), type(uint256).max, "collateral NAV with no junior buffer");
    }

    /// Exact WAD threshold, clean division: ⌈150e18·1e17 / 15e18⌉ = ⌈1.5e37/1.5e19⌉ = 1e18 exactly.
    function test_ComputeCoverageUtilization_ExactWadBoundary_CleanDivision() public pure {
        assertEq(RoycoTestMath.computeCoverageUtilization(150e18, 1e17, 15e18), 1e18, "coverage utilization == WAD exactly");
    }

    /// Ceil engaged: ⌈10·1e17 / 3⌉ = ⌈1e18/3⌉ = ⌈333333333333333333.33…⌉ = 333333333333333334.
    function test_ComputeCoverageUtilization_CeilRounding_FavorsSenior() public pure {
        assertEq(RoycoTestMath.computeCoverageUtilization(10, 1e17, 3), 333_333_333_333_333_334, "ceil(1e18/3)");
    }

    /// Max realistic: ⌈2e30·1e18 / 1⌉ = 2e48 exact (no overflow through mulDiv).
    function test_ComputeCoverageUtilization_MaxRealistic() public pure {
        assertEq(RoycoTestMath.computeCoverageUtilization(2 * MAX_NAV, WAD, 1), 2e48, "2e30 * 1e18 / 1");
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

    /// A genuinely fresh tranche (supply == 0 AND totalValue == 0) mints 1:1 with the contributed value. The
    /// empty-with-backing state (supply == 0, totalValue > 0) is NOT fresh under the virtual-shares offset: it
    /// prices against the virtual-share supply so pre-seeded backing cannot be captured 1:1.
    function test_ConvertToShares_ZeroSupply_MintsOneToOne() public pure {
        assertEq(RoycoTestMath.convertToShares(123e18, 0, 0), 123e18, "fresh tranche mints 1:1");
        assertEq(RoycoTestMath.convertToShares(5, 999, 0), 5000, "empty-with-backing prices vs virtual shares: floor((0+1e6)*5/(999+1)) = 5000");
    }

    /// Live supply over zero NAV pins the denominator to 1 wei (totalValue + VIRTUAL_VALUE = 0 + 1):
    /// ⌊(7 + 1e6)·3/(0 + 1)⌋ = 3·1000007 = 3000021.
    function test_ConvertToShares_ZeroTotalValue_UsesOneWeiDenominator() public pure {
        assertEq(RoycoTestMath.convertToShares(3, 0, 7), 3_000_021, "floor((7+1e6)*3/1) = 3000021");
    }

    /// Floor engaged over the virtual-shares offset: ⌊(5 + 1e6)·3/(7 + 1)⌋ = ⌊3000015/8⌋ = ⌊375001.875⌋ = 375001
    /// (the fractional dust stays with existing holders).
    function test_ConvertToShares_FloorRounding_FavorsExistingHolders() public pure {
        assertEq(RoycoTestMath.convertToShares(3, 7, 5), 375_001, "floor((5+1e6)*3/(7+1)) = floor(3000015/8) = 375001");
    }

    /// The base ratio divides cleanly (200e18·10e18/100e18 = 20e18); the virtual-shares offset lifts the numerator
    /// supply by 1e6 and the denominator by 1, adding a small floored residual:
    /// ⌊(200e18 + 1e6)·10e18/(100e18 + 1)⌋ = 20000000000000099999.
    function test_ConvertToShares_CleanDivision() public pure {
        assertEq(RoycoTestMath.convertToShares(10e18, 100e18, 200e18), 20_000_000_000_000_099_999, "floor((200e18+1e6)*10e18/(100e18+1))");
    }

    /// Zero value mints zero shares against a live market: ⌊(50 + 1e6)·0/(100 + 1)⌋ = 0.
    function test_ConvertToShares_ZeroValue_ReturnsZero() public pure {
        assertEq(RoycoTestMath.convertToShares(0, 100, 50), 0, "nothing in, nothing out");
    }

    /// 1-wei boundaries over the offset: ⌊(1e30 + 1e6)·1/(1e30 + 1)⌋ = 1 (near par), and ⌊(1 + 1e6)·1/(1e30 + 1)⌋ = 0
    /// when the pot dwarfs the supply.
    function test_ConvertToShares_OneWeiBoundaries() public pure {
        assertEq(RoycoTestMath.convertToShares(1, 1e30, 1e30), 1, "floor((1e30+1e6)*1/(1e30+1)) = 1");
        assertEq(RoycoTestMath.convertToShares(1, 1e30, 1), 0, "floor((1+1e6)*1/(1e30+1)) = 0");
    }

    /// Max realistic near par: the virtual-share numerator lifts the mint just above par at scale —
    /// ⌊(1e30 + 1e6)·1e30/(1e30 + 1)⌋ = 1000000000000000000000000999998.
    function test_ConvertToShares_MaxRealistic() public pure {
        assertEq(RoycoTestMath.convertToShares(MAX_NAV, MAX_NAV, MAX_NAV), 1_000_000_000_000_000_000_000_000_999_998, "floor((1e30+1e6)*1e30/(1e30+1))");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            the mint-dilution clamp
    //////////////////////////////////////////////////////////////////////////*/

    /// Bind boundary, exact (continuity) under the virtual-shares offset. With supply S = 1e18, totalValue T = 1e18,
    /// clamp width w = WAD − MAX = 1e6: effectiveSupply = S + 1e6, denom = T + 1 = 1e18 + 1, and
    ///   cap = ⌊effectiveSupply·MAX/w⌋ = ⌊(1e18 + 1e6)·(1e18 − 1e6)/1e6⌋ = 1e30 − 1e6.
    /// The largest non-binding value is threshold = ⌊denom·MAX/w⌋ = ⌊(1e18 + 1)·(1e18 − 1e6)/1e6⌋
    ///   = 1e30 − 1e18 + 1e12 − 1. At v = threshold the fair mint ⌊effectiveSupply·threshold/denom⌋ equals the cap
    /// exactly, so the clamp is continuous at the boundary.
    function test_ConvertToShares_ClampBindBoundary_FairEqualsCapExactly() public pure {
        uint256 threshold = 1e30 - 1e18 + 1e12 - 1;
        uint256 cap = 1e30 - 1e6;
        assertEq(RoycoTestMath.convertToShares(threshold, 1e18, 1e18), cap, "at the boundary the fair mint equals the cap");
    }

    /// Bind boundary + 1 wei: v = threshold + 1 = 1e30 − 1e18 + 1e12 trips the bind and returns the same
    /// cap = 1e30 − 1e6 as the boundary itself (the clamp plateaus, it does not jump).
    function test_ConvertToShares_ClampBindBoundaryPlusOne_ReturnsSameCap() public pure {
        assertEq(RoycoTestMath.convertToShares(1e30 - 1e18 + 1e12, 1e18, 1e18), 1e30 - 1e6, "one wei past the boundary mints the identical cap");
    }

    /// Zero-NAV composition min(effectiveSupply·v, cap) with denom = totalValue + 1 = 1: the mint stays unclamped
    /// for small values (bind iff ⌈3·1e6/(1e18−1e6)⌉ = 1 > 1 is false ⇒ ⌊(7 + 1e6)·3/1⌋ = 3000021), and clamps for
    /// large ones (v = 1e12: ⌈1e12·1e6/(1e18−1e6)⌉ = 2 > 1 ⇒ cap = ⌊(7 + 1e6)·(1e18−1e6)/1e6⌋ = 1000007·(1e12−1)
    /// = 1000006999998999993).
    function test_ConvertToShares_ClampOverZeroNAV_ComposesWithOneWeiDenominator() public pure {
        assertEq(RoycoTestMath.convertToShares(3, 0, 7), 3_000_021, "small dilution mint stays fair-priced");
        assertEq(RoycoTestMath.convertToShares(1e12, 0, 7), 1_000_006_999_998_999_993, "large dilution mint clamps to 1000007*(1e12-1)");
    }

    /// Bootstrap exemption: supply == 0 mints 1:1 no matter how large the value — a first mint dilutes
    /// nobody, so the clamp has nothing to protect (1e40 over a live supply would bind hard).
    function test_ConvertToShares_ClampBootstrapExemption() public pure {
        assertEq(RoycoTestMath.convertToShares(1e40, 0, 0), 1e40, "bootstrap mints 1:1, exempt from the clamp");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            convertToValue
    //////////////////////////////////////////////////////////////////////////*/

    /// Empty-with-backing (supply == 0, totalValue > 0) values a tiny slice at 0: the redeemer's 5 shares price
    /// against the virtual-share supply, ⌊(100 + 1)·5/(0 + 1e6)⌋ = ⌊505/1e6⌋ = 0.
    function test_ConvertToValue_ZeroSupply_ReturnsZero() public pure {
        assertEq(RoycoTestMath.convertToValue(5, 100, 0), 0, "floor((100+1)*5/(0+1e6)) = 0");
    }

    /// Floor engaged (inputs rescaled to 1e18 magnitude so the virtual-shares offset is negligible and the
    /// intended flooring — dust stays with remaining holders — is still exercised):
    /// ⌊(7e18 + 1)·2e18/(3e18 + 1e6)⌋ = 4666666666665111111.
    function test_ConvertToValue_FloorRounding_FavorsRemainingHolders() public pure {
        assertEq(RoycoTestMath.convertToValue(2e18, 7e18, 3e18), 4_666_666_666_665_111_111, "floor((7e18+1)*2e18/(3e18+1e6))");
    }

    /// Full supply (shares == supply) no longer redeems the whole pot: the virtual-share sliver stays behind.
    /// Rescaled to 1e18 magnitude, ⌊(7e18 + 1)·3e18/(3e18 + 1e6)⌋ = 6999999999997666667, leaving a 2333333-wei
    /// virtual-dust sliver of the 7e18 pot with the remaining (virtual) holders.
    function test_ConvertToValue_FullSupply_Exact() public pure {
        assertEq(
            RoycoTestMath.convertToValue(3e18, 7e18, 3e18),
            6_999_999_999_997_666_667,
            "full exit leaves the virtual-share sliver: floor((7e18+1)*3e18/(3e18+1e6))"
        );
    }

    /// Zero shares are worth zero, and a live supply over zero NAV is worth zero.
    function test_ConvertToValue_ZeroShares_AndZeroNav_ReturnZero() public pure {
        assertEq(RoycoTestMath.convertToValue(0, 1e30, 5), 0, "floor((1e30+1)*0/(5+1e6)) = 0");
        assertEq(RoycoTestMath.convertToValue(3, 0, 7), 0, "floor((0+1)*3/(7+1e6)) = 0");
    }

    /// Boundaries under the offset: a 1e18 share of a 1e30 tranche recovers ⌊(1e30 + 1)·1e18/(1e30 + 1e6)⌋ = 1e18 − 1
    /// (one wei short — the virtual-share sliver), and the full max slice ⌊(1e30 + 1)·1e30/(1e30 + 1e6)⌋ =
    /// 999999999999999999999999000001 sits just below par at scale.
    function test_ConvertToValue_Boundaries() public pure {
        assertEq(RoycoTestMath.convertToValue(1e18, 1e30, 1e30), 999_999_999_999_999_999, "floor((1e30+1)*1e18/(1e30+1e6)) = 1e18 - 1");
        assertEq(RoycoTestMath.convertToValue(MAX_NAV, MAX_NAV, MAX_NAV), 999_999_999_999_999_999_999_999_000_001, "floor((1e30+1)*1e30/(1e30+1e6))");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    computeSTFeeAndLiquidityPremiumSharesToMint
    //////////////////////////////////////////////////////////////////////////*/

    /// Near-clean division: the base ratios divide evenly (30e18, 20e18) but each leg is a convertToShares mint over
    /// the virtual-shares offset, so each is lifted by a small floored residual.
    ///   retained      = 1050e18 − 30e18 − 20e18 = 1000e18
    ///   premiumShares = ⌊(1000e18 + 1e6)·30e18/(1000e18 + 1)⌋ = 30000000000000029999
    ///   feeShares     = ⌊(1000e18 + 1e6)·20e18/(1000e18 + 1)⌋ = 20000000000000019999
    ///   supplyAfter   = 1000e18 + premiumShares + feeShares  = 1050000000000000049998
    function test_ComputeSTFeeAndLiquidityPremiumSharesToMint_CleanDivision() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) =
            RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(1050e18, 30e18, 20e18, 1000e18);
        assertEq(premiumShares, 30_000_000_000_000_029_999, "floor((1000e18+1e6)*30e18/(1000e18+1))");
        assertEq(feeShares, 20_000_000_000_000_019_999, "floor((1000e18+1e6)*20e18/(1000e18+1))");
        assertEq(supplyAfter, 1_050_000_000_000_000_049_998, "1000e18 + premiumShares + feeShares");
    }

    /// Floor engaged (inputs rescaled to 1e18 magnitude so the virtual-shares offset no longer swamps the ratio;
    /// each leg floors toward the pre-existing ST holders):
    ///   retained      = 10e18 − 3e18 − 2e18 = 5e18
    ///   premiumShares = ⌊(3e18 + 1e6)·3e18/(5e18 + 1)⌋ = 1800000000000599999
    ///   feeShares     = ⌊(3e18 + 1e6)·2e18/(5e18 + 1)⌋ = 1200000000000399999
    ///   supplyAfter   = 3e18 + premiumShares + feeShares = 6000000000000999998
    function test_ComputeSTFeeAndLiquidityPremiumSharesToMint_FloorRounding_FavorsPreExistingST() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(10e18, 3e18, 2e18, 3e18);
        assertEq(premiumShares, 1_800_000_000_000_599_999, "floor((3e18+1e6)*3e18/(5e18+1))");
        assertEq(feeShares, 1_200_000_000_000_399_999, "floor((3e18+1e6)*2e18/(5e18+1))");
        assertEq(supplyAfter, 6_000_000_000_000_999_998, "3e18 + premiumShares + feeShares");
    }

    /// A degenerate mint consuming all of stEffectiveNAV routes through convertToShares's 1-wei denominator
    /// (retained + VIRTUAL_VALUE = 0 + 1) at effective supply 100 + 1e6:
    ///   retained = 10 − 7 − 3 = 0 ⇒ premiumShares = ⌊(100 + 1e6)·7/1⌋ = 7000700, feeShares = ⌊(100 + 1e6)·3/1⌋ = 3000300.
    function test_ComputeSTFeeAndLiquidityPremiumSharesToMint_RetainedZero_OneWeiDenominator() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(10, 7, 3, 100);
        assertEq(premiumShares, 7_000_700, "floor((100+1e6)*7/1) = 7000700");
        assertEq(feeShares, 3_000_300, "floor((100+1e6)*3/1) = 3000300");
        assertEq(supplyAfter, 10_001_100, "100 + 7000700 + 3000300");
    }

    /// Pre-sync supply 0 mints 1:1 ONLY through convertToShares' genuinely-fresh branch (supply == 0 AND
    /// totalValue == 0): the virtual-shares offset narrowed the exemption, so a 1:1 first mint now also requires
    /// retained == 0. With stEffectiveNAV = premium + fee = 50, retained = 50 − 30 − 20 = 0, both legs mint 1:1.
    function test_ComputeSTFeeAndLiquidityPremiumSharesToMint_ZeroPreSupply_MintsOneToOne() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(50, 30, 20, 0);
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

    /// Max realistic (clamp inert): retained = 1e30 − 5e29 = 5e29, a 100%-of-retained premium nearly doubles the
    /// supply, lifted by the virtual-shares residual:
    ///   premiumShares = ⌊(1e30 + 1e6)·5e29/(5e29 + 1)⌋ = 1000000000000000000000000999997
    ///   supplyAfter   = 1e30 + premiumShares                = 2000000000000000000000000999997
    function test_ComputeSTFeeAndLiquidityPremiumSharesToMint_MaxRealistic() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(1e30, 5e29, 0, 1e30);
        assertEq(premiumShares, 1_000_000_000_000_000_000_000_000_999_997, "floor((1e30+1e6)*5e29/(5e29+1))");
        assertEq(feeShares, 0, "no fee");
        assertEq(supplyAfter, 2_000_000_000_000_000_000_000_000_999_997, "1e30 + premiumShares");
    }

    /// Degenerate mint under the clamp: retained = 0 pins the 1-wei denominator, both legs bind and each clamps to
    /// cap = ⌊(1e18 + 1e6)·(1e18 − 1e6)/1e6⌋ = 1e30 − 1e6 — the per-mint residual guarantee lifted by the virtual
    /// shares.
    function test_ComputeSTFeeAndLiquidityPremiumSharesToMint_RetainedZero_ClampsBothLegsToCap() public pure {
        (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter) = RoycoTestMath.computeSTFeeAndLiquidityPremiumSharesToMint(10e18, 4e18, 6e18, 1e18);
        assertEq(premiumShares, 1e30 - 1e6, "premium leg clamps to the cap = (1e18+1e6)*(1e18-1e6)/1e6");
        assertEq(feeShares, 1e30 - 1e6, "fee leg clamps to the same cap");
        assertEq(supplyAfter, 1e18 + 2 * (1e30 - 1e6), "supply identity across two capped mints");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                scaleClaims
    //////////////////////////////////////////////////////////////////////////*/

    /// All four fields floor independently. The redeemer's slice (shares 2e18 of a 3e18 tranche, rescaled from
    /// wei so the virtual-shares offset does not swamp the ratio) prices against effective supply 3e18 + 1e6:
    ///   ⌊10·2e18/(3e18+1e6)⌋ = 6, ⌊7·2e18/(3e18+1e6)⌋ = 4,
    ///   ⌊3·2e18/(3e18+1e6)⌋ = 1 (the exact 6/3 = 2 is dropped to 1 by the virtual-share sliver),
    ///   ⌊11·2e18/(3e18+1e6)⌋ = 7.
    function test_ScaleClaims_AllFourFieldsFloored() public pure {
        RoycoTestMath.Claims memory total = RoycoTestMath.Claims({ collateralAssets: 10, ltAssets: 7, stShares: 3, nav: 11 });
        RoycoTestMath.Claims memory scaled = RoycoTestMath.scaleClaims(total, 2e18, 3e18);
        assertEq(scaled.collateralAssets, 6, "floor(10*2e18/(3e18+1e6)) = 6");
        assertEq(scaled.ltAssets, 4, "floor(7*2e18/(3e18+1e6)) = 4");
        assertEq(scaled.stShares, 1, "floor(3*2e18/(3e18+1e6)) = 1");
        assertEq(scaled.nav, 7, "floor(11*2e18/(3e18+1e6)) = 7");
    }

    /// Full shares (shares == totalShares) is NO LONGER the identity under the virtual-shares offset: each field
    /// leaves a virtual-dust sliver behind. With shares == totalShares == 1e18 (effective supply 1e18 + 1e6),
    /// scaled = ⌊field·1e18/(1e18 + 1e6)⌋ = field − field/1e12, so each field drops exactly field/1e12 wei
    /// (1e6, 2e6, 3e6, 4e6 respectively).
    function test_ScaleClaims_FullShares_Identity() public pure {
        RoycoTestMath.Claims memory total = RoycoTestMath.Claims({ collateralAssets: 1e18, ltAssets: 2e18, stShares: 3e18, nav: 4e18 });
        RoycoTestMath.Claims memory scaled = RoycoTestMath.scaleClaims(total, 1e18, 1e18);
        assertEq(scaled.collateralAssets, 999_999_999_999_000_000, "floor(1e18*1e18/(1e18+1e6)) = 1e18 - 1e6");
        assertEq(scaled.ltAssets, 1_999_999_999_998_000_000, "floor(2e18*1e18/(1e18+1e6)) = 2e18 - 2e6");
        assertEq(scaled.stShares, 2_999_999_999_997_000_000, "floor(3e18*1e18/(1e18+1e6)) = 3e18 - 3e6");
        assertEq(scaled.nav, 3_999_999_999_996_000_000, "floor(4e18*1e18/(1e18+1e6)) = 4e18 - 4e6");
    }

    /// Zero shares scale every field to zero.
    function test_ScaleClaims_ZeroShares_AllZero() public pure {
        RoycoTestMath.Claims memory total = RoycoTestMath.Claims({ collateralAssets: 1e30, ltAssets: 1e30, stShares: 1e30, nav: 1e30 });
        RoycoTestMath.Claims memory scaled = RoycoTestMath.scaleClaims(total, 0, 1e30);
        assertEq(scaled.collateralAssets, 0, "zero slice collateralAssets");
        assertEq(scaled.ltAssets, 0, "zero slice ltAssets");
        assertEq(scaled.stShares, 0, "zero slice stShares");
        assertEq(scaled.nav, 0, "zero slice nav");
    }

    /// Max realistic: a lone 1-wei slice of a 1e30 tranche now floors to 0 (swallowed by the virtual-share
    /// sliver), so the minimal slice that still recovers 1 wei per field is 2 shares:
    /// ⌊1e30·2/(1e30 + 1e6)⌋ = 1 (the offset raises the minimal value-recovering slice from 1 to 2).
    function test_ScaleClaims_MaxRealistic_OneWeiSlice() public pure {
        RoycoTestMath.Claims memory total = RoycoTestMath.Claims({ collateralAssets: 1e30, ltAssets: 1e30, stShares: 1e30, nav: 1e30 });
        RoycoTestMath.Claims memory scaled = RoycoTestMath.scaleClaims(total, 2, 1e30);
        assertEq(scaled.collateralAssets, 1, "floor(1e30*2/(1e30+1e6)) = 1");
        assertEq(scaled.ltAssets, 1, "floor(1e30*2/(1e30+1e6)) = 1");
        assertEq(scaled.stShares, 1, "floor(1e30*2/(1e30+1e6)) = 1");
        assertEq(scaled.nav, 1, "floor(1e30*2/(1e30+1e6)) = 1");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        getLiquidityTrancheEffectiveNAV
    //////////////////////////////////////////////////////////////////////////*/

    /// No idle shares: effective NAV is the pool leg alone.
    function test_GetLiquidityTrancheEffectiveNAV_NoIdleShares_EqualsLtRaw() public pure {
        assertEq(RoycoTestMath.getLiquidityTrancheEffectiveNAV(100e18, 0, 500e18, 1000e18), 100e18, "pure BPT state");
    }

    /// Idle valuation over the offset: the idle leg is a convertToValue mint priced against effective supply
    /// 1000e18 + 1e6, so 100e18 + ⌊(2000e18 + 1)·10e18/(1000e18 + 1e6)⌋ = 100e18 + 19999999999999980000
    /// = 119999999999999980000 (just under the pre-offset 120e18).
    function test_GetLiquidityTrancheEffectiveNAV_CleanIdleValuation() public pure {
        assertEq(
            RoycoTestMath.getLiquidityTrancheEffectiveNAV(100e18, 10e18, 2000e18, 1000e18),
            119_999_999_999_999_980_000,
            "ltRawNAV + floor((2000e18+1)*10e18/(1000e18+1e6))"
        );
    }

    /// Floor on the idle leg (inputs rescaled to 1e18 magnitude so the offset is negligible and the floor still
    /// favors the pool leg): 5e18 + ⌊(7e18 + 1)·3e18/(2e18 + 1e6)⌋ = 5e18 + 10499999999994750001
    /// = 15499999999994750001.
    function test_GetLiquidityTrancheEffectiveNAV_FloorRounding_FavorsPoolLeg() public pure {
        assertEq(RoycoTestMath.getLiquidityTrancheEffectiveNAV(5e18, 3e18, 7e18, 2e18), 15_499_999_999_994_750_001, "5e18 + floor((7e18+1)*3e18/(2e18+1e6))");
    }

    /// A genuinely fresh ST tranche (stSupply == 0 AND stEffectiveNAV == 0) values the idle leg at 0, so effective
    /// NAV falls back to ltRawNAV. (Under the offset a live stEffectiveNAV with zero supply is empty-with-backing
    /// and would instead be priced, so the fresh case now requires stEffectiveNAV == 0.)
    function test_GetLiquidityTrancheEffectiveNAV_ZeroStSupply_IdleLegIsZero() public pure {
        assertEq(RoycoTestMath.getLiquidityTrancheEffectiveNAV(42, 999, 0, 0), 42, "idle leg zero at genuinely fresh ST tranche");
    }

    /// Zero pool leg with staged premium only (inputs rescaled to 1e18 magnitude so the offset is negligible):
    /// 0 + ⌊(7e18 + 1)·3e18/(2e18 + 1e6)⌋ = 10499999999994750001.
    function test_GetLiquidityTrancheEffectiveNAV_ZeroLtRaw_IdleLegOnly() public pure {
        assertEq(RoycoTestMath.getLiquidityTrancheEffectiveNAV(0, 3e18, 7e18, 2e18), 10_499_999_999_994_750_001, "floor((7e18+1)*3e18/(2e18+1e6))");
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
     * The last collateral NAV is derived as stEffectiveNAVLast + jtEffectiveNAVLast, the conservation
     * precondition every reachable checkpoint satisfies.
     */
    function _syncInputs(
        uint256 stEffectiveNAVLast,
        uint256 jtEffectiveNAVLast,
        uint256 il,
        RoycoTestMath.MarketState stateLast,
        uint256 endLast,
        uint256 dust,
        int256 collateralNAVDelta
    )
        private
        pure
        returns (RoycoTestMath.SyncInputs memory in_)
    {
        in_.collateralNAVLast = stEffectiveNAVLast + jtEffectiveNAVLast;
        in_.stEffectiveNAVLast = stEffectiveNAVLast;
        in_.jtEffectiveNAVLast = jtEffectiveNAVLast;
        in_.jtImpermanentLossLast = il;
        in_.marketStateLast = stateLast;
        in_.fixedTermEndTimestampLast = endLast;
        in_.collateralNAVDelta = collateralNAVDelta;
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
        in_.dustTolerance = dust;
        in_.minLiquidityWAD = 0.05e18;
    }

    /// Field-exact comparison of a computed SyncOutputs against a hand-built expected literal, plus the
    /// standing state-machine invariant: a PERPETUAL commit carries zero IL and a FIXED_TERM commit never does.
    function _assertSyncOutputs(RoycoTestMath.SyncOutputs memory actual, RoycoTestMath.SyncOutputs memory expected) private pure {
        assertEq(
            actual.marketState == RoycoTestMath.MarketState.PERPETUAL, actual.jtImpermanentLoss == 0, "standing invariant: PERPETUAL iff zero jtImpermanentLoss"
        );
        assertEq(actual.collateralNAV, expected.collateralNAV, "collateralNAV");
        assertEq(actual.ltRawNAV, expected.ltRawNAV, "ltRawNAV");
        assertEq(actual.stEffectiveNAV, expected.stEffectiveNAV, "stEffectiveNAV");
        assertEq(actual.jtEffectiveNAV, expected.jtEffectiveNAV, "jtEffectiveNAV");
        assertEq(actual.jtImpermanentLoss, expected.jtImpermanentLoss, "jtImpermanentLoss");
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
     * A shared gain lands on both tranches through the single-delta attribution, so the JT fee takes both
     * parts (own attributed gain plus risk premium) and the premiums resolve through the instantaneous
     * branch. Pins the full up-path fee and premium plumbing.
     * Checkpoint (stEffectiveNAV/jtEffectiveNAV): 1000e18/200e18 (collateral 1200e18), IL 0, dust 0, PERPETUAL.
     * Delta +60e18.
     *   Attribution: deltaSTEff = ⌊60e18·1000e18/1200e18⌋ = 50e18 exact, deltaJTEff = 60e18 − 50e18 = 10e18.
     *   JT leg: jtGain 10e18 > dust 0 ⇒ jtFee = ⌊10e18·0.1⌋ = 1e18, jtEffectiveNAV = 210e18.
     *   ST gain leg: stGain 50e18, no IL. premiumsPaid (50e18 > 0). Instantaneous (elapsed forced 1):
     *     jtPrem = ⌊50e18·0.1e18/(1·1e18)⌋ = 5e18, ltPrem = ⌊50e18·0.05e18/1e18⌋ = 2.5e18 (7.5e18 <= 50e18 ok).
     *     jtFee += ⌊5e18·0.1⌋ = 0.5e18 ⇒ 1.5e18 total, jtEffectiveNAV = 215e18, ltFee = ⌊2.5e18·0.1⌋ = 0.25e18.
     *     Residual 50e18 − 5e18 − 2.5e18 = 42.5e18 ⇒ stFee = 4.25e18, stEffectiveNAV = 1000e18 + 42.5e18 + 2.5e18 = 1045e18.
     *   Conservation 1260 = 1045 + 215 (e18). IL 0 ⇒ PERPETUAL.
     *   coverageUtilizationWAD = ⌈1260e18·0.1e18/215e18⌉ = ⌈586046511627906976.74⌉ = 586046511627906977.
     *   liquidityUtilizationWAD = ⌈1045e18·0.05e18/100e18⌉ = 5.225e17 exact.
     */
    function test_SyncTrancheAccounting_SharedGain_BothJtFeeParts_InstantaneousPremium() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 60e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1260e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1045e18;
        expected.jtEffectiveNAV = 215e18;
        expected.jtImpermanentLoss = 0;
        expected.jtRiskPremium = 5e18;
        expected.ltLiquidityPremium = 2.5e18;
        expected.stProtocolFee = 4.25e18;
        expected.jtProtocolFee = 1.5e18;
        expected.ltProtocolFee = 0.25e18;
        expected.coverageUtilizationWAD = 586_046_511_627_906_977;
        expected.liquidityUtilizationWAD = 522_500_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.fixedTermEndTimestamp = 0;
        expected.premiumsPaid = true;
        expected.ilErased = 0;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A shared loss splits across both legs and the ST leg is fully covered by the junior buffer, so the
     * whole drawdown lands as JT IL while stEffectiveNAV never moves, entering FIXED_TERM.
     * (Mixed-sign ST/JT deltas are unrepresentable under one collateral asset at one rate, so the old
     * ST-loss-with-JT-gain fee-recompute vector has no reachable analogue and no fee recompute exists.)
     * Checkpoint (stEffectiveNAV/jtEffectiveNAV): 1000e18/200e18 (collateral 1200e18), IL 0, dust 0, PERPETUAL.
     * Delta −60e18.
     *   Attribution: deltaSTEff = −⌊60e18·1000e18/1200e18⌋ = −50e18 exact, deltaJTEff = −10e18.
     *   JT leg: loss 10e18 ⇒ jtEffectiveNAV 190e18, IL 10e18 (no fee on a loss).
     *   ST loss leg: stLoss 50e18, coverage = min(50e18, 190e18) = 50e18 ⇒ jtEffectiveNAV = 140e18,
     *   IL = 60e18, residual 0 so stEffectiveNAV unchanged 1000e18.
     *   Conservation 1140 = 1000 + 140 (e18). IL 60e18 > dust 0, no perpetual disjunct ⇒ FIXED_TERM entry
     *   from PERPETUAL: end = T0 + D, no fees were booked (the fee theorem holds trivially on a loss).
     *   coverageUtilizationWAD = ⌈1140e18·0.1e18/140e18⌉ = ⌈814285714285714285.71⌉ = 814285714285714286.
     *   liquidityUtilizationWAD = ⌈1000e18·0.05e18/100e18⌉ = 5e17.
     */
    function test_SyncTrancheAccounting_SharedLoss_CoverageAbsorbsSTLeg_FixedTermEntry() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, -60e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1140e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18;
        expected.jtEffectiveNAV = 140e18;
        expected.jtImpermanentLoss = 60e18;
        expected.coverageUtilizationWAD = 814_285_714_285_714_286;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEndTimestamp = T0 + DURATION;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A dead-ST market (stEffectiveNAV 0) routes the whole delta to JT through the attribution's zero-claim
     * guard, and the JT fee it books survives the PERPETUAL commit: fee zeroing belongs to FIXED_TERM
     * commits only, so a healthy market never drops an earned fee.
     * Checkpoint (stEffectiveNAV/jtEffectiveNAV): 0/200e18 (collateral 200e18), IL 0, dust 0, PERPETUAL.
     * Delta +20e18: deltaSTEff = 0 (claim 0), deltaJTEff = +20e18 ⇒ jtFee = 2e18, jtEffectiveNAV = 220e18,
     * no ST leg runs. Conservation 220 = 0 + 220 (e18). IL 0 ⇒ PERPETUAL.
     * coverageUtilizationWAD = ⌈220e18·0.1e18/220e18⌉ = 1e17 exact.
     * liquidityUtilizationWAD = 0 (the stEffectiveNAV zero edge).
     */
    function test_SyncTrancheAccounting_DeadSTZeroClaim_DeltaRoutesToJT_FeeSurvivesPerpetual() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(0, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 20e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 220e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 0;
        expected.jtEffectiveNAV = 220e18;
        expected.jtProtocolFee = 2e18;
        expected.coverageUtilizationWAD = 100_000_000_000_000_000;
        expected.liquidityUtilizationWAD = 0;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A loss past JT exhaustion wipes the junior buffer out, which forces PERPETUAL and erases the IL: an
     * uncovered loss can never land the market in FIXED_TERM, because the wipeout disjunct always fires first.
     * Checkpoint (stEffectiveNAV/jtEffectiveNAV): 1000e18/200e18 (collateral 1200e18), IL 0, dust 0, PERPETUAL.
     * Delta −300e18: deltaSTEff = −250e18 exact, deltaJTEff = −50e18.
     * JT leg: jtEffectiveNAV 150e18, IL 50e18. ST loss leg: stLoss 250e18, coverage = min(250e18, 150e18)
     * = 150e18 ⇒ jtEffectiveNAV 0, IL 200e18, residual 100e18 ⇒ stEffectiveNAV 900e18.
     * coverageUtilizationWAD = uint256 max (jtEffectiveNAV 0 against a live collateral NAV), which also
     * satisfies the liquidation disjunct. Forced PERPETUAL: ilErased = 200e18, IL = 0, end 0.
     * Conservation 900 = 900 + 0. liquidityUtilizationWAD = ⌈900e18·0.05e18/100e18⌉ = 4.5e17.
     */
    function test_SyncTrancheAccounting_LossPastJtExhaustion_WipeoutErasesIL() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, -300e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 900e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 900e18;
        expected.jtEffectiveNAV = 0;
        expected.jtImpermanentLoss = 0;
        expected.coverageUtilizationWAD = type(uint256).max;
        expected.liquidityUtilizationWAD = 450_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.ilErased = 200e18;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * Exhaustion exactly at the boundary: the loss is fully covered but the junior buffer empties to zero,
     * so senior keeps its full effective NAV while the wipeout disjunct still fires. Distinguishes the
     * covered-boundary case from the residual-loss wipeout above, and pins the loss-side floor: the ST
     * magnitude floors so JT's residual loss is the larger part.
     * Checkpoint (stEffectiveNAV/jtEffectiveNAV): 1000e18/200e18 (collateral 1200e18), IL 0, dust 0, PERPETUAL.
     * Delta −200e18 (= −jtEffectiveNAVLast, the algebraic boundary: the post-JT-leg buffer equals the ST loss):
     *   deltaSTEff = −⌊200e18·1000e18/1200e18⌋ = −166666666666666666666 (⌊166.66…⌋, floor favors seniors),
     *   deltaJTEff = −33333333333333333334 (JT absorbs the residual).
     *   JT leg: jtEffectiveNAV = 166666666666666666666, IL = 33333333333333333334.
     *   ST loss leg: stLoss 166666666666666666666 == jtEffectiveNAV ⇒ coverage empties the buffer exactly,
     *   jtEffectiveNAV 0, IL 200e18, residual 0, stEffectiveNAV intact at 1000e18.
     *   Conservation 1000 = 1000 + 0. Wipeout disjunct ⇒ PERPETUAL, ilErased 200e18.
     *   liquidityUtilizationWAD = ⌈1000e18·0.05e18/100e18⌉ = 5e17.
     */
    function test_SyncTrancheAccounting_ExhaustionAtBoundary_StEffectiveNAVIntact() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, -200e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1000e18;
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
     * A flat sync (zero delta) on a FIXED_TERM market whose IL has already cleared exits back to PERPETUAL:
     * the pure state-machine transition, with no sync leg running and nothing erased.
     * Checkpoint: stEffectiveNAV 1000e18, jtEffectiveNAV 200e18−1 (collateral 1200e18−1), IL 0, dust 0,
     * FIXED_TERM, end T0+D. Zero delta runs no sync legs. IL == 0 with initial FIXED_TERM ⇒
     * PERPETUAL, end deleted, no IL erased.
     * coverageUtilizationWAD = ⌈(1200e18−1)·0.1e18/(200e18−1)⌉ = 600000000000000001 (remainder 5e17 forces
     * the ceil past the exact 6e17). liquidityUtilizationWAD = 5e17.
     */
    function test_SyncTrancheAccounting_FlatSync_ExitsFixedTerm() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18 - 1, 0, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 0);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1200e18 - 1;
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
     * A gain that recovers the whole carried IL through both legs then pays premiums exits FIXED_TERM with
     * premiums and fees intact, pinning that the exit commit does not zero fees the way a FIXED_TERM commit does.
     * Checkpoint: stEffectiveNAV 1000e18, jtEffectiveNAV 180e18 (collateral 1180e18), IL 20e18, dust 0,
     * FIXED_TERM, end T0+D. Delta +59e18:
     *   Attribution: deltaSTEff = ⌊59e18·1000e18/1180e18⌋ = 50e18 exact, deltaJTEff = 9e18.
     *   JT leg: recovery = min(9e18, 20e18) = 9e18 ⇒ IL 11e18, jtEffectiveNAV 189e18, residual 0 so no fee.
     *   ST gain leg: recovery = min(50e18, 11e18) = 11e18 ⇒ IL 0, jtEffectiveNAV 200e18, stGain 39e18.
     *   jtPrem = ⌊39e18·0.1⌋ = 3.9e18, ltPrem = ⌊39e18·0.05⌋ = 1.95e18,
     *   jtFee = 0.39e18, ltFee = 0.195e18, residual 39e18 − 3.9e18 − 1.95e18 = 33.15e18 ⇒ stFee = 3.315e18,
     *   stEffectiveNAV = 1000e18 + 33.15e18 + 1.95e18 = 1035.1e18, jtEffectiveNAV = 200e18 + 3.9e18 = 203.9e18.
     *   Conservation 1239 = 1035.1 + 203.9 (e18). IL 0 ⇒ PERPETUAL exit (premiums imply PERPETUAL), end 0.
     *   coverageUtilizationWAD = ⌈1239e18·0.1e18/203.9e18⌉ = 607650809220205984.
     *   liquidityUtilizationWAD = ⌈1035.1e18·0.05e18/100e18⌉ = 517550000000000000 exact.
     */
    function test_SyncTrancheAccounting_GainRecoversILThenPremiums_ExitsFixedTerm() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 180e18, 20e18, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 59e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1239e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1035.1e18;
        expected.jtEffectiveNAV = 203.9e18;
        expected.jtRiskPremium = 3.9e18;
        expected.ltLiquidityPremium = 1.95e18;
        expected.stProtocolFee = 3.315e18;
        expected.jtProtocolFee = 0.39e18;
        expected.ltProtocolFee = 0.195e18;
        expected.coverageUtilizationWAD = 607_650_809_220_205_984;
        expected.liquidityUtilizationWAD = 517_550_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A gain first recovers the dust-sized IL in full, then pays premiums whose inputs carry awkward wei
     * offsets, pinning every floor in the premium chain at once.
     * Checkpoint: stEffectiveNAV 1000e18+5, jtEffectiveNAV 200e18−5 (collateral 1200e18), IL 5, dust 7,
     * PERPETUAL. Delta +(60e18−7):
     *   Attribution: deltaSTEff = ⌊(60e18−7)·(1000e18+5)/1200e18⌋ = 50e18−6, deltaJTEff = 10e18−1.
     *   JT leg: recovery = min(10e18−1, 5) = 5 ⇒ IL 0, jtEffectiveNAV 200e18, residual 10e18−6 > dust 7
     *   ⇒ jtFee = ⌊(10e18−6)·0.1⌋ = 1e18−1, jtEffectiveNAV = 210e18−6.
     *   ST gain leg: stGain 50e18−6, no IL left. premiumsPaid (> 7).
     *   jtPrem = ⌊(50e18−6)·0.1⌋ = 5e18−1, ltPrem = ⌊(50e18−6)·0.05⌋ = 2.5e18−1,
     *   jtFee += ⌊(5e18−1)·0.1⌋ = 0.5e18−1 ⇒ 1.5e18−2 total, jtEffectiveNAV = 215e18−7,
     *   ltFee = ⌊(2.5e18−1)·0.1⌋ = 0.25e18−1, residual (50e18−6)−(5e18−1)−(2.5e18−1) = 42.5e18−4,
     *   stFee = ⌊(42.5e18−4)·0.1⌋ = 4.25e18−1, stEffectiveNAV = (1000e18+5) + (42.5e18−4) + (2.5e18−1) = 1045e18.
     *   Conservation 1260e18−7 = 1045e18 + (215e18−7). IL 0 ⇒ PERPETUAL.
     *   coverageUtilizationWAD = ⌈(1260e18−7)·0.1e18/(215e18−7)⌉ = 586046511627906977.
     *   liquidityUtilizationWAD = ⌈1045e18·0.05e18/100e18⌉ = 522500000000000000 exact.
     */
    function test_SyncTrancheAccounting_DustIL_RecoveryThenAwkwardPremiumFloors() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18 + 5, 200e18 - 5, 5, RoycoTestMath.MarketState.PERPETUAL, 0, 7, 60e18 - 7);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1260e18 - 7;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1045e18;
        expected.jtEffectiveNAV = 215e18 - 7;
        expected.jtRiskPremium = 5e18 - 1;
        expected.ltLiquidityPremium = 2.5e18 - 1;
        expected.stProtocolFee = 4.25e18 - 1;
        expected.jtProtocolFee = 1.5e18 - 2;
        expected.ltProtocolFee = 0.25e18 - 1;
        expected.coverageUtilizationWAD = 586_046_511_627_906_977;
        expected.liquidityUtilizationWAD = 522_500_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * Dust-IL FIXED_TERM stickiness, the pure case: with a zero delta and an IL of 5 wei inside the dust
     * tolerance of 7, an initially FIXED_TERM market stays FIXED_TERM with its ORIGINAL end — dust-sized IL
     * never silently releases a term.
     * Checkpoint: stEffectiveNAV 1000e18, jtEffectiveNAV 200e18−5 (collateral 1200e18−5), IL 5, dust 7,
     * FIXED_TERM, end T0+D. coverageUtilizationWAD = ⌈(1200e18−5)·0.1e18/(200e18−5)⌉ = 600000000000000001
     * (the −5 offsets leave a fractional part).
     */
    function test_SyncTrancheAccounting_DustIL_FixedTermStickiness() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18 - 5, 5, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 7, 0);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1200e18 - 5;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18;
        expected.jtEffectiveNAV = 200e18 - 5;
        expected.jtImpermanentLoss = 5;
        expected.coverageUtilizationWAD = 600_000_000_000_000_001;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEndTimestamp = T0 + DURATION;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * The JT residual leg recovers the dust-sized IL to exactly zero, exiting the term: the PERPETUAL branch
     * does not zero fees, so the residual gain's JT fee and the premium block's fees survive the exit.
     * Checkpoint: stEffectiveNAV 1000e18, jtEffectiveNAV 200e18−5 (collateral 1200e18−5), IL 5, dust 7,
     * FIXED_TERM, end T0+D. Delta +24e18:
     *   Attribution: deltaSTEff = ⌊24e18·1000e18/(1200e18−5)⌋ = 20e18 exact, deltaJTEff = 4e18.
     *   JT leg: recovery = min(4e18, 5) = 5 ⇒ IL 0, jtEffectiveNAV 200e18, residual 4e18−5 > dust 7
     *   ⇒ jtFee = ⌊(4e18−5)·0.1⌋ = 0.4e18−1, jtEffectiveNAV = 204e18−5.
     *   ST gain leg: stGain 20e18, IL 0. premiumsPaid (> 7). jtPrem 2e18, ltPrem 1e18,
     *   jtFee += 0.2e18 ⇒ 0.6e18−1 total, jtEffectiveNAV = 206e18−5, ltFee 0.1e18, residual 17e18
     *   ⇒ stFee 1.7e18, stEffectiveNAV = 1000e18 + 17e18 + 1e18 = 1018e18.
     *   Conservation 1224e18−5 = 1018e18 + (206e18−5). IL 0 ⇒ PERPETUAL exit keeping the fees, end deleted.
     *   coverageUtilizationWAD = ⌈(1224e18−5)·0.1e18/(206e18−5)⌉ = 594174757281553399.
     *   liquidityUtilizationWAD = ⌈1018e18·0.05e18/100e18⌉ = 509000000000000000 exact.
     */
    function test_SyncTrancheAccounting_JtResidualRecoversDustIL_ExitsFixedTermKeepingFee() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18 - 5, 5, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 7, 24e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1224e18 - 5;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1018e18;
        expected.jtEffectiveNAV = 206e18 - 5;
        expected.jtImpermanentLoss = 0;
        expected.jtRiskPremium = 2e18;
        expected.ltLiquidityPremium = 1e18;
        expected.stProtocolFee = 1.7e18;
        expected.jtProtocolFee = 0.6e18 - 1;
        expected.ltProtocolFee = 0.1e18;
        expected.coverageUtilizationWAD = 594_174_757_281_553_399;
        expected.liquidityUtilizationWAD = 509_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.fixedTermEndTimestamp = 0;
        expected.premiumsPaid = true;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A dust-sized loss from PERPETUAL is erased at commit, not retained: the dust disjunct resolves
     * PERPETUAL, ilErased carries the ≤dust drawdown, and the follow-up gain is a PLAIN gain (fee-gated on
     * > dust as always), never a recovery. A PERPETUAL checkpoint carrying IL is unrepresentable, so the
     * erased dust must not resurface as a recovery deduction on the next sync's fee.
     * Stage 1 checkpoint: stEffectiveNAV 1000e18, jtEffectiveNAV 200e18 (collateral 1200e18), IL 0, dust 7,
     * PERPETUAL. Delta −6: deltaSTEff = −⌊6·1000e18/1200e18⌋ = −5, deltaJTEff = −1.
     * JT leg: jtEffectiveNAV 200e18−1, IL 1. ST loss leg: coverage 5 ⇒ jtEffectiveNAV 200e18−6, IL 6,
     * stEffectiveNAV unchanged. IL 6 <= dust 7 from PERPETUAL ⇒ PERPETUAL, ilErased 6, IL 0, end 0.
     * coverageUtilizationWAD = ⌈(1200e18−6)·0.1e18/(200e18−6)⌉ = 600000000000000001.
     * Stage 2, from the erased checkpoint (stEff 1000e18, jtEff 200e18−6, IL 0), delta +24e18:
     * deltaSTEff = ⌊24e18·1000e18/(1200e18−6)⌋ = 20e18 exact, deltaJTEff = 4e18. No recovery leg runs, so
     * jtFee = ⌊4e18·0.1⌋ = 0.4e18 EXACT on the full residual (a retained-recoverable IL would have shaved it),
     * plus the premium part 0.2e18 ⇒ 0.6e18. jtPrem 2e18, ltPrem 1e18, ltFee 0.1e18, stFee 1.7e18,
     * stEffectiveNAV 1018e18, jtEffectiveNAV 206e18−6, PERPETUAL, ilErased 0.
     * coverageUtilizationWAD = ⌈(1224e18−6)·0.1e18/(206e18−6)⌉ = 594174757281553399.
     */
    function test_SyncTrancheAccounting_DustLossFromPerpetual_ErasedAtCommit_NextGainIsPlain() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 7, -6);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1200e18 - 6;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18;
        expected.jtEffectiveNAV = 200e18 - 6;
        expected.jtImpermanentLoss = 0;
        expected.coverageUtilizationWAD = 600_000_000_000_000_001;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.fixedTermEndTimestamp = 0;
        expected.ilErased = 6;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);

        // Stage 2: the erased dust never resurfaces, the next gain books its fee on the FULL JT residual
        RoycoTestMath.SyncInputs memory next = _syncInputs(1000e18, 200e18 - 6, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 7, 24e18);
        RoycoTestMath.SyncOutputs memory expectedNext;
        expectedNext.collateralNAV = 1224e18 - 6;
        expectedNext.ltRawNAV = 100e18;
        expectedNext.stEffectiveNAV = 1018e18;
        expectedNext.jtEffectiveNAV = 206e18 - 6;
        expectedNext.jtRiskPremium = 2e18;
        expectedNext.ltLiquidityPremium = 1e18;
        expectedNext.stProtocolFee = 1.7e18;
        expectedNext.jtProtocolFee = 0.6e18;
        expectedNext.ltProtocolFee = 0.1e18;
        expectedNext.coverageUtilizationWAD = 594_174_757_281_553_399;
        expectedNext.liquidityUtilizationWAD = 509_000_000_000_000_000;
        expectedNext.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expectedNext.premiumsPaid = true;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(next), expectedNext);
    }

    /**
     * A further shared loss on a checkpoint already carrying IL deepens the drawdown through both legs while
     * the covered ST leg leaves stEffectiveNAV untouched: the IL grows by the full collateral drawdown, JT's
     * residual loss share plus the coverage applied to the ST leg.
     * Checkpoint: stEffectiveNAV 1000e18, jtEffectiveNAV 200e18 (collateral 1200e18), IL 100e18, dust 0,
     * FIXED_TERM, end T0+D. Delta −24e18:
     *   Attribution: deltaSTEff = −20e18 exact, deltaJTEff = −4e18.
     *   JT leg: jtEffectiveNAV 196e18, IL 104e18.
     *   ST loss leg: coverage = min(20e18, 196e18) = 20e18 ⇒ jtEffectiveNAV 176e18, IL 124e18,
     *   stEffectiveNAV unchanged.
     *   Conservation 1176 = 1000 + 176 (e18). FIXED_TERM stays, end kept.
     *   coverageUtilizationWAD = ⌈1176e18·0.1e18/176e18⌉ = ⌈668181818181818181.82⌉ = 668181818181818182.
     */
    function test_SyncTrancheAccounting_SharedLossOnCarriedIL_DeepensILWhileSTFullyCovered() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 100e18, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, -24e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1176e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18;
        expected.jtEffectiveNAV = 176e18;
        expected.jtImpermanentLoss = 124e18;
        expected.coverageUtilizationWAD = 668_181_818_181_818_182;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEndTimestamp = T0 + DURATION;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A gain fully consumed by partial IL recovery: every wei of both legs' gain repays coverage debt, so the
     * premium block never runs and the premium accumulators do not reset.
     * Checkpoint: stEffectiveNAV 1000e18, jtEffectiveNAV 200e18 (collateral 1200e18), IL 100e18, dust 0,
     * FIXED_TERM, end T0+D. Delta +24e18:
     *   Attribution: deltaSTEff = 20e18 exact, deltaJTEff = 4e18.
     *   JT leg: recovery = min(4e18, 100e18) = 4e18 ⇒ IL 96e18, jtEffectiveNAV 204e18, residual 0 so no fee.
     *   ST gain leg: recovery = min(20e18, 96e18) = 20e18 ⇒ IL 76e18, jtEffectiveNAV 224e18, stGain = 0
     *   ⇒ premium block skipped, premiumsPaid false. stEffectiveNAV 1000e18. FIXED_TERM stays, end kept.
     *   Conservation 1224 = 1000 + 224 (e18).
     *   coverageUtilizationWAD = ⌈1224e18·0.1e18/224e18⌉ = ⌈546428571428571428.57⌉ = 546428571428571429.
     */
    function test_SyncTrancheAccounting_GainFullyConsumedByPartialRecovery() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 100e18, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 24e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1224e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18;
        expected.jtEffectiveNAV = 224e18;
        expected.jtImpermanentLoss = 76e18;
        expected.coverageUtilizationWAD = 546_428_571_428_571_429;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.FIXED_TERM;
        expected.fixedTermEndTimestamp = T0 + DURATION;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A gain exactly equal to the IL sits on the recovery boundary: recovery consumes all of it, no premiums
     * pay, premiumsPaid stays false, and the now-IL-free market exits FIXED_TERM.
     * Checkpoint: stEffectiveNAV 1000e18, jtEffectiveNAV 200e18 (collateral 1200e18), IL 24e18, dust 0,
     * FIXED_TERM, end T0+D. Delta +24e18: deltaSTEff = 20e18, deltaJTEff = 4e18.
     * JT leg: recovery 4e18 ⇒ IL 20e18, jtEffectiveNAV 204e18. ST gain leg: recovery = min(20e18, 20e18)
     * = 20e18 ⇒ IL 0, jtEffectiveNAV 224e18, stGain 0 ⇒ premium block skipped.
     * IL 0 with initial FIXED_TERM ⇒ PERPETUAL, end 0. Conservation 1224 = 1000 + 224 (e18).
     * coverageUtilizationWAD = ⌈1224e18·0.1e18/224e18⌉ = 546428571428571429.
     */
    function test_SyncTrancheAccounting_GainExactlyEqualsIL_NoPremiums() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 24e18, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 24e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1224e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18;
        expected.jtEffectiveNAV = 224e18;
        expected.coverageUtilizationWAD = 546_428_571_428_571_429;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * A gain whose recovery leaves exactly 1 wei of senior gain: premiumsPaid fires TRUE while every premium
     * and fee floors to 0, pinning that even a 1-wei paid sync resets the premium accumulators.
     * Checkpoint: stEffectiveNAV 1000e18, jtEffectiveNAV 200e18 (collateral 1200e18), IL 24e18−1, dust 0,
     * FIXED_TERM, end T0+D. Delta +24e18: deltaSTEff = 20e18, deltaJTEff = 4e18.
     * JT leg: recovery = min(4e18, 24e18−1) = 4e18 ⇒ IL 20e18−1, jtEffectiveNAV 204e18.
     * ST gain leg: recovery = 20e18−1 ⇒ IL 0, jtEffectiveNAV 224e18−1, stGain = 1 > dust 0 ⇒ premiumsPaid.
     * jtPrem = ⌊1·0.1⌋ = 0, ltPrem = 0, stFee = ⌊1·0.1⌋ = 0. stEffectiveNAV = 1000e18+1, PERPETUAL, end 0.
     * Conservation 1224e18 = (1000e18+1) + (224e18−1).
     * coverageUtilizationWAD = ⌈1224e18·0.1e18/(224e18−1)⌉ = 546428571428571429.
     * liquidityUtilizationWAD = ⌈(1000e18+1)/2000⌉ = 500000000000000001.
     */
    function test_SyncTrancheAccounting_GainILPlusOneWei_PremiumsPaidWithZeroPremiums() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 24e18 - 1, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 24e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1224e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1000e18 + 1;
        expected.jtEffectiveNAV = 224e18 - 1;
        expected.coverageUtilizationWAD = 546_428_571_428_571_429;
        expected.liquidityUtilizationWAD = 500_000_000_000_000_001;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * The time-weighted premium branch produces the same outputs as the instantaneous sync at the same rates:
     * a 1-day window whose accruals encode the identical constant rates must land the exact outputs of the
     * SharedGain instantaneous vector, and the instantaneous inputs are set hostile (uint256 max) to pin that
     * the time-weighted path ignores them.
     * Checkpoint (stEffectiveNAV/jtEffectiveNAV): 1000e18/200e18 (collateral 1200e18), IL 0, dust 0, PERPETUAL.
     * Warp 1 day: elapsed = 86400, twJT = 0.1e18·86400 = 8640e18, twLT = 0.05e18·86400 = 4320e18.
     * Delta +60e18: deltaSTEff = 50e18, deltaJTEff = 10e18 ⇒ jtFee 1e18 (JT leg),
     * jtPrem = ⌊50e18·8640e18/(86400·1e18)⌋ = 5e18, ltPrem = 2.5e18, jtFee += 0.5e18 ⇒ 1.5e18,
     * ltFee 0.25e18, residual 42.5e18 ⇒ stFee 4.25e18, stEffectiveNAV 1045e18, jtEffectiveNAV 215e18, PERPETUAL.
     * coverageUtilizationWAD = ⌈1260e18·0.1e18/215e18⌉ = 586046511627906977.
     */
    function test_SyncTrancheAccounting_TimeWeightedMatchesInstantaneous_InstantInputsIgnored() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 60e18);
        in_.elapsedSincePremiumPayment = 86_400;
        in_.jtTwYieldShareAccrual = 8640e18;
        in_.ltTwYieldShareAccrual = 4320e18;
        in_.jtInstYieldShareWAD = type(uint256).max;
        in_.ltInstYieldShareWAD = type(uint256).max;
        in_.nowTimestamp = T0 + 86_400;
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1260e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1045e18;
        expected.jtEffectiveNAV = 215e18;
        expected.jtRiskPremium = 5e18;
        expected.ltLiquidityPremium = 2.5e18;
        expected.stProtocolFee = 4.25e18;
        expected.jtProtocolFee = 1.5e18;
        expected.ltProtocolFee = 0.25e18;
        expected.coverageUtilizationWAD = 586_046_511_627_906_977;
        expected.liquidityUtilizationWAD = 522_500_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * Time-weighted averaging over a premium window whose rate changed mid-window: two half-day accrual
     * windows at different JT rates must average to the exact blended premium over the FULL window.
     * Checkpoint (stEffectiveNAV/jtEffectiveNAV): 1000e18/200e18 (collateral 1200e18), IL 0, dust 0, PERPETUAL.
     * Accruals 0.1e18·43200 + 0.2e18·43200 = 12960e18 (the second window's 0.5e18 rate was capped to 0.2e18
     * at accrual, so the input already carries the cap), twLT = 0.05e18·86400 = 4320e18, elapsed = 86400.
     * Delta +60e18: deltaSTEff = 50e18, deltaJTEff = 10e18 ⇒ jtFee 1e18 (JT leg).
     * jtPrem = ⌊50e18·12960e18/(86400·1e18)⌋ = ⌊50e18·0.15⌋ = 7.5e18, ltPrem = 2.5e18,
     * jtFee += 0.75e18 ⇒ 1.75e18, ltFee 0.25e18, residual 40e18 ⇒ stFee 4e18,
     * stEffectiveNAV = 1000e18 + 40e18 + 2.5e18 = 1042.5e18, jtEffectiveNAV = 210e18 + 7.5e18 = 217.5e18.
     * Conservation 1260 = 1042.5 + 217.5. PERPETUAL.
     * coverageUtilizationWAD = ⌈1260e18·0.1e18/217.5e18⌉ = ⌈579310344827586206.90⌉ = 579310344827586207.
     * liquidityUtilizationWAD = 1042.5e18/2000 = 521250000000000000 exact.
     */
    function test_SyncTrancheAccounting_TwoWindowTimeWeightedAveraging() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 60e18);
        in_.elapsedSincePremiumPayment = 86_400;
        in_.jtTwYieldShareAccrual = 12_960e18;
        in_.ltTwYieldShareAccrual = 4320e18;
        in_.nowTimestamp = T0 + 86_400;
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1260e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1042.5e18;
        expected.jtEffectiveNAV = 217.5e18;
        expected.jtRiskPremium = 7.5e18;
        expected.ltLiquidityPremium = 2.5e18;
        expected.stProtocolFee = 4e18;
        expected.jtProtocolFee = 1.75e18;
        expected.ltProtocolFee = 0.25e18;
        expected.coverageUtilizationWAD = 579_310_344_827_586_207;
        expected.liquidityUtilizationWAD = 521_250_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * The instantaneous-branch cap: a hostile preview yield share (uint256 max) is clamped to
     * maxJTYieldShareWAD before it can price a premium, so a misbehaving yield model cannot drain the gain.
     * Checkpoint (stEffectiveNAV/jtEffectiveNAV): 1000e18/200e18 (collateral 1200e18), IL 0, dust 0, PERPETUAL.
     * Delta +60e18 with jtInst = uint256 max, maxJT = 0.2e18: deltaSTEff = 50e18, deltaJTEff = 10e18
     * ⇒ jtFee 1e18 (JT leg).
     * jtPrem = ⌊50e18·0.2e18/1e18⌋ = 10e18, ltPrem = 2.5e18 (lt preview 0.05e18 below its cap),
     * jtFee += 1e18 ⇒ 2e18, ltFee 0.25e18, residual 37.5e18 ⇒ stFee 3.75e18,
     * stEffectiveNAV = 1000e18 + 37.5e18 + 2.5e18 = 1040e18, jtEffectiveNAV = 210e18 + 10e18 = 220e18.
     * Conservation 1260 = 1040 + 220.
     * coverageUtilizationWAD = ⌈1260e18·0.1e18/220e18⌉ = ⌈572727272727272727.27⌉ = 572727272727272728.
     */
    function test_SyncTrancheAccounting_InstantaneousHostilePreview_CappedAtMaxYieldShare() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 200e18, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 60e18);
        in_.jtInstYieldShareWAD = type(uint256).max;
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 1260e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 1040e18;
        expected.jtEffectiveNAV = 220e18;
        expected.jtRiskPremium = 10e18;
        expected.ltLiquidityPremium = 2.5e18;
        expected.stProtocolFee = 3.75e18;
        expected.jtProtocolFee = 2e18;
        expected.ltProtocolFee = 0.25e18;
        expected.coverageUtilizationWAD = 572_727_272_727_272_728;
        expected.liquidityUtilizationWAD = 520_000_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * The empty-checkpoint seniority tie-break: a delta marked from a zero lastCollateralNAV has no live
     * claims to split and routes wholly to ST, flowing through the senior gain leg's premium block.
     * Checkpoint: stEffectiveNAV 0, jtEffectiveNAV 0 (collateral 0), IL 0, dust 0, PERPETUAL.
     * Delta +10e18: deltaSTEff = +10e18 (tie-break), deltaJTEff = 0. ST gain 10e18 > dust ⇒ premiumsPaid.
     * Instantaneous premiums: jtRiskPremium = ⌊10e18·0.1e18/1e18⌋ = 1e18 (jtFee ⌊1e18·0.1⌋ = 1e17),
     * ltLiquidityPremium = ⌊10e18·0.05e18/1e18⌋ = 0.5e18 (ltFee 5e16), residual 8.5e18 ⇒ stFee 85e16.
     * stEffectiveNAV = 8.5e18 + 0.5e18 = 9e18, jtEffectiveNAV = 1e18. Conservation 10 = 9 + 1 (e18).
     * coverageUtilizationWAD = ⌈10e18·0.1e18/1e18⌉ = 1e18 exact.
     * liquidityUtilizationWAD = ⌈9e18·0.05e18/100e18⌉ = 4.5e15 exact.
     */
    function test_SyncTrancheAccounting_ZeroLastCollateral_TieBreakRoutesWholeDeltaToST() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(0, 0, 0, RoycoTestMath.MarketState.PERPETUAL, 0, 0, 10e18);
        RoycoTestMath.SyncOutputs memory expected;
        expected.collateralNAV = 10e18;
        expected.ltRawNAV = 100e18;
        expected.stEffectiveNAV = 9e18;
        expected.jtEffectiveNAV = 1e18;
        expected.jtRiskPremium = 1e18;
        expected.ltLiquidityPremium = 0.5e18;
        expected.stProtocolFee = 0.85e18;
        expected.jtProtocolFee = 0.1e18;
        expected.ltProtocolFee = 0.05e18;
        expected.coverageUtilizationWAD = 1e18;
        expected.liquidityUtilizationWAD = 4_500_000_000_000_000;
        expected.marketState = RoycoTestMath.MarketState.PERPETUAL;
        expected.premiumsPaid = true;
        _assertSyncOutputs(RoycoTestMath.syncTrancheAccounting(in_), expected);
    }

    /**
     * The fee theorem, asserted positively: under same-sign attribution any nonzero fee or premium requires a
     * gain residual that fully recovered the IL, so a fee-carrying sync ALWAYS resolves PERPETUAL with zero
     * IL, and the FIXED_TERM branch's FIXED_TERM_FEES_NONZERO require is unreachable through the waterfall.
     * Driven by the FIXED_TERM gain vector that books every fee field (checkpoint IL 20e18, delta +59e18,
     * see the GainRecoversILThenPremiums vector for the full derivation): all four fee/premium fields are
     * nonzero and the commit is PERPETUAL with the drawdown fully cleared.
     */
    function test_SyncTrancheAccounting_FeeTheorem_NonzeroFeesImplyPerpetual() public pure {
        RoycoTestMath.SyncInputs memory in_ = _syncInputs(1000e18, 180e18, 20e18, RoycoTestMath.MarketState.FIXED_TERM, T0 + DURATION, 0, 59e18);
        RoycoTestMath.SyncOutputs memory out = RoycoTestMath.syncTrancheAccounting(in_);
        assertGt(out.ltLiquidityPremium, 0, "the vector must book a liquidity premium");
        assertGt(out.stProtocolFee, 0, "the vector must book an ST fee");
        assertGt(out.jtProtocolFee, 0, "the vector must book a JT fee");
        assertGt(out.ltProtocolFee, 0, "the vector must book an LT fee");
        assertEq(uint256(out.marketState), uint256(RoycoTestMath.MarketState.PERPETUAL), "a fee-carrying sync must resolve PERPETUAL");
        assertEq(out.jtImpermanentLoss, 0, "the fee-carrying sync must have fully recovered the drawdown");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                maxSTDeposit
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Coverage-binding: covLeg = ⌊200e18·1e18/1e17⌋ − (collateralNAV 1200e18 + dust 0) = 2000e18 − 1200e18 = 800e18.
     * liqLeg = ⌊1000e18·1e18/5e16⌋ − 1000e18 = 20000e18 − 1000e18 = 19000e18. min = 800e18.
     */
    function test_MaxSTDeposit_CoverageBinding() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1200e18, 1000e18, 200e18, 1000e18, 1e17, 5e16, 0), 800e18, "coverage leg binds");
    }

    /// Liquidity-binding twin: liqLeg = ⌊60e18·1e18/5e16⌋ − 1000e18 = 1200e18 − 1000e18 = 200e18 < covLeg 800e18.
    function test_MaxSTDeposit_LiquidityBinding() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1200e18, 1000e18, 200e18, 60e18, 1e17, 5e16, 0), 200e18, "liquidity leg binds");
    }

    /// A zero requirement disables its leg: minCov 0 leaves only the liquidity leg (200e18), minLiq 0 only the
    /// coverage leg (800e18), and both zero return uint256 max.
    function test_MaxSTDeposit_ZeroRequirements_DisableLegs() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1200e18, 1000e18, 200e18, 60e18, 0, 5e16, 0), 200e18, "no coverage leg");
        assertEq(RoycoTestMath.maxSTDeposit(1200e18, 1000e18, 200e18, 60e18, 1e17, 0, 0), 800e18, "no liquidity leg");
        assertEq(RoycoTestMath.maxSTDeposit(1200e18, 1000e18, 200e18, 60e18, 0, 0, 0), type(uint256).max, "no legs");
    }

    /**
     * Dust slack on each leg: the single dustTolerance pads the leg's own NAV term before the subtraction.
     * Coverage leg: ⌊200e18·1e18/1e17⌋ − (collateralNAV 1200e18 + dust 7) = 800e18 − 7.
     * Liquidity leg: ⌊60e18·1e18/5e16⌋ − (stEffectiveNAV 1000e18 + dust 7) = 200e18 − 7.
     */
    function test_MaxSTDeposit_DustSlack_SingleTolerance() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1200e18, 1000e18, 200e18, 1000e18, 1e17, 0, 7), 800e18 - 7, "dust pads the coverage leg");
        assertEq(RoycoTestMath.maxSTDeposit(1200e18, 1000e18, 200e18, 60e18, 0, 5e16, 7), 200e18 - 7, "dust pads the liquidity leg");
    }

    /// Saturation: covered value ⌊50e18·1e18/1e17⌋ = 500e18 below the existing collateral NAV 1050e18 saturates the leg to 0.
    function test_MaxSTDeposit_SaturatesToZero() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1050e18, 1000e18, 50e18, 1000e18, 1e17, 0, 0), 0, "no capacity left");
    }

    /// Floor on both inversions at wei scale: covLeg = ⌊1·1e18/3e17⌋ − 1 = 3 − 1 = 2, and the liquidity twin
    /// liqLeg = ⌊1·1e18/3e17⌋ − 1 = 2.
    function test_MaxSTDeposit_FloorOnInversions_WeiScale() public pure {
        assertEq(RoycoTestMath.maxSTDeposit(1, 0, 1, 0, 3e17, 0, 0), 2, "floor(1e18/3e17) = 3 minus collateralNAV 1");
        assertEq(RoycoTestMath.maxSTDeposit(1, 1, 0, 1, 0, 3e17, 0), 2, "floor(1e18/3e17) = 3 minus stEffectiveNAV 1");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                maxJTWithdrawal
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Nominal with the retention denominator: required = ⌈(collateralNAV 1200e18 + dust 0)·1e17/1e18⌉ = 120e18,
     * surplus = sat(200e18 − 120e18) = 80e18 (the dust folds into the requirement before the ceil, no fudge).
     * JT is coinvested, so each withdrawn NAV unit relaxes the requirement by minCoverageWAD and the surplus grosses
     * up by the retention denominator WAD − minCoverageWAD = 9e17:
     * y = ⌊80e18·1e18/9e17⌋ = ⌊800000000000000000000/9⌋ = 88888888888888888888.
     */
    function test_MaxJTWithdrawal_Nominal_RetentionDenominator() public pure {
        uint256 jtW = RoycoTestMath.maxJTWithdrawal(1200e18, 200e18, 1e17, 0);
        assertEq(jtW, 88_888_888_888_888_888_888, "surplus grossed up by 10/9 retention");
    }

    /**
     * The dust tolerance folds into the collateral NAV before the ceil: required = ⌈(1200e18 + 10)·1e17/1e18⌉
     * = 120e18 + 1, surplus = 80e18 − 1, y = ⌊(80e18 − 1)·1e18/9e17⌋ = 88888888888888888887.
     */
    function test_MaxJTWithdrawal_DustFoldsIntoRequirement() public pure {
        uint256 jtW = RoycoTestMath.maxJTWithdrawal(1200e18, 200e18, 1e17, 10);
        assertEq(jtW, 88_888_888_888_888_888_887, "dust-padded requirement shaves the grossed-up surplus");
    }

    /**
     * Surplus boundary: with jtEffectiveNAV exactly at the requirement the surplus saturates to 0 and the closed
     * form returns 0, while one more wei of buffer yields exactly 1 wei withdrawable.
     *   required = ⌈1200e18·1e17/1e18⌉ = 120e18, jtEffectiveNAV = 120e18 ⇒ surplus 0, jtEffectiveNAV = 120e18 + 1 ⇒ surplus 1,
     *   retention 9e17 ⇒ y = ⌊1·1e18/9e17⌋ = 1.
     */
    function test_MaxJTWithdrawal_SurplusBoundary() public pure {
        uint256 jtW0 = RoycoTestMath.maxJTWithdrawal(1200e18, 120e18, 1e17, 0);
        assertEq(jtW0, 0, "the requirement consumes the whole buffer");
        uint256 jtW1 = RoycoTestMath.maxJTWithdrawal(1200e18, 120e18 + 1, 1e17, 0);
        assertEq(jtW1, 1, "one wei past the requirement is withdrawable");
    }

    /**
     * A large junior buffer: the whole 250e18 effective claim grosses up through the single retention factor.
     *   required = ⌈1200e18·1e17/1e18⌉ = 120e18, surplus = sat(250e18 − 120e18) = 130e18.
     *   retention 9e17 ⇒ y = ⌊130e18·1e18/9e17⌋ = ⌊1300000000000000000000/9⌋ = 144444444444444444444.
     */
    function test_MaxJTWithdrawal_LargeBuffer_SurplusGrossedUp() public pure {
        uint256 jtW = RoycoTestMath.maxJTWithdrawal(1200e18, 250e18, 1e17, 0);
        assertEq(jtW, 144_444_444_444_444_444_444, "coverage surplus grossed up by 10/9 retention");
    }

    /**
     * Zero minCoverage: no coverage requirement makes required 0 and the retention denominator the full WAD, so the
     * withdrawable equals the whole buffer with no gross-up.
     *   required = ⌈100e18·0/1e18⌉ = 0, surplus = sat(5 − 0) = 5, y = ⌊5·1e18/1e18⌋ = 5.
     */
    function test_MaxJTWithdrawal_ZeroMinCoverage_FullRetentionDenominator() public pure {
        uint256 jtW = RoycoTestMath.maxJTWithdrawal(100e18, 5, 0, 0);
        assertEq(jtW, 5, "zero coverage requirement, withdrawable equals the whole buffer");
    }

    /// Zero-surplus early-out: required = ⌈1200e18·3e17/1e18⌉ = 360e18 exceeds jtEffectiveNAV 200e18 entirely, surplus saturates to 0.
    function test_MaxJTWithdrawal_RequiredExceedsBuffer_ReturnsZero() public pure {
        uint256 jtW = RoycoTestMath.maxJTWithdrawal(1200e18, 200e18, 3e17, 0);
        assertEq(jtW, 0, "no surplus");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                maxLTWithdrawal
    //////////////////////////////////////////////////////////////////////////*/

    /// Nominal: required = ⌈1000e18·5e16/1e18⌉ = 50e18 exact, withdrawable = 100e18 − 50e18 = 50e18.
    function test_MaxLTWithdrawal_Nominal() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 5e16, 0), 50e18, "half the pool is surplus");
    }

    /// Ceil on the required depth: stEffectiveNAV 1000e18+1 ⇒ required = ⌈50e18 + 0.05⌉ = 50e18 + 1 ⇒ 50e18 − 1.
    function test_MaxLTWithdrawal_CeilInnerRounding() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18 + 1, 5e16, 0), 50e18 - 1, "ceil bites one wei");
    }

    /// The stDust folds into the senior NAV before μ-scaling: required = ⌈(1000e18 + 3)·0.05⌉ = 50e18 + 1 ⇒ 50e18 − 1.
    function test_MaxLTWithdrawal_StDustSlack() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 5e16, 3), 50e18 - 1, "dust slack");
    }

    /// minLiq == 0 bypasses the gate entirely: the whole ltRawNAV is withdrawable.
    function test_MaxLTWithdrawal_ZeroMinLiquidity_FullLtRaw() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(100e18, 1000e18, 0, 0), 100e18, "no liquidity requirement");
    }

    /// Saturation: required 50e18 above the pool depth 40e18 saturates to 0.
    function test_MaxLTWithdrawal_SaturatesToZero() public pure {
        assertEq(RoycoTestMath.maxLTWithdrawal(40e18, 1000e18, 5e16, 0), 0, "under-provisioned pool");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        seniorTrancheSelfLiquidationBonus
    //////////////////////////////////////////////////////////////////////////*/

    /// Builds a SelfLiqBonusIn with the shared reference state: stEffectiveNAV 960e18, jtEffectiveNAV 140e18
    /// (collateral 1100e18 under conservation), coverage utilization at the 1.1e18 liquidation threshold,
    /// bonus rate 5e17.
    function _bonusIn(uint256 userNav) private pure returns (RoycoTestMath.SeniorTrancheSelfLiquidationBonusInputs memory in_) {
        in_.stEffectiveNAV = 960e18;
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
     * max binding: desired = ⌊200e18·5e17/1e18⌋ = 100e18, jtEffectiveNAV = 140e18, and under conservation the
     * U-neutral denominator is stEffectiveNAV directly ⇒
     * maxNeutral = ⌊200e18·140e18/960e18⌋ = ⌊28000e36/960e18⌋ = 29166666666666666666 ⇒
     * bonus = min(100e18, 140e18, 29166666666666666666).
     */
    function test_SeniorTrancheSelfLiquidationBonus_AtThresholdExactly_NeutralMaxBinds() public pure {
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonus(_bonusIn(200e18)), 29_166_666_666_666_666_666, "floors 28000/960");
    }

    /**
     * U-neutral max with exact division: userClaimNAV 300e18 over the stEffectiveNAV denominator gives
     * maxNeutral = ⌊300e18·140e18/960e18⌋ = 43.75e18 exact.
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
     * The jtEffectiveNAV term binds: stEffectiveNAV 60e18, jtEffectiveNAV 60e18, userClaimNAV 130e18:
     * maxNeutral = ⌊130e18·60e18/60e18⌋ = 130e18, desired = ⌊130e18·5e17/1e18⌋ = 65e18 ⇒
     * bonus = min(65e18, 60e18, 130e18) = 60e18, capped by the remaining JT buffer.
     */
    function test_SeniorTrancheSelfLiquidationBonus_JtEffBinds() public pure {
        RoycoTestMath.SeniorTrancheSelfLiquidationBonusInputs memory in_ = _bonusIn(130e18);
        in_.stEffectiveNAV = 60e18;
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

    /**
     * The reported bonus is the single collateral round trip of the sized bonus: at a 1.0 NAV-per-unit rate
     * both floors are identities, so the report equals the sized bonus exactly.
     */
    function test_SeniorTrancheSelfLiquidationBonusReported_IdentityRate_Exact() public pure {
        assertEq(
            RoycoTestMath.seniorTrancheSelfLiquidationBonusReported(_bonusIn(200e18), 1e18),
            29_166_666_666_666_666_666,
            "identity rate reports the sized bonus exactly"
        );
    }

    /**
     * An awkward rate loses at most 1 wei across the two floors and never overstates: sized bonus
     * 29166666666666666666 at rate 0.7e18 quantizes to assets = ⌊29166666666666666666·1e18/7e17⌋
     * = 41666666666666666665, re-valued once: ⌊41666666666666666665·7e17/1e18⌋ = 29166666666666666665,
     * exactly 1 wei under the sized bonus.
     */
    function test_SeniorTrancheSelfLiquidationBonusReported_AwkwardRate_FloorsOneWeiUnder() public pure {
        assertEq(
            RoycoTestMath.seniorTrancheSelfLiquidationBonusReported(_bonusIn(200e18), 7e17),
            29_166_666_666_666_666_665,
            "the value -> assets -> value round trip floors 1 wei under the sized bonus"
        );
    }

    /// A zero sized bonus short-circuits the round trip: below the threshold the report is 0 at any rate.
    function test_SeniorTrancheSelfLiquidationBonusReported_ZeroBonus_ShortCircuits() public pure {
        RoycoTestMath.SeniorTrancheSelfLiquidationBonusInputs memory in_ = _bonusIn(200e18);
        in_.coverageUtilizationWAD = 1.1e18 - 1;
        assertEq(RoycoTestMath.seniorTrancheSelfLiquidationBonusReported(in_, 7e17), 0, "inactive bonus reports zero");
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
