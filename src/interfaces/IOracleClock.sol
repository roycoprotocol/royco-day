// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IOracleClock
 * @notice Interface for oracle clocks that report when a tranche's pricing information last changed
 * @dev An oracle clock is the information clock for the entry point's execution gate: a request queued against a
 *      tranche with a clock can only execute after the clock has observed at least one update following the request,
 *      guaranteeing any information known at request time is priced into the mark before execution
 */
interface IOracleClock {
    /**
     * @notice Observes the underlying source, checkpointing a new update timestamp if its value has changed
     * @dev Permissionless — the entry point pokes on every request and execution, so queue traffic drives the clock
     * @return lastUpdatedAt The timestamp of the last observed update of the underlying source
     */
    function poke() external returns (uint32 lastUpdatedAt);
}
