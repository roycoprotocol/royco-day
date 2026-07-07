// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { WAD, WAD_INT } from "../../src/libraries/Constants.sol";
import { MarketState } from "../../src/libraries/Types.sol";
import { AdaptiveYieldShareAtTargetExposer } from "../mocks/AdaptiveYieldShareAtTargetExposer.sol";
import { EchoAdaptiveCurveYDM } from "../mocks/EchoAdaptiveCurveYDM.sol";

/**
 * @title BaseAdaptiveCurveYDMSymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for the adaptive curve YDM base engine: the
 *         constructor's configuration partition, the normalization anchors and the over-capacity clamp of
 *         the utilization delta (including the full-target degenerate region), the exact zero-elapsed and
 *         never-adapted identities over a symbolic clock, the fixed-term curve freeze with its intentional
 *         clock restamp, the saturating clamp that guards the exponential from overflow, the exponential
 *         decay floor with its bounds preservation and time-average containment, the at-target and
 *         over-capacity directional anchors of the adaptation, and per-market isolation of curve writes
 * @dev Functions prefixed check_ are discovered only under --symbolic. Curve state is observed through the
 *      echo model (which returns either the time-averaged yield share at target or the shifted normalized
 *      delta straight from the base's curve hook) and through a thin exposer over the internal adaptation
 *      step. The symbolic engine cannot decide any division, signed division, or mulmod whose operands stay
 *      symbolic, so every check here is shaped so that all such operations fold to concrete values on every
 *      reachable path: utilization inputs are concrete (or constrained over-capacity, where the clamp folds
 *      them to exactly WAD), and the stored yield share at target is symbolic only where the exponential
 *      factor folds to zero (deep decay) or the adaptation block is skipped entirely (fixed term)
 * @dev Properties whose natural quantifier cannot satisfy that folding rule are carried empirically by
 *      named owner tests instead of symbolically here:
 *      - The region-scaled normalized-delta form over a symbolic utilization: owned by
 *        testFuzz_AdaptiveCurve_CurveIsFrozenWhileMarketIsInFixedTerm (hand-derived normalized delta over
 *        fuzzed utilizations and kinks) and testFuzz_AdaptiveCurve_OutputStaysInsideSpeedBoundedDriftEnvelope
 *        (exact independent-mirror match) in test/fuzz/YDM/TestFuzz_AdaptiveCurveYDM.t.sol
 *      - Full-domain totality and the exact delta of the 100%-target degenerate region: owned by
 *        testFuzz_TargetAtFullUtilization_NormalizationIsTotalAndDeltaIsClampedShortfall in
 *        test/fuzz/YDM/TestFuzz_AdaptiveTargetAtFullUtilization.t.sol
 *      - The stored-yield-share bounds invariant, the zero-elapsed identity, and the adaptation direction
 *        over a symbolic stored yield share at target and live drift windows: owned by
 *        testFuzz_AdaptiveCurve_OutputStaysInsideSpeedBoundedDriftEnvelope (band, direction, and exact
 *        mirror over fuzzed shares, utilizations, and windows up to a decade) and
 *        testFuzz_AdaptiveCurve_ToleratesACenturyBetweenAdaptations (band survival at the century extreme)
 *        in test/fuzz/YDM/TestFuzz_AdaptiveCurveYDM.t.sol, anchored by the long-dormancy saturation and
 *        adaptation-direction tests in test/concrete/YDM/Test_AdaptiveCurveYDM_V1.t.sol and _V2.t.sol
 *      - The time-average containment on upward drift: owned by the exact-mirror assertion of
 *        testFuzz_AdaptiveCurve_OutputStaysInsideSpeedBoundedDriftEnvelope, which recomputes the trapezoid
 *      - Preview-versus-mutate parity over a symbolic utilization for the concrete models: owned by
 *        testFuzz_StaticCurve_OutputMatchesIndependentDerivationExactly in
 *        test/fuzz/YDM/TestFuzz_StaticCurveYDM.t.sol and by test_PreviewYieldShare_EqualsYieldShareSameBlock
 *        plus testFuzz_PreviewYieldShare_DoesNotPersist in test/concrete/YDM/Test_AdaptiveCurveYDM_V1.t.sol
 *        and _V2.t.sol, with the base-level parity fuzz in test/concrete/YDM/Test_BaseAdaptiveCurveYDM.t.sol
 */
contract BaseAdaptiveCurveYDMSymbolicSpec is Test {
    /// @dev The target utilization (the kink) of the primary echo instance: 80%, so both curve regions are live
    uint256 internal constant TARGET = 8e17;

    /// @dev The configured lower bound on the adaptive yield share at target: 0.01%
    uint256 internal constant MIN_YT = 1e14;

    /// @dev The configured upper bound on the adaptive yield share at target: 100%
    uint256 internal constant MAX_YT = 1e18;

    /// @dev A representative mid-band stored yield share at target used wherever a concrete pin is required
    uint256 internal constant MID_YT = 5e17;

    /**
     * @dev The deploy-time ceiling on the max adaptation speed, derived independently as
     *      floor(100e18 / 31_536_000): a full 100x-per-year e-folding budget spread over the seconds in a
     *      365-day year. Every instance in this file is configured at exactly this ceiling so the concrete
     *      drifts exercise the fastest legal adaptation
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
     * @dev A drift window long enough that BOTH exponential legs of the adaptation fold to zero at max speed
     *      and full downward pressure: the full exponent is -MAX_SPEED * 30e6 = -9.513e19 and the trapezoid
     *      mid-point exponent is half that, -4.756e19, both at or below the WAD exponential's zero
     *      short-circuit boundary of -41446531673892822313 (where the result rounds to under half a wei and
     *      the exponential returns zero from its very first guard, before any polynomial machinery runs)
     */
    uint256 internal constant DEEP_DECAY_SECONDS = 30_000_000;

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

    function setUp() public {
        echo = new EchoAdaptiveCurveYDM(TARGET, MIN_YT, MAX_YT, MAX_SPEED);
        echoTargetAtFull = new EchoAdaptiveCurveYDM(WAD, MIN_YT, MAX_YT, MAX_SPEED);
        exposer = new AdaptiveYieldShareAtTargetExposer(TARGET, MIN_YT, MAX_YT, MAX_SPEED);
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
     * @notice The region-scaled normalization is exact at the five defining anchors of the curve: minus WAD
     *         at an empty pool, minus half WAD halfway down the below-target region, zero on the kink, plus
     *         half WAD halfway up the above-target region, and plus WAD at full utilization
     * @dev Economic why: the adaptation pressure is meant to be relative to how much room the current region
     *      offers, so a pool halfway into either region feels exactly half the maximal pull regardless of
     *      where the kink sits. Each anchor is an exact division with no remainder, derived inline: below the
     *      kink the delta is minus (TARGET - u) * WAD / TARGET, above it is (u - TARGET) * WAD / (WAD -
     *      TARGET). The anchors are concrete so the engine folds the signed division; the same form over a
     *      fully symbolic utilization is carried by the fixed-term freeze fuzz property named in the header
     */
    function check_normalizedDeltaExactAtRegionAnchors() external {
        echo.setEchoMode(EchoAdaptiveCurveYDM.EchoMode.NORMALIZED_DELTA_SHIFTED);
        // Any nonzero stored yield share passes the initialization gate, its value is unused in this mode
        echo.seedCurve(MID_YT, 0);

        // Empty pool: the shortfall is the whole below-target region, so the delta is exactly -WAD
        assert(int256(echo.previewYieldShare(MarketState.FIXED_TERM, 0)) - WAD_INT == -WAD_INT);
        // Halfway down the below-target region: (8e17 - 4e17) * 1e18 / 8e17 = 5e17 exactly, negated
        assert(int256(echo.previewYieldShare(MarketState.FIXED_TERM, TARGET / 2)) - WAD_INT == -5e17);
        // On the kink: zero distance, zero delta
        assert(int256(echo.previewYieldShare(MarketState.FIXED_TERM, TARGET)) - WAD_INT == 0);
        // Halfway up the above-target region: (9e17 - 8e17) * 1e18 / 2e17 = 5e17 exactly
        assert(int256(echo.previewYieldShare(MarketState.FIXED_TERM, (TARGET + WAD) / 2)) - WAD_INT == 5e17);
        // Full utilization: the excess is the whole above-target region, so the delta is exactly WAD
        assert(int256(echo.previewYieldShare(MarketState.FIXED_TERM, WAD)) - WAD_INT == WAD_INT);
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
        echo.seedCurve(MID_YT, 0);

        uint256 echoed = echo.previewYieldShare(MarketState.FIXED_TERM, utilization);

        // At the clamped input the above-target excess is the whole region, whose floored share is exactly WAD
        assert(int256(echoed) - WAD_INT == WAD_INT);
    }

    /**
     * @notice With the target configured at exactly 100%, any over-capacity utilization clamps to the WAD
     *         target and normalizes to a delta of exactly zero, never touching the empty above-target region
     *         whose width would divide by zero
     * @dev Economic why: a market may legitimately want its premium maxed only at full utilization, and the
     *      empty region above the kink must not turn that configuration into a division-by-zero brick under
     *      over-demanded reads. The clamp lands the input exactly on the kink, where the distance is zero.
     *      The below-capacity side of this totality claim (delta exactly the clamped utilization minus WAD
     *      for every input) is carried by the full-target fuzz property named in the header
     */
    function check_targetAtFullUtilizationClampsOverfullReadsToTheKink(uint256 utilization) external {
        vm.assume(utilization > WAD);
        echoTargetAtFull.setEchoMode(EchoAdaptiveCurveYDM.EchoMode.NORMALIZED_DELTA_SHIFTED);
        echoTargetAtFull.seedCurve(MID_YT, 0);

        try echoTargetAtFull.previewYieldShare(MarketState.FIXED_TERM, utilization) returns (uint256 echoed) {
            assert(int256(echoed) - WAD_INT == 0);
        } catch {
            // The clamp lands every over-capacity input on the kink, so no such input may revert
            assert(false);
        }
    }

    /**
     * @notice With the target at exactly 100%, the below-capacity anchors normalize exactly: the delta is the
     *         utilization minus WAD with no rounding at all, because multiplying by WAD and dividing by the
     *         WAD-wide region cancel perfectly
     * @dev Anchors pinned at the empty pool, the half-full pool, one wei under capacity, and exact capacity
     */
    function check_targetAtFullUtilizationDeltaExactAtAnchors() external {
        echoTargetAtFull.setEchoMode(EchoAdaptiveCurveYDM.EchoMode.NORMALIZED_DELTA_SHIFTED);
        echoTargetAtFull.seedCurve(MID_YT, 0);

        assert(int256(echoTargetAtFull.previewYieldShare(MarketState.FIXED_TERM, 0)) - WAD_INT == -WAD_INT);
        assert(int256(echoTargetAtFull.previewYieldShare(MarketState.FIXED_TERM, 5e17)) - WAD_INT == -5e17);
        assert(int256(echoTargetAtFull.previewYieldShare(MarketState.FIXED_TERM, WAD - 1)) - WAD_INT == -1);
        assert(int256(echoTargetAtFull.previewYieldShare(MarketState.FIXED_TERM, WAD)) - WAD_INT == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
                        ZERO-ELAPSED AND NEVER-ADAPTED IDENTITIES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A perpetual-state yield share read in the same block as the last adaptation is an exact
     *         identity at ANY current time: with zero elapsed time the linear adaptation is zero, the
     *         exponential of zero is exactly one, and the new, mid, and trapezoid-averaged yield shares at
     *         target all equal the stored value with no rounding, on the preview path and through the
     *         mutating write alike
     * @dev Economic why: the accountant can sync several times in one block (a deposit and a redemption, or a
     *      preview followed by its commit), and any wei of drift here would compound a same-block adaptation
     *      out of nothing. The current time is symbolic across the whole uint32 clock range, so the identity
     *      is proven independent of when the block lands. The stored yield share is pinned at the band edges
     *      and the mid-band because the engine cannot decide the adaptation's 512-bit multiply on a symbolic
     *      stored value; the symbolic-share side of this identity is carried by the drift-envelope fuzz
     *      property named in the header, whose elapsed window includes zero and which matches an exact mirror
     */
    function check_zeroElapsedAdaptationIsAnExactIdentityAtAnyCurrentTime(uint256 ts) external {
        vm.assume(1 <= ts && ts <= type(uint32).max);
        vm.warp(ts);

        // The utilization is pinned off-kink so a nonzero delta would adapt if any time were counted
        echo.seedCurve(MIN_YT, ts);
        assert(echo.previewYieldShare(MarketState.PERPETUAL, TARGET / 2) == MIN_YT);
        assert(echo.yieldShare(MarketState.PERPETUAL, TARGET / 2) == MIN_YT);
        assert(echo.yieldShareAtTarget(address(this)) == MIN_YT);

        echo.seedCurve(MID_YT, ts);
        assert(echo.previewYieldShare(MarketState.PERPETUAL, TARGET / 2) == MID_YT);
        assert(echo.yieldShare(MarketState.PERPETUAL, TARGET / 2) == MID_YT);
        assert(echo.yieldShareAtTarget(address(this)) == MID_YT);

        echo.seedCurve(MAX_YT, ts);
        assert(echo.previewYieldShare(MarketState.PERPETUAL, TARGET / 2) == MAX_YT);
        assert(echo.yieldShare(MarketState.PERPETUAL, TARGET / 2) == MAX_YT);
        assert(echo.yieldShareAtTarget(address(this)) == MAX_YT);
    }

    /**
     * @notice A market whose curve has never adapted (zero adaptation clock) ignores the wall clock entirely:
     *         at any block timestamp the elapsed window reads zero and the yield share at target passes
     *         through untouched, and only after the first mutating call does the clock start
     * @dev Economic why: the gap between a market's YDM initialization and its first sync is unbounded, and
     *      treating the zero sentinel as a real timestamp would apply that whole gap as a one-shot adaptation
     *      at the first sync, slamming the curve to a bound before any market forces acted. The timestamp is
     *      symbolic across the whole uint32 clock range to pin that the identity is clock-independent. The
     *      stored yield share is pinned at the band edges and mid-band (the engine cannot decide the
     *      adaptation's 512-bit multiply on a symbolic stored value); every run of the drift-envelope fuzz
     *      property named in the header asserts this first-call identity on a fuzzed share before drifting
     */
    function check_neverAdaptedMarketIgnoresTheWallClock(uint256 timestamp) external {
        vm.assume(1 <= timestamp && timestamp <= type(uint32).max);
        vm.warp(timestamp);

        echo.seedCurve(MIN_YT, 0);
        assert(echo.previewYieldShare(MarketState.PERPETUAL, TARGET / 2) == MIN_YT);
        assert(echo.yieldShare(MarketState.PERPETUAL, TARGET / 2) == MIN_YT);
        assert(echo.yieldShareAtTarget(address(this)) == MIN_YT);
        // The first mutating call starts the adaptation clock at the current block
        assert(echo.lastAdaptationTimestamp(address(this)) == timestamp);

        echo.seedCurve(MAX_YT, 0);
        assert(echo.previewYieldShare(MarketState.PERPETUAL, TARGET / 2) == MAX_YT);
        assert(echo.yieldShare(MarketState.PERPETUAL, TARGET / 2) == MAX_YT);
        assert(echo.yieldShareAtTarget(address(this)) == MAX_YT);
        assert(echo.lastAdaptationTimestamp(address(this)) == timestamp);
    }

    /*//////////////////////////////////////////////////////////////////////
                FIXED TERM FREEZES THE CURVE BUT RESTAMPS THE CLOCK
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice PINS AN INTENTIONAL DIVERGENCE. In a fixed-term market the curve is frozen: the output is the
     *         stored yield share at target with the elapsed window ignored, and the curve position persists
     *         unchanged, for a fully symbolic stored share and a fully symbolic stale clock. But the mutating
     *         call still restamps the adaptation clock to the current block, so the time a market spends in
     *         fixed term is permanently erased from the adaptation window rather than applied when the market
     *         re-enters the perpetual state
     * @dev Economic why the freeze: deposits and redemptions are locked in fixed term, so utilization cannot
     *      respond to premium changes and adaptation would spiral against a dead market signal. Why the
     *      restamp is pinned as intentional: on re-entry to perpetual the curve resumes from the re-entry
     *      block instead of retroactively charging the locked period, which matches the design that the curve
     *      adapts only while the market is perpetual. If the restamp behavior is ever changed this check
     *      surfaces it. The utilization is pinned concrete because the delta normalization's signed division
     *      is undecidable for the engine on a symbolic input and the frozen arm ignores the delta anyway;
     *      the symbolic-utilization freeze is carried by the fixed-term fuzz property named in the header
     */
    function check_fixedTermFreezesTheCurveButRestampsTheAdaptationClock(uint256 lastTs, uint256 storedYT) external {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        // A strictly stale clock, so a live elapsed window exists and is provably ignored
        vm.assume(1 <= lastTs && lastTs < SYNC_TIMESTAMP);
        echo.seedCurve(storedYT, lastTs);

        // The frozen preview and the frozen mutating return are both the stored value
        assert(echo.previewYieldShare(MarketState.FIXED_TERM, TARGET / 2) == storedYT);
        uint256 returned = echo.yieldShare(MarketState.FIXED_TERM, TARGET / 2);

        // Frozen: the output and the persisted curve position are the stored value, elapsed time notwithstanding
        assert(returned == storedYT);
        assert(echo.yieldShareAtTarget(address(this)) == storedYT);
        // The divergence pin: the write hook still runs and stamps the clock to now, erasing the stale window
        assert(echo.lastAdaptationTimestamp(address(this)) == SYNC_TIMESTAMP);
    }

    /*//////////////////////////////////////////////////////////////////////
                STORED YIELD SHARE BOUNDS SURVIVE THE DEEP-DECAY WRITE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Ten years of drift at empty utilization keeps the stored yield share at target within its
     *         configured band for every seeded position in the band: the decay lands exactly on the minimum
     * @dev One inductive step of the bounds invariant on the deepest downward drift. This grid point stays
     *      symbolic over the whole stored band because both exponential legs (the full exponent and the
     *      trapezoid mid-point) sit past the exponential's zero short-circuit, so the 512-bit multiply folds
     *      to zero and the engine decides the clamp exactly. Drift windows whose exponential factor is
     *      nonzero cannot keep a symbolic stored share (the multiply is undecidable) and are carried by the
     *      drift-envelope and century fuzz properties named in the header
     */
    function check_storedYieldShareBoundsHoldAfterTenYearsAtZeroUtilization(uint256 storedYT) external {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        echo.seedCurve(storedYT, SYNC_TIMESTAMP - 3650 days);

        echo.yieldShare(MarketState.PERPETUAL, 0);

        uint256 stored = echo.yieldShareAtTarget(address(this));
        assert(MIN_YT <= stored && stored <= MAX_YT);
    }

    /**
     * @notice Ten years of drift at half the target utilization keeps the stored yield share at target within
     *         its configured band for every seeded position in the band
     * @dev The half-pressure twin of the empty-utilization step: the normalized delta is exactly minus half
     *      WAD, and even at half the max speed a decade of drift puts both exponential legs past the zero
     *      short-circuit, so the multiply folds and the min clamp provably catches the collapsed value
     */
    function check_storedYieldShareBoundsHoldAfterTenYearsAtHalfTargetUtilization(uint256 storedYT) external {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        echo.seedCurve(storedYT, SYNC_TIMESTAMP - 3650 days);

        echo.yieldShare(MarketState.PERPETUAL, TARGET / 2);

        uint256 stored = echo.yieldShareAtTarget(address(this));
        assert(MIN_YT <= stored && stored <= MAX_YT);
    }

    /*//////////////////////////////////////////////////////////////////////
                THE UPWARD CLAMP GUARDS THE EXPONENTIAL AND SATURATES
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Any linear adaptation strictly above the clamp threshold is clamped down to it before reaching
     *         the exponential, so the adaptation step never reverts on overflow and the resulting yield share
     *         at target saturates at exactly the configured maximum, from either end of the stored band
     * @dev Economic why: roughly 1.35 years of uninterrupted max-speed upward drift is enough to push the
     *      exponent past the point where the WAD exponential's result no longer fits a signed 256-bit
     *      integer, and an unclamped argument would revert there, bricking every sync of the market forever
     *      (the drift only grows with time). Saturation is the right semantics because the post-clamp
     *      multiplier exceeds 5e58, so even the minimum stored yield share maps far above the WAD ceiling.
     *      The exponent is fully symbolic above the threshold (the clamp folds it to the concrete threshold
     *      constant); the stored share is pinned at both band edges because the engine cannot decide the
     *      512-bit multiply on a symbolic stored value, and the interior of the band is monotone between the
     *      edges, carried empirically by the century fuzz property named in the header
     */
    function check_linearAdaptationAboveClampThresholdSaturatesToMaxWithoutReverting(int256 lin) external view {
        // Strictly above the threshold: the clamp rewrites the exponent to the constant threshold value
        vm.assume(lin > MAX_LIN);

        try exposer.computeYieldShareAtTarget(MIN_YT, lin) returns (uint256 adapted) {
            assert(adapted == MAX_YT);
        } catch {
            assert(false);
        }
        try exposer.computeYieldShareAtTarget(MAX_YT, lin) returns (uint256 adapted) {
            assert(adapted == MAX_YT);
        } catch {
            assert(false);
        }
    }

    /**
     * @notice At exactly the clamp threshold (the largest exponent the WAD exponential accepts) the
     *         adaptation step does not revert and still saturates at the configured maximum, from either end
     *         of the stored band
     * @dev The boundary arm of the clamp's ternary: the exponent passes through unclamped, so this pins that
     *      the threshold constant itself is on the safe side of the exponential's overflow revert
     */
    function check_linearAdaptationExactlyAtClampThresholdSaturatesToMaxWithoutReverting() external view {
        assert(exposer.computeYieldShareAtTarget(MIN_YT, MAX_LIN) == MAX_YT);
        assert(exposer.computeYieldShareAtTarget(MAX_YT, MAX_LIN) == MAX_YT);
    }

    /*//////////////////////////////////////////////////////////////////////
                DEEP DOWNWARD DRIFT DECAYS TO THE MIN WITHOUT A LOWER CLAMP
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Any linear adaptation at or below the exponential's zero short-circuit boundary decays the
     *         yield share at target to exactly the configured minimum, with no revert, for a fully symbolic
     *         stored share anywhere in the band: no symmetric lower clamp on the exponent is needed because
     *         the exponential of a deep negative rounds to zero and the min bound catches the collapsed value
     * @dev Economic why: a market can sit at zero utilization indefinitely, so the downward drift is
     *      unbounded in time and the decay path must be total, and the configured minimum is what keeps a
     *      long-idle market's premium restartable instead of stuck at an unrecoverable zero. The symbolic
     *      exponent here only ever reaches the exponential's first guard, which returns zero before any of
     *      the polynomial machinery executes, so the multiply folds and the whole step stays decidable even
     *      with both arguments symbolic. The boundary constant is the argument at or below which e^(x / 1e18)
     *      scaled by 1e18 rounds to under half a wei
     */
    function check_deepNegativeLinearAdaptationDecaysToMinWithoutReverting(uint256 storedYT, int256 lin) external view {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        // At or below the zero short-circuit boundary the exponential is exactly zero by its first guard
        vm.assume(lin <= -41_446_531_673_892_822_313);

        try exposer.computeYieldShareAtTarget(storedYT, lin) returns (uint256 adapted) {
            assert(adapted == MIN_YT);
        } catch {
            assert(false);
        }
    }

    /**
     * @notice End to end through the full yield share flow: after roughly 347 days at zero utilization and
     *         max speed, one perpetual sync decays the persisted yield share at target to exactly the
     *         configured minimum, wherever in the band it started
     * @dev The concrete drift pins the full exponent at about -95.1 and the trapezoid mid-point exponent at
     *      about -47.6, both past the exponential's zero short-circuit, so the new and mid yield shares both
     *      collapse to the min bound with the stored share left fully symbolic. The write must persist the
     *      min, keeping the curve restartable
     */
    function check_longIdleDriftDecaysThePersistedYieldShareToMin(uint256 storedYT) external {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        echo.seedCurve(storedYT, SYNC_TIMESTAMP - DEEP_DECAY_SECONDS);

        echo.yieldShare(MarketState.PERPETUAL, 0);

        assert(echo.yieldShareAtTarget(address(this)) == MIN_YT);
    }

    /*//////////////////////////////////////////////////////////////////////
                ADAPTATION MOVES TOWARD THE UTILIZATION PRESSURE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Utilization exactly on the kink leaves the curve exactly still for any elapsed window: the
     *         normalized delta is zero, so the adaptation speed and the linear adaptation are zero regardless
     *         of how much time passed, and both the returned yield share and the persisted position equal the
     *         seeded value with no rounding, at either band edge and mid-band
     * @dev Economic why: a market resting on its target is in equilibrium and the model must not manufacture
     *      drift from the mere passage of time, otherwise every equilibrium would erode toward a bound. The
     *      elapsed window is symbolic across the whole clock range because the zero delta annihilates it
     *      (zero speed times any window folds to a zero exponent). The stored share is pinned (the engine
     *      cannot decide the 512-bit multiply on a symbolic stored value even at an exponent of zero); the
     *      symbolic-share equilibrium is carried by the drift-envelope fuzz property named in the header,
     *      whose direction assertions meet at equality on the kink
     */
    function check_atTargetUtilizationLeavesTheCurveExactlyStillForAnyElapsedWindow(uint256 lastTs) external {
        vm.assume(1 <= lastTs && lastTs <= SYNC_TIMESTAMP);

        echo.seedCurve(MIN_YT, lastTs);
        assert(echo.yieldShare(MarketState.PERPETUAL, TARGET) == MIN_YT);
        assert(echo.yieldShareAtTarget(address(this)) == MIN_YT);

        echo.seedCurve(MID_YT, lastTs);
        assert(echo.yieldShare(MarketState.PERPETUAL, TARGET) == MID_YT);
        assert(echo.yieldShareAtTarget(address(this)) == MID_YT);

        echo.seedCurve(MAX_YT, lastTs);
        assert(echo.yieldShare(MarketState.PERPETUAL, TARGET) == MAX_YT);
        assert(echo.yieldShareAtTarget(address(this)) == MAX_YT);
    }

    /**
     * @notice Over-capacity demand never adapts the curve downward: after an hour of drift, every utilization
     *         report above 100% clamps to the full-scarcity delta and moves the mid-band stored yield share
     *         at target upward, keeping it within the configured band
     * @dev Economic why: the adaptation is a restoring force, scarcity of the pooled service must raise the
     *      premium to attract capital, so an adaptation that could move against its own pressure would turn
     *      the feedback loop unstable. The utilization is symbolic across the whole over-capacity range (the
     *      clamp folds it to exactly WAD, making the exponent a concrete positive constant); the general
     *      direction property over a symbolic stored share and both curve regions is carried by the
     *      drift-envelope fuzz property named in the header
     */
    function check_overCapacityDemandNeverAdaptsTheCurveDownward(uint256 utilization) external {
        vm.assume(utilization > WAD);
        echo.seedCurve(MID_YT, SYNC_TIMESTAMP - 1 hours);

        uint256 returned = echo.yieldShare(MarketState.PERPETUAL, utilization);

        uint256 stored = echo.yieldShareAtTarget(address(this));
        assert(stored >= MID_YT && stored <= MAX_YT);
        // The returned value is the trapezoid average of the rising path, so it cannot undershoot the start
        assert(returned >= MID_YT);
    }

    /*//////////////////////////////////////////////////////////////////////
                THE TRAPEZOID AVERAGE LIES BETWEEN OLD AND NEW
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice On the deep-decay drift the time-averaged yield share at target handed to the curve lies
     *         between the newly persisted minimum and the seeded value, for a fully symbolic seeded share
     * @dev Economic why: the average is what the accountant actually pays for the elapsed window, so an
     *      average escaping the endpoints would pay a premium the curve never passed through during the
     *      drift. On this drift both exponential legs collapse to the min bound m, so the trapezoid is
     *      (s + m + 2m) / 4 exactly, and the containment reduces to linear arithmetic: with s >= m the sum
     *      s + 3m is at least 4m and at most 4s, so the floored quarter lies in [m, s]. The upward-drift
     *      twin cannot keep a symbolic seeded share (its exponential factor is nonzero) and is carried by
     *      the exact-mirror drift-envelope fuzz property named in the header
     */
    function check_timeAveragedYieldShareLiesBetweenNewMinAndSeededValueOnDeepDecay(uint256 storedYT) external {
        vm.assume(MIN_YT <= storedYT && storedYT <= MAX_YT);
        echo.seedCurve(storedYT, SYNC_TIMESTAMP - DEEP_DECAY_SECONDS);

        // The echo model returns the trapezoid average straight from the base's curve hook
        uint256 average = echo.yieldShare(MarketState.PERPETUAL, 0);
        uint256 adapted = echo.yieldShareAtTarget(address(this));

        assert(adapted == MIN_YT);
        assert(average >= MIN_YT && average <= storedYT);
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
     *      for markets in any lifecycle stage. Fixed term keeps the caller's path adaptation-free so the
     *      isolation claim carries no curve math, and the utilization is pinned concrete because the delta
     *      normalization's signed division is undecidable for the engine on a symbolic input
     */
    function check_yieldShareWritesOnlyTheCallingMarketsCurve(uint256 storedA, uint256 storedB, uint256 clockB) external {
        vm.assume(MIN_YT <= storedA && storedA <= MAX_YT);
        echo.seedCurveFor(MARKET_A, storedA, 0);
        echo.seedCurveFor(MARKET_B, storedB, clockB);

        vm.prank(MARKET_A);
        echo.yieldShare(MarketState.FIXED_TERM, TARGET / 2);

        // The bystander market's curve is bit-identical, including its never-written output slot
        assert(echo.yieldShareAtTarget(MARKET_B) == storedB);
        assert(echo.lastAdaptationTimestamp(MARKET_B) == clockB);
        assert(echo.lastWrittenYieldShare(MARKET_B) == 0);
        // The caller's own curve took the write (frozen position, restamped clock)
        assert(echo.yieldShareAtTarget(MARKET_A) == storedA);
        assert(echo.lastAdaptationTimestamp(MARKET_A) == SYNC_TIMESTAMP);
    }
}
