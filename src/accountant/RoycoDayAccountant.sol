// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoAccountant } from "./RoycoAccountant.sol";

/**
 * @title RoycoDayAccountant
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice The Royco Day accountant. Extends the Dawn accountant with (eventually) the LT liquidity premium leg,
 *         LDM resolution, the liquidity metric/gate, and 3-tranche NAV conservation.
 * @dev STUB: currently a behavior-preserving subclass of {RoycoAccountant} so a Day market can be deployed and wired.
 *      It is a separate implementation with its own component bytecode + deploy salt, so live Dawn markets keep
 *      running the existing audited bytecode. LT-specific accounting is added in a later phase.
 */
contract RoycoDayAccountant is RoycoAccountant {
    /// @param _kernel The kernel this accountant maintains accounting for.
    constructor(address _kernel) RoycoAccountant(_kernel) { }
}
