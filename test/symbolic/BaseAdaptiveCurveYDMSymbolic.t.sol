// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { WAD, WAD_INT } from "../../src/libraries/Constants.sol";
import { MarketState } from "../../src/libraries/Types.sol";
import { AdaptiveCurveYDM_V1 } from "../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { StaticCurveYDM } from "../../src/ydm/StaticCurveYDM.sol";
import { AdaptiveYieldShareAtTargetExposer } from "../mocks/AdaptiveYieldShareAtTargetExposer.sol";
import { EchoAdaptiveCurveYDM } from "../mocks/EchoAdaptiveCurveYDM.sol";

/**
 * @title BaseAdaptiveCurveYDMSymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for the adaptive curve YDM base engine: the
 *         constructor's configuration partition, the region-scaled normalization of the utilization delta
 *         (including the full-target degenerate region), the exact zero-elapsed and never-adapted identities,
 *         the fixed-term curve freeze with its intentional clock restamp, preservation of the stored yield
 *         share bounds by every adaptation write, the saturating clamp that guards the exponential from
 *         overflow, the exponential decay floor, the directional restoring force of the adaptation, the
 *         containment of the trapezoidal time average, preview-versus-mutate parity, and per-market isolation
 *         of curve writes
 * @dev Functions prefixed check_ are discovered only under --symbolic. Curve state is observed through the
 *      echo model (which returns either the time-averaged yield share at target or the shifted normalized
 *      delta straight from the base's curve hook) and through a thin exposer over the internal adaptation
 *      step. The exponential never receives a live symbolic argument: adaptation checks either run on the
 *      zero-elapsed slice (where the exponent is exactly zero), pin a concrete (elapsed, utilization) grid
 *      point (where the exponent folds to a constant), or constrain the argument past one of the
 *      exponential's own short-circuit boundaries (the zero floor, where the body never executes, and the
 *      overflow clamp, where the clamped value is a compile-time constant)
 * @dev Yield share domains are WAD fractions (at most 1e18) so every expected form is plain checked
 *      arithmetic, and the stored yield share at target is assumed within its configured [min, max] band,
 *      which the bounds-preservation grid itself proves is the band every persisted value stays in
 */
contract BaseAdaptiveCurveYDMSymbolicSpec is Test {
    /// @dev The target utilization (the kink) of the primary echo instance: 80%, so both curve regions are live
    uint256 internal constant TARGET = 8e17;

    /// @dev The configured lower bound on the adaptive yield share at target: 0.01%
    uint256 internal constant MIN_YT = 1e14;

    /// @dev The configured upper bound on the adaptive yield share at target: 100%
    uint256 internal constant MAX_YT = 1e18;

    /**
     * @dev The deploy-time ceiling on the max adaptation speed, derived independently as
     *      floor(100e18 / 31_536_000): a full 100x-per-year e-folding budget spread over the seconds in a
     *      365-day year. Every instance in this file is configured at exactly this ceiling so the grid's
     *      concrete drifts exercise the fastest legal adaptation
     */
    uint256 internal constant MAX_SPEED = 3_170_979_198_376;

    /**
     * @dev The largest linear adaptation the engine may hand the WAD exponential: one below the exponential's
     *      overflow revert threshold of 135305999368893231589 (the point where e^(x / 1e18) * 1e18 no longer
     *      fits a signed 256-bit integer). At this exponent e^135.3 is about 5.8e58, so any stored yield share
     *      of at least one wei maps far above the 1e18 ceiling and must saturate at the configured max
     */
    int256 internal constant MAX_LIN = 135_305_999_368_893_231_588;

    /**
     * @dev The WAD exponential's zero short-circuit boundary: at or below this argument the result rounds to
     *      under half a wei and the exponential returns zero from its very first guard, before any of its
     *      polynomial machinery runs. Reached at max speed after roughly 15 months of full downward pressure
     */
    int256 internal constant EXP_ZERO_FLOOR = -41_446_531_673_892_822_313;

    /// @dev The concrete block timestamp every check runs at unless it warps its own (fits a uint32 clock)
    uint256 internal constant SYNC_TIMESTAMP = 4_000_000_000;

    /// @dev Two concrete accountant addresses used as distinct market keys for the isolation check
    address internal constant MARKET_A = address(0xA11CE);
    address internal constant MARKET_B = address(0xB0B);

    /// @dev Primary echo instance: target 80%, bounds [MIN_YT, MAX_YT], max legal speed
    EchoAdaptiveCurveYDM internal echo;

    /// @dev Echo instance with the target at exactly 100%, so the above-target region is empty
    EchoAdaptiveCurveYDM internal echoTargetAtFull;

    /// @dev Exposer over the internal adaptation step, configured identically to the primary echo instance
    AdaptiveYieldShareAtTargetExposer internal exposer;

    /// @dev The three concrete curve models, used only for the preview-versus-mutate parity checks
    StaticCurveYDM internal staticYdm;
    AdaptiveCurveYDM_V1 internal v1;
    AdaptiveCurveYDM_V2 internal v2;

    function setUp() public {
        echo = new EchoAdaptiveCurveYDM(TARGET, MIN_YT, MAX_YT, MAX_SPEED);
        echoTargetAtFull = new EchoAdaptiveCurveYDM(WAD, MIN_YT, MAX_YT, MAX_SPEED);
        exposer = new AdaptiveYieldShareAtTargetExposer(TARGET, MIN_YT, MAX_YT, MAX_SPEED);
        staticYdm = new StaticCurveYDM(TARGET);
        v1 = new AdaptiveCurveYDM_V1(TARGET);
        v2 = new AdaptiveCurveYDM_V2(TARGET);
        vm.warp(SYNC_TIMESTAMP);
    }

    /*//////////////////////////////////////////////////////////////////////
                            CONSTRUCTOR PARTITION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The adaptive base's constructor accepts a configuration exactly when the target utilization is
     *         in (0, 100%], the yield share bounds are ordered with a positive minimum and a maximum at most
     *         100%, and the adaptation speed is positive and at most the deploy-time speed ceiling
     * @dev Economic why each leg is load-bearing: a zero target would make the below-target region's delta
     *      normalization divide by zero at every utilization, a zero minimum would make an initialized
     *      market's stored yield share indistinguishable from the uninitialized zero sentinel, a maximum
     *      above 100% could pay out more than the whole yield of the paying tranche, and a speed above the
     *      ceiling would let the speed-times-delta product escape the range the exponential guard was sized
     *      for. The expected acceptance predicate is re-derived here as a plain conjunction and compared
     *      against the deployment outcome in both directions
     */
    function check_constructorAcceptsExactlyOrderedBoundsAndCappedSpeed(uint256 target, uint256 minYT, uint256 maxYT, uint256 speed) external {
        bool valid = 0 < target && target <= WAD && 0 < minYT && minYT <= maxYT && maxYT <= WAD && 0 < speed && speed <= MAX_SPEED;

        try new EchoAdaptiveCurveYDM(target, minYT, maxYT, speed) returns (EchoAdaptiveCurveYDM) {
            assert(valid);
        } catch {
            assert(!valid);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                        NORMALIZED DELTA FROM TARGET
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Below or at the target, the normalized delta is the floored fraction of the below-target region
     *         that the utilization shortfall covers, negated: minus floor((target - utilization) * WAD /
     *         target), landing exactly at -WAD when the pool is empty and exactly at zero when it sits on the
     *         kink
     * @dev Economic why: the adaptation pressure is meant to be relative to how much room the current region
     *      offers, so a pool halfway down its below-target region feels the same pull regardless of where the
     *      kink sits. The signed division in the engine truncates toward zero, and the numerator here is an
     *      exact product of a negative difference, so truncation equals the negated unsigned floor used as
     *      the expected form. The delta is read back through the echo model, which shifts it by WAD into
     *      unsigned range on its way out
     */
    function check_normalizedDeltaBelowTargetIsNegatedFlooredShareOfRegion(uint256 utilization) external {
        vm.assume(utilization <= TARGET);
        echo.setEchoMode(EchoAdaptiveCurveYDM.EchoMode.NORMALIZED_DELTA_SHIFTED);
        // Any nonzero stored yield share passes the initialization gate, its value is unused in this mode
        echo.seedCurve(5e17, 0);

        // Fixed term skips the whole adaptation block, so the delta is observed with no exponential in the path
        uint256 echoed = echo.previewYieldShare(MarketState.FIXED_TERM, utilization);
        int256 observed = int256(echoed) - WAD_INT;

        // Independently derived expected form: unsigned floor of the region share, sign applied explicitly
        int256 expected = -int256(((TARGET - utilization) * WAD) / TARGET);
        assert(observed == expected);
        // The normalization maps the whole below-target region into [-WAD, 0]
        assert(-WAD_INT <= observed && observed <= 0);
    }

    /**
     * @notice Above the target, the normalized delta is the floored fraction of the above-target region that
     *         the utilization excess covers: floor((utilization - target) * WAD / (WAD - target)), landing
     *         exactly at WAD when the pool is fully utilized
     * @dev Economic why: scarcity pressure is measured against the room left above the kink, so the curve
     *      accelerates toward its full-utilization posture at the same relative pace for any kink placement.
     *      The numerator is positive here so the engine's truncating division is the plain unsigned floor
     */
    function check_normalizedDeltaAboveTargetIsFlooredShareOfRegion(uint256 utilization) external {
        vm.assume(TARGET < utilization && utilization <= WAD);
        echo.setEchoMode(EchoAdaptiveCurveYDM.EchoMode.NORMALIZED_DELTA_SHIFTED);
        echo.seedCurve(5e17, 0);

        uint256 echoed = echo.previewYieldShare(MarketState.FIXED_TERM, utilization);
        int256 observed = int256(echoed) - WAD_INT;

        int256 expected = int256(((utilization - TARGET) * WAD) / (WAD - TARGET));
        assert(observed == expected);
        // The normalization maps the whole above-target region into (0, WAD]
        assert(0 < observed && observed <= WAD_INT);
    }

    /**
     * @notice Utilization reported above 100% is clamped to exactly 100% before normalization, so any
     *         over-demanded pool reads the same maximal delta of exactly WAD
     * @dev Economic why: demand beyond capacity carries no extra information for the premium model, the pool
     *      is already being paid its full-scarcity rate, and an unclamped input would otherwise blow the
     *      delta past the [-WAD, WAD] contract every downstream curve relies on
     */
    function check_normalizedDeltaClampsOverfullUtilizationToExactlyFull(uint256 utilization) external {
        vm.assume(utilization > WAD);
        echo.setEchoMode(EchoAdaptiveCurveYDM.EchoMode.NORMALIZED_DELTA_SHIFTED);
        echo.seedCurve(5e17, 0);

        uint256 echoed = echo.previewYieldShare(MarketState.FIXED_TERM, utilization);

        // At the clamped input the above-target excess is the whole region, whose floored share is exactly WAD
        assert(int256(echoed) - WAD_INT == WAD_INT);
    }

    /**
     * @notice With the target configured at exactly 100%, the above-target region is empty, yet the
     *         normalization is total for every possible utilization input: the clamp forces the utilization
     *         to at most the target, the below-target branch's divisor is the full WAD target, and the delta
     *         comes out as exactly the clamped utilization minus WAD, always in [-WAD, 0]
     * @dev Economic why: a market may legitimately want its premium maxed only at full utilization, and the
     *      empty region above the kink must not turn that configuration into a division-by-zero brick. The
     *      expected form is exact with no rounding at all because multiplying by WAD and dividing by the WAD
     *      target cancel perfectly
     */
    function check_targetAtFullUtilizationNeverDividesByZeroAndDeltaIsNonpositive(uint256 utilization) external {
        echoTargetAtFull.setEchoMode(EchoAdaptiveCurveYDM.EchoMode.NORMALIZED_DELTA_SHIFTED);
        echoTargetAtFull.seedCurve(5e17, 0);

        try echoTargetAtFull.previewYieldShare(MarketState.FIXED_TERM, utilization) returns (uint256 echoed) {
            uint256 clamped = utilization > WAD ? WAD : utilization;
            int256 observed = int256(echoed) - WAD_INT;
            assert(observed == int256(clamped) - WAD_INT);
            assert(observed <= 0);
        } catch {
            // The region selection can never land on the empty region, so no input may revert
            assert(false);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                        ZERO-ELAPSED AND NEVER-ADAPTED IDENTITIES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A perpetual-state yield share read in the same block as the last adaptation is an exact
     *         identity: with zero elapsed time the linear adaptation is zero, the exponential of zero is
     *         exactly one, and the new, mid, and trapezoid-averaged yield shares at target all equal the
     *         stored value with no rounding, both on the preview path and through the mutating write
     * @dev Economic why: the accountant can sync several times in one block (a deposit and a redemption, or a
     *      preview followed by its commit), and any wei of drift here would compound a same-block adaptation
     *      out of nothing. The average is exact because (s + s + 2s) / 4 divides with no remainder for every
     *      s, so the identity is byte-exact rather than within-one-wei
     */
    function check_zeroElapsedAdaptationIsAnExactIdentity(uint256 utilization, uint256 storedYT) external {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        // The adaptation clock is stamped at the current block, so the elapsed window is exactly zero
        echo.seedCurve(storedYT, SYNC_TIMESTAMP);

        assert(echo.previewYieldShare(MarketState.PERPETUAL, utilization) == storedYT);

        // The mutating path returns the same identity and persists the curve position unchanged
        assert(echo.yieldShare(MarketState.PERPETUAL, utilization) == storedYT);
        assert(echo.yieldShareAtTarget(address(this)) == storedYT);
    }

    /**
     * @notice A market whose curve has never adapted (zero adaptation clock) ignores the wall clock entirely:
     *         at any block timestamp the elapsed window reads zero and the yield share at target passes
     *         through untouched, and only after the first mutating call does the clock start
     * @dev Economic why: the gap between a market's YDM initialization and its first sync is unbounded, and
     *      treating the zero sentinel as a real timestamp would apply that whole gap as a one-shot adaptation
     *      at the first sync, slamming the curve to a bound before any market forces acted. The timestamp is
     *      symbolic across the whole uint32 clock range to pin that the identity is clock-independent
     */
    function check_neverAdaptedMarketIgnoresTheWallClock(uint256 timestamp, uint256 utilization, uint256 storedYT) external {
        vm.assume(1 <= timestamp && timestamp <= type(uint32).max);
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        vm.warp(timestamp);
        echo.seedCurve(storedYT, 0);

        assert(echo.previewYieldShare(MarketState.PERPETUAL, utilization) == storedYT);
        assert(echo.yieldShare(MarketState.PERPETUAL, utilization) == storedYT);
        assert(echo.yieldShareAtTarget(address(this)) == storedYT);
        // The first mutating call starts the adaptation clock at the current block
        assert(echo.lastAdaptationTimestamp(address(this)) == timestamp);
    }

    /*//////////////////////////////////////////////////////////////////////
                FIXED TERM FREEZES THE CURVE BUT RESTAMPS THE CLOCK
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice PINS AN INTENTIONAL DIVERGENCE. In a fixed-term market the curve is frozen: the output is the
     *         stored yield share at target with the elapsed window ignored, and the curve position persists
     *         unchanged. But the mutating call still restamps the adaptation clock to the current block, so
     *         the time a market spends in fixed term is permanently erased from the adaptation window rather
     *         than applied when the market re-enters the perpetual state
     * @dev Economic why the freeze: deposits and redemptions are locked in fixed term, so utilization cannot
     *      respond to premium changes and adaptation would spiral against a dead market signal. Why the
     *      restamp is pinned as intentional: on re-entry to perpetual the curve resumes from the re-entry
     *      block instead of retroactively charging the locked period, which matches the design that the curve
     *      adapts only while the market is perpetual. If the restamp behavior is ever changed this check
     *      surfaces it
     */
    function check_fixedTermFreezesTheCurveButRestampsTheAdaptationClock(uint256 lastTs, uint256 utilization, uint256 storedYT) external {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        // A strictly stale clock, so a live elapsed window exists and is provably ignored
        vm.assume(1 <= lastTs && lastTs < SYNC_TIMESTAMP);
        echo.seedCurve(storedYT, lastTs);

        uint256 returned = echo.yieldShare(MarketState.FIXED_TERM, utilization);

        // Frozen: the output and the persisted curve position are the stored value, elapsed time notwithstanding
        assert(returned == storedYT);
        assert(echo.yieldShareAtTarget(address(this)) == storedYT);
        // The divergence pin: the write hook still runs and stamps the clock to now, erasing the stale window
        assert(echo.lastAdaptationTimestamp(address(this)) == SYNC_TIMESTAMP);
    }

    /*//////////////////////////////////////////////////////////////////////
                STORED YIELD SHARE BOUNDS SURVIVE EVERY ADAPTATION WRITE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev One inductive step of the bounds invariant at a pinned concrete drift: seed a stored yield share
     *      anywhere in the configured [min, max] band, run one mutating adaptation at the given utilization
     *      after the given elapsed window, and assert the persisted value is still inside the band. The
     *      concrete (elapsed, utilization) pin folds the exponential's argument to a constant per grid point,
     *      honoring the rule that the exponential never runs on a live symbolic argument. The band's upper
     *      end (WAD) is far below the 64-bit ceiling, so the concrete models' narrower stored fields truncate
     *      nothing when this invariant holds
     */
    function _driftAndAssertStoredYieldShareWithinBounds(uint256 _elapsedSeconds, uint256 _utilizationWAD, uint256 _storedYT) internal {
        vm.assume(MIN_YT <= _storedYT && _storedYT <= MAX_YT);
        echo.seedCurve(_storedYT, SYNC_TIMESTAMP - _elapsedSeconds);

        echo.yieldShare(MarketState.PERPETUAL, _utilizationWAD);

        uint256 stored = echo.yieldShareAtTarget(address(this));
        assert(MIN_YT <= stored && stored <= MAX_YT);
    }

    /// @notice One hour of drift at empty utilization keeps the stored yield share at target within its band
    function check_storedYieldShareBoundsHoldAfterOneHourAtZeroUtilization(uint256 storedYT) external {
        _driftAndAssertStoredYieldShareWithinBounds(1 hours, 0, storedYT);
    }

    /// @notice One hour of drift at half the target keeps the stored yield share at target within its band
    function check_storedYieldShareBoundsHoldAfterOneHourAtHalfTargetUtilization(uint256 storedYT) external {
        _driftAndAssertStoredYieldShareWithinBounds(1 hours, TARGET / 2, storedYT);
    }

    /// @notice One hour of drift exactly on the kink keeps the stored yield share at target within its band
    function check_storedYieldShareBoundsHoldAfterOneHourAtTargetUtilization(uint256 storedYT) external {
        _driftAndAssertStoredYieldShareWithinBounds(1 hours, TARGET, storedYT);
    }

    /// @notice One hour of drift midway above the kink keeps the stored yield share at target within its band
    function check_storedYieldShareBoundsHoldAfterOneHourBetweenTargetAndFullUtilization(uint256 storedYT) external {
        _driftAndAssertStoredYieldShareWithinBounds(1 hours, (TARGET + WAD) / 2, storedYT);
    }

    /// @notice One hour of drift at full utilization keeps the stored yield share at target within its band
    function check_storedYieldShareBoundsHoldAfterOneHourAtFullUtilization(uint256 storedYT) external {
        _driftAndAssertStoredYieldShareWithinBounds(1 hours, WAD, storedYT);
    }

    /// @notice Thirty days of drift at empty utilization keeps the stored yield share at target within its band
    function check_storedYieldShareBoundsHoldAfterThirtyDaysAtZeroUtilization(uint256 storedYT) external {
        _driftAndAssertStoredYieldShareWithinBounds(30 days, 0, storedYT);
    }

    /// @notice Thirty days of drift at half the target keeps the stored yield share at target within its band
    function check_storedYieldShareBoundsHoldAfterThirtyDaysAtHalfTargetUtilization(uint256 storedYT) external {
        _driftAndAssertStoredYieldShareWithinBounds(30 days, TARGET / 2, storedYT);
    }

    /// @notice Thirty days of drift exactly on the kink keeps the stored yield share at target within its band
    function check_storedYieldShareBoundsHoldAfterThirtyDaysAtTargetUtilization(uint256 storedYT) external {
        _driftAndAssertStoredYieldShareWithinBounds(30 days, TARGET, storedYT);
    }

    /// @notice Thirty days of drift midway above the kink keeps the stored yield share at target within its band
    function check_storedYieldShareBoundsHoldAfterThirtyDaysBetweenTargetAndFullUtilization(uint256 storedYT) external {
        _driftAndAssertStoredYieldShareWithinBounds(30 days, (TARGET + WAD) / 2, storedYT);
    }

    /// @notice Thirty days of drift at full utilization keeps the stored yield share at target within its band
    function check_storedYieldShareBoundsHoldAfterThirtyDaysAtFullUtilization(uint256 storedYT) external {
        _driftAndAssertStoredYieldShareWithinBounds(30 days, WAD, storedYT);
    }

    /// @notice Ten years of drift at empty utilization keeps the stored yield share at target within its band
    function check_storedYieldShareBoundsHoldAfterTenYearsAtZeroUtilization(uint256 storedYT) external {
        _driftAndAssertStoredYieldShareWithinBounds(3650 days, 0, storedYT);
    }

    /// @notice Ten years of drift at half the target keeps the stored yield share at target within its band
    function check_storedYieldShareBoundsHoldAfterTenYearsAtHalfTargetUtilization(uint256 storedYT) external {
        _driftAndAssertStoredYieldShareWithinBounds(3650 days, TARGET / 2, storedYT);
    }

    /// @notice Ten years of drift exactly on the kink keeps the stored yield share at target within its band
    function check_storedYieldShareBoundsHoldAfterTenYearsAtTargetUtilization(uint256 storedYT) external {
        _driftAndAssertStoredYieldShareWithinBounds(3650 days, TARGET, storedYT);
    }

    /// @notice Ten years of drift midway above the kink keeps the stored yield share at target within its band
    function check_storedYieldShareBoundsHoldAfterTenYearsBetweenTargetAndFullUtilization(uint256 storedYT) external {
        _driftAndAssertStoredYieldShareWithinBounds(3650 days, (TARGET + WAD) / 2, storedYT);
    }

    /// @notice Ten years of drift at full utilization keeps the stored yield share at target within its band
    function check_storedYieldShareBoundsHoldAfterTenYearsAtFullUtilization(uint256 storedYT) external {
        _driftAndAssertStoredYieldShareWithinBounds(3650 days, WAD, storedYT);
    }

    /*//////////////////////////////////////////////////////////////////////
                THE UPWARD CLAMP GUARDS THE EXPONENTIAL AND SATURATES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Any linear adaptation strictly above the clamp threshold is clamped down to it before reaching
     *         the exponential, so the adaptation step never reverts on overflow and the resulting yield share
     *         at target saturates at exactly the configured maximum
     * @dev Economic why: roughly 1.35 years of uninterrupted max-speed upward drift is enough to push the
     *      exponent past the point where the WAD exponential's result no longer fits a signed 256-bit
     *      integer, and an unclamped argument would revert there, bricking every sync of the market forever
     *      (the drift only grows with time). Saturation is the right semantics because the pre-clamp
     *      multiplier already exceeds 5e58, so even a one-wei stored yield share maps far above the WAD
     *      ceiling and the max-bound clamp binds regardless of where in the band the stored value sits
     */
    function check_linearAdaptationAboveClampThresholdSaturatesToMaxWithoutReverting(uint256 storedYT, int256 lin) external view {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        // Strictly above the threshold: the clamp rewrites the exponent to the constant threshold value
        vm.assume(lin > MAX_LIN);

        try exposer.computeYieldShareAtTarget(storedYT, lin) returns (uint256 adapted) {
            assert(adapted == MAX_YT);
        } catch {
            assert(false);
        }
    }

    /**
     * @notice At exactly the clamp threshold (the largest exponent the WAD exponential accepts) the
     *         adaptation step does not revert and still saturates at the configured maximum
     * @dev The boundary arm of the clamp's ternary: the exponent passes through unclamped, so this pins that
     *      the threshold constant itself is on the safe side of the exponential's overflow revert
     */
    function check_linearAdaptationExactlyAtClampThresholdSaturatesToMaxWithoutReverting(uint256 storedYT) external view {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);

        try exposer.computeYieldShareAtTarget(storedYT, MAX_LIN) returns (uint256 adapted) {
            assert(adapted == MAX_YT);
        } catch {
            assert(false);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                DEEP DOWNWARD DRIFT DECAYS TO THE MIN WITHOUT A LOWER CLAMP
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Any linear adaptation at or below the exponential's zero short-circuit boundary decays the
     *         yield share at target to exactly the configured minimum, with no revert: no symmetric lower
     *         clamp on the exponent is needed because the exponential of a deep negative rounds to zero and
     *         the min bound catches the collapsed value
     * @dev Economic why: a market can sit at zero utilization indefinitely, so the downward drift is
     *      unbounded in time and the decay path must be total, and the configured minimum is what keeps a
     *      long-idle market's premium restartable instead of stuck at an unrecoverable zero. The symbolic
     *      exponent here only ever reaches the exponential's first guard, which returns zero before any of
     *      the polynomial machinery executes, so no live symbolic argument flows through the approximation
     */
    function check_deepNegativeLinearAdaptationDecaysToMinWithoutReverting(uint256 storedYT, int256 lin) external view {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        // At or below the zero short-circuit boundary the exponential is exactly zero by its first guard
        vm.assume(lin <= EXP_ZERO_FLOOR);

        try exposer.computeYieldShareAtTarget(storedYT, lin) returns (uint256 adapted) {
            assert(adapted == MIN_YT);
        } catch {
            assert(false);
        }
    }

    /**
     * @notice End to end through the full yield share flow: after roughly 231 days at zero utilization and
     *         max speed, one perpetual sync decays the persisted yield share at target to exactly the
     *         configured minimum, wherever in the band it started
     * @dev The concrete drift pins the exponent at about -63.4 (past the zero short-circuit) and the
     *      mid-point exponent at about -31.7, whose exponential is around 1.7e4 in WAD terms, so even a full
     *      WAD stored value maps to under 1.7e4, far below the 1e14 minimum, and both the new and mid values
     *      collapse to the min bound. The write must persist the min, keeping the curve restartable
     */
    function check_longIdleDriftDecaysThePersistedYieldShareToMin(uint256 storedYT) external {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        echo.seedCurve(storedYT, SYNC_TIMESTAMP - 20_000_000);

        echo.yieldShare(MarketState.PERPETUAL, 0);

        assert(echo.yieldShareAtTarget(address(this)) == MIN_YT);
    }

    /*//////////////////////////////////////////////////////////////////////
                ADAPTATION MOVES TOWARD THE UTILIZATION PRESSURE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Above-target utilization never lowers the stored yield share at target: after a thirty-day
     *         drift at utilization midway above the kink, the persisted value is at least the seeded value
     * @dev Economic why: the adaptation is a restoring force, scarcity of the pooled service must raise the
     *      premium to attract capital, so an adaptation that could move against its own pressure would turn
     *      the feedback loop unstable. Derivation on outputs: the concrete positive exponent makes the WAD
     *      exponential at least WAD, so the floored product s * e / WAD is at least s, and the clamp can only
     *      move a value that already sits at or above s up to the max bound, never below s
     */
    function check_aboveTargetUtilizationNeverLowersTheStoredYieldShareAtTarget(uint256 storedYT) external {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        echo.seedCurve(storedYT, SYNC_TIMESTAMP - 30 days);

        echo.yieldShare(MarketState.PERPETUAL, (TARGET + WAD) / 2);

        assert(echo.yieldShareAtTarget(address(this)) >= storedYT);
    }

    /**
     * @notice Below-target utilization never raises the stored yield share at target: after a thirty-day
     *         drift at utilization halfway below the kink, the persisted value is at most the seeded value
     * @dev Economic why: abundance of the pooled service must cheapen the premium so the paying tranche is
     *      not overcharged for capacity nobody uses. Derivation on outputs: the concrete negative exponent
     *      makes the WAD exponential strictly below WAD, so the floored product s * e / WAD is at most s, and
     *      the min-bound clamp can only lift the result to the minimum, which never exceeds the seeded value
     */
    function check_belowTargetUtilizationNeverRaisesTheStoredYieldShareAtTarget(uint256 storedYT) external {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        echo.seedCurve(storedYT, SYNC_TIMESTAMP - 30 days);

        echo.yieldShare(MarketState.PERPETUAL, TARGET / 2);

        assert(echo.yieldShareAtTarget(address(this)) <= storedYT);
    }

    /**
     * @notice Utilization exactly on the kink leaves the curve exactly still for any elapsed window: the
     *         normalized delta is zero, so the adaptation speed and the linear adaptation are zero regardless
     *         of how much time passed, and both the returned yield share and the persisted position equal the
     *         seeded value with no rounding
     * @dev Economic why: a market resting on its target is in equilibrium and the model must not manufacture
     *      drift from the mere passage of time, otherwise every equilibrium would erode toward a bound. The
     *      elapsed window is symbolic across the whole clock range because the zero delta annihilates it
     */
    function check_atTargetUtilizationLeavesTheCurveExactlyStillForAnyElapsedWindow(uint256 lastTs, uint256 storedYT) external {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        vm.assume(1 <= lastTs && lastTs <= SYNC_TIMESTAMP);
        echo.seedCurve(storedYT, lastTs);

        assert(echo.yieldShare(MarketState.PERPETUAL, TARGET) == storedYT);
        assert(echo.yieldShareAtTarget(address(this)) == storedYT);
    }

    /*//////////////////////////////////////////////////////////////////////
                THE TRAPEZOID AVERAGE LIES BETWEEN OLD AND NEW
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On an upward drift the time-averaged yield share at target handed to the curve lies between
     *         the seeded value and the newly persisted value
     * @dev Economic why: the average is what the accountant actually pays for the elapsed window, so an
     *      average escaping the endpoints would pay a premium the curve never passed through during the
     *      drift. Derivation on outputs: the mid-point exponent is half the full exponent, so by monotonicity
     *      of the exponential and of the floored scale-and-clamp the mid value lies between the old value a
     *      and the new value b, hence 4 * min(a, b) <= a + b + 2 * mid <= 4 * max(a, b), and the floored
     *      quarter of that sum stays within [min(a, b), max(a, b)]
     */
    function check_timeAveragedYieldShareLiesBetweenOldAndNewOnUpwardDrift(uint256 storedYT) external {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        echo.seedCurve(storedYT, SYNC_TIMESTAMP - 30 days);

        // The echo model returns the trapezoid average straight from the base's curve hook
        uint256 average = echo.yieldShare(MarketState.PERPETUAL, (TARGET + WAD) / 2);
        uint256 adapted = echo.yieldShareAtTarget(address(this));

        assert(average >= (storedYT < adapted ? storedYT : adapted));
        assert(average <= (storedYT < adapted ? adapted : storedYT));
    }

    /**
     * @notice On a downward drift the time-averaged yield share at target handed to the curve lies between
     *         the newly persisted value and the seeded value
     * @dev The decay twin of the upward containment: same endpoint argument, with the mid-point value
     *      sandwiched by the same monotonicity and the min-bound clamp applying to all three terms alike
     */
    function check_timeAveragedYieldShareLiesBetweenOldAndNewOnDownwardDrift(uint256 storedYT) external {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        echo.seedCurve(storedYT, SYNC_TIMESTAMP - 30 days);

        uint256 average = echo.yieldShare(MarketState.PERPETUAL, TARGET / 2);
        uint256 adapted = echo.yieldShareAtTarget(address(this));

        assert(average >= (storedYT < adapted ? storedYT : adapted));
        assert(average <= (storedYT < adapted ? adapted : storedYT));
    }

    /*//////////////////////////////////////////////////////////////////////
                    PREVIEW EQUALS THE MUTATING RETURN SAME-BLOCK
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice For the static curve model, the view preview and the mutating yield share return the same
     *         value for every utilization
     * @dev Economic why: the accountant prices max-deposit and max-withdrawal views off the preview and
     *      settles operations off the mutating call, so any wedge between the two would let an operation be
     *      quoted on one curve and settled on another. The static model has no adaptation state at all, so
     *      parity here is pure and state-independent
     */
    function check_staticModelPreviewEqualsMutatingYieldShare(uint256 utilization) external {
        // A concrete, valid monotone curve: 1% at empty, 50% at the kink, 90% at full utilization
        staticYdm.initializeYDMForMarket(uint64(1e16), uint64(5e17), uint64(9e17));

        uint256 previewed = staticYdm.previewYieldShare(MarketState.PERPETUAL, utilization);
        uint256 returned = staticYdm.yieldShare(MarketState.PERPETUAL, utilization);

        assert(previewed == returned);
    }

    /**
     * @notice For the V1 adaptive model with a live adaptation clock, a same-block preview equals the
     *         mutating yield share return for every utilization
     * @dev The clock is stamped by a concrete mutating call first, so the parity pair runs on the zero-
     *      elapsed slice where the exponent is exactly zero and no live symbolic argument can reach the
     *      exponential. Sequential idempotence of the mutating call is deliberately not claimed: only the
     *      same-block preview contract matters to the accountant
     */
    function check_v1ModelSameBlockPreviewEqualsMutatingYieldShare(uint256 utilization) external {
        v1.initializeYDMForMarket(uint64(5e17), uint64(9e17));
        // Stamp the adaptation clock at the current block with an on-kink call that leaves the curve still
        v1.yieldShare(MarketState.PERPETUAL, TARGET);

        uint256 previewed = v1.previewYieldShare(MarketState.PERPETUAL, utilization);
        uint256 returned = v1.yieldShare(MarketState.PERPETUAL, utilization);

        assert(previewed == returned);
    }

    /**
     * @notice For the V2 adaptive model with a live adaptation clock, a same-block preview equals the
     *         mutating yield share return for every utilization
     * @dev Same zero-elapsed slice construction as the V1 parity check, over V2's translated-spread curve
     */
    function check_v2ModelSameBlockPreviewEqualsMutatingYieldShare(uint256 utilization) external {
        v2.initializeYDMForMarket(uint64(1e17), uint64(5e17), uint64(9e17));
        v2.yieldShare(MarketState.PERPETUAL, TARGET);

        uint256 previewed = v2.previewYieldShare(MarketState.PERPETUAL, utilization);
        uint256 returned = v2.yieldShare(MarketState.PERPETUAL, utilization);

        assert(previewed == returned);
    }

    /*//////////////////////////////////////////////////////////////////////
                    A WRITE TOUCHES ONLY THE CALLING MARKET'S CURVE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice One YDM instance serves many markets keyed by the calling accountant, and a mutating yield
     *         share call from one market leaves every other market's curve bit-identical: the stored yield
     *         share at target, the adaptation clock, and the last written output of an unrelated market are
     *         untouched, whatever state that market is in
     * @dev Economic why: markets on a shared YDM are economically unrelated, and any cross-market write would
     *      let one market's sync reprice another market's premium without a sync of its own. The bystander
     *      market's state is fully symbolic, including the uninitialized zero sentinel, so isolation holds
     *      for markets in any lifecycle stage
     */
    function check_yieldShareWritesOnlyTheCallingMarketsCurve(uint256 utilization, uint256 storedA, uint256 storedB, uint256 clockB) external {
        vm.assume(MIN_YT <= storedA && storedA <= MAX_YT);
        echo.seedCurveFor(MARKET_A, storedA, 0);
        echo.seedCurveFor(MARKET_B, storedB, clockB);

        // Fixed term keeps the caller's path adaptation-free so the isolation claim carries no curve math
        vm.prank(MARKET_A);
        echo.yieldShare(MarketState.FIXED_TERM, utilization);

        // The bystander market's curve is bit-identical, including its never-written output slot
        assert(echo.yieldShareAtTarget(MARKET_B) == storedB);
        assert(echo.lastAdaptationTimestamp(MARKET_B) == clockB);
        assert(echo.lastWrittenYieldShare(MARKET_B) == 0);
        // The caller's own curve took the write (frozen position, restamped clock)
        assert(echo.yieldShareAtTarget(MARKET_A) == storedA);
        assert(echo.lastAdaptationTimestamp(MARKET_A) == SYNC_TIMESTAMP);
    }
}
