// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoBase } from "../../../base/RoycoBase.sol";
import { IOracleClock } from "../../../interfaces/IOracleClock.sol";
import { WAD } from "../../../libraries/Constants.sol";

/**
 * @title OracleCheckpointClockBase
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Abstract oracle clock for pull-based pricing sources that expose only a current value with no update timestamp
 * @dev Each poke reads the source and checkpoints a new update timestamp when the value has deviated beyond the configured threshold since the last checkpoint,
 *      deriving the update times the source itself does not report
 *      A missed round trip (the value changing and reverting between pokes) goes unobserved, which only delays the clock — it can never advance without an
 *      observed change, so the entry point's execution gate never opens falsely
 *      Concrete clocks implement _readSource and initialize the base via __OracleCheckpointClockBase_init_unchained, which seeds the first checkpoint
 */
abstract contract OracleCheckpointClockBase is RoycoBase, IOracleClock {
    using Math for uint256;

    /// @dev Storage slot for OracleCheckpointClockBaseState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.OracleCheckpointClockBaseState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ORACLE_CHECKPOINT_CLOCK_BASE_STORAGE_SLOT = 0xa682b467b794ac04ad0ae81cdd5d19290cac44f38027b63b9b08663f46a6ec00;

    /**
     * @dev Storage state for the Royco oracle checkpoint clock
     * @custom:storage-location erc7201:Royco.storage.OracleCheckpointClockBaseState
     * @custom:field minDeviationWAD - The minimum relative deviation from the checkpointed value that counts as an update, scaled to WAD precision (zero counts any change)
     * @custom:field lastValue - The value observed at the last checkpoint
     * @custom:field lastUpdatedAt - The timestamp of the last checkpoint
     */
    struct OracleCheckpointClockBaseState {
        uint256 minDeviationWAD;
        uint256 lastValue;
        uint32 lastUpdatedAt;
    }

    /// @notice Emitted when a poke observes a deviated value and checkpoints it
    /// @param value The newly checkpointed value
    event Checkpointed(uint256 value);

    /// @notice Emitted when the minimum deviation threshold is updated
    event MinDeviationUpdated(uint256 minDeviationWAD);

    /// @notice Thrown when the source oracle returns an invalid update timestamp
    error INVALID_ORACLE();

    /// @notice Thrown when the minimum deviation threshold is not strictly less than 100% (WAD)
    error INVALID_MIN_DEVIATION_WAD();

    /**
     * @notice Initializes the oracle checkpoint clock state and seeds the first checkpoint
     * @dev Must be called after the concrete clock's read wiring is set so the seed poke observes the live source
     *      A source reading zero at initialization leaves the clock not live (a zero last updated timestamp) until its
     *      first nonzero observation — the entry point refuses to configure or request against a not-live clock
     * @param _minDeviationWAD The minimum relative deviation that counts as an update, scaled to WAD precision (zero counts any change)
     */
    function __OracleCheckpointClockBase_init_unchained(uint256 _minDeviationWAD) internal onlyInitializing {
        // Initialize the minimum deviation
        _setMinDeviationWAD(_minDeviationWAD);
        // Seed the first checkpoint so the clock starts live at initialization time
        require(poke() > 0, INVALID_ORACLE());
    }

    /// @inheritdoc IOracleClock
    function poke() public override(IOracleClock) returns (uint32 lastUpdatedAt) {
        // Read the source and checkpoint the value if it deviated beyond the threshold since the last checkpoint
        OracleCheckpointClockBaseState storage $ = _getOracleCheckpointClockBaseStorage();
        uint256 value = _readSource();
        if (_hasDeviated(value, $.lastValue, $.minDeviationWAD)) {
            $.lastValue = value;
            $.lastUpdatedAt = uint32(block.timestamp);
            emit Checkpointed(value);
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
        _getOracleCheckpointClockBaseStorage().minDeviationWAD = _minDeviationWAD;
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
        // Any change counts when no threshold is configured, and any change from zero is a full deviation
        if (_minDeviationWAD == 0 || _checkpointValue == 0) return true;
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
