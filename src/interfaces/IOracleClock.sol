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
     * @dev Permissionless — the entry point pokes on every request and execution, so queue traffic organically drives the clock
     * @dev MUST report only honest update times: the wall-clock timestamp of a genuine source update, and zero when none has
     *      been observed yet — never a manufactured (initialization-time) or future timestamp. The entry point's execution
     *      gate compares this directly against request placement times, so a manufactured timestamp would open the gate
     *      without new pricing information, and a zero conservatively holds it shut
     * @return lastUpdatedAt The timestamp of the last observed update of the underlying source (zero if none observed yet)
     */
    function poke() external returns (uint32 lastUpdatedAt);

    /// @notice Gets the description of the oracle clock
    /// @return clockDescription The description of the oracle clock
    function description() external view returns (string memory clockDescription);
}
