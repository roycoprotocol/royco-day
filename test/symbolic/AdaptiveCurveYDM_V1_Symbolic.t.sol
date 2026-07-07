// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { MarketState } from "../../src/libraries/Types.sol";
import { SeedableAdaptiveCurveYDM_V1 } from "../mocks/SeedableAdaptiveCurveYDM_V1.sol";

/**
 * @title AdaptiveCurveYDMV1SymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for the V1 adaptive piecewise yield curve: the
 *         initialization partition with its floored steepness quotient and adaptation-clock reset, the
 *         coefficient bounds that keep the below-target leg from ever going negative, the exact truncated
 *         forms of both curve legs, the three curve anchors (the kink, full utilization, zero utilization),
 *         monotonicity in utilization across both legs and the kink, and totality of an initialized curve
 *         with the output bounded to one hundred percent of the paying tranche's yield
 * @dev Every curve-shape check runs on the same-block slice: no time has elapsed since the last adaptation
 *      (the seeded adaptation clock is zero), so the exponential adaptation pipeline is an exact identity and
 *      the curve is evaluated at the stored yield share at target verbatim. The exponential never receives a
 *      symbolic argument: off-slice behavior is exercised by a concrete elapsed-and-utilization grid here and
 *      owned in depth by the shared adaptive-base symbolic file, the concrete YDM suites, and the YDM
 *      invariant suite
 * @dev Curve states are seeded directly as (stored yield share, steepness) pairs over the full reachable
 *      envelope: initialization stores a steepness in [WAD, 1e22] (proven by the initialization check below)
 *      and later adaptations move only the stored yield share, clamped to [1e14, WAD], while steepness stays
 *      fixed, so the seeded cross product of the two intervals is exactly the reachable set of curve states.
 *      Expected values are derived independently as plain checked multiply-and-divide (every product fits far
 *      under 2^256 on this domain) with signed truncation rewritten as unsigned floors plus an explicit sign,
 *      never by re-running the production arithmetic as its own expectation
 */
contract AdaptiveCurveYDMV1SymbolicSpec is Test {
    /// @dev The target utilization (the kink) for the instance under test: 80%, asymmetric on purpose so the
    ///      below-target divisor (0.8e18) and the above-target divisor (0.2e18) are distinct
    uint256 internal constant TARGET_UTIL = 0.8e18;

    /// @dev The instance's bounds on the stored yield share at target (set by the V1 constructor)
    uint256 internal constant MIN_YT = 0.0001e18;
    uint256 internal constant MAX_YT = WAD;

    /// @dev The extreme steepness a valid initialization can store: WAD * WAD / MIN_YT
    uint256 internal constant MAX_STEEPNESS = 1e22;

    /// @dev The concrete block timestamp every check runs at (fits the curve's uint32 adaptation clock)
    uint256 internal constant SYNC_TIMESTAMP = 4_000_000_000;

    SeedableAdaptiveCurveYDM_V1 internal ydm;

    function setUp() public {
        ydm = new SeedableAdaptiveCurveYDM_V1(TARGET_UTIL);
        vm.warp(SYNC_TIMESTAMP);
    }

    /// @dev Seeds this test contract's market with a curve state on the same-block slice (adaptation clock
    ///      zero), covering the full reachable envelope of post-adaptation curve states
    function _seedCurve(uint64 _storedYT, uint160 _steepness) internal {
        ydm.seedCurve(address(this), _storedYT, 0, _steepness);
    }

    /// @dev The reachable curve-state envelope: the stored yield share at target is clamped by every
    ///      adaptation write to [MIN_YT, MAX_YT], and the steepness is the floored initialization quotient
    ///      in [WAD, MAX_STEEPNESS] (both interval bounds proven by the initialization partition check)
    function _assumeReachableCurve(uint64 _storedYT, uint160 _steepness) internal pure {
        vm.assume(MIN_YT <= _storedYT && _storedYT <= MAX_YT);
        vm.assume(WAD <= _steepness && _steepness <= MAX_STEEPNESS);
    }

    /*//////////////////////////////////////////////////////////////////////
                        INITIALIZATION PARTITION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialization succeeds exactly when the initial curve is ordered inside the model's bounds
     *         (yield share at target in [0.0001e18, WAD] and at most the yield share at full utilization,
     *         which is at most WAD), and on success it stores the yield share at target verbatim, stores the
     *         steepness as the floored ratio of the full-utilization share to the target share, and clears
     *         the adaptation clock even when a previous curve had already adapted
     * @dev Economic why: the accountant wires this pricing curve at market creation, and every premium the
     *      market ever pays is scaled by these two stored numbers, so a config that would misprice (a curve
     *      that pays less at full utilization than at target, or a share above one hundred percent) must be
     *      loudly rejected rather than stored. Clearing the clock on reinitialization matters because a stale
     *      clock would immediately apply a huge phantom adaptation to the fresh curve. The steepness bracket
     *      is stated division-free (S * yT <= yFull * WAD < (S + 1) * yT defines the floored quotient), and
     *      its two interval corollaries (steepness at least WAD because yFull >= yT, and at most 1e22 because
     *      yFull <= WAD while yT >= 1e14) are the envelope every seeded check below relies on. The padding
     *      input routes the query past the engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_v1Init_acceptsExactlyOrderedCurvesStoresFlooredSteepnessAndClearsClock(uint64 yT, uint64 yFull, uint256 p1) external {
        vm.assume(p1 <= 3);

        // Concrete prelude: initialize a valid curve and adapt it once so the adaptation clock is stamped
        // nonzero, making the clock-clearing half of the property observable on the symbolic reinitialization
        ydm.initializeYDMForMarket(uint64(0.01e18), uint64(0.1e18));
        ydm.yieldShare(MarketState.PERPETUAL, TARGET_UTIL);
        (, uint32 stampedClock,) = ydm.accountantToCurve(address(this));
        assert(stampedClock == uint32(SYNC_TIMESTAMP + p1 - p1));

        // The exact acceptance predicate, derived from the model's documented bounds: an ordered curve
        // 0.0001e18 <= yT <= yFull <= WAD (the target share floor keeps the steepness quotient finite and
        // bounded, and WAD caps both shares at one hundred percent of the paying tranche's yield)
        bool valid = MIN_YT <= yT && uint256(yT) <= yFull && uint256(yFull) <= WAD;

        try ydm.initializeYDMForMarket(yT, yFull) {
            assert(valid);
            (uint64 storedYT, uint32 clock, uint160 steepness) = ydm.accountantToCurve(address(this));
            // The target share is stored verbatim and the adaptation clock is cleared by the reinit
            assert(storedYT == yT);
            assert(clock == 0);
            // The stored steepness is the floored quotient floor(yFull * WAD / yT), characterized
            // division-free by its two-sided product bracket
            assert(uint256(steepness) * yT <= uint256(yFull) * WAD);
            assert(uint256(yFull) * WAD < (uint256(steepness) + 1) * yT);
            // Envelope corollaries consumed by every seeded curve-shape check: yFull >= yT forces the
            // quotient to at least WAD, and yFull <= WAD with yT >= 0.0001e18 caps it at 1e22
            assert(WAD <= steepness && uint256(steepness) <= MAX_STEEPNESS);
        } catch {
            assert(!valid);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                        COEFFICIENT BOUNDS (THE NO-WRAP CORE)
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Over the whole reachable curve envelope, the below-target discount coefficient stays inside
     *         [0, WAD - 1] and the above-target markup coefficient stays nonnegative, so the below-target leg
     *         can discount the target share by strictly less than one hundred percent and its signed
     *         intermediate can never go negative: the curve output below the kink is always within the stored
     *         target share, never a negative value wrapped through the final unsigned cast
     * @dev Economic why: below target the service is under-used, so the pool is paid a discount of the target
     *      share, but a discount at or beyond one hundred percent would price the service at zero or negative
     *      and (through the signed-to-unsigned cast plus the WAD cap) could masquerade as a one hundred
     *      percent premium instead. Derivation of the bounds: the reciprocal-steepness term floor(WAD^2 / S)
     *      lies in [1, WAD] because S lies in [WAD, 1e22], so the below coefficient WAD - floor(WAD^2 / S) is
     *      in [0, WAD - 1], the scaled discount floor(coeff * |delta| / WAD) with |delta| <= WAD is at most
     *      WAD - 1, and the inner factor WAD - discount is at least 1, keeping every signed intermediate
     *      positive. The observable corollary asserted on the production output: the below-target yield share
     *      never exceeds the stored target share (the exact-form check below pins the remaining wrap-shaped
     *      corner where the two coincide at WAD). The padding input routes the query past the engine's
     *      built-in arithmetic heuristic to the real SMT solver
     */
    function check_v1Curve_coefficientsBoundedAndBelowTargetOutputNeverExceedsTargetShare(uint64 storedYT, uint160 steepness, uint256 util, uint256 p1) external {
        _assumeReachableCurve(storedYT, steepness);
        // Pin the below-target region (the utilization clamp only lowers inputs to WAD, which is above the
        // kink, so the below region is entered exactly when the raw utilization is below the target)
        vm.assume(util < TARGET_UTIL);
        vm.assume(p1 <= 3);
        _seedCurve(storedYT, steepness);

        // The interval facts behind the no-wrap argument, on the seeded steepness envelope
        uint256 reciprocalSteepness = (WAD * WAD) / uint256(steepness);
        assert(1 <= reciprocalSteepness && reciprocalSteepness <= WAD);

        // The production observable: a below-target utilization is never paid more than the target share
        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, util + p1 - p1);
        assert(yieldShare <= storedYT);
    }

    /*//////////////////////////////////////////////////////////////////////
                            THE KINK ANCHOR
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice At exactly the target utilization the curve pays exactly the stored yield share at target: the
     *         normalized delta is zero, so both curve legs collapse to the identity on the target share with
     *         no rounding loss at all
     * @dev Economic why: the target share is the calibrated price of the service at its intended utilization,
     *      and the kink is the one point both curve legs share, so any wei of drift here would mean the model
     *      never actually pays its own calibration point. Derivation: at the kink the delta numerator
     *      (utilization minus target) is zero, so the normalized delta is exactly zero, the coefficient term
     *      vanishes, and the output is floor(WAD * yT / WAD) == yT exactly. The padding inputs route the
     *      query past the engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_v1Curve_outputAtTargetUtilizationEqualsTargetShareExactly(uint64 storedYT, uint160 steepness, uint256 p1, uint256 p2) external {
        _assumeReachableCurve(storedYT, steepness);
        vm.assume(p1 <= 3 && p2 <= 3);
        _seedCurve(storedYT, steepness);

        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, TARGET_UTIL + p1 - p1 + p2 - p2);
        assert(yieldShare == storedYT);
    }

    /*//////////////////////////////////////////////////////////////////////
                        EXACT FORM OF THE BELOW-TARGET LEG
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Below the target utilization the curve output is exactly the unsigned truncated form
     *         floor((WAD - floor(c * d / WAD)) * yT / WAD), where d is the floored normalized distance below
     *         the kink floor((targetUtil - util) * WAD / targetUtil) and c is the below-target coefficient
     *         WAD - floor(WAD^2 / S): the pool's pay scales down linearly with how far below target the
     *         service utilization sits, flattened by the reciprocal of the steepness
     * @dev Economic why: this is the exact price schedule of the under-utilized region, and any divergence
     *      from it would mean the premium paid out of senior yield is not the advertised function of measured
     *      utilization. Derivation of the unsigned form from the signed production path: the signed delta is
     *      the truncated quotient of a negative numerator, and Solidity's signed division truncates toward
     *      zero, so it equals the negated unsigned floor -d with d as above. The coefficient is nonnegative
     *      (steepness is at least WAD), so coefficient times delta is nonpositive and its truncated division
     *      by WAD is the negated floor -floor(c * d / WAD), which is strictly above -WAD, making the inner
     *      factor positive, so the final signed division is a plain floor and the unsigned cast is exact. The
     *      WAD cap never binds because the result is at most yT which is at most WAD. Every spec-side product
     *      here is at most about 1e40, far below 2^256, so plain checked arithmetic is exact. The padding
     *      input routes the query past the engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_v1Curve_belowTargetOutputMatchesUnsignedTruncatedForm(uint64 storedYT, uint160 steepness, uint256 util, uint256 p1) external {
        _assumeReachableCurve(storedYT, steepness);
        vm.assume(util < TARGET_UTIL);
        vm.assume(p1 <= 3);
        _seedCurve(storedYT, steepness);

        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, util + p1 - p1);

        // Independently derived unsigned truncated form (plain checked multiply-and-divide throughout)
        uint256 distanceBelow = ((TARGET_UTIL - util) * WAD) / TARGET_UTIL;
        uint256 belowCoefficient = WAD - (WAD * WAD) / uint256(steepness);
        uint256 expected = ((WAD - (belowCoefficient * distanceBelow) / WAD) * storedYT) / WAD;
        assert(yieldShare == expected);
    }

    /*//////////////////////////////////////////////////////////////////////
                        EXACT FORM OF THE ABOVE-TARGET LEG
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Above the target utilization (up to full), when the uncapped value fits under one hundred
     *         percent, the curve output is exactly floor((floor((S - WAD) * d / WAD) + WAD) * yT / WAD) with
     *         d the floored normalized distance above the kink floor((util - targetUtil) * WAD /
     *         (WAD - targetUtil)): the pool's pay scales up linearly with how far above target the service
     *         utilization sits, amplified by the steepness
     * @dev Economic why: this is the exact price schedule of the scarce region, the restoring force that
     *      raises the premium when the service the pool provides is over-subscribed, so it must be exactly
     *      the advertised function of measured utilization. Derivation: above the kink the signed delta is a
     *      nonnegative truncated quotient which equals the unsigned floor d, the coefficient S - WAD is
     *      nonnegative, so every signed intermediate is nonnegative and each signed division is a plain
     *      unsigned floor, with the final cast exact. The uncapped sub-region is pinned by assuming the
     *      derived value fits under WAD, so the production cap provably does not fire. The padding input
     *      routes the query past the engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_v1Curve_aboveTargetOutputMatchesUnsignedTruncatedFormWhenUncapped(uint64 storedYT, uint160 steepness, uint256 util, uint256 p1) external {
        _assumeReachableCurve(storedYT, steepness);
        // Pin the above-target region proper (the kink itself is anchored by its own check)
        vm.assume(TARGET_UTIL < util && util <= WAD);
        vm.assume(p1 <= 3);
        _seedCurve(storedYT, steepness);

        // Independently derived unsigned truncated form of the above-target leg
        uint256 distanceAbove = ((util - TARGET_UTIL) * WAD) / (WAD - TARGET_UTIL);
        uint256 uncapped = ((((uint256(steepness) - WAD) * distanceAbove) / WAD + WAD) * storedYT) / WAD;
        // Pin the sub-region where the one hundred percent cap does not bind
        vm.assume(uncapped <= WAD);

        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, util + p1 - p1);
        assert(yieldShare == uncapped);
    }

    /**
     * @notice Above the target utilization, when the steepness-amplified markup would push the pay past one
     *         hundred percent of the paying tranche's yield, the curve output is capped at exactly WAD
     * @dev Economic why: the output is a share of yield, so paying more than one hundred percent would mint
     *      premium out of principal rather than yield. The capped sub-region is genuinely reachable on the
     *      adapted envelope (a steep curve whose stored target share has adapted upward can price past WAD
     *      near full utilization) even though a freshly initialized curve tops out at its configured full
     *      utilization share. Derivation as in the uncapped twin, with the sub-region pinned by assuming the
     *      derived uncapped value exceeds WAD. The padding input routes the query past the engine's built-in
     *      arithmetic heuristic to the real SMT solver
     */
    function check_v1Curve_aboveTargetOutputCapsAtOneHundredPercent(uint64 storedYT, uint160 steepness, uint256 util, uint256 p1) external {
        _assumeReachableCurve(storedYT, steepness);
        vm.assume(TARGET_UTIL < util && util <= WAD);
        vm.assume(p1 <= 3);
        _seedCurve(storedYT, steepness);

        uint256 distanceAbove = ((util - TARGET_UTIL) * WAD) / (WAD - TARGET_UTIL);
        uint256 uncapped = ((((uint256(steepness) - WAD) * distanceAbove) / WAD + WAD) * storedYT) / WAD;
        // Pin the sub-region where the one hundred percent cap binds
        vm.assume(uncapped > WAD);

        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, util + p1 - p1);
        assert(yieldShare == WAD);
    }

    /*//////////////////////////////////////////////////////////////////////
                            THE FULL-UTILIZATION ANCHOR
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A freshly initialized curve evaluated at (or clamped down to) full utilization reproduces the
     *         configured yield share at full utilization to within one wei of flooring: the only losses are
     *         the floored steepness quotient at initialization and the final floored rescale, which together
     *         short the pool by at most one wei
     * @dev Economic why: the full-utilization share is the second calibration point an issuer configures, and
     *      the stored steepness is only a faithful encoding of it if the curve actually reproduces it at full
     *      utilization. Derivation: any utilization at or above WAD is clamped to WAD, where the normalized
     *      delta is exactly WAD (the distance equals the region width), so the inner factor is exactly the
     *      stored steepness S and the output is floor(S * yT / WAD). The initialization bracket
     *      S * yT <= yFull * WAD < (S + 1) * yT gives floor(S * yT / WAD) <= yFull directly, and
     *      S * yT > yFull * WAD - yT >= (yFull - 1) * WAD (since yT <= WAD) gives floor(S * yT / WAD) >=
     *      yFull - 1, so the output lands in [yFull - 1, yFull] and the WAD cap never fires. The padding
     *      input routes the query past the engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_v1Curve_fullUtilizationReproducesFullShareWithinOneWei(uint64 yT, uint64 yFull, uint256 util, uint256 p1) external {
        // A valid initialization pair: the coupling between the stored steepness and the configured full
        // share is the content here, so this check goes through the real initialization
        vm.assume(MIN_YT <= yT && uint256(yT) <= yFull && uint256(yFull) <= WAD);
        // Fold in the utilization clamp arm: anything at or beyond WAD prices identically to exactly WAD
        vm.assume(util >= WAD);
        vm.assume(p1 <= 3);
        ydm.initializeYDMForMarket(yT, yFull);

        // The padding fold subtracts first because the utilization is unbounded above
        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, util - p1 + p1);
        assert(yieldShare <= yFull);
        assert(yieldShare + 1 >= yFull);
    }

    /*//////////////////////////////////////////////////////////////////////
                            THE ZERO-UTILIZATION ANCHOR
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice At zero utilization the curve pays exactly floor(floor(WAD^2 / S) * yT / WAD), the target share
     *         discounted by the full reciprocal of the steepness: the abundant-service floor of the price
     *         schedule, approximately yT / S, bracketed here by two division-free product bounds
     * @dev Economic why: at zero utilization the service is completely unused, so the pool earns the least
     *      the curve can pay, and that floor must still be the advertised yT / S rather than zero or a
     *      rounding artifact, because the premium floor is what makes providing the service rational at all.
     *      Derivation: at zero utilization the normalized delta is exactly -WAD (the distance equals the
     *      region width), so the scaled discount collapses to the coefficient itself and the inner factor to
     *      the reciprocal-steepness term floor(WAD^2 / S). The loose two-sided bound follows by composing the
     *      two floor brackets: the upper side Y * S <= yT * WAD, and the lower side
     *      (Y + 1) * WAD * S + S * yT > WAD^2 * yT, i.e. Y is within about one wei plus yT / WAD of the true
     *      yT * WAD / S. The padding inputs route the query past the engine's built-in arithmetic heuristic
     *      to the real SMT solver
     */
    function check_v1Curve_zeroUtilizationPaysTargetShareDiscountedBySteepness(uint64 storedYT, uint160 steepness, uint256 p1, uint256 p2) external {
        _assumeReachableCurve(storedYT, steepness);
        vm.assume(p1 <= 3 && p2 <= 3);
        _seedCurve(storedYT, steepness);

        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, 0 + p1 - p1 + p2 - p2);

        // The exact truncated form at the empty-service anchor
        uint256 reciprocalSteepness = (WAD * WAD) / uint256(steepness);
        assert(yieldShare == (reciprocalSteepness * storedYT) / WAD);

        // The loose division-free bracket around the ideal yT * WAD / S, stated in product form
        assert(yieldShare * uint256(steepness) <= uint256(storedYT) * WAD);
        assert((yieldShare + 1) * WAD * uint256(steepness) + uint256(steepness) * storedYT > WAD * WAD * uint256(storedYT));
    }

    /*//////////////////////////////////////////////////////////////////////
                        MONOTONE NONDECREASING IN UTILIZATION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Within the below-target leg, a higher utilization is never paid a smaller yield share: the
     *         discount shrinks monotonically as the service utilization climbs toward the kink
     * @dev Economic why: monotonicity is the restoring force of the premium model. If the pay could dip as
     *      utilization rises, the market would be rewarded for letting the service it depends on get scarcer,
     *      inverting the incentive the premium exists to create. Derivation: the floored distance below the
     *      kink is nonincreasing in utilization, so the floored scaled discount is nonincreasing, the inner
     *      factor is nondecreasing, and the final floored rescale preserves the order
     */
    function check_v1Curve_monotoneNondecreasingBelowTarget(uint64 storedYT, uint160 steepness, uint256 utilLow, uint256 utilHigh) external {
        _assumeReachableCurve(storedYT, steepness);
        vm.assume(utilLow <= utilHigh && utilHigh < TARGET_UTIL);
        _seedCurve(storedYT, steepness);

        uint256 shareLow = ydm.previewYieldShare(MarketState.PERPETUAL, utilLow);
        uint256 shareHigh = ydm.previewYieldShare(MarketState.PERPETUAL, utilHigh);
        assert(shareLow <= shareHigh);
    }

    /**
     * @notice Within the above-target leg (kink to full utilization), a higher utilization is never paid a
     *         smaller yield share: the steepness-amplified markup grows monotonically, and the one hundred
     *         percent cap only flattens it into a plateau, never inverts it
     * @dev Economic why: above target the service is over-subscribed and the premium must keep climbing to
     *      pull in fresh capital, so a dip would stall the model's self-healing loop exactly when it is
     *      needed most. Derivation: the floored distance above the kink is nondecreasing in utilization, so
     *      the floored scaled markup, the inner factor, and the final floored rescale are all nondecreasing,
     *      and taking the minimum with the constant WAD preserves monotonicity
     */
    function check_v1Curve_monotoneNondecreasingAboveTarget(uint64 storedYT, uint160 steepness, uint256 utilLow, uint256 utilHigh) external {
        _assumeReachableCurve(storedYT, steepness);
        vm.assume(TARGET_UTIL <= utilLow && utilLow <= utilHigh && utilHigh <= WAD);
        _seedCurve(storedYT, steepness);

        uint256 shareLow = ydm.previewYieldShare(MarketState.PERPETUAL, utilLow);
        uint256 shareHigh = ydm.previewYieldShare(MarketState.PERPETUAL, utilHigh);
        assert(shareLow <= shareHigh);
    }

    /**
     * @notice Across the kink the two legs order correctly through the target share: every below-target
     *         utilization is paid at most the stored target share, and every utilization at or above the
     *         target (including inputs beyond WAD, which clamp down to full) is paid at least it, so the
     *         curve is monotone through the regime change and the kink is its exact hinge
     * @dev Economic why: the target share is the calibrated pivot between the discounted and the amplified
     *      regime, so an under-utilized market must never out-earn an over-utilized one. Derivation: below
     *      the kink the inner factor is at most WAD, so the output floors to at most yT, and at or above the
     *      kink the nonnegative markup keeps the inner factor at least WAD, so the output is at least
     *      floor(WAD * yT / WAD) == yT, with the cap at WAD still at least yT
     */
    function check_v1Curve_monotoneAcrossTheKink(uint64 storedYT, uint160 steepness, uint256 utilBelow, uint256 utilAbove) external {
        _assumeReachableCurve(storedYT, steepness);
        vm.assume(utilBelow < TARGET_UTIL && TARGET_UTIL <= utilAbove);
        _seedCurve(storedYT, steepness);

        uint256 shareBelow = ydm.previewYieldShare(MarketState.PERPETUAL, utilBelow);
        uint256 shareAbove = ydm.previewYieldShare(MarketState.PERPETUAL, utilAbove);
        assert(shareBelow <= storedYT);
        assert(storedYT <= shareAbove);
    }

    /*//////////////////////////////////////////////////////////////////////
                    TOTALITY AND THE ONE-HUNDRED-PERCENT BOUND
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice An initialized curve on the same-block slice never reverts for any utilization in the full
     *         uint256 range and either market state, and its output never exceeds one hundred percent of the
     *         paying tranche's yield: the model is total where the accountant calls it
     * @dev Economic why: the accountant queries the YDM inside every premium-paying sync, so a revert here
     *      would brick the sync and with it every deposit and redemption in the market, and an output above
     *      WAD would draw premium out of principal rather than yield. The same-block slice is realized both
     *      by a never-adapted clock (zero) and by a clock stamped at the current block, the two ways no time
     *      can have passed. In the fixed-term state the adaptation block is skipped outright, and in the
     *      perpetual state the zero elapsed time makes it an identity, so the exponential never sees a live
     *      argument. Off-slice (nonzero elapsed) totality is exercised on the concrete grid check below
     */
    function check_v1_initializedCurveNeverRevertsAndStaysWithinFullShareOnAnyUtilization(
        uint64 storedYT,
        uint160 steepness,
        uint256 util,
        uint8 stateRaw,
        uint32 clock
    )
        external
    {
        _assumeReachableCurve(storedYT, steepness);
        // Both members of the market state machine
        vm.assume(stateRaw <= 1);
        // The two same-block slice realizations: never adapted, or adapted in this very block
        vm.assume(clock == 0 || clock == uint32(SYNC_TIMESTAMP));
        ydm.seedCurve(address(this), storedYT, clock, steepness);

        try ydm.previewYieldShare(MarketState(stateRaw), util) returns (uint256 yieldShare) {
            // A yield share is a fraction of the paying tranche's yield: never more than one hundred percent
            assert(yieldShare <= WAD);
        } catch {
            assert(false);
        }
    }

    /**
     * @notice Across a concrete grid of elapsed adaptation windows (one hour, thirty days, ten years) and
     *         utilizations (empty, the kink, full), an initialized curve with any reachable stored state
     *         never reverts and never pays more than one hundred percent: the exponential adaptation path,
     *         including its deep-decay floor and its linear-adaptation clamp, is total over the stored state
     * @dev Economic why: these are the states a live market actually passes through between syncs, including
     *      a market left un-synced for years, whose accumulated adaptation must saturate into the configured
     *      clamps rather than revert and freeze the market. Every exponential argument on the grid is a
     *      concrete constant (speed, delta, and elapsed are all concrete per grid point), so only the stored
     *      curve state is symbolic, per the suite-wide rule that the exponential never receives a symbolic
     *      argument. The ten-year full-utilization point exercises the linear-adaptation clamp and the
     *      ten-year empty point the deep-decay floor
     */
    function check_v1_initializedCurveNeverRevertsAcrossConcreteAdaptationGrid(uint64 storedYT, uint160 steepness, uint256 p1) external {
        _assumeReachableCurve(storedYT, steepness);
        vm.assume(p1 <= 3);

        uint256[3] memory elapsedGrid = [uint256(1 hours), 30 days, 3650 days];
        uint256[3] memory utilGrid = [uint256(0), TARGET_UTIL, WAD];

        for (uint256 i = 0; i < elapsedGrid.length; ++i) {
            // Stamp the adaptation clock so exactly the grid window has elapsed at the pinned block time
            ydm.seedCurve(address(this), storedYT, uint32(SYNC_TIMESTAMP - elapsedGrid[i]), steepness);
            for (uint256 j = 0; j < utilGrid.length; ++j) {
                try ydm.previewYieldShare(MarketState.PERPETUAL, utilGrid[j] + p1 - p1) returns (uint256 yieldShare) {
                    assert(yieldShare <= WAD);
                } catch {
                    assert(false);
                }
            }
        }
    }
}
