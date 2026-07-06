// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { toNAVUnits } from "../../../src/libraries/Units.sol";
import { UtilizationLogic } from "../../../src/libraries/logic/UtilizationLogic.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";

/**
 * @title UtilizationFuzz
 * @notice Fuzz properties for the two gating metrics: coverage utilization (gates senior deposits) and
 *         liquidity utilization (gates LT redemptions), each asserted exactly equal to the independent
 *         RoycoTestMath mirror including the zero edges, plus the senior-favoring ceil-rounding direction
 * @dev Pure-library layer, no market deploy. Overflow in the bias cross-multiplications is precluded by
 *      the suite NAV/WAD bounds, derived per property below
 */
contract UtilizationFuzz is Test {
    /// @notice WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /// @notice Suite-wide NAV ceiling
    uint256 internal constant MAX_NAV = 1e30;

    /**
     * Coverage utilization is the metric that blocks senior deposits when junior first-loss capital is
     * too thin, so it must round UP: an under-read would admit senior exposure the junior tranche cannot
     * cover. Property (UtilizationLogic.sol:27-48):
     *   covU == RoycoTestMath.covUtil(stRaw, jtRaw, coinvested, minCov, jtEff)   [exact, full input space]
     * Zero edges pinned exactly, and the zero edges take precedence over the infinite edge:
     *   minCov == 0 or exposure == 0 => 0, then jtEff == 0 => type(uint256).max
     * Ceil direction on the finite branch: covU * jtEff >= exposure * minCov (the metric reads high,
     * favoring senior). Overflow guard: covU * jtEff <= exposure * minCov + jtEff - 1 <= 2e48 + 1e30 < 2^256
     * because covU = ceil(exposure * minCov / jtEff) with exposure <= 2e30 and minCov < 1e18
     */
    function testFuzz_CoverageUtilization_matchesMirrorAndCeilBias(
        uint256 _stRaw,
        uint256 _jtRaw,
        bool _jtCoinvested,
        uint256 _minCov,
        uint256 _jtEff
    )
        public
        pure
    {
        _stRaw = bound(_stRaw, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _jtRaw = bound(_jtRaw, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _minCov = bound(_minCov, 0, WAD - 1); // config invariant: setMinCoverage enforces minCoverageWAD < WAD, incl. the 0 edge
        _jtEff = bound(_jtEff, 0, MAX_NAV); // includes 0 => the infinite-utilization branch

        uint256 covU = UtilizationLogic._computeCoverageUtilization(toNAVUnits(_stRaw), toNAVUnits(_jtRaw), _jtCoinvested, _minCov, toNAVUnits(_jtEff));

        // Exact equality with the independent mirror over the entire input space
        assertEq(covU, RoycoTestMath.covUtil(_stRaw, _jtRaw, _jtCoinvested, _minCov, _jtEff), "covU == RoycoTestMath.covUtil");

        uint256 exposure = _stRaw + (_jtCoinvested ? _jtRaw : 0);
        if (_minCov == 0 || exposure == 0) {
            assertEq(covU, 0, "no requirement or no exposure reads zero");
        } else if (_jtEff == 0) {
            assertEq(covU, type(uint256).max, "positive requirement against no junior buffer is infinite");
        } else {
            // Ceil rounding favors senior: the utilization never under-reads the required coverage
            assertGe(covU * _jtEff, exposure * _minCov, "ceil bias: covU * jtEff >= exposure * minCov");
            // And it over-reads by less than one denominator unit (exact ceil, not merely an upper bound)
            assertLt(covU * _jtEff, exposure * _minCov + _jtEff, "ceil tightness: covU is the least such value");
        }
    }

    /**
     * Liquidity utilization is the metric that blocks LT redemptions from pulling pool depth below the
     * senior tranche's required exit liquidity, so it must round UP: an under-read would let a redemption
     * drain depth senior exits depend on. Property (UtilizationLogic.sol:60-75):
     *   liqU == RoycoTestMath.liqUtil(stEff, minLiq, ltRaw)   [exact, full input space]
     * Zero edges pinned exactly, and the zero edges take precedence over the infinite edge:
     *   stEff == 0 or minLiq == 0 => 0, then ltRaw == 0 => type(uint256).max
     * Ceil direction on the finite branch: liqU * ltRaw >= stEff * minLiq (the metric reads high,
     * favoring senior). Overflow guard: liqU * ltRaw <= stEff * minLiq + ltRaw - 1 <= 1e48 + 1e30 < 2^256
     */
    function testFuzz_LiquidityUtilization_matchesMirrorAndCeilBias(uint256 _stEff, uint256 _minLiq, uint256 _ltRaw) public pure {
        _stEff = bound(_stEff, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _minLiq = bound(_minLiq, 0, WAD - 1); // config invariant: setMinLiquidity enforces minLiquidityWAD < WAD, incl. the 0 edge
        _ltRaw = bound(_ltRaw, 0, MAX_NAV); // includes 0 => the infinite-utilization branch

        uint256 liqU = UtilizationLogic._computeLiquidityUtilization(toNAVUnits(_stEff), _minLiq, toNAVUnits(_ltRaw));

        // Exact equality with the independent mirror over the entire input space
        assertEq(liqU, RoycoTestMath.liqUtil(_stEff, _minLiq, _ltRaw), "liqU == RoycoTestMath.liqUtil");

        if (_stEff == 0 || _minLiq == 0) {
            assertEq(liqU, 0, "no senior value or no requirement reads zero");
        } else if (_ltRaw == 0) {
            assertEq(liqU, type(uint256).max, "positive requirement against no pool depth is infinite");
        } else {
            // Ceil rounding favors senior: the utilization never under-reads the required depth
            assertGe(liqU * _ltRaw, _stEff * _minLiq, "ceil bias: liqU * ltRaw >= stEff * minLiq");
            // And it over-reads by less than one denominator unit (exact ceil, not merely an upper bound)
            assertLt(liqU * _ltRaw, _stEff * _minLiq + _ltRaw, "ceil tightness: liqU is the least such value");
        }
    }
}
