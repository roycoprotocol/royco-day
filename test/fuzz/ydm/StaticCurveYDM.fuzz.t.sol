// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { MarketState } from "../../../src/libraries/Types.sol";
import { StaticCurveYDM } from "../../../src/ydm/StaticCurveYDM.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";

/**
 * @title StaticCurveYDMFuzz
 * @notice Fuzz properties for the static piecewise yield curve: exact agreement with the independent
 *         RoycoTestMath mirror over the whole valid parameter space, monotonicity of the output as
 *         utilization rises through the kink, and the hard 100% caps on both the input and the output
 * @dev The test contract itself plays the accountant: it initializes the curve as msg.sender and reads
 *      the share back for that same key, exactly as a production accountant would
 */
contract StaticCurveYDMFuzz is Test {
    /// @notice WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /**
     * @notice Bounds a fuzzed parameter tuple into a curve the production contract can actually store
     * @dev targetU stays in [1, WAD - 1]: the slope of each region divides its rise by the region's run
     *      (targetU below the kink, WAD - targetU above), so both runs must be nonzero for initialization
     *      to succeed. Each rise is additionally capped so the stored uint64 slope cannot overflow:
     *      slope = floor(rise * WAD / run) <= type(uint64).max iff rise <= floor(uint64max * run / WAD)
     * @return targetU The kink utilization, y0/yT/yFull the curve points with 0 <= y0 <= yT <= yFull <= WAD and yT >= 1
     */
    function _boundCurve(
        uint256 _targetU,
        uint256 _yT,
        uint256 _riseLt,
        uint256 _riseGte
    )
        internal
        pure
        returns (uint256 targetU, uint256 y0, uint256 yT, uint256 yFull)
    {
        targetU = bound(_targetU, 1, WAD - 1); // uniform over every kink both regions can be built around
        yT = bound(_yT, 1, WAD); // uniform over the positive share range (the contract treats yT == 0 as uninitialized)

        // Below-kink rise: at most yT (so y0 >= 0) and at most the uint64-slope fit for a run of targetU
        uint256 riseLtMax = uint256(type(uint64).max) * targetU / WAD;
        if (riseLtMax > yT) riseLtMax = yT;
        y0 = yT - bound(_riseLt, 0, riseLtMax); // uniform over the feasible below-kink rises incl. the flat edge

        // Above-kink rise: at most WAD - yT (so yFull <= WAD) and at most the uint64-slope fit for a run of WAD - targetU
        uint256 riseGteMax = uint256(type(uint64).max) * (WAD - targetU) / WAD;
        if (riseGteMax > WAD - yT) riseGteMax = WAD - yT;
        yFull = yT + bound(_riseGte, 0, riseGteMax); // uniform over the feasible above-kink rises incl. the flat edge
    }

    /// @notice Deploys a static curve at the given kink and initializes it with this test as the market accountant
    function _deployCurve(uint256 _targetU, uint256 _y0, uint256 _yT, uint256 _yFull) internal returns (StaticCurveYDM ydm) {
        ydm = new StaticCurveYDM(_targetU);
        ydm.initializeYDMForMarket(uint64(_y0), uint64(_yT), uint64(_yFull));
    }

    /**
     * Property: the production curve output equals the independent RoycoTestMath re-derivation exactly, at
     * every utilization (below, at, and above the kink, and past 100%), the mutating call returns the same
     * value as the preview (the static curve has no state to adapt), the market state is irrelevant to a
     * static curve, and the output never exceeds 100%
     */
    function testFuzz_StaticCurve_outputMatchesIndependentDerivationExactly(
        uint256 _targetU,
        uint256 _yT,
        uint256 _riseLt,
        uint256 _riseGte,
        uint256 _u
    )
        public
    {
        (uint256 targetU, uint256 y0, uint256 yT, uint256 yFull) = _boundCurve(_targetU, _yT, _riseLt, _riseGte);
        uint256 u = bound(_u, 0, 2 * WAD); // half the mass below 100% (spanning the kink), half in the over-capacity region

        StaticCurveYDM ydm = _deployCurve(targetU, y0, yT, yFull);

        uint256 preview = ydm.previewYieldShare(MarketState.PERPETUAL, u);
        assertEq(preview, RoycoTestMath.staticYdm(u, y0, yT, yFull, targetU), "static curve output must equal the independent mirror exactly");

        // A static curve reads identically in both market states (nothing adapts, so nothing is state-dependent)
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, u), preview, "market state must not change a static curve's output");

        // The mutating call only emits an event, so it must return exactly what the preview promised
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, u), preview, "mutating call must return the previewed share");

        // The share paid can never exceed the whole of the paying tranche's yield
        assertLe(preview, WAD, "yield share must never exceed 100%");
    }

    /**
     * Property: the curve is monotone non-decreasing in utilization across its whole domain, including pairs
     * that straddle the kink. Scarcer service must never be paid less: both slopes are non-negative by the
     * initialization constraint y0 <= yT <= yFull, and the value just below the kink is at most yT because
     * the stored slope is floored, so no rounding artifact can invert the ordering either
     */
    function testFuzz_StaticCurve_yieldShareNeverFallsAsUtilizationRises(
        uint256 _targetU,
        uint256 _yT,
        uint256 _riseLt,
        uint256 _riseGte,
        uint256 _uLo,
        uint256 _uHi
    )
        public
    {
        (uint256 targetU, uint256 y0, uint256 yT, uint256 yFull) = _boundCurve(_targetU, _yT, _riseLt, _riseGte);
        uint256 uLo = bound(_uLo, 0, 2 * WAD); // both points span below/at/above the kink and the over-capacity region
        uint256 uHi = bound(_uHi, 0, 2 * WAD); // ordered below, so every pair (incl. equal points) is exercised
        if (uLo > uHi) (uLo, uHi) = (uHi, uLo);

        StaticCurveYDM ydm = _deployCurve(targetU, y0, yT, yFull);

        assertLe(
            ydm.previewYieldShare(MarketState.PERPETUAL, uLo),
            ydm.previewYieldShare(MarketState.PERPETUAL, uHi),
            "a higher utilization must never be paid a smaller yield share"
        );
    }

    /**
     * Property: any utilization at or beyond 100% reads exactly as 100%. Over-capacity demand is reported
     * above WAD by the caller and must saturate rather than extrapolate, so the whole over-capacity range
     * collapses onto the single full-utilization output, which itself never exceeds 100%
     */
    function testFuzz_StaticCurve_overCapacityUtilizationReadsAsFull(
        uint256 _targetU,
        uint256 _yT,
        uint256 _riseLt,
        uint256 _riseGte,
        uint256 _u
    )
        public
    {
        (uint256 targetU, uint256 y0, uint256 yT, uint256 yFull) = _boundCurve(_targetU, _yT, _riseLt, _riseGte);
        uint256 u = bound(_u, WAD, type(uint256).max); // the entire over-capacity range up to the absolute maximum input

        StaticCurveYDM ydm = _deployCurve(targetU, y0, yT, yFull);

        uint256 atFull = ydm.previewYieldShare(MarketState.PERPETUAL, WAD);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, u), atFull, "over-capacity utilization must saturate at the 100% output");
        assertEq(atFull, RoycoTestMath.staticYdm(WAD, y0, yT, yFull, targetU), "the 100% output must equal the independent mirror exactly");
        assertLe(atFull, WAD, "yield share must never exceed 100%");
    }
}
