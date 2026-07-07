// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { toNAVUnits } from "../../../src/libraries/Units.sol";
import { UtilizationLogic } from "../../../src/libraries/logic/UtilizationLogic.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title TestFuzz_Utilization_Logic
 * @notice Fuzz properties for the two gating metrics: coverage utilization (gates senior deposits) and
 *         liquidity utilization (gates LT redemptions), each asserted exactly equal to the independent
 *         RoycoTestMath mirror including the zero edges, plus the senior-favoring ceil-rounding direction
 *         and the exactly-100% gate boundary
 * @dev Pure-library layer, no market deploy. Overflow in the bias cross-multiplications is precluded by
 *      the suite NAV/WAD bounds, derived per property below
 */
contract TestFuzz_Utilization_Logic is Test {
    /// @notice WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /// @notice Suite-wide NAV ceiling
    uint256 internal constant MAX_NAV = 1e30;

    /**
     * Coverage utilization is the metric that blocks senior deposits when junior first-loss capital is
     * too thin, so it must round UP: an under-read would admit senior exposure the junior tranche cannot
     * cover. Property (UtilizationLogic.sol:27-48):
     *   coverageUtilizationWAD == RoycoTestMath.computeCoverageUtilization(stRawNAV, jtRawNAV, coinvested, minCov, jtEffectiveNAV)   [exact, full input space]
     * Zero edges pinned exactly, and the zero edges take precedence over the infinite edge:
     *   minCov == 0 or exposure == 0 => 0, then jtEffectiveNAV == 0 => type(uint256).max
     * Ceil direction on the finite branch: utilization * jtEffectiveNAV >= exposure * minCov (the metric reads high,
     * favoring senior). Overflow guard: utilization * jtEffectiveNAV <= exposure * minCov + jtEffectiveNAV - 1 <= 2e48 + 1e30 < 2^256
     * because utilization = ceil(exposure * minCov / jtEffectiveNAV) with exposure <= 2e30 and minCov < 1e18
     */
    function testFuzz_CoverageUtilization_MatchesMirrorAndCeilBias(
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

        uint256 coverageUtilizationWAD =
            UtilizationLogic._computeCoverageUtilization(toNAVUnits(_stRaw), toNAVUnits(_jtRaw), _jtCoinvested, _minCov, toNAVUnits(_jtEff));

        // Exact equality with the independent mirror over the entire input space
        assertEq(
            coverageUtilizationWAD,
            RoycoTestMath.computeCoverageUtilization(_stRaw, _jtRaw, _jtCoinvested, _minCov, _jtEff),
            "coverage utilization == RoycoTestMath.computeCoverageUtilization"
        );

        uint256 exposure = _stRaw + (_jtCoinvested ? _jtRaw : 0);
        if (_minCov == 0 || exposure == 0) {
            assertEq(coverageUtilizationWAD, 0, "no requirement or no exposure reads zero");
        } else if (_jtEff == 0) {
            assertEq(coverageUtilizationWAD, type(uint256).max, "positive requirement against no junior buffer is infinite");
        } else {
            // Ceil rounding favors senior: the utilization never under-reads the required coverage
            assertGe(coverageUtilizationWAD * _jtEff, exposure * _minCov, "ceil bias: utilization * jtEffectiveNAV >= exposure * minCov");
            // And it over-reads by less than one denominator unit (exact ceil, not merely an upper bound)
            assertLt(coverageUtilizationWAD * _jtEff, exposure * _minCov + _jtEff, "ceil tightness: the utilization is the least such value");
        }
    }

    /**
     * Liquidity utilization is the metric that blocks LT redemptions from pulling pool depth below the
     * senior tranche's required exit liquidity, so it must round UP: an under-read would let a redemption
     * drain depth senior exits depend on. Property (UtilizationLogic.sol:60-75):
     *   liquidityUtilizationWAD == RoycoTestMath.computeLiquidityUtilization(stEffectiveNAV, minLiq, ltRawNAV)   [exact, full input space]
     * Zero edges pinned exactly, and the zero edges take precedence over the infinite edge:
     *   stEffectiveNAV == 0 or minLiq == 0 => 0, then ltRawNAV == 0 => type(uint256).max
     * Ceil direction on the finite branch: utilization * ltRawNAV >= stEffectiveNAV * minLiq (the metric reads high,
     * favoring senior). Overflow guard: utilization * ltRawNAV <= stEffectiveNAV * minLiq + ltRawNAV - 1 <= 1e48 + 1e30 < 2^256
     */
    function testFuzz_LiquidityUtilization_MatchesMirrorAndCeilBias(uint256 _stEff, uint256 _minLiq, uint256 _ltRaw) public pure {
        _stEff = bound(_stEff, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _minLiq = bound(_minLiq, 0, WAD - 1); // config invariant: setMinLiquidity enforces minLiquidityWAD < WAD, incl. the 0 edge
        _ltRaw = bound(_ltRaw, 0, MAX_NAV); // includes 0 => the infinite-utilization branch

        uint256 liquidityUtilizationWAD = UtilizationLogic._computeLiquidityUtilization(toNAVUnits(_stEff), _minLiq, toNAVUnits(_ltRaw));

        // Exact equality with the independent mirror over the entire input space
        assertEq(
            liquidityUtilizationWAD,
            RoycoTestMath.computeLiquidityUtilization(_stEff, _minLiq, _ltRaw),
            "liquidity utilization == RoycoTestMath.computeLiquidityUtilization"
        );

        if (_stEff == 0 || _minLiq == 0) {
            assertEq(liquidityUtilizationWAD, 0, "no senior value or no requirement reads zero");
        } else if (_ltRaw == 0) {
            assertEq(liquidityUtilizationWAD, type(uint256).max, "positive requirement against no pool depth is infinite");
        } else {
            // Ceil rounding favors senior: the utilization never under-reads the required depth
            assertGe(liquidityUtilizationWAD * _ltRaw, _stEff * _minLiq, "ceil bias: utilization * ltRawNAV >= stEffectiveNAV * minLiq");
            // And it over-reads by less than one denominator unit (exact ceil, not merely an upper bound)
            assertLt(liquidityUtilizationWAD * _ltRaw, _stEff * _minLiq + _ltRaw, "ceil tightness: the utilization is the least such value");
        }
    }

    /**
     * Adversarial boundary parking: every gate compares utilization <= WAD, so an attacker's best position
     * is the exactly-backed state. That state must read exactly 100% (still allowed), and a single extra
     * exposure wei must push the ceil'd read strictly past 100% (blocked) — if the boundary read were WAD - 1
     * or the wei were absorbed, the gate's <= would admit exposure the junior buffer cannot cover.
     * Construction: jtEffectiveNAV = j x minCov backs an exposure of j x WAD exactly, so
     *   ceil(j x WAD x minCov / (j x minCov)) == WAD and adding 1 exposure wei adds ceil(minCov / (j x minCov)) == 1
     */
    function testFuzz_CoverageUtilization_ExactBoundaryReadsOneHundredPercentAndOneMoreWeiExceedsIt(uint256 _j, uint256 _minCov) public pure {
        _minCov = bound(_minCov, 1, WAD - 1); // positive requirement below 100%, setMinCoverage's config range
        _j = bound(_j, 1, MAX_NAV / WAD); // scale factor keeping exposure = j x WAD inside the NAV domain
        uint256 jtEff = _j * _minCov; // the exact junior buffer that backs the exposure at precisely 100%
        uint256 exposure = _j * WAD;

        uint256 atBoundary = UtilizationLogic._computeCoverageUtilization(toNAVUnits(exposure), ZERO_NAV_UNITS, false, _minCov, toNAVUnits(jtEff));
        assertEq(atBoundary, WAD, "the exactly-backed state must read exactly 100%, keeping the <= gate open");

        uint256 pastBoundary = UtilizationLogic._computeCoverageUtilization(toNAVUnits(exposure + 1), ZERO_NAV_UNITS, false, _minCov, toNAVUnits(jtEff));
        assertEq(pastBoundary, WAD + 1, "one exposure wei past the boundary must read 100% + 1 wei, tripping the <= gate");
    }

    /**
     * Adversarial boundary parking on the liquidity side: an LT redemption is valid only while the
     * post-redemption liquidity utilization stays at or below 100%. The exactly-provisioned pool must read
     * exactly 100% (the redemption down to the floor is allowed), and one more senior NAV wei must push the
     * ceil'd read strictly past it (the redemption through the floor is blocked).
     * Construction: ltRawNAV = j x minLiq exactly provisions a senior effective NAV of j x WAD, so
     *   ceil(j x WAD x minLiq / (j x minLiq)) == WAD and adding 1 senior wei adds ceil(minLiq / (j x minLiq)) == 1
     */
    function testFuzz_LiquidityUtilization_ExactBoundaryReadsOneHundredPercentAndOneMoreWeiExceedsIt(uint256 _j, uint256 _minLiq) public pure {
        _minLiq = bound(_minLiq, 1, WAD - 1); // positive requirement below 100%, setMinLiquidity's config range
        _j = bound(_j, 1, MAX_NAV / WAD); // scale factor keeping stEffectiveNAV = j x WAD inside the NAV domain
        uint256 ltRaw = _j * _minLiq; // the exact pool depth that provisions the senior NAV at precisely 100%
        uint256 stEff = _j * WAD;

        uint256 atBoundary = UtilizationLogic._computeLiquidityUtilization(toNAVUnits(stEff), _minLiq, toNAVUnits(ltRaw));
        assertEq(atBoundary, WAD, "the exactly-provisioned pool must read exactly 100%, keeping the <= gate open");

        uint256 pastBoundary = UtilizationLogic._computeLiquidityUtilization(toNAVUnits(stEff + 1), _minLiq, toNAVUnits(ltRaw));
        assertEq(pastBoundary, WAD + 1, "one senior NAV wei past the boundary must read 100% + 1 wei, tripping the <= gate");
    }
}
