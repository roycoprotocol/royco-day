// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { NAV_UNIT, TRANCHE_UNIT } from "./Units.sol";

/// @dev Constant for 0 NAV units
NAV_UNIT constant ZERO_NAV_UNITS = NAV_UNIT.wrap(0);

/// @dev Constant for the max value expressable as NAV units
NAV_UNIT constant MAX_NAV_UNITS = NAV_UNIT.wrap(type(uint256).max);

/// @dev Constant for 0 tranche units
TRANCHE_UNIT constant ZERO_TRANCHE_UNITS = TRANCHE_UNIT.wrap(0);

/// @dev Constant for the max value expressable as tranche units
TRANCHE_UNIT constant MAX_TRANCHE_UNITS = TRANCHE_UNIT.wrap(type(uint256).max);

/// @dev Constant for the WAD scaling factor
uint256 constant WAD = 1e18;

/// @dev Constant for the WAD scaling factor as an integer
int256 constant WAD_INT = int256(WAD);

/// @dev Constant for the number of decimals of precision a WAD denominated quantity has
uint256 constant WAD_DECIMALS = 18;

/// @dev The minimum configurable minimum coverage percentage (1%), scaled to WAD precision
uint256 constant MIN_COVERAGE_LOWER_BOUND_WAD = 0.01e18;

/// @dev The maximum configurable minimum coverage percentage (~100%), scaled to WAD precision
uint256 constant MIN_COVERAGE_UPPER_BOUND_WAD = 1e18 - 1;

/// @dev The maximum configurable coverage percentage (~100%), scaled to WAD precision
uint256 constant MIN_LIQUIDITY_UPPER_BOUND_WAD = 1e18 - 1;

/// @dev The max protocol fee percentage on tranche yields, scaled to WAD precision
uint256 constant MAX_PROTOCOL_FEE_WAD = 1e18;
