// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { AttributionExposer } from "../mocks/AttributionExposer.sol";

/**
 * @title AttributionSymbolicSpec
 * @notice Native symbolic specs for the signed PnL attribution step of the tranche accounting sync
 *         (the accountant's internal pure helper that slices a pool's raw NAV delta pro-rata to a tranche's
 *         claim on the last checkpoint). The load-bearing properties: a zero delta, claim, or checkpoint NAV
 *         attributes nothing, every other attribution is the exactly floored pro-rata slice with the delta's
 *         sign preserved, splitting one claim into two loses at most one wei against the split side, a bigger
 *         claim never receives a smaller slice, the helper is total on the physical domain, and a delta no
 *         larger than the checkpoint can never attribute more than the claim itself, which is what keeps the
 *         downstream effective-NAV subtractions in the loss waterfall from underflowing
 * @dev Run with `forge test --symbolic --match-path test/symbolic/AttributionSymbolic.t.sol`. Functions
 *      prefixed check_ are discovered only under --symbolic. Domain: NAVs up to 1e30 wei (one trillion
 *      whole 18-decimal tokens, beyond any underwritable market) and deltas in [-1e30, 1e30]. Every expected
 *      value is derived independently: the floor as plain integer division (products cap at 1e60, far below
 *      2^256, so plain checked arithmetic is exact) and every bound stated on outputs, never by re-running
 *      the production mulDiv as its own expectation. All six checks verify with the default z3 profile
 */
contract AttributionSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound: 1e30 NAV wei
    uint256 internal constant MAX_NAV = 1e30;

    AttributionExposer internal exposer;

    function setUp() public {
        exposer = new AttributionExposer();
    }

    /*//////////////////////////////////////////////////////////////////////
                            ZERO-OPERAND BRANCH
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice A zero delta, a zero claim, or a zero last-checkpoint NAV attributes exactly nothing. An empty
     *         tranche can never be handed a share of another tranche's PnL, and a flat sync can never conjure
     *         a gain or a loss out of rounding
     */
    function check_attributionZeroOperandAttributesNothing(int256 delta, uint256 claim, uint256 lastRaw) external view {
        vm.assume(delta >= -int256(MAX_NAV) && delta <= int256(MAX_NAV));
        vm.assume(claim <= MAX_NAV && lastRaw <= MAX_NAV);
        // Pin the zero-operand short-circuit branch: at least one operand is zero
        vm.assume(delta == 0 || claim == 0 || lastRaw == 0);

        // Why this matters: the attribution feeds signed effective-NAV deltas straight into the waterfall, so a
        // nonzero slice here would move value between tranches on a sync where nothing happened or nobody had a claim
        int256 attributed = exposer.attribute(delta, claim, lastRaw);
        assert(attributed == 0);
    }

    /*//////////////////////////////////////////////////////////////////////
                        EXACT FLOORED PRO-RATA FORM
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The attributed slice is exactly floor(|delta| * claim / lastRaw) with the delta's sign re-applied:
     *         the magnitude floors toward zero on both signs (a loss is never over-attributed and a gain never
     *         rounds up), the sign always matches the delta, and because the claim never exceeds the checkpoint
     *         NAV the slice never exceeds the whole delta
     * @dev Expected floor is plain checked multiply and divide (|delta| * claim <= 1e60 fits uint256), not a
     *      re-run of the production mulDiv. The two padding inputs only push the input count past the engine's
     *      built-in arithmetic heuristic (which cannot conclude on division-shaped queries) so the query reaches
     *      the real SMT solver
     */
    function check_attributionIsFlooredProRataSliceWithSignPreserved(int256 delta, uint256 claim, uint256 lastRaw, uint256 p1, uint256 p2) external view {
        // A live checkpoint with a claim on part of it: 0 < claim <= lastRaw
        vm.assume(delta >= -int256(MAX_NAV) && delta <= int256(MAX_NAV) && delta != 0);
        vm.assume(1 <= lastRaw && lastRaw <= MAX_NAV);
        vm.assume(1 <= claim && claim <= lastRaw);
        vm.assume(p1 <= 3 && p2 <= 3);

        int256 attributed = exposer.attribute(delta, claim, lastRaw);

        // Why flooring toward zero on both signs: the leftover rounding wei must land in the complementary
        // tranche (the residual side of the waterfall), so the claimant's slice is always the conservative one
        uint256 absDelta = delta < 0 ? uint256(-delta) : uint256(delta);
        uint256 expectedMagnitude = (absDelta * claim) / lastRaw + p1 + p2 - p1 - p2;
        if (delta > 0) {
            assert(attributed == int256(expectedMagnitude));
            // claim <= lastRaw caps the slice at the whole delta: a tranche cannot be paid more gain than occurred
            assert(attributed <= delta);
        } else {
            assert(attributed == -int256(expectedMagnitude));
            // and cannot be charged more loss than occurred
            assert(attributed >= delta);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                        SPLIT-CLAIM FLOORING DRIFT
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Attributing one delta to two claims separately recovers the single-claim attribution of their sum
     *         to within one wei, and the flooring drift always shorts the split side: on a gain the two slices
     *         sum to at most the whole (never over-paying), on a loss they sum to at least the whole (never
     *         over-charging), so the complementary tranche silently absorbs at most one wei of dust
     * @dev Floor superadditivity stated purely on the production outputs, floor(a) + floor(b) <= floor(a+b)
     *      <= floor(a) + floor(b) + 1, with no spec-side division at all. The padding input routes the query
     *      past the engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_attributionSplitLosesAtMostOneWeiShortingTheSplitSide(int256 delta, uint256 claimA, uint256 claimB, uint256 lastRaw, uint256 p1) external view {
        // Two disjoint claims on one live checkpoint
        vm.assume(delta >= -int256(MAX_NAV) && delta <= int256(MAX_NAV) && delta != 0);
        vm.assume(1 <= lastRaw && lastRaw <= MAX_NAV);
        vm.assume(claimA <= lastRaw && claimB <= lastRaw - claimA);
        vm.assume(p1 <= 3);

        // Why this matters: the sync attributes the senior pool's delta to ST's claim and leaves the residual
        // to JT, so the split drift is exactly the wei-level value transfer between tranches per sync. Bounding
        // it at one wei, in the direction that shorts the claimant, is the conservation-dust guarantee
        int256 whole = exposer.attribute(delta, claimA + claimB, lastRaw) + int256(p1) - int256(p1);
        int256 splitSum = exposer.attribute(delta, claimA, lastRaw) + exposer.attribute(delta, claimB, lastRaw);

        if (delta > 0) {
            // On a gain the two floors can only under-pay the split side, by at most one wei combined
            assert(splitSum <= whole);
            assert(whole - splitSum <= 1);
        } else {
            // On a loss the two floors can only under-charge the split side, by at most one wei combined
            assert(splitSum >= whole);
            assert(splitSum - whole <= 1);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                            MONOTONICITY IN THE CLAIM
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice For a fixed delta on a fixed checkpoint, a larger claim never receives a smaller slice: on a gain
     *         the attribution is non-decreasing in the claim, and on a loss it is non-increasing (a larger claim
     *         absorbs at least as much of the loss). Growing a tranche's claim between checkpoints can therefore
     *         never shrink its share of the next gain nor shift its share of the next loss onto the other tranche
     * @dev Two mulDivs over the same denominator, monotone numerators. If z3 stalls, the product-form fallback
     *      is attrA * lastRaw <= |delta| * claimA <= |delta| * claimB < (attrB + 1) * lastRaw, stated on
     *      outputs. The padding input routes the query past the engine's built-in arithmetic heuristic to the
     *      real SMT solver
     */
    function check_attributionIsMonotoneInClaim(int256 delta, uint256 claimA, uint256 claimB, uint256 lastRaw, uint256 p1) external view {
        vm.assume(delta >= -int256(MAX_NAV) && delta <= int256(MAX_NAV) && delta != 0);
        vm.assume(1 <= lastRaw && lastRaw <= MAX_NAV);
        vm.assume(claimA <= claimB && claimB <= lastRaw);
        vm.assume(p1 <= 3);

        int256 attrA = exposer.attribute(delta, claimA, lastRaw) + int256(p1) - int256(p1);
        int256 attrB = exposer.attribute(delta, claimB, lastRaw);

        // Why this matters: monotonicity is the fairness ordering of the pro-rata split. Without it a tranche
        // could be paid less gain, or dodge loss, by holding a strictly bigger claim on the same pool, which
        // would invert the seniority economics of the waterfall
        if (delta > 0) {
            // A bigger claim on the same gain is paid at least as much
            assert(attrA <= attrB);
        } else {
            // A bigger claim on the same loss absorbs at least as much (both slices are negative)
            assert(attrA >= attrB);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                        TOTALITY ON THE PHYSICAL DOMAIN
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The attribution helper never reverts anywhere on the physical domain: any delta up to the NAV
     *         bound in either direction, any claim up to the checkpoint NAV, any checkpoint NAV up to the bound,
     *         zeros included. The attribution runs at the top of every P&L sync, so a revert here would brick
     *         the sync itself and with it every deposit, redemption, and premium payment in the market
     * @dev The one theoretical revert edge is negating int256.min inside the magnitude split, which this domain
     *      bounds away. It is also unreachable in production: the delta is always the difference of two NAV
     *      values, each of which passed a checked uint256-to-int256 conversion and is therefore below 2^255, so
     *      the difference is at least -(2^255 - 1) and int256.min is never formed. The mulDiv itself cannot
     *      revert since claim <= lastRaw keeps the quotient at or below |delta|, and lastRaw >= 1 on the branch
     *      where it divides. The padding inputs route the query past the engine's built-in arithmetic heuristic
     *      to the real SMT solver
     */
    function check_attributionNeverRevertsOnPhysicalDomain(int256 delta, uint256 claim, uint256 lastRaw, uint256 p1, uint256 p2) external view {
        vm.assume(delta >= -int256(MAX_NAV) && delta <= int256(MAX_NAV));
        vm.assume(lastRaw <= MAX_NAV);
        vm.assume(claim <= lastRaw);
        vm.assume(p1 <= 3 && p2 <= 3);

        try exposer.attribute(delta + int256(p1) - int256(p1), claim + p2 - p2, lastRaw) returns (int256) {
            // Total on the whole physical domain: every sync can always price its attribution
        } catch {
            assert(false);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                        MAGNITUDE CAPPED BY THE CLAIM
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice When the pool's delta magnitude does not exceed the last checkpoint NAV (a pool cannot lose more
     *         than it holds, and this sync's physical gain bound is the same), the attributed magnitude never
     *         exceeds the claim itself. This is the underflow shield for the loss waterfall: the loss charged
     *         against a tranche's claim is at most the claim, so subtracting it from the tranche's effective NAV
     *         can never underflow, and no sync can drive a tranche's books below zero
     * @dev Derivation, independent of the production path: attributed magnitude is the floor of
     *      |delta| * claim / lastRaw, and |delta| <= lastRaw makes the true quotient at most
     *      lastRaw * claim / lastRaw == claim, so the floor is at most claim. Tight at |delta| == lastRaw,
     *      where the slice equals the whole claim exactly. The padding inputs route the query past the
     *      engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_attributionNeverExceedsTheClaimWhenDeltaWithinCheckpoint(int256 delta, uint256 claim, uint256 lastRaw, uint256 p1, uint256 p2) external view {
        vm.assume(1 <= lastRaw && lastRaw <= MAX_NAV);
        vm.assume(1 <= claim && claim <= lastRaw);
        // The physical per-sync bound: the pool cannot move by more than the whole checkpoint NAV downward,
        // and the same magnitude bound is imposed on the gain side
        vm.assume(delta != 0 && delta >= -int256(lastRaw) && delta <= int256(lastRaw));
        vm.assume(p1 <= 3 && p2 <= 3);

        int256 attributed = exposer.attribute(delta, claim, lastRaw) + int256(p1 + p2) - int256(p1 + p2);
        uint256 attributedMagnitude = attributed < 0 ? uint256(-attributed) : uint256(attributed);

        // A full wipeout (delta == -lastRaw) charges exactly the claim and nothing more, so the checked
        // effective-NAV subtraction downstream lands exactly at zero instead of underflowing
        assert(attributedMagnitude <= claim);
    }
}
