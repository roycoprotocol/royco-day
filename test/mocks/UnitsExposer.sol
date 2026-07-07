// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {
    NAV_UNIT,
    TRANCHE_UNIT,
    RoycoUnitsMath,
    toNAVUnits,
    toTrancheUnits,
    toUint256,
    toInt256
} from "../../src/libraries/Units.sol";

/**
 * @title UnitsExposer
 * @notice Thin external exposer over the typed unit math in Units.sol so a symbolic test can observe reverts
 *         through try/catch and drive every production code path (the wrap/unwrap round trip, the signed wrap
 *         and int256 conversions, the NAV delta, saturating subtraction, minimum, all seven mulDiv overloads,
 *         and the checked arithmetic operators bound to the two unit types)
 * @dev Every function is external and pure so the caller can wrap it in try/catch to characterize its revert
 *      surface. The operator bindings (+, -, /) are exercised through the globally bound free functions, so a
 *      revert here is the exact checked-arithmetic panic a production caller would hit
 */
contract UnitsExposer {
    /*//////////////////////////////////////////////////////////////////////
                            WRAP / UNWRAP ROUND TRIP
    //////////////////////////////////////////////////////////////////////*/

    /// @notice Wraps then unwraps a raw amount as a NAV unit
    function wrapUnwrapNAV(uint256 _x) external pure returns (uint256) {
        return toUint256(toNAVUnits(_x));
    }

    /// @notice Wraps then unwraps a raw amount as a tranche unit
    function wrapUnwrapTranche(uint256 _x) external pure returns (uint256) {
        return toUint256(toTrancheUnits(_x));
    }

    /*//////////////////////////////////////////////////////////////////////
                            SIGNED CONVERSIONS
    //////////////////////////////////////////////////////////////////////*/

    /// @notice Wraps a signed amount as a NAV unit (reverts on a negative input) and unwraps it back to raw
    function signedToNAV(int256 _x) external pure returns (uint256) {
        return toUint256(toNAVUnits(_x));
    }

    /// @notice Unwraps a NAV unit to a signed int256 (reverts when the top bit is set)
    function navToInt256(uint256 _x) external pure returns (int256) {
        return toInt256(toNAVUnits(_x));
    }

    /// @notice Signed difference of two NAV units (reverts when either operand has its top bit set)
    function navDelta(uint256 _a, uint256 _b) external pure returns (int256) {
        return RoycoUnitsMath.computeNAVDelta(toNAVUnits(_a), toNAVUnits(_b));
    }

    /*//////////////////////////////////////////////////////////////////////
                            SATURATING SUB AND MIN
    //////////////////////////////////////////////////////////////////////*/

    /// @notice Clamped subtraction of two NAV units
    function saturatingSubNAV(uint256 _a, uint256 _b) external pure returns (uint256) {
        return toUint256(RoycoUnitsMath.saturatingSub(toNAVUnits(_a), toNAVUnits(_b)));
    }

    /// @notice Minimum of two NAV units
    function minNAV(uint256 _a, uint256 _b) external pure returns (uint256) {
        return toUint256(RoycoUnitsMath.min(toNAVUnits(_a), toNAVUnits(_b)));
    }

    /*//////////////////////////////////////////////////////////////////////
                            THE SEVEN MULDIV OVERLOADS
    //////////////////////////////////////////////////////////////////////*/

    /// @dev The rounding is a literal at every call site below, not a passed parameter, so the compiler folds
    ///      the `unsignedRoundsUp` branch away. For Floor this drops the extra `mulmod` term entirely, leaving
    ///      the plain 256-by-256 quotient the symbolic engine can discharge (matching the proven scale path)

    /// @notice Rounded-down `(a*b)/c` with a, b, c all NAV-denominated
    function mulDivNavNavNavFloor(uint256 _a, uint256 _b, uint256 _c) external pure returns (uint256) {
        return toUint256(RoycoUnitsMath.mulDiv(toNAVUnits(_a), toNAVUnits(_b), toNAVUnits(_c), Math.Rounding.Floor));
    }

    /// @notice Rounded-up `(a*b)/c` with a, b, c all NAV-denominated
    function mulDivNavNavNavCeil(uint256 _a, uint256 _b, uint256 _c) external pure returns (uint256) {
        return toUint256(RoycoUnitsMath.mulDiv(toNAVUnits(_a), toNAVUnits(_b), toNAVUnits(_c), Math.Rounding.Ceil));
    }

    /// @notice Rounded-down `(a*b)/c` with a NAV-denominated and b, c scalars
    function mulDivNavScalarScalarFloor(uint256 _a, uint256 _b, uint256 _c) external pure returns (uint256) {
        return toUint256(RoycoUnitsMath.mulDiv(toNAVUnits(_a), _b, _c, Math.Rounding.Floor));
    }

    /// @notice Rounded-down `(a*b)/c` with a NAV-denominated, b a scalar, c NAV-denominated
    function mulDivNavScalarNavFloor(uint256 _a, uint256 _b, uint256 _c) external pure returns (uint256) {
        return RoycoUnitsMath.mulDiv(toNAVUnits(_a), _b, toNAVUnits(_c), Math.Rounding.Floor);
    }

    /// @notice Rounded-down `(a*b)/c` with a NAV-denominated and b, c tranche-denominated
    function mulDivNavTrancheTrancheFloor(uint256 _a, uint256 _b, uint256 _c) external pure returns (uint256) {
        return toUint256(RoycoUnitsMath.mulDiv(toNAVUnits(_a), toTrancheUnits(_b), toTrancheUnits(_c), Math.Rounding.Floor));
    }

    /// @notice Rounded-down `(a*b)/c` with a tranche-denominated and b, c NAV-denominated
    function mulDivTrancheNavNavFloor(uint256 _a, uint256 _b, uint256 _c) external pure returns (uint256) {
        return toUint256(RoycoUnitsMath.mulDiv(toTrancheUnits(_a), toNAVUnits(_b), toNAVUnits(_c), Math.Rounding.Floor));
    }

    /// @notice Rounded-down `(a*b)/c` with a tranche-denominated and b, c scalars
    function mulDivTrancheScalarScalarFloor(uint256 _a, uint256 _b, uint256 _c) external pure returns (uint256) {
        return toUint256(RoycoUnitsMath.mulDiv(toTrancheUnits(_a), _b, _c, Math.Rounding.Floor));
    }

    /// @notice Rounded-down `(a*b)/c` with a a scalar and b, c NAV-denominated
    function mulDivScalarNavNavFloor(uint256 _a, uint256 _b, uint256 _c) external pure returns (uint256) {
        return RoycoUnitsMath.mulDiv(_a, toNAVUnits(_b), toNAVUnits(_c), Math.Rounding.Floor);
    }

    /*//////////////////////////////////////////////////////////////////////
                            CHECKED OPERATOR BINDINGS
    //////////////////////////////////////////////////////////////////////*/

    /// @notice NAV-unit checked addition (bound `+`)
    function addNAV(uint256 _a, uint256 _b) external pure returns (uint256) {
        return toUint256(toNAVUnits(_a) + toNAVUnits(_b));
    }

    /// @notice NAV-unit checked subtraction (bound `-`)
    function subNAV(uint256 _a, uint256 _b) external pure returns (uint256) {
        return toUint256(toNAVUnits(_a) - toNAVUnits(_b));
    }

    /// @notice NAV-unit checked division (bound `/`)
    function divNAV(uint256 _a, uint256 _b) external pure returns (uint256) {
        return toUint256(toNAVUnits(_a) / toNAVUnits(_b));
    }

    /// @notice Tranche-unit checked addition (bound `+`)
    function addTranche(uint256 _a, uint256 _b) external pure returns (uint256) {
        return toUint256(toTrancheUnits(_a) + toTrancheUnits(_b));
    }

    /// @notice Tranche-unit checked subtraction (bound `-`)
    function subTranche(uint256 _a, uint256 _b) external pure returns (uint256) {
        return toUint256(toTrancheUnits(_a) - toTrancheUnits(_b));
    }

    /// @notice Tranche-unit checked division (bound `/`)
    function divTranche(uint256 _a, uint256 _b) external pure returns (uint256) {
        return toUint256(toTrancheUnits(_a) / toTrancheUnits(_b));
    }
}
