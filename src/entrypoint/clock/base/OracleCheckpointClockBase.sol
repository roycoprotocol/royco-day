// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { RoycoBase } from "../../../base/RoycoBase.sol";
import { IOracleClock } from "../../../interfaces/IOracleClock.sol";
import { WAD } from "../../../libraries/Constants.sol";

/**
 * @title OracleCheckpointClockBase
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Abstract oracle clock for pull-based pricing sources that expose only a current value with no update timestamp
 * @dev Each poke reads the source and checkpoints a new update timestamp when the value has deviated beyond the configured threshold since the last checkpoint, deriving conservative update times for the source
 */
abstract contract OracleCheckpointClockBase is RoycoBase, IOracleClock {
    using Math for uint256;
    using SafeCast for uint256;

    /// @dev Storage slot for OracleCheckpointClockBaseState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.OracleCheckpointClockBaseState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ORACLE_CHECKPOINT_CLOCK_BASE_STORAGE_SLOT = 0xa682b467b794ac04ad0ae81cdd5d19290cac44f38027b63b9b08663f46a6ec00;

    /**
     * @dev Storage state for the Royco oracle checkpoint clock, packed into a single word
     * @custom:storage-location erc7201:Royco.storage.OracleCheckpointClockBaseState
     * @custom:field minDeviationWAD - The minimum relative deviation from the checkpointed value that counts as an update, scaled to WAD precision (zero counts any change)
     * @custom:field lastValue - The value observed at the last checkpoint (the initialization baseline before the first deviation)
     * @custom:field lastUpdatedAt - The timestamp of the last checkpoint (zero until the first observed deviation)
     */
    struct OracleCheckpointClockBaseState {
        uint64 minDeviationWAD;
        uint160 lastValue;
        uint32 lastUpdatedAt;
    }

    /// @notice Emitted when the minimum deviation threshold is updated
    event MinDeviationUpdated(uint256 minDeviationWAD);

    /// @notice Thrown when the minimum deviation threshold is not strictly less than 100% (WAD)
    error INVALID_MIN_DEVIATION_WAD();

    /**
     * @notice Initializes the oracle checkpoint clock state and records the source's current value as the baseline
     * @dev Must be called after the concrete clock's read wiring is set so the baseline read observes the live source
     * @dev The baseline is recorded WITHOUT an update timestamp: an initialization read carries no new pricing information, so recording it would be incorrect
     * @param _minDeviationWAD The minimum relative deviation from the checkpointed value that counts as an update, scaled to WAD precision (zero counts any change)
     */
    function __OracleCheckpointClockBase_init_unchained(uint256 _minDeviationWAD) internal onlyInitializing {
        // Initialize the minimum deviation
        _setMinDeviationWAD(_minDeviationWAD);
        // Record the baseline value so the first deviation is measured against the source's state at initialization
        _getOracleCheckpointClockBaseStorage().lastValue = _readSource().toUint160();
    }

    /// @inheritdoc IOracleClock
    function poke() public override(IOracleClock) returns (uint32 lastUpdatedAt) {
        OracleCheckpointClockBaseState storage $ = _getOracleCheckpointClockBaseStorage();
        // Query the current value of the oracle, and update the checkpoint and clock if it deviated
        uint256 value = _readSource();
        if (_hasDeviated(value, $.lastValue, $.minDeviationWAD)) {
            ($.lastValue, $.lastUpdatedAt) = (value.toUint160(), uint32(block.timestamp));
        }
        return $.lastUpdatedAt;
    }

    /// @notice Sets the minimum deviation threshold that counts as an update
    /// @param _minDeviationWAD The new minimum relative deviation, scaled to WAD precision (zero counts any change)
    function setMinDeviationWAD(uint256 _minDeviationWAD) external restricted {
        _setMinDeviationWAD(_minDeviationWAD);
    }

    /// @notice Returns the oracle checkpoint clock state
    /// @return state The oracle checkpoint clock state
    function getOracleCheckpointClockState() external view returns (OracleCheckpointClockBaseState memory state) {
        return _getOracleCheckpointClockBaseStorage();
    }

    /**
     * @notice Sets the new minimum deviation threshold
     * @dev A threshold at or above 100% would mute all downward updates (a downward deviation caps at exactly WAD), making the clock asymmetric
     * @param _minDeviationWAD The new minimum relative deviation, scaled to WAD precision
     */
    function _setMinDeviationWAD(uint256 _minDeviationWAD) internal {
        require(_minDeviationWAD < WAD, INVALID_MIN_DEVIATION_WAD());
        // The threshold is bounded strictly under WAD, so the narrowing cast can never truncate
        _getOracleCheckpointClockBaseStorage().minDeviationWAD = uint64(_minDeviationWAD);
        emit MinDeviationUpdated(_minDeviationWAD);
    }

    /**
     * @notice Returns whether the observed value deviated from the checkpointed value beyond the configured threshold
     * @param _value The value observed by this poke
     * @param _checkpointValue The value observed at the last checkpoint
     * @param _minDeviationWAD The minimum relative deviation that counts as an update, scaled to WAD precision
     * @return deviated Whether the deviation counts as an update
     */
    function _hasDeviated(uint256 _value, uint256 _checkpointValue, uint256 _minDeviationWAD) internal pure returns (bool deviated) {
        if (_value == _checkpointValue) return false;
        if (_minDeviationWAD == 0) return true;
        uint256 delta = (_value > _checkpointValue) ? (_value - _checkpointValue) : (_checkpointValue - _value);
        return (WAD.mulDiv(delta, _checkpointValue) >= _minDeviationWAD);
    }

    /// @notice Reads the source's current value, implemented by the concrete clock
    /// @return value The source's current value
    function _readSource() internal view virtual returns (uint256 value);

    /**
     * @notice Returns a storage pointer to the OracleCheckpointClockBaseState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer
     */
    function _getOracleCheckpointClockBaseStorage() private pure returns (OracleCheckpointClockBaseState storage $) {
        assembly ("memory-safe") {
            $.slot := ORACLE_CHECKPOINT_CLOCK_BASE_STORAGE_SLOT
        }
    }
}
