// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { UnitsExposer } from "../../mocks/UnitsExposer.sol";

/**
 * @title TestFuzz_UnitsMath
 * @notice Fuzz owners for the typed unit-math primitives: the minimum, the saturating subtraction,
 *         and the three mulDiv properties (the floor anchor, the ceil anchor, and the seven-overload
 *         parity sweep). Every expected form here is derived from first principles on the raw operands,
 *         never by re-running the production helper or OpenZeppelin's mulDiv as its own expectation
 * @dev The two mulDiv anchors and the parity sweep run on the 1e30 NAV-wei operand domain (one trillion
 *      whole 18-decimal tokens, beyond any underwritable market), where every product caps near 1e60,
 *      far below 2^256, so the spec-side checked multiplies are exact. The min and saturating-sub twins
 *      run on the full uint256 domain since they carry no division
 */
contract TestFuzz_UnitsMath is Test {
    /// @dev Operand bound for the division-shaped properties: 1e30 NAV wei
    uint256 internal constant MAX_NAV = 1e30;

    UnitsExposer internal exposer;

    function setUp() public {
        exposer = new UnitsExposer();
    }

    /**
     * @notice The minimum of two NAV units equals one of the two inputs, never exceeds either, and picks
     *         the arithmetically smaller one, on the full uint256 domain
     */
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_MinReturnsTheSmallerOperandExactly(uint256 _a, uint256 _b) public view {
        uint256 r = exposer.minNAV(_a, _b);

        // The smaller operand, written out independently of the production min
        uint256 expected = _a <= _b ? _a : _b;
        assertEq(r, expected, "min picks the arithmetically smaller operand");
        // The two defining properties of a minimum, stated purely on the output
        assertTrue(r <= _a && r <= _b, "min never exceeds either operand");
        assertTrue(r == _a || r == _b, "min equals one of the two operands");
    }

    /**
     * @notice The saturating subtraction of two NAV units is exactly the clamped difference: the
     *         arithmetic difference when the first operand is larger, zero otherwise, never underflowing
     */
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_SaturatingSubIsExactlyTheClampedDifference(uint256 _a, uint256 _b) public view {
        uint256 r = exposer.saturatingSubNAV(_a, _b);

        // The clamp, written out independently: subtract when non-negative, otherwise floor at zero
        uint256 expected = _a > _b ? _a - _b : 0;
        assertEq(r, expected, "saturating sub is the clamped difference");
        assertTrue(r <= _a, "a saturating difference never exceeds the minuend");
    }

    /**
     * @notice The rounding-down mulDiv is exactly the floor of the raw product over the divisor: the
     *         returned quotient q satisfies q*c <= a*b < (q+1)*c on the bounded operand domain
     * @dev The two-sided product bracket characterizes the floored quotient with no division on the spec
     *      side: q*c <= a*b says the quotient does not over-report, a*b < (q+1)*c says it is the largest
     *      that fits. All products stay below 2^256 on this domain so the checked multiplies are exact
     */
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_MulDivFloorMatchesRawProductDivisionOnTheBoundedDomain(uint256 _a, uint256 _b, uint256 _c) public view {
        _a = bound(_a, 0, MAX_NAV);
        _b = bound(_b, 0, MAX_NAV);
        _c = bound(_c, 1, MAX_NAV);

        uint256 q = exposer.mulDivNavNavNavFloor(_a, _b, _c);

        assertTrue(q * _c <= _a * _b, "floor quotient never over-reports the product");
        assertTrue(_a * _b < (q + 1) * _c, "floor quotient is the largest that fits");
    }

    /**
     * @notice The rounding-up mulDiv is exactly the ceiling of the raw product over the divisor: the
     *         returned quotient q satisfies a*b <= q*c < a*b + c on the bounded operand domain
     * @dev The ceiled quotient's two-sided product bracket: a*b <= q*c says the quotient covers the
     *      numerator, q*c < a*b + c says it overshoots by strictly less than one divisor
     */
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_MulDivCeilMatchesRawProductDivisionOnTheBoundedDomain(uint256 _a, uint256 _b, uint256 _c) public view {
        _a = bound(_a, 0, MAX_NAV);
        _b = bound(_b, 0, MAX_NAV);
        _c = bound(_c, 1, MAX_NAV);

        uint256 q = exposer.mulDivNavNavNavCeil(_a, _b, _c);

        assertTrue(_a * _b <= q * _c, "ceil quotient covers the numerator");
        assertTrue(q * _c < _a * _b + _c, "ceil quotient overshoots by less than one divisor");
    }

    /**
     * @notice Every one of the seven typed mulDiv overloads computes the identical raw result on identical
     *         unwrapped operands: the unit tags only change the compile-time type, never the arithmetic,
     *         and no overload permutes its operands
     */
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_AllSevenMulDivOverloadsAgreeOnIdenticalUnwrappedOperands(uint256 _a, uint256 _b, uint256 _c) public view {
        _a = bound(_a, 0, MAX_NAV);
        _b = bound(_b, 0, MAX_NAV);
        _c = bound(_c, 1, MAX_NAV);

        uint256 r1 = exposer.mulDivNavNavNavFloor(_a, _b, _c);

        // No overload transposes or drops an operand: they all land on the one raw result
        assertEq(r1, exposer.mulDivNavScalarScalarFloor(_a, _b, _c), "NAV*scalar/scalar overload agrees");
        assertEq(r1, exposer.mulDivNavScalarNavFloor(_a, _b, _c), "NAV*scalar/NAV overload agrees");
        assertEq(r1, exposer.mulDivNavTrancheTrancheFloor(_a, _b, _c), "NAV*tranche/tranche overload agrees");
        assertEq(r1, exposer.mulDivTrancheNavNavFloor(_a, _b, _c), "tranche*NAV/NAV overload agrees");
        assertEq(r1, exposer.mulDivTrancheScalarScalarFloor(_a, _b, _c), "tranche*scalar/scalar overload agrees");
        assertEq(r1, exposer.mulDivScalarNavNavFloor(_a, _b, _c), "scalar*NAV/NAV overload agrees");
    }
}
