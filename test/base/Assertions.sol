// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { NAV_UNIT, TRANCHE_UNIT, toUint256 } from "../../src/libraries/Units.sol";
import { Test } from "forge-std/Test.sol";

/// @title Assertions
/// @notice Typed assertion helpers for the `NAV_UNIT` / `TRANCHE_UNIT` value types plus a small set of
///         protocol-specific invariant assertions (wei-exact NAV conservation) used across the suite.
/// @dev Kept deliberately thin: it only wraps forge-std assertions to accept the custom value types and
///      adds the conservation identity so tests never re-implement it inline (and never loosen it by accident).
contract Assertions is Test {
    // ─────────────────────────────────────────────────────────────────────────────
    // TRANCHE_UNIT
    // ─────────────────────────────────────────────────────────────────────────────

    function assertEq(TRANCHE_UNIT left, TRANCHE_UNIT right, string memory err) internal pure {
        assertEq(toUint256(left), toUint256(right), err);
    }

    function assertNotEq(TRANCHE_UNIT left, TRANCHE_UNIT right, string memory err) internal pure {
        assertNotEq(toUint256(left), toUint256(right), err);
    }

    function assertLt(TRANCHE_UNIT left, TRANCHE_UNIT right, string memory err) internal pure {
        assertLt(toUint256(left), toUint256(right), err);
    }

    function assertLe(TRANCHE_UNIT left, TRANCHE_UNIT right, string memory err) internal pure {
        assertLe(toUint256(left), toUint256(right), err);
    }

    function assertGt(TRANCHE_UNIT left, TRANCHE_UNIT right, string memory err) internal pure {
        assertGt(toUint256(left), toUint256(right), err);
    }

    function assertGe(TRANCHE_UNIT left, TRANCHE_UNIT right, string memory err) internal pure {
        assertGe(toUint256(left), toUint256(right), err);
    }

    function assertApproxEqAbs(TRANCHE_UNIT left, TRANCHE_UNIT right, uint256 maxAbsDelta, string memory err) internal pure {
        assertApproxEqAbs(toUint256(left), toUint256(right), maxAbsDelta, err);
    }

    function assertApproxEqAbs(TRANCHE_UNIT left, TRANCHE_UNIT right, TRANCHE_UNIT maxAbsDelta, string memory err) internal pure {
        assertApproxEqAbs(toUint256(left), toUint256(right), toUint256(maxAbsDelta), err);
    }

    function assertApproxEqRel(TRANCHE_UNIT left, TRANCHE_UNIT right, uint256 maxRelDelta, string memory err) internal pure {
        assertApproxEqRel(toUint256(left), toUint256(right), maxRelDelta, err);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // NAV_UNIT
    // ─────────────────────────────────────────────────────────────────────────────

    function assertEq(NAV_UNIT left, NAV_UNIT right, string memory err) internal pure {
        assertEq(toUint256(left), toUint256(right), err);
    }

    function assertNotEq(NAV_UNIT left, NAV_UNIT right, string memory err) internal pure {
        assertNotEq(toUint256(left), toUint256(right), err);
    }

    function assertLt(NAV_UNIT left, NAV_UNIT right, string memory err) internal pure {
        assertLt(toUint256(left), toUint256(right), err);
    }

    function assertLe(NAV_UNIT left, NAV_UNIT right, string memory err) internal pure {
        assertLe(toUint256(left), toUint256(right), err);
    }

    function assertGt(NAV_UNIT left, NAV_UNIT right, string memory err) internal pure {
        assertGt(toUint256(left), toUint256(right), err);
    }

    function assertGe(NAV_UNIT left, NAV_UNIT right, string memory err) internal pure {
        assertGe(toUint256(left), toUint256(right), err);
    }

    function assertApproxEqAbs(NAV_UNIT left, NAV_UNIT right, uint256 maxAbsDelta, string memory err) internal pure {
        assertApproxEqAbs(toUint256(left), toUint256(right), maxAbsDelta, err);
    }

    function assertApproxEqAbs(NAV_UNIT left, NAV_UNIT right, NAV_UNIT maxAbsDelta, string memory err) internal pure {
        assertApproxEqAbs(toUint256(left), toUint256(right), toUint256(maxAbsDelta), err);
    }

    function assertApproxEqRel(NAV_UNIT left, NAV_UNIT right, uint256 maxRelDelta, string memory err) internal pure {
        assertApproxEqRel(toUint256(left), toUint256(right), maxRelDelta, err);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Protocol invariants
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Asserts the two-term NAV conservation identity `stRaw + jtRaw == stEff + jtEff` at WEI precision.
    /// @dev The spec (CLAUDE.md) guarantees this holds byte-for-byte; the suite asserts it exactly rather than
    ///      with a tolerance so a one-wei attribution leak cannot hide. Use `assertNAVConservationApprox` only
    ///      where a documented, quantified rounding term makes exactness provably unattainable.
    function assertNAVConservation(NAV_UNIT stRaw, NAV_UNIT jtRaw, NAV_UNIT stEff, NAV_UNIT jtEff, string memory ctx) internal pure {
        assertEq(
            toUint256(stRaw) + toUint256(jtRaw),
            toUint256(stEff) + toUint256(jtEff),
            string.concat(ctx, ": NAV conservation violated (stRaw + jtRaw != stEff + jtEff)")
        );
    }

    /// @notice Asserts NAV conservation within an explicit, justified wei tolerance.
    /// @dev Prefer `assertNAVConservation` (exact). This overload exists only for paths with a documented
    ///      rounding bound; callers must pass the smallest defensible `maxAbsDelta` and name the reason in `ctx`.
    function assertNAVConservationApprox(
        NAV_UNIT stRaw,
        NAV_UNIT jtRaw,
        NAV_UNIT stEff,
        NAV_UNIT jtEff,
        uint256 maxAbsDelta,
        string memory ctx
    )
        internal
        pure
    {
        assertApproxEqAbs(
            toUint256(stRaw) + toUint256(jtRaw),
            toUint256(stEff) + toUint256(jtEff),
            maxAbsDelta,
            string.concat(ctx, ": NAV conservation violated beyond tolerance")
        );
    }
}
