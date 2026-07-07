// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { FixedPointMathLib } from "../../../lib/solady/src/utils/FixedPointMathLib.sol";
import { MarketState } from "../../../src/libraries/Types.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title TestFuzz_YieldShare_AdaptiveCurveYDM
 * @notice Fuzz properties for the adaptive yield curve: the output always sits inside the envelope allowed
 *         by the maximum adaptation speed and the fixed spreads, the preview equals the mutating return,
 *         the curve is frozen (time-invariant) while the market is in its fixed term, and a full century
 *         between adaptations never reverts
 * @dev The test contract plays the accountant: it initializes and queries the curve as msg.sender.
 *      Deployment constants are pinned as literals with their constructor arithmetic shown, then every
 *      envelope bound is derived from those literals independently of the contract's internals
 */
contract TestFuzz_YieldShare_AdaptiveCurveYDM is Test {
    /// @notice WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /// @dev Deployment floor on the share at the kink: the V2 constructor passes 0.0001e18 (one basis point)
    uint256 internal constant MIN_YT = 0.0001e18;

    /// @dev Deployment ceiling on the share at the kink: the V2 constructor passes WAD (100%)
    uint256 internal constant MAX_YT = WAD;

    /// @dev Deployment max adaptation speed per second: the V2 constructor passes 100e18 / 365 days = 3_170_979_198_376 wei/s
    uint256 internal constant MAX_SPEED = 100e18 / uint256(365 days);

    /// @dev One below solady expWad's overflow threshold, the clamp the adaptation applies before exponentiating
    int256 internal constant MAX_LINEAR_ADAPTATION = 135_305_999_368_893_231_589 - 1;

    /// @dev Bundle of one bounded curve deployment so the tests stay within stack limits
    struct Curve {
        AdaptiveCurveYDM_V2 ydm;
        uint256 targetU;
        uint256 y0;
        uint256 yT;
        uint256 yFull;
    }

    /**
     * @notice Bounds a fuzzed tuple into a valid adaptive curve and deploys + initializes it
     * @dev Initialization requires MIN_YT <= yT (so the stored share is never the uninitialized zero sentinel),
     *      y0 <= yT <= yFull <= WAD, and a kink in (0, WAD]. The spreads yT - y0 and yFull - yT are stored as
     *      the fixed discount/premium, both at most WAD so the uint64 fields cannot overflow
     */
    function _deployBoundedCurve(uint256 _targetU, uint256 _yT, uint256 _spreadDown, uint256 _spreadUp) internal returns (Curve memory c) {
        c.targetU = bound(_targetU, 1, WAD); // uniform over the whole constructible kink range incl. the 100% edge
        c.yT = bound(_yT, MIN_YT, WAD); // uniform over every share at target the deployment clamps allow
        c.y0 = c.yT - bound(_spreadDown, 0, c.yT); // uniform over the feasible zero-utilization discounts incl. flat
        c.yFull = c.yT + bound(_spreadUp, 0, WAD - c.yT); // uniform over the feasible full-utilization premiums incl. flat

        c.ydm = new AdaptiveCurveYDM_V2(c.targetU);
        c.ydm.initializeYDMForMarket(uint64(c.y0), uint64(c.yT), uint64(c.yFull));

        // The deployment constants the envelope below is derived from, pinned against the live instance
        assertEq(c.ydm.MIN_YIELD_SHARE_AT_TARGET_WAD(), MIN_YT, "deployed floor on the share at target must be 0.0001e18");
        assertEq(c.ydm.MAX_YIELD_SHARE_AT_TARGET_WAD(), MAX_YT, "deployed ceiling on the share at target must be WAD");
        assertEq(c.ydm.MAX_ADAPTATION_SPEED_WAD(), MAX_SPEED, "deployed max adaptation speed must be 100e18 / 365 days");
    }

    /**
     * @notice Stamps the curve's adaptation clock at the current timestamp without moving the stored share
     * @dev The first-ever mutating call treats the elapsed time as zero (nothing to adapt from), and applying
     *      a zero linear adaptation multiplies the stored share by expWad(0) == WAD exactly, so only the
     *      timestamp changes. Verified here so every test's drift window provably starts at the initial share
     */
    function _stampAdaptationClock(Curve memory c, uint256 _u) internal {
        c.ydm.yieldShare(MarketState.PERPETUAL, _u);
        (uint64 storedYT, uint32 lastTs,,) = c.ydm.accountantToCurve(address(this));
        assertEq(storedYT, c.yT, "the first mutating call must not move the stored share at target");
        assertEq(lastTs, uint32(block.timestamp), "the first mutating call must stamp the adaptation clock");
    }

    /**
     * @notice One extreme point of the drift envelope: the stored share after the largest allowed adaptation
     * @dev Mirrors only the outer shape the speed limit imposes: exponentiate the extreme linear adaptation
     *      (clamped below expWad's overflow threshold exactly as production clamps it) and clamp the result to
     *      the deployment [MIN_YT, MAX_YT] band. Any realized adaptation is milder, because the realized speed
     *      is the max speed scaled down by the normalized distance from the kink
     */
    function _extremeAdaptedShare(uint256 _startYT, int256 _extremeLinear) internal pure returns (uint256 point) {
        if (_extremeLinear > MAX_LINEAR_ADAPTATION) _extremeLinear = MAX_LINEAR_ADAPTATION;
        point = Math.mulDiv(_startYT, uint256(FixedPointMathLib.expWad(_extremeLinear)), WAD);
        if (point < MIN_YT) point = MIN_YT;
        if (point > MAX_YT) point = MAX_YT;
    }

    /**
     * Property: in a perpetual market the output can never escape the speed-bounded drift envelope. Over a
     * window of `elapsed` seconds the linear adaptation is at most MAX_SPEED * elapsed in magnitude, so every
     * adapted point (start, mid, end, and their average) lies between the two extreme adapted shares, and the
     * final output adds at most the fixed spread on its side of the kink. The persisted share at target must
     * land inside the same band, drift in the direction of the utilization imbalance, and the whole result
     * must equal the independent RoycoTestMath re-derivation exactly. Preview must equal the mutating return
     */
    function testFuzz_AdaptiveCurve_OutputStaysInsideSpeedBoundedDriftEnvelope(
        uint256 _targetU,
        uint256 _yT,
        uint256 _spreadDown,
        uint256 _spreadUp,
        uint256 _u,
        uint256 _elapsed
    )
        public
    {
        Curve memory c = _deployBoundedCurve(_targetU, _yT, _spreadDown, _spreadUp);
        uint256 u = bound(_u, 0, 2 * WAD); // half the mass below 100% (spanning the kink), half over-capacity
        uint256 elapsed = bound(_elapsed, 0, 10 * 365 days); // zero to a decade between adaptations

        _stampAdaptationClock(c, u);
        vm.warp(block.timestamp + elapsed);

        uint256 preview = c.ydm.previewYieldShare(MarketState.PERPETUAL, u);
        uint256 output = c.ydm.yieldShare(MarketState.PERPETUAL, u);
        assertEq(output, preview, "preview must equal the mutating return");

        // Exact agreement with the independent mirror on both the output and the persisted curve position
        RoycoTestMath.AdaptiveCurveYieldShareOutputs memory expected = RoycoTestMath.adaptiveCurveYieldShare(
            RoycoTestMath.AdaptiveCurveYieldShareInputs({
                utilizationWAD: u,
                targetUtilizationWAD: c.targetU,
                startYieldShareAtTargetWAD: c.yT,
                elapsedSeconds: elapsed,
                discountToTargetAtZeroUtilWAD: c.yT - c.y0,
                premiumToTargetAtFullUtilWAD: c.yFull - c.yT,
                maxAdaptationSpeedWAD: MAX_SPEED,
                minYieldShareAtTargetWAD: MIN_YT,
                maxYieldShareAtTargetWAD: MAX_YT,
                perpetual: true
            })
        );
        assertEq(output, expected.yieldShareWAD, "adaptive output must equal the independent mirror exactly");
        (uint64 storedYT,,,) = c.ydm.accountantToCurve(address(this));
        assertEq(storedYT, expected.endYieldShareAtTargetWAD, "persisted share at target must equal the independent mirror exactly");

        // Drift envelope: |linear adaptation| <= MAX_SPEED * elapsed, so the persisted share is pinned between
        // the two extreme adapted points, and the output adds at most the fixed spread on its side of the kink
        uint256 maxLinear = MAX_SPEED * elapsed;
        uint256 upPoint = _extremeAdaptedShare(c.yT, int256(maxLinear));
        uint256 downPoint = _extremeAdaptedShare(c.yT, -int256(maxLinear));
        assertGe(storedYT, downPoint, "persisted share cannot fall faster than the max adaptation speed");
        assertLe(storedYT, upPoint, "persisted share cannot rise faster than the max adaptation speed");

        uint256 spreadDown = c.yT - c.y0;
        uint256 lowerBound = downPoint > spreadDown ? downPoint - spreadDown : 0;
        uint256 upperBound = upPoint + (c.yFull - c.yT);
        if (upperBound > WAD) upperBound = WAD;
        assertGe(output, lowerBound, "output cannot undershoot the envelope floor (max downward drift minus the full discount)");
        assertLe(output, upperBound, "output cannot overshoot the envelope ceiling (max upward drift plus the full premium)");
        assertLe(output, WAD, "yield share must never exceed 100%");

        // Drift direction follows the imbalance: scarce service (at or above the kink) never adapts the curve
        // down, abundant service (below the kink) never adapts it up
        uint256 uCapped = u > WAD ? WAD : u;
        if (uCapped >= c.targetU) assertGe(storedYT, c.yT, "at or above the kink the curve must not adapt downward");
        else assertLe(storedYT, c.yT, "below the kink the curve must not adapt upward");
    }

    /**
     * Property: while the market is in its fixed term the curve does not adapt, no matter how much time
     * passes. The stored share at target is untouched, the output is the pure spread formula evaluated at the
     * unadapted share (derived by hand below), and re-reading at any later time returns the identical value.
     * The mutating call still restamps the adaptation clock, which is pinned here because it means a later
     * perpetual adaptation measures its elapsed window from the fixed-term call, not from before it
     */
    function testFuzz_AdaptiveCurve_CurveIsFrozenWhileMarketIsInFixedTerm(
        uint256 _targetU,
        uint256 _yT,
        uint256 _spreadDown,
        uint256 _spreadUp,
        uint256 _u,
        uint256 _elapsed,
        uint256 _elapsedAfter
    )
        public
    {
        Curve memory c = _deployBoundedCurve(_targetU, _yT, _spreadDown, _spreadUp);
        uint256 u = bound(_u, 0, 2 * WAD); // half the mass below 100% (spanning the kink), half over-capacity
        uint256 elapsed = bound(_elapsed, 0, 10 * 365 days); // zero to a decade of frozen time before the call
        uint256 elapsedAfter = bound(_elapsedAfter, 0, 10 * 365 days); // and another zero to a decade after it

        _stampAdaptationClock(c, u);
        vm.warp(block.timestamp + elapsed);

        uint256 preview = c.ydm.previewYieldShare(MarketState.FIXED_TERM, u);
        uint256 output = c.ydm.yieldShare(MarketState.FIXED_TERM, u);
        assertEq(output, preview, "preview must equal the mutating return");

        // Hand-derived expectation with zero time term: normalize the distance from the kink over its region,
        // scale the fixed spread on that side, and add it to the UNADAPTED share, clamping into [0, WAD]
        uint256 uCapped = u > WAD ? WAD : u;
        uint256 regionWidth = uCapped > c.targetU ? WAD - c.targetU : c.targetU;
        int256 normalizedDelta = ((int256(uCapped) - int256(c.targetU)) * int256(WAD)) / int256(regionWidth);
        uint256 spread = normalizedDelta < 0 ? c.yT - c.y0 : c.yFull - c.yT;
        int256 signedExpected = int256(c.yT) + (normalizedDelta * int256(spread)) / int256(WAD);
        uint256 expected = signedExpected <= 0 ? 0 : (signedExpected >= int256(WAD) ? WAD : uint256(signedExpected));
        assertEq(output, expected, "fixed-term output must be the pure spread formula at the unadapted share");

        // The stored share is untouched, the clock is restamped at the fixed-term call
        (uint64 storedYT, uint32 lastTs,,) = c.ydm.accountantToCurve(address(this));
        assertEq(storedYT, c.yT, "fixed term must not move the stored share at target");
        assertEq(lastTs, uint32(block.timestamp), "the fixed-term mutating call restamps the adaptation clock");

        // Time invariance: any later fixed-term read returns the identical output
        vm.warp(block.timestamp + elapsedAfter);
        assertEq(c.ydm.previewYieldShare(MarketState.FIXED_TERM, u), output, "fixed-term output must be identical at any later time");
    }

    /**
     * Property: a full century between adaptations never reverts. The linear adaptation grows to
     * MAX_SPEED * 100 years = 3_170_979_198_376 * 3_153_600_000 ≈ 1e22, far past expWad's overflow threshold
     * of ~135.3e18, so this exercises the internal clamp on the up side and expWad's zero saturation on the
     * down side. The call must succeed and the output must still respect the 100% cap and equal its preview
     */
    function testFuzz_AdaptiveCurve_ToleratesACenturyBetweenAdaptations(
        uint256 _targetU,
        uint256 _yT,
        uint256 _spreadDown,
        uint256 _spreadUp,
        uint256 _u,
        uint256 _elapsed
    )
        public
    {
        Curve memory c = _deployBoundedCurve(_targetU, _yT, _spreadDown, _spreadUp);
        uint256 u = bound(_u, 0, 2 * WAD); // half the mass below 100% (spanning the kink), half over-capacity
        uint256 elapsed = bound(_elapsed, 0, 100 * 365 days); // zero to a full century between adaptations

        _stampAdaptationClock(c, u);
        vm.warp(block.timestamp + elapsed);

        uint256 preview = c.ydm.previewYieldShare(MarketState.PERPETUAL, u);
        uint256 output = c.ydm.yieldShare(MarketState.PERPETUAL, u);
        assertEq(output, preview, "preview must equal the mutating return");
        assertLe(output, WAD, "yield share must never exceed 100%");

        // The persisted share must still respect the deployment band even at the century extreme
        (uint64 storedYT,,,) = c.ydm.accountantToCurve(address(this));
        assertGe(uint256(storedYT), MIN_YT, "persisted share cannot decay below the deployment floor");
        assertLe(uint256(storedYT), MAX_YT, "persisted share cannot grow above the deployment ceiling");
    }
}
