// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { toNAVUnits } from "../../../src/libraries/Units.sol";
import { UtilizationLogic } from "../../../src/libraries/logic/UtilizationLogic.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";

/**
 * @title UtilizationFuzz
 * @notice Phase C fuzz properties for the F7/F8 utilization math (testing-strategy.md §4.2 row `covUtil/liqUtil`):
 *         exact equality against the independent RoycoTestMath mirror including the four zero edges, plus the
 *         senior-favoring ceil-bias direction on both metrics
 * @dev Pure-library layer, no market deploy. Overflow in the bias cross-multiplications is precluded by the
 *      suite NAV/WAD bounds, derived per property below
 */
contract UtilizationFuzz is Test {
    /// @notice WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /// @notice Suite-wide NAV ceiling (testing-strategy.md §4.2 global bounds)
    uint256 internal constant MAX_NAV = 1e30;

    /**
     * Property (F7 + ceil bias, UtilizationLogic:27-48):
     *   covU == RoycoTestMath.covUtil(stRaw, jtRaw, coinvested, minCov, jtEff)   [exact, full input space]
     * Zero edges pinned exactly (zero edges take precedence over the infinite edge):
     *   minCov == 0 or exposure == 0 => 0, then jtEff == 0 => type(uint256).max
     * Ceil-bias direction on the finite branch: covU * jtEff >= exposure * minCov (utilization reads high,
     * favoring senior). Overflow guard: covU * jtEff <= exposure * minCov + jtEff - 1 <= 1e48 + 1e30 < 2^256
     * because covU = ceil(exposure * minCov / jtEff), exposure <= 2e30 and minCov < 1e18
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
        assertEq(covU, RoycoTestMath.covUtil(_stRaw, _jtRaw, _jtCoinvested, _minCov, _jtEff), "F7: covU == RoycoTestMath.covUtil");

        uint256 exposure = _stRaw + (_jtCoinvested ? _jtRaw : 0);
        if (_minCov == 0 || exposure == 0) {
            assertEq(covU, 0, "F7 edge: no requirement or no exposure reads zero");
        } else if (_jtEff == 0) {
            assertEq(covU, type(uint256).max, "F7 edge: positive requirement against no buffer is infinite");
        } else {
            // Ceil bias favors senior: the utilization never under-reads the required coverage
            assertGe(covU * _jtEff, exposure * _minCov, "F7 ceil bias: covU * jtEff >= exposure * minCov");
            // And it over-reads by less than one denominator unit (exact ceil, not merely an upper bound)
            assertLt(covU * _jtEff, exposure * _minCov + _jtEff, "F7 ceil tightness: covU is the least such value");
        }
    }

    /**
     * Property (F8 + ceil bias, UtilizationLogic:60-75):
     *   liqU == RoycoTestMath.liqUtil(stEff, minLiq, ltRaw)   [exact, full input space]
     * Zero edges pinned exactly (zero edges take precedence over the infinite edge):
     *   stEff == 0 or minLiq == 0 => 0, then ltRaw == 0 => type(uint256).max
     * Ceil-bias direction on the finite branch: liqU * ltRaw >= stEff * minLiq (utilization reads high,
     * favoring senior). Overflow guard: liqU * ltRaw <= stEff * minLiq + ltRaw - 1 <= 1e48 + 1e30 < 2^256
     */
    function testFuzz_LiquidityUtilization_matchesMirrorAndCeilBias(uint256 _stEff, uint256 _minLiq, uint256 _ltRaw) public pure {
        _stEff = bound(_stEff, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _minLiq = bound(_minLiq, 0, WAD - 1); // config invariant: setMinLiquidity enforces minLiquidityWAD < WAD, incl. the 0 edge
        _ltRaw = bound(_ltRaw, 0, MAX_NAV); // includes 0 => the infinite-utilization branch

        uint256 liqU = UtilizationLogic._computeLiquidityUtilization(toNAVUnits(_stEff), _minLiq, toNAVUnits(_ltRaw));

        // Exact equality with the independent mirror over the entire input space
        assertEq(liqU, RoycoTestMath.liqUtil(_stEff, _minLiq, _ltRaw), "F8: liqU == RoycoTestMath.liqUtil");

        if (_stEff == 0 || _minLiq == 0) {
            assertEq(liqU, 0, "F8 edge: no senior value or no requirement reads zero");
        } else if (_ltRaw == 0) {
            assertEq(liqU, type(uint256).max, "F8 edge: positive requirement against no depth is infinite");
        } else {
            // Ceil bias favors senior: the utilization never under-reads the required depth
            assertGe(liqU * _ltRaw, _stEff * _minLiq, "F8 ceil bias: liqU * ltRaw >= stEff * minLiq");
            // And it over-reads by less than one denominator unit (exact ceil, not merely an upper bound)
            assertLt(liqU * _ltRaw, _stEff * _minLiq + _ltRaw, "F8 ceil tightness: liqU is the least such value");
        }
    }
}
