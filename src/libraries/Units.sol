// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @notice Common unit of account for Royco NAV values (e.g., USD, BTC) used consistently across a market's tranches
 * @dev `NAV_UNIT` must be expressed in the same underlying unit and precision for both ST and JT within a market
 * @dev `NAV_UNIT` always has WAD decimals (18) of precision
 */
type NAV_UNIT is uint256;

/// @notice Unit for tranche asset amounts (native token units for a specific tranche)
/// @dev `TRANCHE_UNIT` always has the same precision as the asset it represents (base asset of the tranche)
type TRANCHE_UNIT is uint256;

/**
 * @title RoycoUnitsMath
 * @notice Typed math helpers for Royco units (NAV_UNIT and TRANCHE_UNIT)
 * @dev Wraps OpenZeppelin Math helpers and preserves unit typing on return values
 */
library RoycoUnitsMath {
    /// @notice Returns the minimum of two NAV-denominated quantities
    function min(NAV_UNIT _a, NAV_UNIT _b) internal pure returns (NAV_UNIT) {
        return toNAVUnits(Math.min(toUint256(_a), toUint256(_b)));
    }

    /// @notice Returns the minimum of two tranche-denominated quantities
    function min(TRANCHE_UNIT _a, TRANCHE_UNIT _b) internal pure returns (TRANCHE_UNIT) {
        return toTrancheUnits(Math.min(toUint256(_a), toUint256(_b)));
    }

    /// @notice Returns the signed delta `_a - _b` for NAV-denominated quantities
    function computeNAVDelta(NAV_UNIT _a, NAV_UNIT _b) internal pure returns (int256) {
        return (toInt256(_a) - toInt256(_b));
    }

    /// @notice Returns `max(_a - _b, 0)` for NAV-denominated quantities
    function saturatingSub(NAV_UNIT _a, NAV_UNIT _b) internal pure returns (NAV_UNIT) {
        return toNAVUnits(Math.saturatingSub(toUint256(_a), toUint256(_b)));
    }

    /// @notice Returns `(_a * _b) / _c` for NAV-denominated quantities with explicit rounding
    function mulDiv(NAV_UNIT _a, NAV_UNIT _b, NAV_UNIT _c, Math.Rounding _rounding) internal pure returns (NAV_UNIT) {
        return toNAVUnits(Math.mulDiv(toUint256(_a), toUint256(_b), toUint256(_c), _rounding));
    }

    /// @notice Returns `(_a * _b) / _c` where `_a` is NAV-denominated and `_b`/`_c` are scalars, with explicit rounding
    function mulDiv(NAV_UNIT _a, uint256 _b, uint256 _c, Math.Rounding _rounding) internal pure returns (NAV_UNIT) {
        return toNAVUnits(Math.mulDiv(toUint256(_a), _b, _c, _rounding));
    }

    /// @notice Returns `(_a * _b) / _c` where `_a`/`_c` are NAV-denominated and `_b` is a scalar, with explicit rounding
    function mulDiv(NAV_UNIT _a, uint256 _b, NAV_UNIT _c, Math.Rounding _rounding) internal pure returns (uint256) {
        return Math.mulDiv(toUint256(_a), _b, toUint256(_c), _rounding);
    }

    /// @notice Returns `(_a * _b) / _c` where `_a` is NAV-denominated and `_b`/`_c` are tranche-denominated, with explicit rounding
    function mulDiv(NAV_UNIT _a, TRANCHE_UNIT _b, TRANCHE_UNIT _c, Math.Rounding _rounding) internal pure returns (NAV_UNIT) {
        return toNAVUnits(Math.mulDiv(toUint256(_a), toUint256(_b), toUint256(_c), _rounding));
    }

    /// @notice Returns `(_a * _b) / _c` where `_a` is tranche-denominated and `_b`/`_c` are NAV-denominated, with explicit rounding
    function mulDiv(TRANCHE_UNIT _a, NAV_UNIT _b, NAV_UNIT _c, Math.Rounding _rounding) internal pure returns (TRANCHE_UNIT) {
        return toTrancheUnits(Math.mulDiv(toUint256(_a), toUint256(_b), toUint256(_c), _rounding));
    }

    /// @notice Returns `(_a * _b) / _c` where `_a` is tranche-denominated and `_b`/`_c` are scalars, with explicit rounding
    function mulDiv(TRANCHE_UNIT _a, uint256 _b, uint256 _c, Math.Rounding _rounding) internal pure returns (TRANCHE_UNIT) {
        return toTrancheUnits(Math.mulDiv(toUint256(_a), _b, _c, _rounding));
    }

    /// @notice Returns `(_a * _b) / _c` where `_a` is a scalar and `_b`/`_c` are NAV-denominated, with explicit rounding
    function mulDiv(uint256 _a, NAV_UNIT _b, NAV_UNIT _c, Math.Rounding _rounding) internal pure returns (uint256) {
        return Math.mulDiv(_a, toUint256(_b), toUint256(_c), _rounding);
    }
}

/**
 * -----------------------------------------------------------------------
 * Global NAV_UNIT Helpers
 * -----------------------------------------------------------------------
 */

/// @notice Wraps a raw `uint256` amount as a `NAV_UNIT`
function toNAVUnits(uint256 _assets) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(_assets);
}

/// @notice Thrown when a signed NAV amount that must be non-negative is negative, or a `NAV_UNIT` exceeds the int256 range
error ASSETS_MUST_BE_NON_NEGATIVE();

/// @notice Wraps a signed `int256` amount as a `NAV_UNIT`, reverting if negative
function toNAVUnits(int256 _assets) pure returns (NAV_UNIT) {
    require(_assets >= 0, ASSETS_MUST_BE_NON_NEGATIVE());
    // forge-lint: disable-next-line(unsafe-typecast)
    return NAV_UNIT.wrap(uint256(_assets));
}

/// @notice Unwraps a `NAV_UNIT` to its raw `uint256` value
function toUint256(NAV_UNIT _units) pure returns (uint256) {
    return NAV_UNIT.unwrap(_units);
}

/// @notice Unwraps a `NAV_UNIT` to a signed `int256`, reverting if it exceeds the int256 range
function toInt256(NAV_UNIT _units) pure returns (int256 assets) {
    // Ensure there was no overflow in the cast
    require((assets = int256(NAV_UNIT.unwrap(_units))) >= 0, ASSETS_MUST_BE_NON_NEGATIVE());
}

/// @notice Adds two NAV-denominated quantities (bound to the `+` operator)
function addNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(NAV_UNIT.unwrap(_a) + NAV_UNIT.unwrap(_b));
}

/// @notice Subtracts one NAV-denominated quantity from another (bound to the `-` operator)
function subNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(NAV_UNIT.unwrap(_a) - NAV_UNIT.unwrap(_b));
}

/// @notice Multiplies two NAV-denominated quantities as raw values (bound to the `*` operator)
function mulNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(NAV_UNIT.unwrap(_a) * NAV_UNIT.unwrap(_b));
}

/// @notice Divides one NAV-denominated quantity by another as raw values (bound to the `/` operator)
function divNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(NAV_UNIT.unwrap(_a) / NAV_UNIT.unwrap(_b));
}

/// @notice Returns whether `_a` is strictly less than `_b` (bound to the `<` operator)
function lessThanNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) < NAV_UNIT.unwrap(_b);
}

/// @notice Returns whether `_a` is less than or equal to `_b` (bound to the `<=` operator)
function lessThanOrEqualToNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) <= NAV_UNIT.unwrap(_b);
}

/// @notice Returns whether `_a` is strictly greater than `_b` (bound to the `>` operator)
function greaterThanNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) > NAV_UNIT.unwrap(_b);
}

/// @notice Returns whether `_a` is greater than or equal to `_b` (bound to the `>=` operator)
function greaterThanOrEqualToNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) >= NAV_UNIT.unwrap(_b);
}

/// @notice Returns whether `_a` equals `_b` (bound to the `==` operator)
function equalsNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) == NAV_UNIT.unwrap(_b);
}

/// @notice Returns whether `_a` does not equal `_b` (bound to the `!=` operator)
function notEqualsNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) != NAV_UNIT.unwrap(_b);
}

/// @dev Binds the arithmetic and comparison operators above to `NAV_UNIT` globally
using {
    addNAVUnits as +,
    subNAVUnits as -,
    mulNAVUnits as *,
    divNAVUnits as /,
    lessThanNAVUnits as <,
    lessThanOrEqualToNAVUnits as <=,
    greaterThanNAVUnits as >,
    greaterThanOrEqualToNAVUnits as >=,
    equalsNAVUnits as ==,
    notEqualsNAVUnits as !=
} for NAV_UNIT global;

/**
 * -----------------------------------------------------------------------
 * Global TRANCHE_UNIT Helpers
 * -----------------------------------------------------------------------
 */

/// @notice Wraps a raw `uint256` amount as a `TRANCHE_UNIT`
function toTrancheUnits(uint256 _assets) pure returns (TRANCHE_UNIT) {
    return TRANCHE_UNIT.wrap(_assets);
}

/// @notice Unwraps a `TRANCHE_UNIT` to its raw `uint256` value
function toUint256(TRANCHE_UNIT _units) pure returns (uint256) {
    return TRANCHE_UNIT.unwrap(_units);
}

/// @notice Adds two tranche-denominated quantities (bound to the `+` operator)
function addTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (TRANCHE_UNIT) {
    return TRANCHE_UNIT.wrap(TRANCHE_UNIT.unwrap(_a) + TRANCHE_UNIT.unwrap(_b));
}

/// @notice Subtracts one tranche-denominated quantity from another (bound to the `-` operator)
function subTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (TRANCHE_UNIT) {
    return TRANCHE_UNIT.wrap(TRANCHE_UNIT.unwrap(_a) - TRANCHE_UNIT.unwrap(_b));
}

/// @notice Multiplies two tranche-denominated quantities as raw values (bound to the `*` operator)
function mulTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (TRANCHE_UNIT) {
    return TRANCHE_UNIT.wrap(TRANCHE_UNIT.unwrap(_a) * TRANCHE_UNIT.unwrap(_b));
}

/// @notice Divides one tranche-denominated quantity by another as raw values (bound to the `/` operator)
function divTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (TRANCHE_UNIT) {
    return TRANCHE_UNIT.wrap(TRANCHE_UNIT.unwrap(_a) / TRANCHE_UNIT.unwrap(_b));
}

/// @notice Returns whether `_a` is strictly less than `_b` (bound to the `<` operator)
function lessThanTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) < TRANCHE_UNIT.unwrap(_b);
}

/// @notice Returns whether `_a` is less than or equal to `_b` (bound to the `<=` operator)
function lessThanOrEqualToTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) <= TRANCHE_UNIT.unwrap(_b);
}

/// @notice Returns whether `_a` is strictly greater than `_b` (bound to the `>` operator)
function greaterThanTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) > TRANCHE_UNIT.unwrap(_b);
}

/// @notice Returns whether `_a` is greater than or equal to `_b` (bound to the `>=` operator)
function greaterThanOrEqualToTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) >= TRANCHE_UNIT.unwrap(_b);
}

/// @notice Returns whether `_a` equals `_b` (bound to the `==` operator)
function equalsTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) == TRANCHE_UNIT.unwrap(_b);
}

/// @notice Returns whether `_a` does not equal `_b` (bound to the `!=` operator)
function notEqualsTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) != TRANCHE_UNIT.unwrap(_b);
}

/// @dev Binds the arithmetic and comparison operators above to `TRANCHE_UNIT` globally
using {
    addTrancheUnits as +,
    subTrancheUnits as -,
    mulTrancheUnits as *,
    divTrancheUnits as /,
    lessThanTrancheUnits as <,
    lessThanOrEqualToTrancheUnits as <=,
    greaterThanTrancheUnits as >,
    greaterThanOrEqualToTrancheUnits as >=,
    equalsTrancheUnits as ==,
    notEqualsTrancheUnits as !=
} for TRANCHE_UNIT global;
