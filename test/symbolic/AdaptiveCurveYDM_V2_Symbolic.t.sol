// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { MarketState } from "../../src/libraries/Types.sol";
import { SeedableAdaptiveCurveYDM_V2 } from "../mocks/SeedableAdaptiveCurveYDM_V2.sol";

/**
 * @title AdaptiveCurveYDMV2SymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for the V2 adaptive piecewise yield curve: the
 *         initialization partition with its exactly stored spreads and adaptation-clock reset, the exact
 *         spread-scaled forms of both curve legs, the zero floor an adapted-down curve can hit below target
 *         (pinned as an intentional divergence from the configured minimum target share), the one hundred
 *         percent cap above target, the exact reproduction of all three initialization anchors (V2's
 *         signature contrast with the quotient-encoded models, which lose up to a wei to flooring), the
 *         monotonicity of the curve in utilization across both legs and the kink, and totality of an
 *         initialized curve with the output bounded to one hundred percent of the paying tranche's yield
 * @dev Every curve-shape check runs on the same-block slice: no time has elapsed since the last adaptation
 *      (the seeded adaptation clock is zero), so the exponential adaptation pipeline is an exact identity and
 *      the curve is evaluated at the stored yield share at target verbatim. The exponential never receives a
 *      symbolic argument: off-slice behavior is exercised by a concrete elapsed-and-utilization grid here and
 *      owned in depth by the shared adaptive-base symbolic file, the concrete YDM suites, and the YDM
 *      invariant suite
 * @dev Curve states are seeded directly as (stored yield share, discount spread, premium spread) triples
 *      over the full reachable envelope: initialization stores the two spreads exactly (proven by the
 *      initialization check below) with their sum at most WAD (the initial curve spans y0 to yFull inside
 *      [0, WAD]), and later adaptations move only the stored yield share, clamped to [1e14, WAD], while both
 *      spreads stay fixed, so the seeded cross product of the intervals is exactly the reachable set of curve
 *      states. Expected values are derived independently as plain checked multiply-and-divide (every product
 *      fits far under 2^256 on this domain) with signed truncation rewritten as unsigned floors plus an
 *      explicit sign, never by re-running the production arithmetic as its own expectation
 */
contract AdaptiveCurveYDMV2SymbolicSpec is Test {
    /// @dev The target utilization (the kink) for the instance under test: 80%, asymmetric on purpose so the
    ///      below-target divisor (0.8e18) and the above-target divisor (0.2e18) are distinct
    uint256 internal constant TARGET_UTIL = 0.8e18;

    /// @dev The instance's bounds on the stored yield share at target (set by the V2 constructor)
    uint256 internal constant MIN_YT = 0.0001e18;
    uint256 internal constant MAX_YT = WAD;

    /// @dev The concrete block timestamp every check runs at (fits the curve's uint32 adaptation clock)
    uint256 internal constant SYNC_TIMESTAMP = 4_000_000_000;

    SeedableAdaptiveCurveYDM_V2 internal ydm;

    function setUp() public {
        ydm = new SeedableAdaptiveCurveYDM_V2(TARGET_UTIL);
        vm.warp(SYNC_TIMESTAMP);
    }

    /// @dev Seeds this test contract's market with a curve state on the same-block slice (adaptation clock
    ///      zero), covering the full reachable envelope of post-adaptation curve states
    function _seedCurve(uint64 _storedYT, uint64 _discount, uint64 _premium) internal {
        ydm.seedCurve(address(this), _storedYT, 0, _discount, _premium);
    }

    /// @dev The reachable curve-state envelope: the stored yield share at target is clamped by every
    ///      adaptation write to [MIN_YT, MAX_YT], and the two fixed spreads are the initialization
    ///      differences yT - y0 and yFull - yT, whose sum yFull - y0 is at most WAD (both spread facts
    ///      proven exactly by the initialization partition check)
    function _assumeReachableCurve(uint64 _storedYT, uint64 _discount, uint64 _premium) internal pure {
        vm.assume(MIN_YT <= _storedYT && _storedYT <= MAX_YT);
        vm.assume(uint256(_discount) + uint256(_premium) <= WAD);
    }

    /*//////////////////////////////////////////////////////////////////////
                        INITIALIZATION PARTITION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialization succeeds exactly when the initial curve is ordered inside the model's bounds
     *         (yield share at target at least 0.0001e18, at least the zero-utilization share, and at most the
     *         full-utilization share, which is at most WAD), and on success it stores the yield share at
     *         target verbatim, stores both spreads as exact differences (discount yT - y0 and premium
     *         yFull - yT, with no division and therefore no rounding at all), and clears the adaptation clock
     *         even when a previous curve had already adapted
     * @dev Economic why: the accountant wires this pricing curve at market creation, and every premium the
     *      market ever pays is an offset of these three stored numbers, so a config that would misprice (a
     *      curve that pays less at full utilization than at target, more at zero utilization than at target,
     *      or a share above one hundred percent) must be loudly rejected rather than stored. Clearing the
     *      clock on reinitialization matters because a stale clock would immediately apply a huge phantom
     *      adaptation to the fresh curve. The two exact-difference spread facts are the envelope every seeded
     *      check below relies on: their sum yFull - y0 is at most WAD because the initial curve is ordered
     *      inside [0, WAD]. The padding input routes the query past the engine's built-in arithmetic
     *      heuristic to the real SMT solver
     */
    function check_v2Init_acceptsExactlyOrderedCurvesStoresExactSpreadsAndClearsClock(uint64 y0, uint64 yT, uint64 yFull, uint256 p1) external {
        vm.assume(p1 <= 3);

        // Concrete prelude: initialize a valid curve and adapt it once so the adaptation clock is stamped
        // nonzero, making the clock-clearing half of the property observable on the symbolic reinitialization
        ydm.initializeYDMForMarket(uint64(0.005e18), uint64(0.01e18), uint64(0.1e18));
        ydm.yieldShare(MarketState.PERPETUAL, TARGET_UTIL);
        (, uint32 stampedClock,,) = ydm.accountantToCurve(address(this));
        assert(stampedClock == uint32(SYNC_TIMESTAMP));

        // The exact acceptance predicate, derived from the model's documented bounds: an ordered curve
        // 0 <= y0 <= yT <= yFull <= WAD with yT at least 0.0001e18 (the target share floor keeps an
        // initialized market distinguishable from the zero sentinel and bounds later downward adaptation)
        bool valid = MIN_YT <= yT && y0 <= yT && uint256(yT) <= yFull && uint256(yFull) <= WAD;

        try ydm.initializeYDMForMarket(y0, yT + uint64(p1) - uint64(p1), yFull) {
            assert(valid);
            (uint64 storedYT, uint32 clock, uint64 discount, uint64 premium) = ydm.accountantToCurve(address(this));
            // The target share is stored verbatim and the adaptation clock is cleared by the reinit
            assert(storedYT == yT);
            assert(clock == 0);
            // Both spreads are stored as exact unsigned differences, division-free, so no rounding anywhere
            assert(discount == yT - y0);
            assert(premium == yFull - yT);
            // Envelope corollary consumed by every seeded curve-shape check: the spreads sum to the total
            // initialized curve span yFull - y0, which the ordering bounds inside [0, WAD]
            assert(uint256(discount) + uint256(premium) <= WAD);
        } catch {
            assert(!valid);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                        EXACT FORM OF THE BELOW-TARGET LEG
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Below the target utilization, whenever the scaled discount does not exceed the stored target
     *         share, the curve output is exactly yT - floor(d * discount / WAD), where d is the floored
     *         normalized distance below the kink floor((targetUtil - util) * WAD / targetUtil): the pool's
     *         pay is the target share minus a linear slice of the fixed discount spread, and a single floored
     *         multiply is the only rounding in the whole leg
     * @dev Economic why: this is the exact price schedule of the under-utilized region, and any divergence
     *      from it would mean the premium paid out of senior yield is not the advertised function of measured
     *      utilization. Derivation of the unsigned form from the signed production path: the signed delta is
     *      the truncated quotient of a negative numerator, and Solidity's signed division truncates toward
     *      zero, so it equals the negated unsigned floor -d with d as above and d at most WAD. The scaled
     *      adjustment -d * discount / WAD truncates the same way to -floor(d * discount / WAD), so the signed
     *      output is yT minus that floor, which under the pinned no-clamp condition is nonnegative (exactly
     *      zero is returned by the floor clamp unchanged) and at most WAD (a value of exactly WAD is returned
     *      by the cap unchanged), making the final cast exact. Every spec-side product is at most about 1e36,
     *      far below 2^256, so plain checked arithmetic is exact. The padding input routes the query past the
     *      engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_v2Curve_belowTargetOutputIsTargetShareMinusScaledDiscount(uint64 storedYT, uint64 discount, uint64 premium, uint256 util, uint256 p1) external {
        _assumeReachableCurve(storedYT, discount, premium);
        // Pin the below-target region (the utilization clamp only lowers inputs to WAD, which is above the
        // kink, so the below region is entered exactly when the raw utilization is below the target)
        vm.assume(util < TARGET_UTIL);
        vm.assume(p1 <= 3);
        _seedCurve(storedYT, discount, premium);

        // Independently derived spread-scaled form (plain checked multiply-and-divide throughout)
        uint256 distanceBelow = ((TARGET_UTIL - util) * WAD) / TARGET_UTIL;
        uint256 scaledDiscount = (distanceBelow * discount) / WAD;
        // Pin the sub-region where the zero floor does not bind (its binding twin is pinned below)
        vm.assume(scaledDiscount <= storedYT);

        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, util + p1 - p1);
        assert(yieldShare == storedYT - scaledDiscount);
    }

    /*//////////////////////////////////////////////////////////////////////
                        EXACT FORM OF THE ABOVE-TARGET LEG
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice At or above the target utilization (up to full), whenever the raised value fits under one
     *         hundred percent, the curve output is exactly yT + floor(d * premium / WAD), where d is the
     *         floored normalized distance above the kink floor((util - targetUtil) * WAD / (WAD -
     *         targetUtil)): the pool's pay is the target share plus a linear slice of the fixed premium
     *         spread, again with a single floored multiply as the only rounding
     * @dev Economic why: this is the exact price schedule of the scarce region, the restoring force that
     *      raises the premium when the service the pool provides is over-subscribed, so it must be exactly
     *      the advertised function of measured utilization. Derivation: at or above the kink the signed delta
     *      is a nonnegative truncated quotient which equals the unsigned floor d (at the kink itself the
     *      numerator is zero, so the production divisor difference between the two regions is immaterial and
     *      d is zero either way), the fixed premium spread is nonnegative, so every signed intermediate is
     *      nonnegative and each signed division is a plain unsigned floor. Under the pinned no-cap condition
     *      the signed output is at most WAD (a value of exactly WAD is returned by the cap unchanged) and the
     *      final cast is exact. The padding input routes the query past the engine's built-in arithmetic
     *      heuristic to the real SMT solver
     */
    function check_v2Curve_aboveTargetOutputIsTargetSharePlusScaledPremium(uint64 storedYT, uint64 discount, uint64 premium, uint256 util, uint256 p1) external {
        _assumeReachableCurve(storedYT, discount, premium);
        vm.assume(TARGET_UTIL <= util && util <= WAD);
        vm.assume(p1 <= 3);
        _seedCurve(storedYT, discount, premium);

        // Independently derived spread-scaled form of the at-or-above-target leg
        uint256 distanceAbove = ((util - TARGET_UTIL) * WAD) / (WAD - TARGET_UTIL);
        uint256 scaledPremium = (distanceAbove * premium) / WAD;
        // Pin the sub-region where the one hundred percent cap does not bind
        vm.assume(uint256(storedYT) + scaledPremium <= WAD);

        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, util + p1 - p1);
        assert(yieldShare == uint256(storedYT) + scaledPremium);
    }

    /*//////////////////////////////////////////////////////////////////////
            DIVERGENCE PIN: THE ZERO FLOOR BELOW TARGET ON AN ADAPTED CURVE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice PINS AN INTENTIONAL DIVERGENCE. Below the target utilization, when the scaled discount exceeds
     *         the stored target share, the curve pays exactly zero, even though the model configures a
     *         strictly positive minimum yield share at target: the configured minimum floors only the stored
     *         target share that adaptation decays toward, never the curve's own output, so an adapted-down
     *         market with a large fixed discount spread pays its pool nothing at low utilization
     * @dev Economic why this deserves an explicit pin: the fixed spreads are set once at initialization
     *      against the initial target share, but adaptation can walk the target share all the way down to the
     *      configured minimum (0.0001e18) while the spreads stay fixed, at which point the target share minus
     *      the scaled discount goes negative and the output clamps to zero rather than to the minimum. A pool
     *      whose service is abundant is then paid exactly nothing, which is coherent (an unused service can
     *      rationally earn zero) but is a genuine divergence from reading the configured minimum as an output
     *      floor. Derivation: the signed output yT - floor(d * discount / WAD) is negative or zero exactly
     *      when the floored scaled discount reaches yT, and the production floor clamp returns zero for the
     *      whole nonpositive range. Reachability requires an adapted state (a freshly initialized curve has
     *      discount at most yT, and the scaled discount is monotone in d, so it never exceeds yT at
     *      initialization), which is why this check seeds the curve rather than initializing it. The padding
     *      input routes the query past the engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_v2Curve_floorsAtZeroWhenScaledDiscountExceedsAdaptedTargetShare(uint64 storedYT, uint64 discount, uint64 premium, uint256 util, uint256 p1) external {
        _assumeReachableCurve(storedYT, discount, premium);
        vm.assume(util < TARGET_UTIL);
        vm.assume(p1 <= 3);
        _seedCurve(storedYT, discount, premium);

        // Pin the sub-region where the zero floor binds: the scaled discount strictly exceeds the stored
        // target share (reachable only after downward adaptation, per the derivation above)
        uint256 distanceBelow = ((TARGET_UTIL - util) * WAD) / TARGET_UTIL;
        uint256 scaledDiscount = (distanceBelow * discount) / WAD;
        vm.assume(scaledDiscount > storedYT);

        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, util + p1 - p1);
        // The output is exactly zero: the configured minimum target share is not an output floor
        assert(yieldShare == 0);
        assert(yieldShare < MIN_YT);
    }

    /*//////////////////////////////////////////////////////////////////////
                    THE ONE-HUNDRED-PERCENT CAP ABOVE TARGET
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice At or above the target utilization, when the scaled premium exceeds the headroom between the
     *         stored target share and one hundred percent, the curve output is capped at exactly WAD
     * @dev Economic why: the output is a share of yield, so paying more than one hundred percent would mint
     *      premium out of principal rather than yield. The capped sub-region is genuinely reachable on the
     *      adapted envelope (a curve whose stored target share has adapted upward keeps its fixed premium
     *      spread, so near full utilization the sum can price past WAD) even though a freshly initialized
     *      curve tops out at exactly its configured full-utilization share. Derivation as in the uncapped
     *      twin, with the sub-region pinned by the raised value strictly exceeding WAD, where the production
     *      ceiling clamp returns WAD for the whole range. The padding input routes the query past the
     *      engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_v2Curve_capsAtOneHundredPercentWhenScaledPremiumExceedsHeadroom(uint64 storedYT, uint64 discount, uint64 premium, uint256 util, uint256 p1) external {
        _assumeReachableCurve(storedYT, discount, premium);
        vm.assume(TARGET_UTIL <= util && util <= WAD);
        vm.assume(p1 <= 3);
        _seedCurve(storedYT, discount, premium);

        // Pin the sub-region where the one hundred percent cap binds
        uint256 distanceAbove = ((util - TARGET_UTIL) * WAD) / (WAD - TARGET_UTIL);
        uint256 scaledPremium = (distanceAbove * premium) / WAD;
        vm.assume(uint256(storedYT) + scaledPremium > WAD);

        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, util + p1 - p1);
        assert(yieldShare == WAD);
    }

    /*//////////////////////////////////////////////////////////////////////
                    THE THREE INITIALIZATION ANCHORS ARE EXACT
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A freshly initialized curve reproduces all three of its configured calibration points exactly,
     *         to the wei: it pays y0 at zero utilization, yT at the target utilization, and yFull at (or
     *         clamped down to) full utilization. Exactness at all three anchors is this model's signature:
     *         the spreads are stored as exact differences rather than a floored quotient, so the endpoints
     *         suffer no encoding loss at all
     * @dev Economic why: these are the three prices an issuer actually configures, and the model's fidelity
     *      claim is that the curve passes through all of them rather than through floor-perturbed neighbors,
     *      so the advertised premium schedule is met exactly at its calibration points. Derivation: at zero
     *      utilization the normalized delta is exactly -WAD (the distance equals the region width), so the
     *      scaled adjustment collapses to the full discount spread and the output is yT - (yT - y0) == y0,
     *      with a zero result returned by the floor clamp unchanged. At the kink the delta numerator is zero,
     *      so the adjustment vanishes and the output is yT exactly. At or beyond full utilization the input
     *      clamps to WAD where the delta is exactly WAD, the adjustment collapses to the full premium spread,
     *      and the output is yT + (yFull - yT) == yFull, with a result of exactly WAD returned by the cap
     *      unchanged. No division ever loses a wei because each anchor's delta is exactly a whole WAD or
     *      zero. The padding input routes the query past the engine's built-in arithmetic heuristic to the
     *      real SMT solver
     */
    function check_v2Curve_endpointAnchorsReproduceInitializedCurveExactly(uint64 y0, uint64 yT, uint64 yFull, uint256 util, uint256 p1) external {
        // A valid initialization triple: the coupling between the stored spreads and the configured
        // endpoints is the content here, so this check goes through the real initialization
        vm.assume(MIN_YT <= yT && y0 <= yT && uint256(yT) <= yFull && uint256(yFull) <= WAD);
        // Fold in the utilization clamp arm: anything at or beyond WAD prices identically to exactly WAD
        vm.assume(util >= WAD);
        vm.assume(p1 <= 3);
        ydm.initializeYDMForMarket(y0, yT, yFull);

        // The empty-service anchor pays exactly the configured zero-utilization share
        assert(ydm.previewYieldShare(MarketState.PERPETUAL, 0 + p1 - p1) == y0);
        // The kink pays exactly the configured target share
        assert(ydm.previewYieldShare(MarketState.PERPETUAL, TARGET_UTIL + p1 - p1) == yT);
        // Full utilization (and anything beyond, through the clamp) pays exactly the configured full share
        assert(ydm.previewYieldShare(MarketState.PERPETUAL, util + p1 - p1) == yFull);
    }

    /*//////////////////////////////////////////////////////////////////////
                        MONOTONE NONDECREASING IN UTILIZATION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Within the below-target leg, a higher utilization is never paid a smaller yield share: the
     *         scaled discount shrinks monotonically as the service utilization climbs toward the kink, and
     *         the zero floor only flattens the low end into a plateau, never inverts the order
     * @dev Economic why: monotonicity is the restoring force of the premium model. If the pay could dip as
     *      utilization rises, the market would be rewarded for letting the service it depends on get scarcer,
     *      inverting the incentive the premium exists to create. Derivation: the floored distance below the
     *      kink is nonincreasing in utilization, so the floored scaled discount is nonincreasing, the signed
     *      difference from the stored target share is nondecreasing, and clamping at zero preserves the order
     */
    function check_v2Curve_monotoneNondecreasingBelowTarget(uint64 storedYT, uint64 discount, uint64 premium, uint256 utilLow, uint256 utilHigh) external {
        _assumeReachableCurve(storedYT, discount, premium);
        vm.assume(utilLow <= utilHigh && utilHigh < TARGET_UTIL);
        _seedCurve(storedYT, discount, premium);

        uint256 shareLow = ydm.previewYieldShare(MarketState.PERPETUAL, utilLow);
        uint256 shareHigh = ydm.previewYieldShare(MarketState.PERPETUAL, utilHigh);
        assert(shareLow <= shareHigh);
    }

    /**
     * @notice Within the at-or-above-target leg (kink to full utilization), a higher utilization is never
     *         paid a smaller yield share: the scaled premium grows monotonically, and the one hundred percent
     *         cap only flattens the high end into a plateau, never inverts the order
     * @dev Economic why: above target the service is over-subscribed and the premium must keep climbing to
     *      pull in fresh capital, so a dip would stall the model's self-healing loop exactly when it is
     *      needed most. Derivation: the floored distance above the kink is nondecreasing in utilization, so
     *      the floored scaled premium is nondecreasing, the sum with the stored target share is
     *      nondecreasing, and taking the minimum with the constant WAD preserves monotonicity
     */
    function check_v2Curve_monotoneNondecreasingAboveTarget(uint64 storedYT, uint64 discount, uint64 premium, uint256 utilLow, uint256 utilHigh) external {
        _assumeReachableCurve(storedYT, discount, premium);
        vm.assume(TARGET_UTIL <= utilLow && utilLow <= utilHigh && utilHigh <= WAD);
        _seedCurve(storedYT, discount, premium);

        uint256 shareLow = ydm.previewYieldShare(MarketState.PERPETUAL, utilLow);
        uint256 shareHigh = ydm.previewYieldShare(MarketState.PERPETUAL, utilHigh);
        assert(shareLow <= shareHigh);
    }

    /**
     * @notice Across the kink the two legs order correctly through the target share: every below-target
     *         utilization is paid at most the stored target share, and every utilization at or above the
     *         target (including inputs beyond WAD, which clamp down to full) is paid at least it, so the
     *         curve is monotone through the regime change and the kink is its exact hinge
     * @dev Economic why: the target share is the calibrated pivot between the discounted and the raised
     *      regime, so an under-utilized market must never out-earn an over-utilized one. Derivation: below
     *      the kink the adjustment is nonpositive, so the output is at most the stored target share (with the
     *      zero floor only lowering it further), and at or above the kink the adjustment is nonnegative, so
     *      the output is at least the stored target share, the WAD cap included since the stored share never
     *      exceeds WAD
     */
    function check_v2Curve_monotoneAcrossTheKink(uint64 storedYT, uint64 discount, uint64 premium, uint256 utilBelow, uint256 utilAbove) external {
        _assumeReachableCurve(storedYT, discount, premium);
        vm.assume(utilBelow < TARGET_UTIL && TARGET_UTIL <= utilAbove);
        _seedCurve(storedYT, discount, premium);

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
     *      WAD would draw premium out of principal rather than yield. The signed intermediates cannot
     *      overflow (the normalized delta has magnitude at most WAD and the spreads fit in 64 bits, so the
     *      adjustment product is at most about 2e37 and the signed sum stays within a few WAD of zero, both
     *      minuscule against 2^255), which the no-revert claim makes observable since checked signed
     *      arithmetic would revert on any overflow. The same-block slice is realized both by a never-adapted
     *      clock (zero) and by a clock stamped at the current block, the two ways no time can have passed. In
     *      the fixed-term state the adaptation block is skipped outright, and in the perpetual state the zero
     *      elapsed time makes it an identity, so the exponential never sees a live argument. Off-slice
     *      (nonzero elapsed) totality is exercised on the concrete grid check below
     */
    function check_v2_initializedCurveNeverRevertsAndStaysWithinFullShareOnAnyUtilization(
        uint64 storedYT,
        uint64 discount,
        uint64 premium,
        uint256 util,
        uint8 stateRaw,
        uint32 clock
    )
        external
    {
        _assumeReachableCurve(storedYT, discount, premium);
        // Both members of the market state machine
        vm.assume(stateRaw <= 1);
        // The two same-block slice realizations: never adapted, or adapted in this very block
        vm.assume(clock == 0 || clock == uint32(SYNC_TIMESTAMP));
        ydm.seedCurve(address(this), storedYT, clock, discount, premium);

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
    function check_v2_initializedCurveNeverRevertsAcrossConcreteAdaptationGrid(uint64 storedYT, uint64 discount, uint64 premium, uint256 p1) external {
        _assumeReachableCurve(storedYT, discount, premium);
        vm.assume(p1 <= 3);

        uint256[3] memory elapsedGrid = [uint256(1 hours), 30 days, 3650 days];
        uint256[3] memory utilGrid = [uint256(0), TARGET_UTIL, WAD];

        for (uint256 i = 0; i < elapsedGrid.length; ++i) {
            // Stamp the adaptation clock so exactly the grid window has elapsed at the pinned block time
            ydm.seedCurve(address(this), storedYT, uint32(SYNC_TIMESTAMP - elapsedGrid[i]), discount, premium);
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
