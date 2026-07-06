// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";
import { RoycoTestMath } from "../../base/math/RoycoTestMath.sol";

/**
 * @title ValuationFuzz
 * @notice Fuzz properties for the share/value conversion primitives every tranche deposit and redemption
 *         prices through: exact equality against the independent RoycoTestMath mirror on every zero edge,
 *         a derived round-trip loss bound, and monotonicity of the share mint in the contributed value
 * @dev Pure-library layer, no market deploy. Production is asserted against RoycoTestMath or a hand-derived
 *      bound, never against a second call of the function under test
 */
contract ValuationFuzz is Test {
    /// @notice Suite-wide NAV and share-supply ceiling
    uint256 internal constant MAX_NAV = 1e30;

    /**
     * Deposit-side pricing: the shares minted for a value contribution floor in favor of existing holders,
     * so a depositor can never mint more than its exact pro-rata share count. This is the primitive every
     * tranche deposit prices through, so an edge regression here misprices every entry.
     * Property: _convertToShares(v, T, S, Floor) == RoycoTestMath.sharesFor(v, T, S) exactly, with each
     * edge additionally re-pinned against inline math so the mirror itself cannot mask a regression:
     *   S == 0            => shares == v (the first deposit mints 1:1 with the value, totalValue ignored)
     *   S > 0 and T == 0  => shares == S * v (the denominator pins to 1 wei, ValuationLogic.sol:106)
     *   otherwise         => shares == floor(S * v / T)
     */
    function testFuzz_ConvertToShares_matchesMirrorIncludingZeroEdges(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        _value = bound(_value, 0, MAX_NAV); // uniform over the full supported NAV range incl. the 0 edge
        _totalValue = bound(_totalValue, 0, MAX_NAV); // includes 0 => the 1-wei pinned-denominator branch
        _supply = bound(_supply, 0, MAX_NAV); // includes 0 => the first-mint 1:1 branch

        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);

        // Exact equality with the independent mirror over the entire input space
        assertEq(shares, RoycoTestMath.sharesFor(_value, _totalValue, _supply), "shares == RoycoTestMath.sharesFor");

        // Zero edges re-pinned with inline math independent of both production and the mirror
        if (_supply == 0) {
            assertEq(shares, _value, "zero supply mints 1:1 with the value");
        } else if (_totalValue == 0) {
            // No overflow: S * v <= 1e30 * 1e30 = 1e60 < 2^256
            assertEq(shares, _supply * _value, "zero total value pins the denominator to 1 wei");
        } else {
            assertEq(shares, Math.mulDiv(_supply, _value, _totalValue, Math.Rounding.Floor), "shares == floor(S*v/T)");
        }
    }

    /**
     * Redemption-side pricing: the value paid out for a share count floors in favor of the holders who
     * stay, so a redeemer can never extract more than its exact pro-rata slice of the backing value.
     * Property: _convertToValue(shares, S, T, Floor) == RoycoTestMath.valueFor(shares, T, S) exactly,
     * with the zero edge pinned inline:
     *   S == 0    => value == 0 (an empty supply backs no claim)
     *   otherwise => value == floor(T * shares / S)
     */
    function testFuzz_ConvertToValue_matchesMirrorIncludingZeroEdges(uint256 _shares, uint256 _totalValue, uint256 _supply) public pure {
        _shares = bound(_shares, 0, MAX_NAV); // uniform over the full share range incl. the 0 edge
        _totalValue = bound(_totalValue, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _supply = bound(_supply, 0, MAX_NAV); // includes 0 => the zero-claim edge

        uint256 value = toUint256(ValuationLogic._convertToValue(_shares, _supply, toNAVUnits(_totalValue), Math.Rounding.Floor));

        assertEq(value, RoycoTestMath.valueFor(_shares, _totalValue, _supply), "value == RoycoTestMath.valueFor");

        if (_supply == 0) {
            assertEq(value, 0, "zero supply values every share count at zero");
        } else {
            assertEq(value, Math.mulDiv(_totalValue, _shares, _supply, Math.Rounding.Floor), "value == floor(T*shares/S)");
        }
    }

    /**
     * A deposit immediately followed by a full redemption of the minted shares must never come out ahead,
     * and can lose at most the floor dust of the two conversions, so round-tripping cannot be used to
     * drain a tranche and an honest LP's loss is bounded by one share's worth of value.
     * Property: for a live vault (S >= 1, T >= 1), valueFor(sharesFor(v)) sits in [v - (ceil(T/S) + 1), v].
     * Slack derivation (both conversions floor):
     *   shares = floor(S*v/T) > S*v/T - 1, so value = floor(T*shares/S) > T*shares/S - 1 > v - T/S - 1,
     *   hence value >= v - ceil(T/S) - 1. Upper side: shares <= S*v/T gives value <= floor(v) = v.
     * The zero edges are excluded here by construction: S == 0 collapses the round trip to 0 (pinned in
     * the equality properties above) and T == 0 routes through the 1-wei denominator whose round trip is 0
     */
    function testFuzz_ValuationRoundTrip_lossWithinDerivedSlack(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        _value = bound(_value, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _totalValue = bound(_totalValue, 1, MAX_NAV); // live vault: positive backing (T == 0 pinned in the equality property)
        _supply = bound(_supply, 1, MAX_NAV); // live vault: positive supply (S == 0 pinned in the equality property)

        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        uint256 value = toUint256(ValuationLogic._convertToValue(shares, _supply, toNAVUnits(_totalValue), Math.Rounding.Floor));

        // Derived bound, see derivation in the property comment: one NAV-per-share ceiling plus one wei
        uint256 roundTripSlackDerivedBound = Math.ceilDiv(_totalValue, _supply) + 1;
        assertLe(value, _value, "round trip never manufactures value");
        assertGe(value + roundTripSlackDerivedBound, _value, "round-trip loss bounded by ceil(T/S) + 1");
    }

    /**
     * Depositing more can never mint fewer shares: the mint is non-decreasing in the contributed value
     * across all three branches (first-mint identity, 1-wei denominator, and the floored mulDiv), so a
     * depositor cannot be better off splitting or shading its contribution size
     */
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
