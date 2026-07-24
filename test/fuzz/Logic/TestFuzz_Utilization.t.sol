// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { toNAVUnits } from "../../../src/libraries/Units.sol";
import { UtilizationLogic } from "../../../src/libraries/logic/UtilizationLogic.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title TestFuzz_Utilization_Logic
 * @notice Fuzz properties for the two gating metrics: coverage utilization (gates senior deposits) and
 *         liquidity utilization (gates LPT redemptions), each asserted exactly equal to the independent
 *         RoycoTestMath mirror including the zero edges, plus the senior-favoring ceil-rounding direction
 *         and the exactly-100% gate boundary
 * @dev Pure-library layer, no market deploy. Overflow in the bias cross-multiplications is precluded by
 *      the suite NAV/WAD bounds, derived per property below
 */
contract TestFuzz_Utilization_Logic is Test {
    /// @notice Suite-wide NAV ceiling
    uint256 internal constant MAX_NAV = 1e30;

    /**
     * Coverage utilization is the metric that blocks senior deposits when junior first-loss capital is
     * too thin, so it must round UP: an under-read would admit collateral the junior tranche cannot
     * cover. Property (UtilizationLogic.sol:25-40):
     *   coverageUtilizationWAD == RoycoTestMath.computeCoverageUtilization(collateralNAV, minCov, jtEffectiveNAV)   [exact, full input space]
     * Zero edges pinned exactly, and the zero edges take precedence over the infinite edge:
     *   minCov == 0 or collateralNAV == 0 => 0, then jtEffectiveNAV == 0 => type(uint256).max
     * Ceil direction on the finite branch: utilization * jtEffectiveNAV >= collateralNAV * minCov (the metric reads high,
     * favoring senior). Overflow guard: utilization * jtEffectiveNAV <= collateralNAV * minCov + jtEffectiveNAV - 1 <= 1e48 + 1e30 < 2^256
     * because utilization = ceil(collateralNAV * minCov / jtEffectiveNAV) with collateralNAV <= 1e30 and minCov < 1e18
     */
    function testFuzz_CoverageUtilization_MatchesMirrorAndCeilBias(uint256 _collateral, uint256 _minCov, uint256 _jtEff) public pure {
        _collateral = bound(_collateral, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _minCov = bound(_minCov, 0, WAD - 1); // config invariant: setMinCoverage enforces minCoverageWAD < WAD, incl. the 0 edge
        _jtEff = bound(_jtEff, 0, MAX_NAV); // includes 0 => the infinite-utilization branch

        uint256 coverageUtilizationWAD = UtilizationLogic._computeCoverageUtilization(toNAVUnits(_collateral), _minCov, toNAVUnits(_jtEff));

        // Exact equality with the independent mirror over the entire input space
        assertEq(
            coverageUtilizationWAD,
            RoycoTestMath.computeCoverageUtilization(_collateral, _minCov, _jtEff),
            "coverage utilization == RoycoTestMath.computeCoverageUtilization"
        );

        if (_minCov == 0 || _collateral == 0) {
            assertEq(coverageUtilizationWAD, 0, "no requirement or no collateral reads zero");
        } else if (_jtEff == 0) {
            assertEq(coverageUtilizationWAD, type(uint256).max, "positive requirement against no junior buffer is infinite");
        } else {
            // Ceil rounding favors senior: the utilization never under-reads the required coverage
            assertGe(coverageUtilizationWAD * _jtEff, _collateral * _minCov, "ceil bias: utilization * jtEffectiveNAV >= collateralNAV * minCov");
            // And it over-reads by less than one denominator unit (exact ceil, not merely an upper bound)
            assertLt(coverageUtilizationWAD * _jtEff, _collateral * _minCov + _jtEff, "ceil tightness: the utilization is the least such value");
        }
    }

    /**
     * Liquidity utilization is the metric that blocks LPT redemptions from pulling pool depth below the
     * senior tranche's required exit liquidity, so it must round UP: an under-read would let a redemption
     * drain depth senior exits depend on. Property (UtilizationLogic.sol:52-67):
     *   liquidityUtilizationWAD == RoycoTestMath.computeLiquidityUtilization(stEffectiveNAV, minLiq, lptRawNAV)   [exact, full input space]
     * Zero edges pinned exactly, and the zero edges take precedence over the infinite edge:
     *   stEffectiveNAV == 0 or minLiq == 0 => 0, then lptRawNAV == 0 => type(uint256).max
     * Ceil direction on the finite branch: utilization * lptRawNAV >= stEffectiveNAV * minLiq (the metric reads high,
     * favoring senior). Overflow guard: utilization * lptRawNAV <= stEffectiveNAV * minLiq + lptRawNAV - 1 <= 1e48 + 1e30 < 2^256
     */
    function testFuzz_LiquidityUtilization_MatchesMirrorAndCeilBias(uint256 _stEff, uint256 _minLiq, uint256 _lptRaw) public pure {
        _stEff = bound(_stEff, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _minLiq = bound(_minLiq, 0, WAD - 1); // config invariant: setMinLiquidity enforces minLiquidityWAD < WAD, incl. the 0 edge
        _lptRaw = bound(_lptRaw, 0, MAX_NAV); // includes 0 => the infinite-utilization branch

        uint256 liquidityUtilizationWAD = UtilizationLogic._computeLiquidityUtilization(toNAVUnits(_stEff), _minLiq, toNAVUnits(_lptRaw));

        // Exact equality with the independent mirror over the entire input space
        assertEq(
            liquidityUtilizationWAD,
            RoycoTestMath.computeLiquidityUtilization(_stEff, _minLiq, _lptRaw),
            "liquidity utilization == RoycoTestMath.computeLiquidityUtilization"
        );

        if (_stEff == 0 || _minLiq == 0) {
            assertEq(liquidityUtilizationWAD, 0, "no senior value or no requirement reads zero");
        } else if (_lptRaw == 0) {
            assertEq(liquidityUtilizationWAD, type(uint256).max, "positive requirement against no pool depth is infinite");
        } else {
            // Ceil rounding favors senior: the utilization never under-reads the required depth
            assertGe(liquidityUtilizationWAD * _lptRaw, _stEff * _minLiq, "ceil bias: utilization * lptRawNAV >= stEffectiveNAV * minLiq");
            // And it over-reads by less than one denominator unit (exact ceil, not merely an upper bound)
            assertLt(liquidityUtilizationWAD * _lptRaw, _stEff * _minLiq + _lptRaw, "ceil tightness: the utilization is the least such value");
        }
    }

    /**
     * Adversarial boundary parking: every gate compares utilization <= WAD, so an attacker's best position
     * is the exactly-backed state. That state must read exactly 100% (still allowed), and a single extra
     * collateral wei must push the ceil'd read strictly past 100% (blocked) - if the boundary read were WAD - 1
     * or the wei were absorbed, the gate's <= would admit collateral the junior buffer cannot cover.
     * Construction: jtEffectiveNAV = j x minCov backs a collateral NAV of j x WAD exactly, so
     *   ceil(j x WAD x minCov / (j x minCov)) == WAD and adding 1 collateral wei adds ceil(minCov / (j x minCov)) == 1
     */
    function testFuzz_CoverageUtilization_ExactBoundaryReadsOneHundredPercentAndOneMoreWeiExceedsIt(uint256 _j, uint256 _minCov) public pure {
        _minCov = bound(_minCov, 1, WAD - 1); // positive requirement below 100%, setMinCoverage's config range
        _j = bound(_j, 1, MAX_NAV / WAD); // scale factor keeping collateralNAV = j x WAD inside the NAV domain
        uint256 jtEff = _j * _minCov; // the exact junior buffer that backs the collateral at precisely 100%
        uint256 collateral = _j * WAD;

        uint256 atBoundary = UtilizationLogic._computeCoverageUtilization(toNAVUnits(collateral), _minCov, toNAVUnits(jtEff));
        assertEq(atBoundary, WAD, "the exactly-backed state must read exactly 100%, keeping the <= gate open");

        uint256 pastBoundary = UtilizationLogic._computeCoverageUtilization(toNAVUnits(collateral + 1), _minCov, toNAVUnits(jtEff));
        assertEq(pastBoundary, WAD + 1, "one collateral wei past the boundary must read 100% + 1 wei, tripping the <= gate");
    }

    /**
     * Adversarial boundary parking on the liquidity side: an LPT redemption is valid only while the
     * post-redemption liquidity utilization stays at or below 100%. The exactly-provisioned pool must read
     * exactly 100% (the redemption down to the floor is allowed), and one more senior NAV wei must push the
     * ceil'd read strictly past it (the redemption through the floor is blocked).
     * Construction: lptRawNAV = j x minLiq exactly provisions a senior effective NAV of j x WAD, so
     *   ceil(j x WAD x minLiq / (j x minLiq)) == WAD and adding 1 senior wei adds ceil(minLiq / (j x minLiq)) == 1
     */
    function testFuzz_LiquidityUtilization_ExactBoundaryReadsOneHundredPercentAndOneMoreWeiExceedsIt(uint256 _j, uint256 _minLiq) public pure {
        _minLiq = bound(_minLiq, 1, WAD - 1); // positive requirement below 100%, setMinLiquidity's config range
        _j = bound(_j, 1, MAX_NAV / WAD); // scale factor keeping stEffectiveNAV = j x WAD inside the NAV domain
        uint256 lptRaw = _j * _minLiq; // the exact pool depth that provisions the senior NAV at precisely 100%
        uint256 stEff = _j * WAD;

        uint256 atBoundary = UtilizationLogic._computeLiquidityUtilization(toNAVUnits(stEff), _minLiq, toNAVUnits(lptRaw));
        assertEq(atBoundary, WAD, "the exactly-provisioned pool must read exactly 100%, keeping the <= gate open");

        uint256 pastBoundary = UtilizationLogic._computeLiquidityUtilization(toNAVUnits(stEff + 1), _minLiq, toNAVUnits(lptRaw));
        assertEq(pastBoundary, WAD + 1, "one senior NAV wei past the boundary must read 100% + 1 wei, tripping the <= gate");
    }
}
