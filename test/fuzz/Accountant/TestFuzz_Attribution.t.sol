// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { AttributionExposer } from "../../mocks/AttributionExposer.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title TestFuzz_Attribution_Accountant
 * @notice Fuzz properties for the sync's PnL attribution primitive: a signed raw-NAV move scaled onto a
 *         tranche's claim on that raw NAV, floored on the magnitude, sign-preserving, and additive across a
 *         claim and its complement up to one wei of flooring dust
 * @dev Every expected value is recomputed inline or through the independent RoycoTestMath mirror, never
 *      through a second call of the function under test
 */
contract TestFuzz_Attribution_Accountant is Test {
    /// @notice Suite-wide NAV ceiling for fuzzed inputs
    uint256 internal constant MAX_NAV = 1e30;

    AttributionExposer internal exposer;

    function setUp() public {
        exposer = new AttributionExposer();
    }

    /**
     * Scenario: one tranche holds a claim on a raw NAV pool and the pool moves by a signed delta since the
     * last checkpoint. The sync must hand that tranche exactly the floored pro-rata slice of the move — no
     * more (which would conjure NAV), no less than the floor (which would leak it), and never in the opposite
     * direction. This primitive is what splits every senior/junior PnL, so its rounding direction decides who
     * absorbs the attribution dust.
     *
     * Expected magnitude, recomputed inline: |attributed| = floor(|delta| * claim / lastRaw)
     */
    function testFuzz_Attribution_FlooredProRataMagnitudeWithDeltaSign(int256 _delta, uint256 _claim, uint256 _lastRaw) public view {
        _lastRaw = bound(_lastRaw, 0, MAX_NAV); // full NAV range incl. 0, the empty-pool edge that attributes nothing
        _claim = bound(_claim, 0, _lastRaw); // a claim can never exceed the raw NAV it is measured against
        _delta = bound(_delta, -int256(MAX_NAV), int256(MAX_NAV)); // signed move across the full NAV range incl. 0

        int256 attributed = exposer.attribute(_delta, _claim, _lastRaw);

        // Production equals the independent mirror over the entire input space. The mirror's division is safe
        // here because claim <= lastRaw forces claim == 0 whenever lastRaw == 0, hitting its zero early-out
        assertEq(attributed, RoycoTestMath.attributeDeltaToClaimOnRawNAV(_delta, _claim, _lastRaw), "attribution: production == independent mirror");

        if (_delta == 0 || _claim == 0 || _lastRaw == 0) {
            assertEq(attributed, 0, "attribution: any zero operand attributes nothing");
        } else {
            uint256 absDelta = _delta < 0 ? uint256(-_delta) : uint256(_delta);
            uint256 absAttributed = attributed < 0 ? uint256(-attributed) : uint256(attributed);
            // Magnitude conjunct: the floored pro-rata slice, recomputed inline
            assertEq(absAttributed, Math.mulDiv(absDelta, _claim, _lastRaw), "attribution: |attributed| == floor(|delta| * claim / lastRaw)");
            // Sign conjunct: the attributed move never flips direction
            if (_delta < 0) {
                assertLe(attributed, 0, "attribution: a loss never attributes as a gain");
            } else {
                assertGe(attributed, 0, "attribution: a gain never attributes as a loss");
            }
            // The slice never exceeds the whole move (claim <= lastRaw makes the scale factor at most 1)
            assertLe(absAttributed, absDelta, "attribution: the slice never exceeds the whole move");
        }
    }

    /**
     * Scenario: a raw NAV pool is fully decomposed into one tranche's claim and its complement — exactly how
     * the sync splits a senior raw pool between the senior self-claim and the junior cross-claim. Attributing
     * the same move to both pieces must reassemble the whole move except for at most one wei lost toward zero
     * (two independent floors), because the sync assigns one side by attribution and the other as the exact
     * residual: if the floored halves could drift further apart, the residual side would silently absorb more
     * than rounding dust.
     *
     * Expected reassembly, derived inline: floor(x*c/L) + floor(x*(L-c)/L) is x or x-1 in magnitude, since the
     * two fractional parts sum to either 0 or exactly 1
     */
    function testFuzz_Attribution_ComplementarySplitReassemblesWithinOneWei(int256 _delta, uint256 _claim, uint256 _lastRaw) public view {
        _lastRaw = bound(_lastRaw, 1, MAX_NAV); // a positive pool so the claim/complement split is meaningful
        _claim = bound(_claim, 0, _lastRaw); // full split range incl. both trivial ends
        _delta = bound(_delta, -int256(MAX_NAV), int256(MAX_NAV)); // signed move across the full NAV range incl. 0

        int256 toClaim = exposer.attribute(_delta, _claim, _lastRaw);
        int256 toComplement = exposer.attribute(_delta, _lastRaw - _claim, _lastRaw);
        int256 reassembled = toClaim + toComplement;

        uint256 absDelta = _delta < 0 ? uint256(-_delta) : uint256(_delta);
        uint256 absReassembled = reassembled < 0 ? uint256(-reassembled) : uint256(reassembled);

        // The reassembled move keeps the delta's direction
        if (_delta < 0) {
            assertLe(reassembled, 0, "split: a reassembled loss stays a loss");
        } else {
            assertGe(reassembled, 0, "split: a reassembled gain stays a gain");
        }
        // The two floored halves never exceed the whole move (nothing is conjured)
        assertLe(absReassembled, absDelta, "split: the halves never exceed the whole");
        // And lose at most one wei of flooring dust toward zero (nothing beyond rounding leaks)
        assertLe(absDelta - absReassembled, 1, "split: at most one wei of flooring dust");
        // The trivial splits (whole pool on one side) are exact by construction
        if (_claim == 0 || _claim == _lastRaw) {
            assertEq(reassembled, _delta, "split: a whole-pool claim reassembles exactly");
        }
    }
}
