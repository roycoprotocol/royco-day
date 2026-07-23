// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { NAV_UNIT, TRANCHE_UNIT } from "./Units.sol";

/// @dev Constant for 0 NAV units
NAV_UNIT constant ZERO_NAV_UNITS = NAV_UNIT.wrap(0);

/// @dev Constant for 1 NAV unit
NAV_UNIT constant ONE_NAV_UNIT = NAV_UNIT.wrap(1);

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
 * @dev The max mint dilution, scaled to WAD precision: the largest fraction of the POST-mint share supply a
 *      single mint may own ((WAD - 1e6) / WAD = 1 - 1e-12), flipped around: pre-existing holders always
 *      collectively retain at least the 1e-12 complement, however large the deposit, so one mint can grow
 *      the supply by at most a factor of 1e12 - 1
 *
 *      Fair pro-rata pricing keeps every mint far below this ceiling on its own (owning 1 - 1e-12 of a
 *      healthy tranche costs ~1e12x its entire value)
 *      The cap only ever binds in one degenerate state - a
 *      deposit into a wiped tranche (supply alive, NAV ~ 0) - where pro-rata pricing divides by ~zero and
 *      would mint effectively unbounded shares
 *
 *      Why the ceiling sits this close to 100%: when it binds, the incumbents' shares are genuinely
 *      worthless and the depositor's fresh capital IS essentially the whole tranche, so the depositor
 *      fairly owns ~all of it - whatever incumbents keep is paid out of the depositor's pocket. 1e-12
 *      makes that transfer economically invisible while staying numerically load-bearing:
 *      - Invisible: wiped holders keep <= 1e-12 of any recovery (sub-dust at any realistic NAV), and the
 *        clamped depositor forgoes at most 1e-12 of its own deposit, no one loses measurable value, which is
 *        why the mint clamps rather than reverts
 *      - Load-bearing: supply grows at most ~2^40 per wipe-and-redeposit cycle (unbounded, three cycles
 *        empirically pushed supply to ~1e77 and bricked every later mint), keeping the cap math's own
 *        overflow cliff (supply ~1.16e65) ~4 annihilation cycles away - and a market wiped four times over is likely
 *        not underwritable anyway
 */
uint256 constant MAX_MINT_DILUTION_WAD = WAD - 1e6;

/// @dev Constant for the virtual shares injected into the tranche to prevent the first depositor from capturing the pre-existing backing
/// @dev Set to 1e6 to discourage a fair share of the 18 decimals precision of the NAV units for the virtual shares
uint256 constant VIRTUAL_SHARES = 1e6;

/// @dev Constant for the virtual value backing the virtual shares, denominated in NAV units
NAV_UNIT constant VIRTUAL_VALUE = ONE_NAV_UNIT;
