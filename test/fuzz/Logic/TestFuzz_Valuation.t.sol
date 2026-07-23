// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { MAX_MINT_DILUTION_WAD, WAD } from "../../../src/libraries/Constants.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { ValuationLogic } from "../../../src/libraries/logic/ValuationLogic.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title TestFuzz_Valuation_Logic
 * @notice Fuzz properties for the share/value conversion primitives every tranche deposit and redemption
 *         prices through: exact equality against the independent RoycoTestMath mirror on every zero edge,
 *         a derived round-trip loss bound, rounding-direction bracketing, and monotonicity of the share
 *         mint in the contributed value
 * @dev Pure-library layer, no market deploy. Production is asserted against RoycoTestMath or a hand-derived
 *      bound, never against a second call of the function under test
 * @dev The share mint carries the protocol's mint-dilution clamp (MAX_MINT_DILUTION_WAD = WAD − 1e6): a
 *      single mint owns at most (1 − 1e-12) of the post-mint supply, leaving incumbents the residual
 *      WAD − MAX_MINT_DILUTION_WAD = 1e6. The inline pins below recompute the bind predicate from first
 *      principles per branch; the clamp-specific properties (cap exactness, ownership bound, depositor loss)
 *      live in TestFuzz_MintDilutionClamp.t.sol
 */
contract TestFuzz_Valuation_Logic is Test {
    /// @notice Suite-wide NAV and share-supply ceiling
    uint256 internal constant MAX_NAV = 1e30;

    /// @notice Virtual shares / virtual value, restated inline independently of production and the mirror
    uint256 internal constant VS = 1e6;
    uint256 internal constant VA = 1;

    /// @dev The clamp's bind predicate, restated inline and independently of both production and the mirror:
    ///      a mint binds iff value · (WAD − MAX_MINT_DILUTION_WAD) > (totalValue + VA) · MAX_MINT_DILUTION_WAD (the
    ///      effective supply cancels, so the predicate carries only the virtual-value denominator). Products fit:
    ///      value, totalValue + VA <= 1e30 + 1 and WAD − MAX_MINT_DILUTION_WAD = 1e6, so both sides stay below 1e48
    function _binds(uint256 _value, uint256 _totalValue) internal pure returns (bool) {
        uint256 d = _totalValue + VA;
        return _value * (WAD - MAX_MINT_DILUTION_WAD) > d * MAX_MINT_DILUTION_WAD;
    }

    /**
     * Deposit-side pricing: the shares minted for a value contribution floor in favor of existing holders,
     * so a depositor can never mint more than its exact pro-rata share count. This is the primitive every
     * tranche deposit prices through, so an edge regression here misprices every entry.
     * Property: _convertToShares(v, T, S, Floor) == RoycoTestMath.convertToShares(v, T, S) exactly, with each
     * branch additionally re-pinned against inline math so the mirror itself cannot mask a regression:
     *   S == 0                 => shares == v (the first deposit mints 1:1, totalValue ignored, clamp exempt)
     *   S > 0, mint binds      => shares == floor(S * MAX_MINT_DILUTION_WAD / (WAD − MAX_MINT_DILUTION_WAD)) (the dilution cap)
     *   S > 0, T == 0, no bind => shares == S * v (the denominator pins to 1 wei)
     *   otherwise              => shares == floor(S * v / T)
     */
    function testFuzz_ConvertToShares_MatchesMirrorIncludingZeroEdges(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        _value = bound(_value, 0, MAX_NAV); // uniform over the full supported NAV range incl. the 0 edge
        _totalValue = bound(_totalValue, 0, MAX_NAV); // includes 0 => the 1-wei pinned-denominator branch
        _supply = bound(_supply, 0, MAX_NAV); // includes 0 => the first-mint 1:1 branch

        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);

        // Exact equality with the independent mirror over the entire input space
        assertEq(shares, RoycoTestMath.convertToShares(_value, _totalValue, _supply), "shares == RoycoTestMath.convertToShares");

        // Every branch re-pinned with inline math independent of both production and the mirror. Under virtual
        // shares / virtual value there are three branches: the fresh-tranche 1:1 bootstrap (no shares AND no
        // backing), the dilution clamp, and the fair price against the effective supply (S + VS) over (T + VA)
        uint256 effectiveSupply = _supply + VS;
        if (_supply == 0 && _totalValue == 0) {
            assertEq(shares, _value, "a fresh tranche mints 1:1");
        } else if (_binds(_value, _totalValue)) {
            assertEq(
                shares,
                Math.mulDiv(effectiveSupply, MAX_MINT_DILUTION_WAD, WAD - MAX_MINT_DILUTION_WAD),
                "a binding mint clamps to the cap on the effective supply"
            );
        } else {
            assertEq(shares, Math.mulDiv(effectiveSupply, _value, _totalValue + VA, Math.Rounding.Floor), "fair mint == floor((S + VS) * v / (T + VA))");
        }
    }

    /**
     * Redemption-side pricing: the value paid out for a share count floors in favor of the holders who
     * stay, so a redeemer can never extract more than its exact pro-rata slice of the backing value.
     * Property: _convertToValue(shares, S, T, Floor) == RoycoTestMath.convertToValue(shares, T, S) exactly,
     * with the zero edge pinned inline:
     *   S == 0    => value == 0 (an empty supply backs no claim)
     *   otherwise => value == floor(T * shares / S)
     */
    function testFuzz_ConvertToValue_MatchesMirrorIncludingZeroEdges(uint256 _shares, uint256 _totalValue, uint256 _supply) public pure {
        _shares = bound(_shares, 0, MAX_NAV); // uniform over the full share range incl. the 0 edge
        _totalValue = bound(_totalValue, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _supply = bound(_supply, 0, MAX_NAV); // includes 0 => the zero-claim edge

        uint256 value = toUint256(ValuationLogic._convertToValue(_shares, _supply, toNAVUnits(_totalValue), Math.Rounding.Floor));

        assertEq(value, RoycoTestMath.convertToValue(_shares, _totalValue, _supply), "value == RoycoTestMath.convertToValue");

        if (_supply == 0 && _totalValue == 0) {
            assertEq(value, 0, "a fresh tranche has no claim");
        } else {
            assertEq(value, Math.mulDiv(_totalValue + VA, _shares, _supply + VS, Math.Rounding.Floor), "value == floor((T + VA) * shares / (S + VS))");
        }
    }

    /**
     * A deposit immediately followed by a full redemption of the minted shares must never come out ahead,
     * and can lose at most the floor dust of the two conversions, so round-tripping cannot be used to
     * drain a tranche and an honest LP's loss is bounded by one share's worth of value.
     * Property: for a live vault (S >= 1, T >= 1) and a NON-BINDING mint, valueFor(sharesFor(v)) sits in
     * [v - (ceil(T/S) + 1), v]. Slack derivation (both conversions floor):
     *   shares = floor(S*v/T) > S*v/T - 1, so value = floor(T*shares/S) > T*shares/S - 1 > v - T/S - 1,
     *   hence value >= v - ceil(T/S) - 1. Upper side: shares <= S*v/T gives value <= floor(v) = v.
     * The fair-pricing round trip only exists below the bind: a binding mint deliberately returns less
     * (the clamp's purpose; its loss bound is the DepositorLossBounded property in
     * TestFuzz_MintDilutionClamp.t.sol), so the domain is shaped to the no-bind region via bound(), not
     * assumed away: v is drawn from [0, min(MAX_NAV, T * MAX_MINT_DILUTION_WAD / (WAD − MAX_MINT_DILUTION_WAD))], the exact no-bind interval
     */
    function testFuzz_ValuationRoundTrip_LossWithinDerivedSlack(uint256 _value, uint256 _totalValue, uint256 _supply) public pure {
        _totalValue = bound(_totalValue, 1, MAX_NAV); // live vault: positive backing (T == 0 pinned in the equality property)
        _supply = bound(_supply, 1, MAX_NAV); // live vault: positive supply (S == 0 pinned in the equality property)
        // The exact no-bind ceiling: v <= floor((T + VA) * MAX_MINT_DILUTION_WAD / (WAD − MAX_MINT_DILUTION_WAD)) never binds (integer lemma); capped to the domain
        uint256 noBindCeiling = Math.mulDiv(_totalValue + VA, MAX_MINT_DILUTION_WAD, WAD - MAX_MINT_DILUTION_WAD);
        _value = bound(_value, 0, noBindCeiling < MAX_NAV ? noBindCeiling : MAX_NAV); // uniform over the fair-priced region

        uint256 shares = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        uint256 value = toUint256(ValuationLogic._convertToValue(shares, _supply, toNAVUnits(_totalValue), Math.Rounding.Floor));

        // Derived bound under virtual shares / virtual value (both conversions floor): value >= v - ceil((T+VA)/(S+VS)) - 1
        uint256 roundTripSlackDerivedBound = Math.ceilDiv(_totalValue + VA, _supply + VS) + 1;
        assertLe(value, _value, "round trip never manufactures value");
        assertGe(value + roundTripSlackDerivedBound, _value, "round-trip loss bounded by ceil(T/S) + 1");
    }

    /**
     * Depositing more can never mint fewer shares: the mint is non-decreasing in the contributed value
     * across all branches — first-mint identity, 1-wei denominator, the floored mulDiv, and the dilution
     * clamp (a ceiling: the mint grows fairly below the bind and plateaus at the cap above it) — so a
     * depositor cannot be better off splitting or shading its contribution size
     */
    function testFuzz_ConvertToShares_MonotonicInValue(uint256 _valueLo, uint256 _valueHi, uint256 _totalValue, uint256 _supply) public pure {
        _valueLo = bound(_valueLo, 0, MAX_NAV); // uniform over the full NAV range incl. the 0 edge
        _valueHi = bound(_valueHi, _valueLo, MAX_NAV); // second point at or above the first, uniform over the remainder
        _totalValue = bound(_totalValue, 0, MAX_NAV); // includes 0 => monotonicity must also hold on the 1-wei branch
        _supply = bound(_supply, 0, MAX_NAV); // includes 0 => monotonicity must also hold on the first-mint branch

        uint256 sharesLo = ValuationLogic._convertToShares(toNAVUnits(_valueLo), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        uint256 sharesHi = ValuationLogic._convertToShares(toNAVUnits(_valueHi), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        assertLe(sharesLo, sharesHi, "shares non-decreasing in the converted value");
    }

    /**
     * Adversarial rounding-direction probe: the caller (the tranche or the kernel) picks the rounding side
     * per flow, always the one that favors the protocol, so the Ceil and Floor variants of both conversions
     * must bracket the exact ratio — Floor at or below it, Ceil at or above it, at most one unit apart. If
     * Ceil could fall below the exact ratio (or Floor rise above it), the side an attacker gets to trigger
     * would leak a wei on every call, and repeated dust-sized calls would drain the tranche.
     * Bracketing is asserted in cross-multiplied integer form (no division can hide a violation):
     *   sharesFloor * T <= S * v <= sharesCeil * T   and   valueFloor * S <= T * shares <= valueCeil * S
     * Overflow guards: v <= T * MAX_MINT_DILUTION_WAD/(WAD − MAX_MINT_DILUTION_WAD) caps sharesCeil <= S * v / T + 1 <= ~1e42, so every product here
     * stays below 1e72 < 2^256; on the value side valueCeil * S <= T * shares + S <= 1e60 + 1e30
     */
    function testFuzz_RoundingDirectionPair_CeilAndFloorBracketTheExactRatio(
        uint256 _value,
        uint256 _shares,
        uint256 _totalValue,
        uint256 _supply
    )
        public
        pure
    {
        _totalValue = bound(_totalValue, 1, MAX_NAV); // positive backing so the exact ratios are well-defined
        _supply = bound(_supply, 1, MAX_NAV); // live supply so neither bootstrap branch triggers
        _shares = bound(_shares, 0, MAX_NAV); // full share range incl. the 0 edge
        // Stay below the clamp bind so both share variants price fairly (a binding mint returns the cap
        // regardless of the rounding argument, which is pinned in TestFuzz_MintDilutionClamp.t.sol)
        uint256 noBindCeiling = Math.mulDiv(_totalValue + VA, MAX_MINT_DILUTION_WAD, WAD - MAX_MINT_DILUTION_WAD);
        _value = bound(_value, 0, noBindCeiling < MAX_NAV ? noBindCeiling : MAX_NAV); // uniform over the fair-priced region

        // The exact ratios are taken against the EFFECTIVE supply (S + VS) over (T + VA), the same amounts the
        // conversions price against. Products stay below 2^256: (S + VS), (T + VA) <= ~1e30, so each side <= ~1e60
        uint256 effectiveSupply = _supply + VS;
        uint256 effectiveValue = _totalValue + VA;

        // Deposit-side pair: shares for a value contribution
        uint256 sharesFloor = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Floor);
        uint256 sharesCeil = ValuationLogic._convertToShares(toNAVUnits(_value), toNAVUnits(_totalValue), _supply, Math.Rounding.Ceil);
        assertLe(sharesFloor, sharesCeil, "share pair: floor never exceeds ceil");
        assertLe(sharesCeil - sharesFloor, 1, "share pair: the two sides differ by at most one share");
        assertLe(sharesFloor * effectiveValue, effectiveSupply * _value, "share pair: floor sits at or below the exact ratio");
        assertGe(sharesCeil * effectiveValue, effectiveSupply * _value, "share pair: ceil sits at or above the exact ratio");

        // Redemption-side pair: value for a share count
        uint256 valueFloor = toUint256(ValuationLogic._convertToValue(_shares, _supply, toNAVUnits(_totalValue), Math.Rounding.Floor));
        uint256 valueCeil = toUint256(ValuationLogic._convertToValue(_shares, _supply, toNAVUnits(_totalValue), Math.Rounding.Ceil));
        assertLe(valueFloor, valueCeil, "value pair: floor never exceeds ceil");
        assertLe(valueCeil - valueFloor, 1, "value pair: the two sides differ by at most one NAV wei");
        assertLe(valueFloor * effectiveSupply, effectiveValue * _shares, "value pair: floor sits at or below the exact ratio");
        assertGe(valueCeil * effectiveSupply, effectiveValue * _shares, "value pair: ceil sits at or above the exact ratio");
    }
}
