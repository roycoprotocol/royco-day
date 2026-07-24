// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title TestFuzz_Attribution_Accountant
 * @notice Fuzz properties for the sync's gain attribution primitive: a collateral-NAV gain scaled onto a
 *         tranche's claim on that collateral NAV, floored, and exact under the residual split the sync uses
 *         (ST by attribution, JT as the exact remainder)
 * @dev The function under test is the RoycoTestMath mirror primitive: production inlined the split into the
 *      sync's residual-gain step (a loss is absorbed junior-first and never splits), so production parity is
 *      asserted field-for-field at the sync level in TestFuzz_SyncTrancheAccounting and this suite certifies
 *      the mirror primitive's own properties, with every expected value recomputed inline, never through a
 *      second call of the function under test
 */
contract TestFuzz_Attribution_Accountant is Test {
    /// @notice Suite-wide NAV ceiling for fuzzed inputs
    uint256 internal constant MAX_NAV = 1e30;

    /**
     * Scenario: one tranche holds a claim on the collateral NAV and the pool gains since the last checkpoint.
     * The sync must hand that tranche exactly the floored pro-rata slice of the gain - no more (which would
     * conjure NAV), no less than the floor (which would leak it). This primitive is what splits every residual
     * collateral gain between senior and junior, so its rounding direction decides who absorbs the
     * attribution dust.
     *
     * Expected value, recomputed inline: attributed = floor(gain * claim / lastCollateral)
     */
    function testFuzz_Attribution_FlooredProRataSlice(uint256 _gain, uint256 _claim, uint256 _lastCollateral) public view {
        _lastCollateral = bound(_lastCollateral, 0, MAX_NAV); // full NAV range incl. 0, the empty-pool edge that attributes nothing
        _claim = bound(_claim, 0, _lastCollateral); // a claim can never exceed the collateral NAV it is measured against
        _gain = bound(_gain, 0, MAX_NAV); // gain across the full NAV range incl. 0

        uint256 attributed = RoycoTestMath.attributeGainToClaimOnCollateralNAV(_gain, _claim, _lastCollateral);

        if (_gain == 0 || _claim == 0 || _lastCollateral == 0) {
            assertEq(attributed, 0, "attribution: any zero operand attributes nothing");
        } else {
            // The floored pro-rata slice, recomputed inline
            assertEq(attributed, Math.mulDiv(_gain, _claim, _lastCollateral), "attribution: attributed == floor(gain * claim / lastCollateral)");
            // The slice never exceeds the whole gain (claim <= lastCollateral makes the scale factor at most 1)
            assertLe(attributed, _gain, "attribution: the slice never exceeds the whole gain");
        }
    }

    /**
     * Scenario: the sync splits one collateral gain exactly as production does - the senior slice by
     * attribution against its claim, the junior slice as the exact residual gain - toClaim. The split must
     * conserve the whole gain to the wei (JT absorbs every unit the senior floor drops) and hand the residual
     * side no more than one wei above its own pro-rata floor - the flooring drift is rounding dust, never a
     * transfer.
     *
     * Expected residual, derived inline: residual = gain - floor(gain * claim / L), which is
     * floor(gain * (L - claim) / L) plus the fractional carry of 0 or exactly 1
     */
    function testFuzz_Attribution_ResidualSplitConservesExactlyAndDriftIsOneWei(uint256 _gain, uint256 _claim, uint256 _lastCollateral) public view {
        _lastCollateral = bound(_lastCollateral, 1, MAX_NAV); // a positive pool so the claim/residual split is meaningful
        _claim = bound(_claim, 0, _lastCollateral); // full split range incl. both trivial ends
        _gain = bound(_gain, 0, MAX_NAV); // gain across the full NAV range incl. 0

        uint256 toClaim = RoycoTestMath.attributeGainToClaimOnCollateralNAV(_gain, _claim, _lastCollateral);
        uint256 residual = _gain - toClaim;

        // Wei-exact conservation is structural under the residual split: the two sides always reassemble the whole gain
        assertEq(toClaim + residual, _gain, "split: the claim slice and the residual reassemble the gain exactly");
        // The residual never exceeds the whole gain (nothing is conjured on the junior side)
        assertLe(residual, _gain, "split: the residual never exceeds the whole gain");
        // JT absorption bound: the residual is at least the junior pro-rata floor and at most one wei above it,
        // so the flooring drift the residual side absorbs is bounded by a single wei
        uint256 jtFloor = Math.mulDiv(_gain, _lastCollateral - _claim, _lastCollateral);
        assertGe(residual, jtFloor, "split: the residual is never below the junior pro-rata floor");
        assertLe(residual - jtFloor, 1, "split: the residual exceeds the junior floor by at most one wei");
        // The trivial splits (whole pool on one side) are exact by construction
        if (_claim == 0) {
            assertEq(residual, _gain, "split: a zero claim routes the whole gain to the residual");
        } else if (_claim == _lastCollateral) {
            assertEq(toClaim, _gain, "split: a whole-pool claim takes the whole gain");
        }
    }
}
