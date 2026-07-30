// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
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

/// @dev The max protocol fee percentage on tranche yields, scaled to WAD precision
uint256 constant MAX_PROTOCOL_FEE_WAD = 1e18;

/**
 * @dev The max fraction of the post-mint share supply a single mint may own, scaled to WAD precision
 * @dev Fair pricing keeps every healthy mint far below this bound, it only binds on a deposit into a wiped tranche
 *      (supply alive, backing near zero) where pro-rata pricing would mint an effectively unbounded share count
 * @dev Sits near 100% because a binding mint is essentially the whole tranche: the wiped incumbents keep only sub-dust
 *      paid out of the depositor's pocket, which is why the mint clamps instead of reverting, while the bound still
 *      caps the supply growth per wipe cycle far below the cap math's own overflow cliff
 */
uint256 constant MAX_MINT_DILUTION_WAD = (WAD - 1e6);

/// @dev Constant for the virtual shares injected into the tranche to prevent the first depositor from capturing the pre-existing backing
uint256 constant VIRTUAL_SHARES = 1;

/// @dev Constant for the virtual value backing the virtual shares, denominated in NAV units
NAV_UNIT constant VIRTUAL_VALUE = NAV_UNIT.wrap(1);
