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
 *      prefixed check_ are discovered only under --symbolic. The target utilization (the kink) is always a
 *      concrete deploy-time value here: a contract deployed with a symbolic constructor argument bakes a
 *      symbolic immutable into its runtime code, and the engine cannot execute calls into such code. Curve
 *      points and utilization stay fully symbolic. Curve-shape checks run on a model with an asymmetric 70%
 *      kink (both leg divisors are distinct and neither divides WAD evenly, so both stored slopes genuinely
 *      floor), and the initialization partition runs per concrete grid target so each leg's uint64 slope
 *      frontier is exercised on both sides
 * @dev Expected values are derived independently: every division-shaped expectation is either a plain checked
 *      multiply and divide (all products here are far below 2^256 since curve points fit uint64 and utilization
 *      is capped at WAD = 1e18) or a two-sided floor bracket stated on the production outputs, never a re-run of
 *      the production mulDiv chain as its own expectation. Padding inputs (assumed at most 3 and folded away as
 *      exact identities) only push division-shaped queries past the engine's built-in arithmetic heuristic,
 *      which cannot conclude on them, so the queries reach the real SMT solver
 */
contract StaticCurveYDMSymbolicSpec is Test {
    /// @dev WAD fixed-point unit, 1e18 == 100%
    uint256 internal constant WAD = 1e18;

    /// @dev The uint64 ceiling: a computed slope at or above this cannot be stored and makes initialization revert
    uint256 internal constant UINT64_CEILING = uint256(1) << 64;

    /**
     * @dev The concrete kink for every curve-shape check: 70%, asymmetric on purpose so the below-target
     *      divisor (0.7e18) and the above-target divisor (0.3e18) are distinct and neither divides WAD
     *      evenly, making both stored slopes genuinely floored rather than exact
     */
    uint256 internal constant SHAPE_TARGET = 0.7e18;

    /// @dev Concrete target utilization grid for the initialization partition: the extremes (1 wei and WAD - 1)
    ///      make each slope's uint64 frontier reachable, the mid targets keep both slopes always storable
    uint256[5] internal partitionTargets;

    /// @dev One model per grid target, deployed uninitialized so each check exercises its own initialization
    StaticCurveYDM[5] internal partitionModels;

    /// @dev A model constructed with the target utilization at exactly WAD (accepted by the constructor)
    StaticCurveYDM internal targetAtWadModel;

    /// @dev The model every curve-shape check initializes and queries, deployed with the 70% kink
    StaticCurveYDM internal shapeModel;

    function setUp() public {
        partitionTargets = [uint256(1), 5e16, 5e17, 9e17, WAD - 1];
        for (uint256 i; i < partitionTargets.length; ++i) {
            partitionModels[i] = new StaticCurveYDM(partitionTargets[i]);
        }
        targetAtWadModel = new StaticCurveYDM(WAD);
        shapeModel = new StaticCurveYDM(SHAPE_TARGET);
    }

    /*//////////////////////////////////////////////////////////////////////
                            SHARED INITIALIZATION HELPER
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Initializes the shape model's curve for this test contract's market, constraining the inputs to
     *      exactly the constructible domain at the 70% kink: a monotone non-decreasing curve capped at 100%
     *      with a nonzero target point. At this kink every such curve fits both uint64 slope slots, so no
     *      further constraint is needed: each leg's rise is at most WAD, and WAD * WAD = 1e36 is below both
     *      2^64 * 0.7e18 and 2^64 * 0.3e18 (about 1.29e37 and 5.53e36). The padding input is folded away as
     *      an exact identity and only routes the initialization's division-shaped queries past the engine's
     *      built-in arithmetic heuristic to the real SMT solver
     */
    function _initShapeCurve(uint64 y0, uint64 yT, uint64 yFull, uint256 p1) internal {
        vm.assume(p1 <= 3);
        vm.assume(y0 <= yT && yT <= yFull && uint256(yFull) <= WAD && yT > 0);
        // This initialization must succeed on the whole assumed domain, so a revert here would itself be a
        // counterexample to the acceptance frontier derived above
        shapeModel.initializeYDMForMarket(y0, uint64(uint256(yT) + p1 - p1), yFull);
    }

    /*//////////////////////////////////////////////////////////////////////
                        CONSTRUCTOR ACCEPTANCE PARTITION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The constructor accepts exactly the target utilizations in (0, WAD]: anything in that window
     *         deploys, zero and anything above 100% revert. The concrete complements pin the two halves the
     *         symbolic partition cannot see into: an accepted target is stamped into the immutable verbatim
     *         (no scaling, no clamping) and a rejection is the model's own configuration error, not a panic
     * @dev Economic why: the target is the curve's kink, the utilization at which the premium's slope steepens
     *      to pull capital in. A zero target would put the kink at the origin and leave the below-target leg's
     *      slope dividing by zero, and a target above 100% would place the kink beyond the model's own
     *      utilization cap where it could never bind, so both are rejected at deployment rather than left to
     *      brick the market later. The symbolic half only observes deploy-or-revert: a contract deployed with
     *      a symbolic constructor argument carries a symbolic immutable in its code, which the engine cannot
     *      execute calls into, so the stamped-verbatim and error-selector facts are asserted on concrete
     *      deployments instead (the grid extremes, the WAD instance, and both rejection boundaries)
     */
    function check_ydmConstructor_acceptsExactlyTargetInZeroToWAD(uint256 target) external {
        try new StaticCurveYDM(target) returns (StaticCurveYDM) {
            // The acceptance window, derived from what makes the kink meaningful: strictly positive, at most 100%
            assert(1 <= target && target <= WAD);
        } catch {
            assert(target == 0 || target > WAD);
        }

        // Concrete complement one: the immutable is the exact supplied target across the whole deployed grid
        assert(partitionModels[0].TARGET_UTILIZATION_WAD() == 1);
        assert(partitionModels[2].TARGET_UTILIZATION_WAD() == 5e17);
        assert(partitionModels[4].TARGET_UTILIZATION_WAD() == WAD - 1);
        assert(targetAtWadModel.TARGET_UTILIZATION_WAD() == WAD);

        // Concrete complement two: both rejection boundaries revert with the model's own configuration error
        bytes32 expectedError = keccak256(abi.encodeWithSelector(IYDM.INVALID_YDM_INITIALIZATION.selector));
        try new StaticCurveYDM(0) returns (StaticCurveYDM) {
            assert(false);
        } catch (bytes memory err) {
            assert(keccak256(err) == expectedError);
        }
        try new StaticCurveYDM(WAD + 1) returns (StaticCurveYDM) {
            assert(false);
        } catch (bytes memory err) {
            assert(keccak256(err) == expectedError);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                        INITIALIZATION ACCEPTANCE PARTITION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice At a 1-wei target, market initialization succeeds for exactly the monotone curves whose
     *         below-target rise is at most 18 wei: the below leg's slope floor((yT - y0) * WAD / 1) must fit
     *         uint64 storage, so (yT - y0) * WAD < 2^64, an undocumented configuration constraint that makes
     *         a near-origin kink reject almost every rising curve. The above leg's slope always fits here,
     *         since its rise is at most WAD and WAD * WAD is far below 2^64 * (WAD - 1)
     * @dev Economic why: the monotonicity guard enforces the model's incentive direction (scarcer service is
     *      never paid less), the nonzero target point is the initialization sentinel (a zero would make the
     *      market read as uninitialized forever), and the slope frontier is real storage truncation, derived
     *      here as a plain product on both sides rather than by re-running the slope division. The padding
     *      input is folded away as an exact identity and only routes the division-shaped queries past the
     *      engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_staticInit_oneWeiTargetAcceptsExactlyBelowLegRiseUnderUint64Frontier(uint64 y0, uint64 yT, uint64 yFull, uint256 p1) external {
        vm.assume(p1 <= 3);

        // The independently derived acceptance condition: monotone, capped, nonzero sentinel, below slope storable
        bool expectSuccess = y0 <= yT && yT <= yFull && uint256(yFull) + p1 - p1 <= WAD && yT > 0;
        if (expectSuccess) {
            expectSuccess = uint256(yT - y0) * WAD < UINT64_CEILING;
        }

        try partitionModels[0].initializeYDMForMarket(y0, yT, yFull) {
            assert(expectSuccess);
        } catch {
            assert(!expectSuccess);
        }
    }

    /**
     * @notice At a 5% target, market initialization succeeds for exactly the monotone curves whose
     *         below-target rise scaled by WAD stays below 2^64 * 5e16: a rise past roughly 0.92 WAD over the
     *         short run to the kink computes a below slope too wide for its uint64 slot and reverts. The
     *         above leg's slope always fits here (its run is 95% of WAD)
     * @dev The frontier is derived as a plain product on both sides, never by re-running the slope division.
     *      The padding input is folded away as an exact identity and only routes the division-shaped queries
     *      past the engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_staticInit_fivePercentTargetAcceptsExactlyBelowLegSlopeUnderUint64Frontier(uint64 y0, uint64 yT, uint64 yFull, uint256 p1) external {
        vm.assume(p1 <= 3);

        bool expectSuccess = y0 <= yT && yT <= yFull && uint256(yFull) + p1 - p1 <= WAD && yT > 0;
        if (expectSuccess) {
            expectSuccess = uint256(yT - y0) * WAD < UINT64_CEILING * 5e16;
        }

        try partitionModels[1].initializeYDMForMarket(y0, yT, yFull) {
            assert(expectSuccess);
        } catch {
            assert(!expectSuccess);
        }
    }

    /**
     * @notice At the 50% target, market initialization succeeds for exactly the monotone curves capped at
     *         100% with a nonzero target point: both slope frontiers are unreachable here, since each leg's
     *         rise is at most WAD and WAD * WAD = 1e36 is below 2^64 * 5e17 (about 9.2e36) on both sides, so
     *         the slope storage constraint never binds and the acceptance condition is purely the curve shape
     * @dev The padding input is folded away as an exact identity and only routes the division-shaped queries
     *      past the engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_staticInit_midTargetAcceptsExactlyMonotoneCappedCurves(uint64 y0, uint64 yT, uint64 yFull, uint256 p1) external {
        vm.assume(p1 <= 3);

        bool expectSuccess = y0 <= yT && yT <= yFull && uint256(yFull) + p1 - p1 <= WAD && yT > 0;

        try partitionModels[2].initializeYDMForMarket(y0, yT, yFull) {
            assert(expectSuccess);
        } catch {
            assert(!expectSuccess);
        }
    }

    /**
     * @notice At the 90% target, market initialization succeeds for exactly the monotone curves capped at
     *         100% with a nonzero target point: even the short 10% above-target run keeps every slope
     *         storable, since the above rise is at most WAD and WAD * WAD = 1e36 is below 2^64 * 1e17
     *         (about 1.8e36), so neither uint64 frontier binds
     * @dev The padding input is folded away as an exact identity and only routes the division-shaped queries
     *      past the engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_staticInit_ninetyPercentTargetAcceptsExactlyMonotoneCappedCurves(uint64 y0, uint64 yT, uint64 yFull, uint256 p1) external {
        vm.assume(p1 <= 3);

        bool expectSuccess = y0 <= yT && yT <= yFull && uint256(yFull) + p1 - p1 <= WAD && yT > 0;

        try partitionModels[3].initializeYDMForMarket(y0, yT, yFull) {
            assert(expectSuccess);
        } catch {
            assert(!expectSuccess);
        }
    }

    /**
     * @notice At a target of WAD - 1, market initialization succeeds for exactly the monotone curves whose
     *         above-target rise is at most 18 wei: the above leg's run to full utilization is a single wei,
     *         so its slope floor((yFull - yT) * WAD / 1) must satisfy (yFull - yT) * WAD < 2^64 to fit uint64
     *         storage, the mirror of the 1-wei-target frontier on the other leg. The below leg always fits
     * @dev The frontier is derived as a plain product on both sides, never by re-running the slope division.
     *      The padding input is folded away as an exact identity and only routes the division-shaped queries
     *      past the engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_staticInit_nearWadTargetAcceptsExactlyAboveLegRiseUnderUint64Frontier(uint64 y0, uint64 yT, uint64 yFull, uint256 p1) external {
        vm.assume(p1 <= 3);

        bool expectSuccess = y0 <= yT && yT <= yFull && uint256(yFull) + p1 - p1 <= WAD && yT > 0;
        if (expectSuccess) {
            expectSuccess = uint256(yFull - yT) * WAD < UINT64_CEILING;
        }

        try partitionModels[4].initializeYDMForMarket(y0, yT, yFull) {
            assert(expectSuccess);
        } catch {
            assert(!expectSuccess);
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
     *      This check re-pins the already-adjudicated concrete divergence across the entire valid input space.
     *      The padding input is folded away as an exact identity and only routes the division-shaped queries
     *      past the engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_staticInit_targetAtWADAlwaysPanics(uint64 y0, uint64 yT, uint64 yFull, uint256 p1) external {
        vm.assume(p1 <= 3);
        // Every otherwise-valid curve: monotone, capped at 100%, nonzero target point
        vm.assume(y0 <= yT && yT <= yFull && uint256(yFull) <= WAD && yT > 0);

        try targetAtWadModel.initializeYDMForMarket(y0, uint64(uint256(yT) + p1 - p1), yFull) {
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
    function check_staticCurve_zeroUtilizationReproducesShareAtZeroExactly(uint64 y0, uint64 yT, uint64 yFull, uint256 p1) external {
        _initShapeCurve(y0, yT, yFull, p1);

        // Zero is always strictly below the (positive) kink, so this exercises the below-target leg's intercept
        assert(shapeModel.previewYieldShare(MarketState.PERPETUAL, 0) == y0);
    }

    /**
     * @notice At exactly the target utilization the curve reproduces the configured target yield share
     *         exactly: the at-or-above-target leg anchors at the kink with a vanishing slope term
     * @dev Economic why: the target point is the calibration anchor issuers actually reason about (the premium
     *      at the utilization the market is steered toward), so it must be reproduced to the wei even though
     *      both stored slopes are floored. The kink belongs to the upper leg, whose distance term is zero there
     */
    function check_staticCurve_targetUtilizationReproducesShareAtTargetExactly(uint64 y0, uint64 yT, uint64 yFull, uint256 p1) external {
        _initShapeCurve(y0, yT, yFull, p1);

        // Utilization == kink takes the at-or-above-target leg, whose scaled distance from the kink is zero
        assert(shapeModel.previewYieldShare(MarketState.PERPETUAL, SHAPE_TARGET) == yT);
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
    function check_staticCurve_fullUtilizationReproducesShareAtFullWithinOneWei(uint64 y0, uint64 yT, uint64 yFull, uint256 p1) external {
        _initShapeCurve(y0, yT, yFull, p1);

        uint256 atFull = shapeModel.previewYieldShare(MarketState.PERPETUAL, WAD);
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
    function check_staticCurve_belowTargetLegMeetsKinkWithinOneWei(uint64 y0, uint64 yT, uint64 yFull, uint256 p1) external {
        _initShapeCurve(y0, yT, yFull, p1);

        // The stored below-target slope, read back from the model's storage for this market
        (, uint64 slopeLt,,) = shapeModel.accountantToCurve(address(this));

        // The below-target leg evaluated at the kink itself (production only evaluates it strictly below)
        uint256 extrapolated = uint256(slopeLt) * SHAPE_TARGET / WAD + y0;
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
    function check_staticCurve_belowTargetOutputStaysBetweenZeroAndTargetShares(uint64 y0, uint64 yT, uint64 yFull, uint256 utilization, uint256 p1) external {
        _initShapeCurve(y0, yT, yFull, p1);
        // Pin the below-target leg
        vm.assume(utilization < SHAPE_TARGET);

        uint256 share = shapeModel.previewYieldShare(MarketState.PERPETUAL, utilization);
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
    function check_staticCurve_aboveTargetOutputStaysBetweenTargetAndFullShares(uint64 y0, uint64 yT, uint64 yFull, uint256 utilization, uint256 p1) external {
        _initShapeCurve(y0, yT, yFull, p1);
        // Pin the at-or-above-target leg; the utilization is otherwise unbounded to cover the clamp
        vm.assume(utilization >= SHAPE_TARGET);

        uint256 share = shapeModel.previewYieldShare(MarketState.PERPETUAL, utilization);
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
    function check_staticCurve_monotoneWhenBothUtilizationsBelowTarget(uint64 y0, uint64 yT, uint64 yFull, uint256 utilA, uint256 utilB, uint256 p1) external {
        _initShapeCurve(y0, yT, yFull, p1);
        // Pin both points inside the below-target leg, ordered
        vm.assume(utilA <= utilB && utilB < SHAPE_TARGET);

        assert(shapeModel.previewYieldShare(MarketState.PERPETUAL, utilA) <= shapeModel.previewYieldShare(MarketState.PERPETUAL, utilB));
    }

    /**
     * @notice Within the at-or-above-target leg the yield share is monotone non-decreasing in utilization:
     *         past the kink the steeper leg keeps paying weakly more as the service saturates
     * @dev Both outputs floor the same slope against ordered distances from the kink. The leg is pinned up to
     *      WAD, inputs beyond that are the plateau property, proven separately
     */
    function check_staticCurve_monotoneWhenBothUtilizationsAtOrAboveTarget(uint64 y0, uint64 yT, uint64 yFull, uint256 utilA, uint256 utilB, uint256 p1) external {
        _initShapeCurve(y0, yT, yFull, p1);
        // Pin both points inside the at-or-above-target leg, ordered, up to the clamp boundary
        vm.assume(SHAPE_TARGET <= utilA && utilA <= utilB && utilB <= WAD);

        assert(shapeModel.previewYieldShare(MarketState.PERPETUAL, utilA) <= shapeModel.previewYieldShare(MarketState.PERPETUAL, utilB));
    }

    /**
     * @notice Across the kink the yield share is monotone non-decreasing: any below-target utilization is paid
     *         at most any at-or-above-target utilization, so crossing the target can never lower the premium
     * @dev Independent derivation: the below-target output is at most yT (its slope term is capped by the
     *      slope's floor bracket, as in the per-leg bound above) and the at-or-above-target output is at least
     *      yT (its slope term is non-negative), so the kink value separates the two legs. Both halves of that
     *      separation are asserted explicitly before the comparison, keeping each solver query a single-leg
     *      bound instead of one four-term inequality
     */
    function check_staticCurve_monotoneAcrossTheKink(uint64 y0, uint64 yT, uint64 yFull, uint256 utilA, uint256 utilB, uint256 p1) external {
        _initShapeCurve(y0, yT, yFull, p1);
        // Pin one point on each side of the kink
        vm.assume(utilA < SHAPE_TARGET && SHAPE_TARGET <= utilB && utilB <= WAD);

        uint256 shareBelow = shapeModel.previewYieldShare(MarketState.PERPETUAL, utilA);
        uint256 shareAbove = shapeModel.previewYieldShare(MarketState.PERPETUAL, utilB);
        // The kink value separates the legs: below never exceeds it, above never undershoots it
        assert(shareBelow <= yT);
        assert(shareAbove >= yT);
        assert(shareBelow <= shareAbove);
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
    function check_staticCurve_utilizationAboveWADIsPlateau(uint64 y0, uint64 yT, uint64 yFull, uint256 utilization, uint256 p1) external {
        _initShapeCurve(y0, yT, yFull, p1);
        // Pin the clamp branch: strictly above 100%
        vm.assume(utilization > WAD);

        assert(shapeModel.previewYieldShare(MarketState.PERPETUAL, utilization) == shapeModel.previewYieldShare(MarketState.PERPETUAL, WAD));
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
    function check_staticCurve_initializedPreviewNeverReverts(uint64 y0, uint64 yT, uint64 yFull, uint256 utilization, uint256 p1) external {
        _initShapeCurve(y0, yT, yFull, p1);

        try shapeModel.previewYieldShare(MarketState.PERPETUAL, utilization) returns (uint256) {
            // Total in the perpetual state for the entire uint256 utilization range
        } catch {
            assert(false);
        }
        try shapeModel.previewYieldShare(MarketState.FIXED_TERM, utilization) returns (uint256) {
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
    function check_staticYieldShare_isViewEquivalentAndWritesNothing(uint64 y0, uint64 yT, uint64 yFull, uint256 utilization, uint256 p1) external {
        _initShapeCurve(y0, yT, yFull, p1);

        // The caller's stored curve before the mutating call: the model's entire storage footprint for this market
        (uint64 a0, uint64 b0, uint64 c0, uint64 d0) = shapeModel.accountantToCurve(address(this));

        uint256 previewed = shapeModel.previewYieldShare(MarketState.PERPETUAL, utilization);
        // Mutating entrypoint, deliberately under the other market state: same output either way
        uint256 committed = shapeModel.yieldShare(MarketState.FIXED_TERM, utilization);
        assert(committed == previewed);

        // The stored curve is bit-identical: the mutating call wrote nothing
        (uint64 a1, uint64 b1, uint64 c1, uint64 d1) = shapeModel.accountantToCurve(address(this));
        assert(a0 == a1 && b0 == b1 && c0 == c1 && d0 == d1);

        // And a repeat preview reproduces the same output: no hidden state moved anywhere
        assert(shapeModel.previewYieldShare(MarketState.FIXED_TERM, utilization) == previewed);
    }
}
