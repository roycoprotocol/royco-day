// SPDX-License-Identifier: UNLICENSED
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
 *      single mint may own ((WAD - 1e6) / WAD = 1 - 1e-12) — flipped around: pre-existing holders always
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
 *        clamped depositor forgoes at most 1e-12 of its own deposit — no one loses measurable value, which is
 *        why the mint clamps rather than reverts
 *      - Load-bearing: supply grows at most ~2^40 per wipe-and-redeposit cycle (unbounded, three cycles
 *        empirically pushed supply to ~1e77 and bricked every later mint), keeping the cap math's own
 *        overflow cliff (supply ~1.16e65) ~4 annihilation cycles away - and a market wiped four times over is likely
 *        not underwritable anyway
 */
uint256 constant MAX_MINT_DILUTION_WAD = WAD - 1e6;

/// @dev The execution delay for the operational admin roles that change a live market's configuration (the
///      kernel, accountant, protocol fee setter, unpauser, oracle quoter, market ops, and Balancer pool manager
///      roles). It is the common operational timelock.
uint32 constant SHORT_DELAY_SECONDS = 2 days;

/// @dev The root admin's execution delay on the AccessManager, the grant delay on the consequential roles, and
///      the target admin delay on every deployed proxy. It is the conservative delay for changes that
///      restructure the system.
uint32 constant LONG_DELAY_SECONDS = 15 days;

// NOTE: the deploy asserts the long delay is at least this cap, and the accountant rejects any fixed term above it, so
// at deploy a committed user can always exit before a governance change takes effect. A later reduction of the long
// delay below this cap cannot take effect faster than the long delay itself, so the cap is self-protecting through the
// AccessManager and needs no separate runtime check: the AccessManager applies every delay change through
// Time.Delay.withUpdate, which makes a reduction wait a setback equal to the amount reduced, and every admin path that
// could reduce it is itself bounded by the long delay (the governance admin's execution delay is the long delay, and
// the factory's retained admin can only be driven by a registered template, whose registration now waits the long
// delay). Keep the long delay at least this cap at deploy.

/// @dev The maximum fixed-term duration any market may carry. The long delay must be at least this, so a
///      governance change cannot take effect faster than a committed user can exit.
uint32 constant MAX_FIXED_TERM_SECONDS = 14 days;
