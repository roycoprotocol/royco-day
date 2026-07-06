// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";

/**
 * @title ValuationFuzz
 * @notice Phase C fuzz properties for the F9/F10 share-conversion primitives (testing-strategy.md §4.2 row
 *         `_convertToShares/_convertToValue`): exact equality against the independent RoycoTestMath mirror
 *         including every zero edge, the derived round-trip loss bound, and monotonicity in the converted value
 * @dev Pure-library layer, no market deploy. Production is asserted against RoycoTestMath or a hand-derived
 *      bound, never against a second call of the function under test
 */
contract ValuationFuzz is Test {
    /// @notice Suite-wide NAV and share-supply ceiling (testing-strategy.md §4.2 global bounds)
    uint256 internal constant MAX_NAV = 1e30;

    /**
     * Property (F9, VL:102-107): _convertToShares(v, T, S, Floor) == RoycoTestMath.sharesFor(v, T, S) exactly,
     * with the two zero edges additionally pinned against inline independent math so the mirror itself cannot
     * mask an edge regression:
     *   S == 0            => shares == v (first-mint 1:1, totalValue ignored)
     *   S > 0 and T == 0  => shares == floor(S * v / 1) (the 1-wei pinned denominator, VL:106)
     *   otherwise         => shares == floor(S * v / T)
     */
    function testFuzz_ConvertToShares_matchesMirrorIncludingZeroEdges(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        _value = bound(_value, 0, MAX_NAV); // uniform over the full supported NAV range incl. the 0 edge
        _totalValue = bound(_totalValue, 0, MAX_NAV); // includes 0 => the 1-wei pinned-denominator branch
        _supply = bound(_supply, 0, MAX_NAV); // includes 0 => the first-mint 1:1 branch

        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);

        // Exact equality with the independent mirror over the entire input space
        assertEq(shares, RoycoTestMath.sharesFor(_value, _totalValue, _supply), "F9: shares == RoycoTestMath.sharesFor");

        // Zero edges re-pinned with inline math independent of both production and the mirror
        if (_supply == 0) {
            assertEq(shares, _value, "F9 edge: zero supply mints 1:1 with the value");
        } else if (_totalValue == 0) {
            // No overflow: S * v <= 1e30 * 1e30 = 1e60 < 2^256
            assertEq(shares, _supply * _value, "F9 edge: zero total value pins the denominator to 1 wei");
        } else {
            assertEq(shares, Math.mulDiv(_supply, _value, _totalValue, Math.Rounding.Floor), "F9: floor(S*v/T)");
        }
    }

    /**
     * Property (F10, VL:118-122): _convertToValue(shares, S, T, Floor) == RoycoTestMath.valueFor(shares, T, S)
     * exactly, with the zero edge pinned:
     *   S == 0    => value == 0 (nothing to claim against an empty supply)
     *   otherwise => value == floor(T * shares / S)
     */
    function testFuzz_ConvertToValue_matchesMirrorIncludingZeroEdges(uint256 _shares, uint256 _totalValue, uint256 _supply) public pure {
        _shares = bound(_shares, 0, MAX_NAV); // uniform over the full share range incl. the 0 edge
        _totalValue = bound(_totalValue, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _supply = bound(_supply, 0, MAX_NAV); // includes 0 => the zero-claim edge

        uint256 value = toUint256(ValuationLogic._convertToValue(_shares, _supply, toNAVUnits(_totalValue), Math.Rounding.Floor));

        assertEq(value, RoycoTestMath.valueFor(_shares, _totalValue, _supply), "F10: value == RoycoTestMath.valueFor");

        if (_supply == 0) {
            assertEq(value, 0, "F10 edge: zero supply values every share count at zero");
        } else {
            assertEq(value, Math.mulDiv(_totalValue, _shares, _supply, Math.Rounding.Floor), "F10: floor(T*shares/S)");
        }
    }

    /**
     * Property (§4.2 round-trip): for a live vault (S >= 1, T >= 1),
     *   valueFor(sharesFor(v)) ∈ [v - (ceil(T/S) + 1), v]
     * Derivation of the slack (both conversions Floor):
     *   shares = floor(S*v/T) > S*v/T - 1, so value = floor(T*shares/S) > T*shares/S - 1 > v - T/S - 1,
     *   hence value >= v - ceil(T/S) - 1. Upper side: shares <= S*v/T gives value <= floor(v) = v.
     * The zero edges are excluded here by construction: S == 0 collapses the round trip to 0 (pinned in the
     * equality properties above) and T == 0 routes through the 1-wei denominator whose round trip is 0
     */
    function testFuzz_ValuationRoundTrip_lossWithinDerivedSlack(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        _value = bound(_value, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _totalValue = bound(_totalValue, 1, MAX_NAV); // live vault: positive backing (T == 0 pinned in the equality property)
        _supply = bound(_supply, 1, MAX_NAV); // live vault: positive supply (S == 0 pinned in the equality property)

        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        uint256 value = toUint256(ValuationLogic._convertToValue(shares, _supply, toNAVUnits(_totalValue), Math.Rounding.Floor));

        // Derived bound, see derivation in the property natspec: one NAV-per-share ceiling plus one wei
        uint256 roundTripSlackDerivedBound = Math.ceilDiv(_totalValue, _supply) + 1;
        assertLe(value, _value, "round trip never manufactures value");
        assertGe(value + roundTripSlackDerivedBound, _value, "round-trip loss bounded by ceil(T/S) + 1");
    }

    /// Property (§4.2 monotonicity): _convertToShares is non-decreasing in the converted value across all
    /// three branches (first-mint identity, 1-wei denominator, and the floored mulDiv)
    function testFuzz_ConvertToShares_monotonicInValue(uint256 _valueLo, uint256 _valueHi, uint256 _totalValue, uint256 _supply) public pure {
        _valueLo = bound(_valueLo, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _valueHi = bound(_valueHi, _valueLo, MAX_NAV); // second point at or above the first, uniform over the remainder
        _totalValue = bound(_totalValue, 0, MAX_NAV); // includes 0 => monotonicity must also hold on the 1-wei branch
        _supply = bound(_supply, 0, MAX_NAV); // includes 0 => monotonicity must also hold on the first-mint branch

        uint256 sharesLo = ValuationLogic._convertToShares(toNAVUnits(_valueLo), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        uint256 sharesHi = ValuationLogic._convertToShares(toNAVUnits(_valueHi), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        assertLe(sharesLo, sharesHi, "shares non-decreasing in the converted value");
    }
}
