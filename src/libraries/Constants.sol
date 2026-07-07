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
 * @dev The mint-dilution residual, scaled to WAD precision: the fraction of the POST-mint share supply that
 *      pre-existing holders are guaranteed to retain against any single share mint. 1e6 WAD = a residual of
 *      1e-12, i.e. one mint may own at most (1 - 1e-12) of the post-mint supply, so a single mint never grows
 *      the supply by more than a factor of (WAD - residual) / residual = 1e12 - 1.
 *
 *      Why 1e-12 specifically:
 *      - Capture stays economically total: wiped holders collectively retain <= 1e-12 of any future recovery,
 *        which is below one NAV wei for any tranche NAV under 1e12 wei per wei of claim and at or below the
 *        market dust tolerances for all realistic NAVs (a tranche that recovers to 1e30 NAV wei leaves them
 *        1e18 wei - one token's worth of dust across all wiped holders together).
 *      - A clamped depositor's loss is bounded by residual x deposit: the clamp can only bind when the entire
 *        pre-existing tranche is worth less than ~1e-12 of the deposit, so the depositor forgoes at most
 *        ~1e-12 of its own contribution (a 10M-token deposit loses at most ~1e-5 tokens). This is why the
 *        clamp can safely CLAMP rather than revert: no measurable value is ever taken from anyone.
 *      - Supply growth per wipe cycle is bounded at x(1e12 - 1) (~40 bits), so the uint256 overflow cliff at
 *        supply ~1.16e65 (where the cap computation itself no longer fits) is ~4 total-annihilation cycles
 *        away instead of ~3 unbounded ones - and a market wiped four times over is not underwritable anyway
 *        (accepted residual risk; pinned by test_FINDING_11 rather than removed with an absolute ceiling)
 */
uint256 constant MINT_DILUTION_RESIDUAL_WAD = 1e6;

/// @dev The execution delay for the operational admin roles that change a live market's configuration (the
///      kernel, accountant, protocol fee setter, unpauser, oracle quoter, market ops, and Balancer pool manager
///      roles). Two days is the common operational timelock.
uint32 constant SHORT_DELAY_SECONDS = 2 days;

/// @dev The root admin's execution delay on the AccessManager, the grant delay on the consequential roles, and
///      the target admin delay on every deployed proxy. Fourteen days is the conservative delay for changes that
///      restructure the system.
uint32 constant LONG_DELAY_SECONDS = 14 days;

// NOTE: the deploy asserts the long delay is at least this cap, and the accountant rejects any fixed term above it, so
// at deploy a committed user can always exit before a governance change takes effect. The reverse is not checked
// anywhere: the long delay lives in the AccessManager, and nothing rejects a later reduction of it below this cap. If
// the long delay is ever lowered below the maximum fixed term, a user committed for the full term could be locked in
// past the point a change takes effect. Keep the long delay at least this cap; if the delay ever becomes adjustable
// from a Day contract, enforce this there.

/// @dev The maximum fixed-term duration any market may carry. The long delay must be at least this, so a
///      governance change cannot take effect faster than a committed user can exit; ten days leaves a four-day
///      margin under the fourteen-day long delay.
uint32 constant MAX_FIXED_TERM_SECONDS = 10 days;
