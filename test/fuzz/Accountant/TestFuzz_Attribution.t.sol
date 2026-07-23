// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title TestFuzz_Attribution_Accountant
 * @notice Fuzz properties for the sync's PnL attribution primitive: a signed collateral-NAV move scaled
 *         onto a tranche's claim on that collateral NAV, floored on the magnitude, sign-preserving, and
 *         exact under the residual split the sync uses (ST by attribution, JT as the exact remainder)
 * @dev The function under test is the RoycoTestMath mirror primitive: production inlined the split into the
 *      sync's attribution step, so production parity is asserted field-for-field at the sync level in
 *      TestFuzz_SyncTrancheAccounting and this suite certifies the mirror primitive's own properties, with
 *      every expected value recomputed inline, never through a second call of the function under test
 */
contract TestFuzz_Attribution_Accountant is Test {
    /// @notice Suite-wide NAV ceiling for fuzzed inputs
    uint256 internal constant MAX_NAV = 1e30;

    /**
     * Scenario: one tranche holds a claim on the collateral NAV and the pool moves by a signed delta since
     * the last checkpoint. The sync must hand that tranche exactly the floored pro-rata slice of the move
     * - no more (which would conjure NAV), no less than the floor (which would leak it), and never in the
     * opposite direction. This primitive is what splits every collateral PnL between senior and junior, so
     * its rounding direction decides who absorbs the attribution dust.
     *
     * Expected magnitude, recomputed inline: |attributed| = floor(|delta| * claim / lastCollateral)
     */
    function testFuzz_Attribution_FlooredProRataMagnitudeWithDeltaSign(int256 _delta, uint256 _claim, uint256 _lastCollateral) public view {
        _lastCollateral = bound(_lastCollateral, 0, MAX_NAV); // full NAV range incl. 0, the empty-pool edge that attributes nothing
        _claim = bound(_claim, 0, _lastCollateral); // a claim can never exceed the collateral NAV it is measured against
        _delta = bound(_delta, -int256(MAX_NAV), int256(MAX_NAV)); // signed move across the full NAV range incl. 0

        int256 attributed = RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(_delta, _claim, _lastCollateral);

        if (_delta == 0 || _claim == 0 || _lastCollateral == 0) {
            assertEq(attributed, 0, "attribution: any zero operand attributes nothing");
        } else {
            uint256 absDelta = _delta < 0 ? uint256(-_delta) : uint256(_delta);
            uint256 absAttributed = attributed < 0 ? uint256(-attributed) : uint256(attributed);
            // Magnitude conjunct: the floored pro-rata slice, recomputed inline
            assertEq(absAttributed, Math.mulDiv(absDelta, _claim, _lastCollateral), "attribution: |attributed| == floor(|delta| * claim / lastCollateral)");
            // Sign conjunct: the attributed move never flips direction
            if (_delta < 0) {
                assertLe(attributed, 0, "attribution: a loss never attributes as a gain");
            } else {
                assertGe(attributed, 0, "attribution: a gain never attributes as a loss");
            }
            // The slice never exceeds the whole move (claim <= lastCollateral makes the scale factor at most 1)
            assertLe(absAttributed, absDelta, "attribution: the slice never exceeds the whole move");
        }
    }

    /**
     * Scenario: the sync splits one collateral move exactly as production does - the senior slice by
     * attribution against its claim, the junior slice as the exact residual delta - toClaim. The split must
     * conserve the whole move to the wei (JT absorbs every unit the senior floor drops), keep the delta's
     * direction on both sides, and hand the residual side no more than one wei above its own pro-rata floor
     * - the flooring drift is rounding dust, never a transfer.
     *
     * Expected residual, derived inline: |residual| = |delta| - floor(|delta| * claim / L), which is
     * floor(|delta| * (L - claim) / L) plus the fractional carry of 0 or exactly 1
     */
    function testFuzz_Attribution_ResidualSplitConservesExactlyAndDriftIsOneWei(int256 _delta, uint256 _claim, uint256 _lastCollateral) public view {
        _lastCollateral = bound(_lastCollateral, 1, MAX_NAV); // a positive pool so the claim/residual split is meaningful
        _claim = bound(_claim, 0, _lastCollateral); // full split range incl. both trivial ends
        _delta = bound(_delta, -int256(MAX_NAV), int256(MAX_NAV)); // signed move across the full NAV range incl. 0

        int256 toClaim = RoycoTestMath.attributeDeltaToClaimOnCollateralNAV(_delta, _claim, _lastCollateral);
        int256 residual = _delta - toClaim;

        // Wei-exact conservation is structural under the residual split: the two sides always reassemble the whole move
        assertEq(toClaim + residual, _delta, "split: the claim slice and the residual reassemble the move exactly");

        uint256 absDelta = _delta < 0 ? uint256(-_delta) : uint256(_delta);
        uint256 absResidual = residual < 0 ? uint256(-residual) : uint256(residual);

        // The residual keeps the delta's direction (the floored claim slice never exceeds the whole move)
        if (_delta < 0) {
            assertLe(residual, 0, "split: the residual of a loss stays a loss");
        } else {
            assertGe(residual, 0, "split: the residual of a gain stays a gain");
        }
        // The residual never exceeds the whole move (nothing is conjured on the junior side)
        assertLe(absResidual, absDelta, "split: the residual never exceeds the whole move");
        // JT absorption bound: the residual is at least the junior pro-rata floor and at most one wei above it,
        // so the flooring drift the residual side absorbs is bounded by a single wei
        uint256 jtFloor = Math.mulDiv(absDelta, _lastCollateral - _claim, _lastCollateral);
        assertGe(absResidual, jtFloor, "split: the residual is never below the junior pro-rata floor");
        assertLe(absResidual - jtFloor, 1, "split: the residual exceeds the junior floor by at most one wei");
        // The trivial splits (whole pool on one side) are exact by construction
        if (_claim == 0) {
            assertEq(residual, _delta, "split: a zero claim routes the whole move to the residual");
        } else if (_claim == _lastCollateral) {
            assertEq(toClaim, _delta, "split: a whole-pool claim takes the whole move");
        }
    }
}
