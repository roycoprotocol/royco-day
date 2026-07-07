// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { MarketState } from "../../src/libraries/Types.sol";
import { StaticCurveYDM } from "../../src/ydm/StaticCurveYDM.sol";

/**
 * @title StaticCurveYDMSymbolicSpec
 * @notice Native symbolic specs (`forge test --symbolic`) for the static curve yield distribution model: the
 *         constructor's target utilization acceptance window, the per-market initialization partition (which
 *         curves are accepted, including the undocumented uint64 slope-frontier constraint), the permanently
 *         bricked target-at-WAD configuration (a known divergence, re-pinned universally here), exact endpoint
 *         and kink fidelity of the stored piecewise curve, the output bounds, monotonicity across both legs and
 *         the kink, the plateau above 100% utilization, totality of an initialized curve over the entire uint256
 *         utilization range, the uninitialized-market revert with its zero-sentinel soundness, and the purity of
 *         the state-mutating entrypoint (view-equivalent, market-state-independent, and writes nothing)
 * @dev Run with `forge test --symbolic --match-path test/symbolic/StaticCurveYDMSymbolic.t.sol`. Functions
 *      prefixed check_ are discovered only under --symbolic. Curve-shape checks deploy a fresh model inside the
 *      check with a fully symbolic target utilization in [1, WAD-1] and a symbolic monotone curve constrained to
 *      the slope frontier, so every property is proven for every constructible instance at once. The
 *      initialization partition instead uses the concrete target grid deployed in setUp, because its acceptance
 *      frontier must be exercised on both sides (a symbolic target would entangle the two frontier products)
 * @dev Expected values are derived independently: every division-shaped expectation is either a plain checked
 *      multiply and divide (all products here are far below 2^256 since curve points fit uint64 and utilization
 *      is capped at WAD = 1e18) or a two-sided floor bracket stated on the production outputs, never a re-run of
 *      the production mulDiv chain as its own expectation
 */
contract StaticCurveYDMSymbolicSpec is Test {
    /// @dev WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /// @dev The uint64 ceiling: a computed slope at or above this cannot be stored and makes initialization revert
    uint256 internal constant UINT64_CEILING = uint256(1) << 64;

    /// @dev Concrete target utilization grid for the initialization partition: the extremes (1 wei and WAD - 1)
    ///      make each slope's uint64 frontier reachable, the mid targets keep both slopes always storable
    uint256[5] internal partitionTargets;

    /// @dev One model per grid target, deployed uninitialized so each check exercises its own initialization
    StaticCurveYDM[5] internal partitionModels;

    /// @dev A model constructed with the target utilization at exactly WAD (accepted by the constructor)
    StaticCurveYDM internal targetAtWadModel;

    function setUp() public {
        partitionTargets = [uint256(1), 5e16, 5e17, 9e17, WAD - 1];
        for (uint256 i; i < partitionTargets.length; ++i) {
            partitionModels[i] = new StaticCurveYDM(partitionTargets[i]);
        }
        targetAtWadModel = new StaticCurveYDM(WAD);
    }

    /*//////////////////////////////////////////////////////////////////////
                            SHARED DEPLOYMENT HELPER
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Deploys a fresh static curve model with a symbolic target utilization and initializes it for this
     *      test contract's market, constraining the inputs to exactly the constructible domain: a target in
     *      [1, WAD-1] (WAD is excluded because that configuration can never be initialized, pinned separately
     *      below), a monotone non-decreasing curve capped at 100% with a nonzero target point, and both slopes
     *      below the uint64 storage ceiling. The slope-fit conditions are derived independently of the model's
     *      slope math: a floored slope floor(rise * WAD / run) fits uint64 exactly when rise * WAD < 2^64 * run
     */
    function _deployInitialized(uint256 target, uint64 y0, uint64 yT, uint64 yFull) internal returns (StaticCurveYDM model) {
        vm.assume(1 <= target && target <= WAD - 1);
        vm.assume(y0 <= yT && yT <= yFull && uint256(yFull) <= WAD && yT > 0);
        vm.assume(uint256(yT - y0) * WAD < UINT64_CEILING * target);
        vm.assume(uint256(yFull - yT) * WAD < UINT64_CEILING * (WAD - target));
        model = new StaticCurveYDM(target);
        // A plain call: this initialization must succeed on the whole assumed domain, so a revert here would
        // itself be a counterexample to the acceptance frontier derived above
        model.initializeYDMForMarket(y0, yT, yFull);
    }

    /*//////////////////////////////////////////////////////////////////////
                        CONSTRUCTOR ACCEPTANCE PARTITION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The constructor accepts exactly the target utilizations in (0, WAD]: anything in that window
     *         deploys and stamps the immutable target verbatim, zero and anything above 100% revert with the
     *         invalid-initialization error
     * @dev Economic why: the target is the curve's kink, the utilization at which the premium's slope steepens
     *      to pull capital in. A zero target would put the kink at the origin and leave the below-target leg's
     *      slope dividing by zero, and a target above 100% would place the kink beyond the model's own
     *      utilization cap where it could never bind, so both are rejected at deployment rather than left to
     *      brick the market later
     */
    function check_ydmConstructor_acceptsExactlyTargetInZeroToWAD(uint256 target) external {
        try new StaticCurveYDM(target) returns (StaticCurveYDM model) {
            // The acceptance window, derived from what makes the kink meaningful: strictly positive, at most 100%
            assert(1 <= target && target <= WAD);
            // The immutable is the exact supplied target: no scaling, no clamping
            assert(model.TARGET_UTILIZATION_WAD() == target);
        } catch (bytes memory err) {
            assert(target == 0 || target > WAD);
            // The rejection is the model's own configuration error, not an arithmetic panic
            assert(keccak256(err) == keccak256(abi.encodeWithSelector(IYDM.INVALID_YDM_INITIALIZATION.selector)));
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                        INITIALIZATION ACCEPTANCE PARTITION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Market initialization succeeds for exactly the monotone curves whose two slopes fit uint64
     *         storage: the three curve points must be non-decreasing, capped at 100%, with a nonzero target
     *         point, AND the rise of each leg scaled by WAD must stay below 2^64 times that leg's run. The
     *         second family of conditions is an undocumented configuration constraint: a very steep leg (a
     *         large rise over a tiny run) computes a slope too wide for its uint64 storage slot and reverts
     * @dev Economic why: the monotonicity guard enforces the model's incentive direction (scarcer service is
     *      never paid less), the nonzero target point is the initialization sentinel (a zero would make the
     *      market read as uninitialized forever), and the slope frontier is real: with the kink at 1 wei of
     *      utilization the below-target leg can rise at most 18 wei of yield share (2^64 / 1e18) before its
     *      slope floor((yT - y0) * WAD / target) overflows uint64. The expected frontier is derived as plain
     *      products on both sides, never by re-running the slope division. The grid pins targets on both sides
     *      of each leg's frontier: 1 and 5e16 make the below-leg frontier reachable, 9e17 and WAD - 1 the
     *      above-leg frontier, and 5e17 neither (every monotone curve fits)
     */
    function check_staticInit_acceptsExactlyMonotoneCurvesThatFitUint64Slopes(uint64 y0, uint64 yT, uint64 yFull) external {
        for (uint256 i; i < partitionTargets.length; ++i) {
            uint256 target = partitionTargets[i];
            // The independently derived acceptance condition: monotone, capped, nonzero sentinel, both slopes storable
            bool expectSuccess = y0 <= yT && yT <= yFull && uint256(yFull) <= WAD && yT > 0;
            if (expectSuccess) {
                expectSuccess = uint256(yT - y0) * WAD < UINT64_CEILING * target && uint256(yFull - yT) * WAD < UINT64_CEILING * (WAD - target);
            }
            try partitionModels[i].initializeYDMForMarket(y0, yT, yFull) {
                assert(expectSuccess);
            } catch {
                assert(!expectSuccess);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////
            KNOWN DIVERGENCE: TARGET AT WAD IS PERMANENTLY BRICKED
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice PINS A KNOWN DIVERGENCE. A model constructed with the target utilization at exactly WAD is
     *         accepted by the constructor but can never be initialized for any market: every valid curve
     *         triple makes initialization revert with a division-by-zero panic, universally, so the deployed
     *         instance is permanently unusable
     * @dev Why this is a divergence: the constructor documents (0, WAD] as the valid target window, but the
     *      above-target slope divides the leg's rise by (WAD - target), which is zero when the kink sits at
     *      100%. The division panics even when the rise is zero (0 / 0 also panics), so no curve shape escapes
     *      it. The deployment succeeds, the failure only surfaces when a market tries to wire the model in.
     *      This check re-pins the already-adjudicated concrete finding across the entire valid input space
     */
    function check_staticInit_targetAtWADAlwaysPanics(uint64 y0, uint64 yT, uint64 yFull) external {
        // Every otherwise-valid curve: monotone, capped at 100%, nonzero target point
        vm.assume(y0 <= yT && yT <= yFull && uint256(yFull) <= WAD && yT > 0);

        try targetAtWadModel.initializeYDMForMarket(y0, yT, yFull) {
            // No curve shape can make the zero-run division survive
            assert(false);
        } catch (bytes memory err) {
            // The failure is specifically the division-by-zero panic (0x12), not the configuration error
            assert(keccak256(err) == keccak256(abi.encodeWithSignature("Panic(uint256)", uint256(0x12))));
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                            ENDPOINT FIDELITY
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice At zero utilization the curve reproduces the configured zero-utilization yield share exactly:
     *         the below-target leg's slope term vanishes and only the intercept remains
     * @dev Economic why: zero utilization means the capital pool's service is entirely unused, so the premium
     *      must be exactly the configured floor of the curve, with no rounding drift in either direction. The
     *      expected value is the raw initialization input itself, no arithmetic at all
     */
    function check_staticCurve_zeroUtilizationReproducesShareAtZeroExactly(uint256 target, uint64 y0, uint64 yT, uint64 yFull) external {
        StaticCurveYDM model = _deployInitialized(target, y0, yT, yFull);

        // Zero is always strictly below the (positive) kink, so this exercises the below-target leg's intercept
        assert(model.previewYieldShare(MarketState.PERPETUAL, 0) == y0);
    }

    /**
     * @notice At exactly the target utilization the curve reproduces the configured target yield share
     *         exactly: the at-or-above-target leg anchors at the kink with a vanishing slope term
     * @dev Economic why: the target point is the calibration anchor issuers actually reason about (the premium
     *      at the utilization the market is steered toward), so it must be reproduced to the wei even though
     *      both stored slopes are floored. The kink belongs to the upper leg, whose distance term is zero there
     */
    function check_staticCurve_targetUtilizationReproducesShareAtTargetExactly(uint256 target, uint64 y0, uint64 yT, uint64 yFull) external {
        StaticCurveYDM model = _deployInitialized(target, y0, yT, yFull);

        // Utilization == kink takes the at-or-above-target leg, whose scaled distance from the kink is zero
        assert(model.previewYieldShare(MarketState.PERPETUAL, target) == yT);
    }

    /**
     * @notice At full utilization the curve reproduces the configured full-utilization yield share to within
     *         one wei from below: the stored above-target slope is floored once at initialization, so replaying
     *         it across the whole upper leg can lose at most a single wei against the configured endpoint
     * @dev Independent derivation of the bracket, from the floor bracket of the stored slope s over run
     *      r = WAD - target and rise g = yFull - yT: s * r <= g * WAD < (s + 1) * r. The upper leg at full
     *      utilization returns floor(s * r / WAD) + yT. Upper side: s * r <= g * WAD gives floor(s * r / WAD)
     *      <= g. Lower side: s * r > g * WAD - r >= g * WAD - WAD = (g - 1) * WAD gives floor(s * r / WAD)
     *      >= g - 1. Undershooting is the safe direction: the premium never exceeds what the issuer configured
     */
    function check_staticCurve_fullUtilizationReproducesShareAtFullWithinOneWei(uint256 target, uint64 y0, uint64 yT, uint64 yFull) external {
        StaticCurveYDM model = _deployInitialized(target, y0, yT, yFull);

        uint256 atFull = model.previewYieldShare(MarketState.PERPETUAL, WAD);
        // Never above the configured endpoint, and at most one wei below it
        assert(atFull <= yFull);
        assert(atFull + 1 >= yFull);
    }

    /*//////////////////////////////////////////////////////////////////////
                            KINK CONTINUITY
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The below-target leg, extrapolated to the kink, meets the configured target yield share to
     *         within one wei from below: the curve is continuous at the kink up to the single flooring of the
     *         stored below-target slope
     * @dev Economic why: a gap at the kink would make the premium jump discontinuously as utilization crosses
     *      the target, creating a cliff an operation could deliberately land on either side of. The
     *      extrapolation is computed from the stored slope with plain multiply and divide (the below-target
     *      leg's own form), and the bracket is derived from the slope's floor bracket over run t and rise
     *      g = yT - y0: slope * t <= g * WAD < (slope + 1) * t, so floor(slope * t / WAD) is at most g and,
     *      since slope * t > g * WAD - t > (g - 1) * WAD, at least g - 1
     */
    function check_staticCurve_belowTargetLegMeetsKinkWithinOneWei(uint256 target, uint64 y0, uint64 yT, uint64 yFull) external {
        StaticCurveYDM model = _deployInitialized(target, y0, yT, yFull);

        // The stored below-target slope, read back from the model's storage for this market
        (, uint64 slopeLt,,) = model.accountantToCurve(address(this));

        // The below-target leg evaluated at the kink itself (production only evaluates it strictly below)
        uint256 extrapolated = uint256(slopeLt) * target / WAD + y0;
        assert(extrapolated <= yT);
        assert(extrapolated + 1 >= yT);
    }

    /*//////////////////////////////////////////////////////////////////////
                            OUTPUT BOUNDS PER LEG
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Below the target utilization the yield share never leaves [y0, yT]: the premium is at least the
     *         configured floor and never reaches past the target point before the kink is crossed
     * @dev Independent derivation of the upper bound: the stored slope satisfies slope * target <= (yT - y0)
     *      * WAD, and utilization < target, so slope * utilization < (yT - y0) * WAD and the floored slope
     *      term is at most yT - y0. The lower bound is the intercept: the slope term is non-negative. A
     *      premium escaping this envelope would pay the pool more than the issuer configured for sub-target
     *      scarcity, out of yield the paying tranche never agreed to give up
     */
    function check_staticCurve_belowTargetOutputStaysBetweenZeroAndTargetShares(uint256 target, uint64 y0, uint64 yT, uint64 yFull, uint256 utilization) external {
        StaticCurveYDM model = _deployInitialized(target, y0, yT, yFull);
        // Pin the below-target leg
        vm.assume(utilization < target);

        uint256 share = model.previewYieldShare(MarketState.PERPETUAL, utilization);
        assert(share >= y0);
        assert(share <= yT);
    }

    /**
     * @notice At or above the target utilization the yield share never leaves [yT, yFull]: the premium starts
     *         at the target point and is capped by the configured full-utilization share even for utilization
     *         inputs far above 100%, so the model can never promise more than the issuer's configured maximum
     * @dev Independent derivation of the upper bound: the input is clamped to WAD first, so the distance past
     *      the kink is at most WAD - target; the stored slope satisfies slope * (WAD - target) <= (yFull - yT)
     *      * WAD, so the floored slope term is at most yFull - yT. Combined with yFull <= WAD from the
     *      initialization guard, the output can never exceed 100% of the paying tranche's yield
     */
    function check_staticCurve_aboveTargetOutputStaysBetweenTargetAndFullShares(uint256 target, uint64 y0, uint64 yT, uint64 yFull, uint256 utilization) external {
        StaticCurveYDM model = _deployInitialized(target, y0, yT, yFull);
        // Pin the at-or-above-target leg; the utilization is otherwise unbounded to cover the clamp
        vm.assume(utilization >= target);

        uint256 share = model.previewYieldShare(MarketState.PERPETUAL, utilization);
        assert(share >= yT);
        assert(share <= yFull);
    }

    /*//////////////////////////////////////////////////////////////////////
                        MONOTONE NON-DECREASING IN UTILIZATION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Within the below-target leg the yield share is monotone non-decreasing in utilization: more
     *         demand on the pool's service is never paid less
     * @dev Both outputs are the same floored slope term over the same slope, and flooring preserves the order
     *      of the numerators. Monotonicity is the model's whole incentive mechanism: if the premium could dip
     *      as utilization rises, capital would be paid to leave exactly when the service grows scarcer
     */
    function check_staticCurve_monotoneWhenBothUtilizationsBelowTarget(uint256 target, uint64 y0, uint64 yT, uint64 yFull, uint256 utilA, uint256 utilB) external {
        StaticCurveYDM model = _deployInitialized(target, y0, yT, yFull);
        // Pin both points inside the below-target leg, ordered
        vm.assume(utilA <= utilB && utilB < target);

        assert(model.previewYieldShare(MarketState.PERPETUAL, utilA) <= model.previewYieldShare(MarketState.PERPETUAL, utilB));
    }

    /**
     * @notice Within the at-or-above-target leg the yield share is monotone non-decreasing in utilization:
     *         past the kink the steeper leg keeps paying weakly more as the service saturates
     * @dev Both outputs floor the same slope against ordered distances from the kink. The leg is pinned up to
     *      WAD, inputs beyond that are the plateau property, proven separately
     */
    function check_staticCurve_monotoneWhenBothUtilizationsAtOrAboveTarget(uint256 target, uint64 y0, uint64 yT, uint64 yFull, uint256 utilA, uint256 utilB) external {
        StaticCurveYDM model = _deployInitialized(target, y0, yT, yFull);
        // Pin both points inside the at-or-above-target leg, ordered, up to the clamp boundary
        vm.assume(target <= utilA && utilA <= utilB && utilB <= WAD);

        assert(model.previewYieldShare(MarketState.PERPETUAL, utilA) <= model.previewYieldShare(MarketState.PERPETUAL, utilB));
    }

    /**
     * @notice Across the kink the yield share is monotone non-decreasing: any below-target utilization is paid
     *         at most any at-or-above-target utilization, so crossing the target can never lower the premium
     * @dev Independent derivation: the below-target output is at most yT (its slope term is capped by the
     *      slope's floor bracket, as in the per-leg bound above) and the at-or-above-target output is at least
     *      yT (its slope term is non-negative), so the kink value separates the two legs
     */
    function check_staticCurve_monotoneAcrossTheKink(uint256 target, uint64 y0, uint64 yT, uint64 yFull, uint256 utilA, uint256 utilB) external {
        StaticCurveYDM model = _deployInitialized(target, y0, yT, yFull);
        // Pin one point on each side of the kink
        vm.assume(utilA < target && target <= utilB && utilB <= WAD);

        assert(model.previewYieldShare(MarketState.PERPETUAL, utilA) <= model.previewYieldShare(MarketState.PERPETUAL, utilB));
    }

    /*//////////////////////////////////////////////////////////////////////
                        PLATEAU ABOVE FULL UTILIZATION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Any utilization above 100% is priced exactly as 100%: the curve plateaus at its full-utilization
     *         value instead of extrapolating, so a reported over-demand (demand beyond the pool's capacity)
     *         cannot leverage the premium past the configured maximum
     * @dev Economic why: utilization above WAD means the metric's numerator outgrew the pool, which the caller
     *      reports honestly rather than capping. The model owns the cap: paying beyond the full-utilization
     *      share would let a transiently manipulated or degenerate metric extract unbounded premium. Stated as
     *      exact equality of two production outputs, no arithmetic on the spec side
     */
    function check_staticCurve_utilizationAboveWADIsPlateau(uint256 target, uint64 y0, uint64 yT, uint64 yFull, uint256 utilization) external {
        StaticCurveYDM model = _deployInitialized(target, y0, yT, yFull);
        // Pin the clamp branch: strictly above 100%
        vm.assume(utilization > WAD);

        assert(model.previewYieldShare(MarketState.PERPETUAL, utilization) == model.previewYieldShare(MarketState.PERPETUAL, WAD));
    }

    /*//////////////////////////////////////////////////////////////////////
                    TOTALITY OVER THE WHOLE UTILIZATION RANGE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice An initialized curve never reverts for any uint256 utilization in either market state: the
     *         model is queried inside every accounting sync, so a revert here would brick the sync and with it
     *         every deposit, redemption, and premium payment in the market
     * @dev Independent derivation of why no arithmetic can fail: the utilization is clamped to WAD before any
     *      math, both stored slopes fit uint64, and slope * clampedDistance is below 2^64 * 2^60, far under
     *      the uint256 ceiling; the final addition caps below 2^65. The market state parameter is ignored by
     *      this static model, so both enum members are exercised explicitly
     */
    function check_staticCurve_initializedPreviewNeverReverts(uint256 target, uint64 y0, uint64 yT, uint64 yFull, uint256 utilization) external {
        StaticCurveYDM model = _deployInitialized(target, y0, yT, yFull);

        try model.previewYieldShare(MarketState.PERPETUAL, utilization) returns (uint256) {
            // Total in the perpetual state for the entire uint256 utilization range
        } catch {
            assert(false);
        }
        try model.previewYieldShare(MarketState.FIXED_TERM, utilization) returns (uint256) {
            // And identically total in the fixed-term state
        } catch {
            assert(false);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                        UNINITIALIZED MARKETS ALWAYS REVERT
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A market that never initialized its curve always reverts with the uninitialized error, for every
     *         utilization, both market states, and both entrypoints. The sentinel is sound: initialization
     *         requires a nonzero target-point share, so a zero stored target point can only mean uninitialized,
     *         and a wired-but-unconfigured market fails loudly instead of silently pricing a zero premium
     * @dev A silent zero here would let an accountant run premium syncs against a curve nobody configured,
     *      paying the pool nothing while reporting success. The target grid instance used carries a fresh
     *      storage mapping, so this caller's curve is the uint64 zero default
     */
    function check_staticCurve_uninitializedAlwaysRevertsUninitialized(uint256 utilization) external {
        StaticCurveYDM model = partitionModels[2];

        // Sentinel soundness: the never-initialized market's stored target point is zero
        (,, uint64 storedYT,) = model.accountantToCurve(address(this));
        assert(storedYT == 0);

        bytes32 expectedError = keccak256(abi.encodeWithSelector(IYDM.UNINITIALIZED_YDM.selector));
        try model.previewYieldShare(MarketState.PERPETUAL, utilization) returns (uint256) {
            assert(false);
        } catch (bytes memory err) {
            assert(keccak256(err) == expectedError);
        }
        try model.previewYieldShare(MarketState.FIXED_TERM, utilization) returns (uint256) {
            assert(false);
        } catch (bytes memory err) {
            assert(keccak256(err) == expectedError);
        }
        // The state-mutating entrypoint shares the same guard
        try model.yieldShare(MarketState.PERPETUAL, utilization) returns (uint256) {
            assert(false);
        } catch (bytes memory err) {
            assert(keccak256(err) == expectedError);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                    THE MUTATING ENTRYPOINT IS PURE PRICING
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The state-mutating yield share entrypoint is pure pricing on a static curve: it returns exactly
     *         what the view preview returns, its output is independent of the market state, and it writes
     *         nothing (the caller's stored curve, the only storage this model keeps, is bit-identical after
     *         the call, and a repeat preview reproduces the same output)
     * @dev Economic why: the accountant previews the yield share when quoting and commits it when syncing, so
     *      any daylight between the two, or any hidden state drift across calls, would make quoted and settled
     *      premiums diverge. The static model must also ignore the market state entirely, unlike the adaptive
     *      family, so the two entrypoints are compared across different state arguments deliberately
     */
    function check_staticYieldShare_isViewEquivalentAndWritesNothing(uint256 target, uint64 y0, uint64 yT, uint64 yFull, uint256 utilization) external {
        StaticCurveYDM model = _deployInitialized(target, y0, yT, yFull);

        // The caller's stored curve before the mutating call: the model's entire storage footprint for this market
        (uint64 a0, uint64 b0, uint64 c0, uint64 d0) = model.accountantToCurve(address(this));

        uint256 previewed = model.previewYieldShare(MarketState.PERPETUAL, utilization);
        // Mutating entrypoint, deliberately under the other market state: same output either way
        uint256 committed = model.yieldShare(MarketState.FIXED_TERM, utilization);
        assert(committed == previewed);

        // The stored curve is bit-identical: the mutating call wrote nothing
        (uint64 a1, uint64 b1, uint64 c1, uint64 d1) = model.accountantToCurve(address(this));
        assert(a0 == a1 && b0 == b1 && c0 == c1 && d0 == d1);

        // And a repeat preview reproduces the same output: no hidden state moved anywhere
        assert(model.previewYieldShare(MarketState.FIXED_TERM, utilization) == previewed);
    }
}
