// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { ITrancheOracleClock } from "../../../interfaces/ITrancheOracleClock.sol";
import { WAD } from "../../../libraries/Constants.sol";

/**
 * @title OracleCheckpointClockBase
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Abstract oracle clock for pull-based pricing sources that expose only a current value with no update timestamp
 * @dev Each poke reads the source and checkpoints a new update timestamp when the value has deviated beyond the configured threshold since the last checkpoint,
 *      deriving the update times the source itself does not report
 *      A missed round trip (the value changing and reverting between pokes) goes unobserved, which only delays the clock — it can never advance without an
 *      observed change, so the entry point's execution gate never opens falsely
 *      Concrete clocks implement _readSource and must call _seedCheckpoint at the end of construction, after their read wiring is set
 */
abstract contract OracleCheckpointClockBase is ITrancheOracleClock {
    using Math for uint256;

    /// @notice The minimum relative deviation from the checkpointed value that counts as an update, scaled to WAD precision (zero counts any change)
    uint256 public immutable MIN_DEVIATION_WAD;

    /// @notice The value observed at the last checkpoint
    uint256 public lastValue;

    /// @notice The timestamp of the last checkpoint
    uint32 public lastUpdatedAt;

    /**
     * @notice Emitted when a poke observes a deviated value and checkpoints it
     * @param value The newly checkpointed value
     * @param updatedAt The timestamp of the checkpoint
     */
    event Checkpointed(uint256 value, uint32 updatedAt);

    /// @notice Constructs the base checkpoint clock state
    /// @param _minDeviationWAD The minimum relative deviation that counts as an update, scaled to WAD precision (zero counts any change)
    constructor(uint256 _minDeviationWAD) {
        // Set the immutable state
        MIN_DEVIATION_WAD = _minDeviationWAD;
    }

    /// @inheritdoc ITrancheOracleClock
    function poke() external override(ITrancheOracleClock) returns (uint32) {
        // Read the source and checkpoint the value if it deviated beyond the threshold since the last checkpoint
        uint256 value = _readSource();
        if (_hasDeviated(value, lastValue)) {
            lastValue = value;
            lastUpdatedAt = uint32(block.timestamp);
            emit Checkpointed(value, uint32(block.timestamp));
        }
        return lastUpdatedAt;
    }

    /**
     * @notice Seeds the first checkpoint so the clock starts at construction time
     * @dev Must be called at the end of the concrete clock's constructor, after its read wiring is set — the base constructor cannot seed itself
     *      because _readSource dispatches into the concrete clock before its immutables are assigned
     */
    function _seedCheckpoint() internal {
        lastValue = _readSource();
        lastUpdatedAt = uint32(block.timestamp);
    }

    /**
     * @notice Returns whether the observed value deviated from the checkpointed value beyond the configured threshold
     * @param _value The value observed by this poke
     * @param _checkpointValue The value observed at the last checkpoint
     * @return Whether the deviation counts as an update
     */
    function _hasDeviated(uint256 _value, uint256 _checkpointValue) internal view returns (bool) {
        if (_value == _checkpointValue) return false;
        // Any change counts when no threshold is configured, and any change from zero is a full deviation
        if (MIN_DEVIATION_WAD == 0 || _checkpointValue == 0) return true;
        uint256 delta = (_value > _checkpointValue) ? (_value - _checkpointValue) : (_checkpointValue - _value);
        return WAD.mulDiv(delta, _checkpointValue) >= MIN_DEVIATION_WAD;
    }

    /// @notice Reads the source's current value, implemented by the concrete clock
    /// @return value The source's current value
    function _readSource() internal view virtual returns (uint256 value);
}
