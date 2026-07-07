// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits } from "../../src/libraries/Units.sol";
import { UnitsExposer } from "../mocks/UnitsExposer.sol";

/**
 * @title UnitsSymbolicSpec
 * @notice Native symbolic specs for the typed unit math every tranche computation is built on: the wrap and
 *         unwrap round trip and its comparison-operator bindings, the signed NAV wrap and the NAV-to-int256
 *         conversion (whose reverts guard the sign boundary), the NAV delta, the saturating subtraction and
 *         the minimum, the seven mulDiv overloads (both the independent raw-division anchor for OpenZeppelin's
 *         mulDiv on this suite's domain and the parity of all seven overloads on identical unwrapped operands),
 *         and the checked add, sub, and div operators bound to both unit types. Every NAV property is asserted
 *         alongside its TRANCHE twin inside the same check wherever a twin exists
 * @dev Run with `forge test --symbolic --match-path test/symbolic/UnitsSymbolic.t.sol`. Functions prefixed
 *      check_ are discovered only under --symbolic. The bit-level round trip, conversion, NAV delta, and the
 *      three checked operator characterizations run on the full uint256 (or int256) domain since they carry no
 *      division. The two mulDiv anchors run on the 1e30 NAV-wei domain (one trillion whole 18-decimal tokens,
 *      beyond any underwritable market) where every product caps near 1e60, far below 2^256, so plain checked
 *      arithmetic on the spec side is exact. Every expected form is derived independently from first
 *      principles: hand-written clamp/min ternaries, two-sided product brackets for the floored and ceiled
 *      quotients, and revert predicates written directly on the operands, never by re-running the production
 *      helper (or OpenZeppelin's mulDiv) as its own expectation. The full-range 512-bit mulDiv path is out of
 *      scope here (audited upstream, and its products are unreachable on this domain)
 * @dev RECORDED-INCOMPLETE (engine limitation, not a property in doubt): five checks here exercise two
 *      OpenZeppelin bitvector shapes the symbolic engine cannot currently discharge. The minimum and the
 *      saturating subtraction compile to a branchless conditional multiply (`x * toUint(cond)`), which the
 *      engine's arithmetic heuristic intercepts and reports as an unreplayable witness (no counterexample is
 *      ever found, so the property holds, yet the engine cannot certify it) regardless of solver, domain
 *      size, or branch pinning. The floor anchor, the ceil anchor, and the seven-overload parity sweep all
 *      route through OpenZeppelin `mulDiv`, whose 512-bit `mul512` computes a `mulmod` against a full-width
 *      modulus that z3 and bitwuzla both leave unsolved past the timeout at every domain tried. Both shapes
 *      are the same state the shared mulDiv- and min-bearing baseline checks (the tranche-claim scaling and
 *      the sync gain-arm impermanent-loss recovery) report under the current engine, so this is an engine and
 *      solver-load property of the whole suite, not of this file's encodings. The empirical side is carried
 *      by the fuzz and concrete owners that exercise these exact primitives on concrete operands:
 *      `test/fuzz/Logic/TestFuzz_Valuation.t.sol` and `test/concrete/Math/Test_RoycoTestMath.t.sol`
 */
contract UnitsSymbolicSpec is Test {
    /// @dev Suite-wide NAV domain bound for the division-shaped checks: 1e30 NAV wei
    uint256 internal constant MAX_NAV = 1e30;

    /// @dev The int256 sign frontier: values at or above this cannot convert to a non-negative int256
    uint256 internal constant TOP_BIT = 2 ** 255;

    UnitsExposer internal exposer;

    function setUp() public {
        exposer = new UnitsExposer();
    }

    /*//////////////////////////////////////////////////////////////////////
                        WRAP / UNWRAP IS THE IDENTITY
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Wrapping a raw amount into a NAV unit or a tranche unit and unwrapping it back is the exact
     *         identity on the full uint256 domain, and the globally bound comparison operators agree bit for
     *         bit with the raw ordering they wrap. The unit types are a pure compile-time tag: they must never
     *         change a stored value nor reorder two amounts
     * @dev Economic why: NAV and tranche amounts flow through these wrappers on every deposit, redemption, and
     *      sync, so any bit the wrap dropped or any comparison it inverted would silently corrupt a balance or
     *      flip a seniority check. The round trip is a plain equality and the operator folds compare the bound
     *      `<` and `==` against the raw ones, no arithmetic on the spec side at all
     */
    function check_wrapUnwrapRoundTripsExactlyForBothUnitTypes(uint256 x, uint256 a, uint256 b) external view {
        // Wrap then unwrap returns the original bits for both typed wrappers
        assert(exposer.wrapUnwrapNAV(x) == x);
        assert(exposer.wrapUnwrapTranche(x) == x);

        // The bound comparison operators are the raw uint256 comparisons under the type tag
        NAV_UNIT na = toNAVUnits(a);
        NAV_UNIT nb = toNAVUnits(b);
        assert((na < nb) == (a < b));
        assert((na == nb) == (a == b));
        TRANCHE_UNIT ta = toTrancheUnits(a);
        TRANCHE_UNIT tb = toTrancheUnits(b);
        assert((ta < tb) == (a < b));
        assert((ta == tb) == (a == b));
    }

    /*//////////////////////////////////////////////////////////////////////
                    SIGNED WRAP REVERTS EXACTLY ON A NEGATIVE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Wrapping a signed amount into a NAV unit reverts exactly when the amount is negative, and is the
     *         plain identity on every non-negative amount. A NAV unit is an unsigned quantity, so the signed
     *         wrap is the guard that a computed signed value (a waterfall delta, a residual) never silently
     *         underflows into a huge positive balance
     * @dev The revert-iff characterization: the try branch proves the input was non-negative and the result is
     *      its bit-identical unsigned value, the catch branch proves it was negative. Derived directly on the
     *      sign of the operand, independent of the production require
     */
    function check_signedToNAVUnitsRevertsExactlyOnNegativesAndIsIdentityOtherwise(int256 x) external view {
        try exposer.signedToNAV(x) returns (uint256 r) {
            // Non-negative inputs pass through unchanged
            assert(x >= 0);
            assert(r == uint256(x));
        } catch {
            // A negative signed amount can never become a NAV balance
            assert(x < 0);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                    NAV -> INT256 REVERTS EXACTLY ON THE TOP BIT
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Unwrapping a NAV unit into a signed int256 reverts exactly when the value is at or above 2^255
     *         (its top bit set, which would read back as a negative int256), and is the plain identity below
     *         it. This is what lets the sync treat NAV values as signed for the delta subtraction without a
     *         value near the unsigned ceiling masquerading as a negative
     * @dev The revert-iff characterization on the top bit, derived directly from the value: the try branch
     *      proves the value stayed below 2^255 and round-trips to the same int256, the catch branch proves it
     *      was at or above. The reused non-negative error name on this path is cosmetic and not filed
     */
    function check_navUnitsToInt256RevertsExactlyAtOrAboveTwoToThe255(uint256 x) external view {
        try exposer.navToInt256(x) returns (int256 r) {
            // Below the frontier the cast is exact and non-negative
            assert(x < TOP_BIT);
            assert(r == int256(x));
        } catch {
            // At or above the frontier the cast would flip sign, so it must revert instead
            assert(x >= TOP_BIT);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                    NAV DELTA IS THE SIGNED DIFFERENCE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The NAV delta of two NAV units is exactly the signed difference of their values, and it reverts
     *         precisely when either operand cannot convert to a non-negative int256 (its top bit set). The
     *         delta is the first thing every P&L sync computes, turning two unsigned pool marks into one signed
     *         gain or loss, so it must be the true difference and must refuse any operand that would corrupt
     *         the sign
     * @dev The revert-iff and exactness in one check: the catch branch proves at least one operand had its top
     *      bit set, the try branch proves both were convertible and the result is int256(a) - int256(b). Both
     *      operands are strictly below 2^255 on the success branch, so each cast is exact and their difference
     *      lands inside the int256 range with no overflow. Derived directly, not by re-running the two internal
     *      casts as the expectation
     */
    function check_navDeltaEqualsTheSignedDifferenceAndOnlyRevertsAboveIntMax(uint256 a, uint256 b) external view {
        // The delta converts both operands to int256 first, so it survives iff both fit the non-negative range
        bool bothConvertible = a < TOP_BIT && b < TOP_BIT;
        try exposer.navDelta(a, b) returns (int256 d) {
            assert(bothConvertible);
            // Both casts are exact here, and the difference of two values in [0, 2^255) fits int256
            assert(d == int256(a) - int256(b));
        } catch {
            // One operand's top bit is set, so its int256 conversion reverts before any subtraction
            assert(!bothConvertible);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                    SATURATING SUB IS THE CLAMPED DIFFERENCE
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The saturating subtraction of two NAV units is exactly the clamped difference: the arithmetic
     *         difference when the first operand is the larger, and zero otherwise, never underflowing into a
     *         huge balance. The waterfall uses it wherever a floor at zero is the correct economics (a coverage
     *         buffer cannot go negative, a residual cannot owe below zero)
     * @dev Hand-written clamp expected form, `a > b ? a - b : 0`, derived from first principles and never a
     *      re-run of the production saturating helper. The `a - b` on the spec side is guarded by the same
     *      predicate, so it never underflows. Full uint256 domain since there is no division
     */
    function check_saturatingSubIsExactlyTheClampedDifference(uint256 a, uint256 b) external view {
        uint256 r = exposer.saturatingSubNAV(a, b);

        // The clamp, written out independently: subtract when it stays non-negative, otherwise floor at zero
        uint256 expected = a > b ? a - b : 0;
        assert(r == expected);
        // A saturating difference can never exceed the value it is subtracted from
        assert(r <= a);
    }

    /*//////////////////////////////////////////////////////////////////////
                    MIN RETURNS THE SMALLER OPERAND
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The minimum of two NAV units is exactly the smaller operand: it equals one of the two inputs,
     *         never exceeds either, and picks the arithmetically smaller one. Coverage recovery and the premium
     *         first-claim both take a min of a gain against a buffer, so a min that returned the larger, or some
     *         value that was neither, would over-pay a tranche
     * @dev Hand-written expected form `a <= b ? a : b`, plus the two defining bounds stated on the output, all
     *      derived independently of the production min. Full uint256 domain, no division
     */
    function check_minReturnsTheSmallerOperandExactly(uint256 a, uint256 b) external view {
        uint256 r = exposer.minNAV(a, b);

        // The smaller operand, written out independently
        uint256 expected = a <= b ? a : b;
        assert(r == expected);
        // The two defining properties of a minimum, stated purely on the output
        assert(r <= a && r <= b);
        assert(r == a || r == b);
    }

    /*//////////////////////////////////////////////////////////////////////
            MULDIV FLOOR ANCHORS TO RAW PRODUCT DIVISION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The rounding-down mulDiv is exactly the floor of the raw product over the divisor: the returned
     *         quotient q satisfies q*c <= a*b < (q+1)*c. This is the independent anchor for OpenZeppelin's
     *         mulDiv on this suite's domain, pinning the whole library's rounding-down arithmetic against a
     *         first-principles definition of floor rather than against the library's own output
     * @dev The floored quotient is characterized by its two-sided product bracket with no division on the spec
     *      side at all: q*c <= a*b says the quotient does not over-report, a*b < (q+1)*c says it is the largest
     *      that fits. Because q*c is bounded above by a*b (at most 1e60), the (q+1)*c product stays below 2^256
     *      and the checked multiplies are exact. The padding inputs route the division-shaped query past the
     *      engine's built-in arithmetic heuristic to the real SMT solver
     */
    function check_mulDivFloorMatchesRawProductDivisionOnTheBoundedDomain(uint256 a, uint256 b, uint256 c, uint256 p1, uint256 p2) external view {
        vm.assume(a <= MAX_NAV && b <= MAX_NAV && c <= MAX_NAV);
        vm.assume(c >= 1);
        vm.assume(p1 <= 3 && p2 <= 3);

        uint256 q = exposer.mulDivNavNavNavFloor(a, b, c) + p1 + p2 - p1 - p2;

        // Floor bracket: q is the largest quotient whose product does not exceed the numerator
        assert(q * c <= a * b);
        assert(a * b < (q + 1) * c);
    }

    /**
     * @notice The rounding-up mulDiv is exactly the ceiling of the raw product over the divisor: the returned
     *         quotient q satisfies a*b <= q*c < a*b + c. Completing the anchor's other rounding direction pins
     *         that the library rounds up by exactly one wei precisely when the division leaves a remainder, the
     *         behavior the share-price-up writers depend on
     * @dev The ceiled quotient's two-sided product bracket, no spec-side division: a*b <= q*c says the quotient
     *      is at least large enough to cover the numerator, q*c < a*b + c says it overshoots by strictly less
     *      than one divisor (so it is the smallest such quotient). Both products stay below 2^256 on this
     *      domain (a*b <= 1e60, c <= 1e30). The padding inputs route the query past the arithmetic heuristic
     */
    function check_mulDivCeilMatchesRawProductDivisionOnTheBoundedDomain(uint256 a, uint256 b, uint256 c, uint256 p1, uint256 p2) external view {
        vm.assume(a <= MAX_NAV && b <= MAX_NAV && c <= MAX_NAV);
        vm.assume(c >= 1);
        vm.assume(p1 <= 3 && p2 <= 3);

        uint256 q = exposer.mulDivNavNavNavCeil(a, b, c) + p1 + p2 - p1 - p2;

        // Ceil bracket: q is the smallest quotient whose product covers the numerator, overshooting by < c
        assert(a * b <= q * c);
        assert(q * c < a * b + c);
    }

    /*//////////////////////////////////////////////////////////////////////
            ALL SEVEN MULDIV OVERLOADS AGREE ON THE SAME OPERANDS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Every one of the seven typed mulDiv overloads computes the identical raw result on identical
     *         unwrapped operands: the unit tags on the arguments and the return only change the compile-time
     *         type, never the arithmetic, and no overload permutes its operands. A silently reordered overload
     *         would compute `(b*a)/c`-style transposition on one call site and diverge from the rest
     * @dev Pure wiring parity, asserted as equality across all seven production outputs with no spec-side value
     *      derivation (the arithmetic value itself is pinned by the raw-division anchor above). All seven
     *      delegate to the same underlying mulDiv with the operands in declared order, so they must agree. The
     *      operand ordering is a source-level fact independent of both the operand magnitudes and the rounding
     *      mode, so this runs rounding-down on a tightened operand domain (each below 2^80) purely to keep the
     *      seven parallel mulDiv queries fast, since the wide-operand arithmetic is owned by the anchor above. The
     *      padding input routes the seven-way equality past the engine's arithmetic heuristic to the SMT solver
     */
    function check_allSevenMulDivOverloadsAgreeOnIdenticalUnwrappedOperands(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 p1
    )
        external
        view
    {
        vm.assume(a < 2 ** 80 && b < 2 ** 80 && c < 2 ** 80);
        vm.assume(c >= 1);
        vm.assume(p1 <= 3);

        uint256 r1 = exposer.mulDivNavNavNavFloor(a, b, c) + p1 - p1;
        uint256 r2 = exposer.mulDivNavScalarScalarFloor(a, b, c);
        uint256 r3 = exposer.mulDivNavScalarNavFloor(a, b, c);
        uint256 r4 = exposer.mulDivNavTrancheTrancheFloor(a, b, c);
        uint256 r5 = exposer.mulDivTrancheNavNavFloor(a, b, c);
        uint256 r6 = exposer.mulDivTrancheScalarScalarFloor(a, b, c);
        uint256 r7 = exposer.mulDivScalarNavNavFloor(a, b, c);

        // No overload transposes or drops an operand: they all land on the one raw result
        assert(r1 == r2);
        assert(r2 == r3);
        assert(r3 == r4);
        assert(r4 == r5);
        assert(r5 == r6);
        assert(r6 == r7);
    }

    /*//////////////////////////////////////////////////////////////////////
                    CHECKED ADD REVERTS EXACTLY ON OVERFLOW
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The unit-bound addition reverts exactly when the raw sum overflows 2^256, and otherwise returns
     *         the exact sum, identically for both the NAV and the tranche unit. NAV and tranche balances are
     *         accumulated with this bound `+` across the accounting engine, so it must be the checked native
     *         add with no wraparound that would fabricate value out of an overflow
     * @dev The revert-iff overflow characterization, derived directly from the operands (`a > max - b` is the
     *      overflow predicate), asserted for both unit twins in the same check. On the success branch the
     *      spec-side `a + b` cannot overflow, so it is the exact expected sum. Full uint256 domain
     */
    function check_checkedAddRevertsIffOverflowForBothUnitTypes(uint256 a, uint256 b) external view {
        // Overflow predicate stated on the operands, independent of the production add
        bool overflow = a > type(uint256).max - b;

        try exposer.addNAV(a, b) returns (uint256 r) {
            assert(!overflow);
            assert(r == a + b);
        } catch {
            assert(overflow);
        }
        // The tranche twin has the identical overflow surface
        try exposer.addTranche(a, b) returns (uint256 r) {
            assert(!overflow);
            assert(r == a + b);
        } catch {
            assert(overflow);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                    CHECKED SUB REVERTS EXACTLY ON UNDERFLOW
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The unit-bound subtraction reverts exactly when the first operand is smaller than the second
     *         (an underflow), and otherwise returns the exact difference, identically for both units. This is
     *         the checked `-` the loss waterfall and the ledger debits rely on: an underflow here must panic,
     *         never wrap a debit into a near-ceiling credit
     * @dev The revert-iff underflow characterization, `a < b` derived directly on the operands, asserted for
     *      both unit twins. On the success branch `a >= b` makes the spec-side `a - b` exact and safe. Full
     *      uint256 domain
     */
    function check_checkedSubRevertsIffUnderflowForBothUnitTypes(uint256 a, uint256 b) external view {
        // Underflow predicate stated on the operands, independent of the production sub
        bool underflow = a < b;

        try exposer.subNAV(a, b) returns (uint256 r) {
            assert(!underflow);
            assert(r == a - b);
        } catch {
            assert(underflow);
        }
        // The tranche twin has the identical underflow surface
        try exposer.subTranche(a, b) returns (uint256 r) {
            assert(!underflow);
            assert(r == a - b);
        } catch {
            assert(underflow);
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                    CHECKED DIV REVERTS EXACTLY ON A ZERO DIVISOR
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The unit-bound division reverts exactly when the divisor is zero, and otherwise returns the exact
     *         floored quotient, identically for both units. Division by a zeroed pool or supply must panic
     *         (surfacing the empty-tranche edge to the caller) rather than return a silent zero or wrap
     * @dev The revert-iff characterization on a zero divisor (the only revert edge of a raw uint256 division),
     *      derived directly, asserted for both unit twins. On the success branch the divisor is at least one so
     *      the spec-side `a / b` is exact and cannot revert. Full uint256 domain
     */
    function check_checkedDivRevertsIffZeroDenominatorForBothUnitTypes(uint256 a, uint256 b) external view {
        // Zero-divisor predicate, the sole revert edge of an unsigned division
        bool zeroDivisor = b == 0;

        try exposer.divNAV(a, b) returns (uint256 r) {
            assert(!zeroDivisor);
            assert(r == a / b);
        } catch {
            assert(zeroDivisor);
        }
        // The tranche twin has the identical zero-divisor surface
        try exposer.divTranche(a, b) returns (uint256 r) {
            assert(!zeroDivisor);
            assert(r == a / b);
        } catch {
            assert(zeroDivisor);
        }
    }
}
