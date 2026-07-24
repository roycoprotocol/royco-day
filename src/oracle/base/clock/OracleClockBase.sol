// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { RoycoBase } from "../../../base/RoycoBase.sol";
import { WAD } from "../../../libraries/Constants.sol";

/**
 * @title OracleClockBase
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Abstract oracle clock for pull-based pricing sources that expose only a current value with no update timestamp
 * @dev Each poke reads the source and checkpoints a new update timestamp when the value has deviated beyond the configured threshold since the last checkpoint, deriving conservative update times for the source
 */
abstract contract OracleClockBase is RoycoBase {
    using Math for uint256;
    using SafeCast for uint256;

    /// @dev Storage slot for OracleClockBaseState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.OracleClockBaseState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ORACLE_CLOCK_BASE_STORAGE_SLOT = 0x60d48f2f15caf05f6b544c545208056627dce709084702465248e587970ac900;

    /**
     * @dev Storage state for the Royco oracle checkpoint clock, packed into a single word
     * @custom:storage-location erc7201:Royco.storage.OracleClockBaseState
     * @custom:field minDeviationWAD - The minimum relative deviation from the checkpointed value that counts as an update, scaled to WAD precision (zero counts any change)
     * @custom:field lastValue - The value observed at the last checkpoint (the initialization baseline before the first deviation)
     * @custom:field lastUpdatedAt - The timestamp of the last checkpoint (zero until the first observed deviation)
     */
    struct OracleClockBaseState {
        uint64 minDeviationWAD;
        uint160 lastValue;
        uint32 lastUpdatedAt;
    }

    /// @notice Emitted when the minimum deviation threshold is updated
    event MinDeviationUpdated(uint256 minDeviationWAD);

    /// @notice Emitted when an admin force-checkpoints the source's current value and update timestamp
    event ClockTicked(uint256 value);

    /// @notice Thrown when the minimum deviation threshold is not strictly less than 100% (WAD)
    error INVALID_MIN_DEVIATION_WAD();

    /**
     * @notice Initializes the oracle checkpoint clock state and records the source's current value as the baseline
     * @dev Must be called after the concrete clock's read wiring is set so the baseline read observes the live source
     * @dev The baseline is recorded WITHOUT an update timestamp: an initialization read carries no new pricing information, so recording it would be incorrect
     * @param _minDeviationWAD The minimum relative deviation from the checkpointed value that counts as an update, scaled to WAD precision (zero counts any change)
     */
    function __OracleClockBase_init_unchained(uint256 _minDeviationWAD) internal onlyInitializing {
        // Initialize the minimum deviation
        _setMinDeviationWAD(_minDeviationWAD);
        // Record the baseline value so the first deviation is measured against the source's state at initialization
        _getOracleClockBaseStorage().lastValue = _getSourcePrice().toUint160();
    }

    /**
     * @notice Observes the source, checkpointing a new update timestamp if its value deviated beyond the threshold
     * @dev Satisfies IRoycoPriceOracle.poke for pull-based sources: a zero (no deviation observed yet) conservatively holds the entry point's execution gate shut
     * @return lastUpdatedAt The timestamp of the last observed update of the source (zero if none observed yet)
     */
    function poke() public virtual returns (uint256 lastUpdatedAt) {
        OracleClockBaseState storage $ = _getOracleClockBaseStorage();
        // Observe the source, and update the checkpoint and clock if it deviated
        (uint256 value, bool deviated) = _observe();
        if (deviated) ($.lastValue, $.lastUpdatedAt) = (value.toUint160(), uint32(block.timestamp));
        return $.lastUpdatedAt;
    }

    /**
     * @notice Simulates a poke, returning the update timestamp it would checkpoint without committing it
     * @dev Used by poke-consistent view paths (eg. a preview sync): an observed deviation reports the current
     *      timestamp exactly as the poke would stamp it, so view and mutating paths can never disagree
     * @dev A circuit-breaking override reverts here too, so a preview sync fails shut identically to the real one
     * @return lastUpdatedAt The timestamp a poke would report (zero if no update has been observed yet)
     */
    function previewPoke() public view virtual returns (uint256 lastUpdatedAt) {
        // Observe the source, and report the current timestamp if it deviated
        (, bool deviated) = _observe();
        return deviated ? block.timestamp : _getOracleClockBaseStorage().lastUpdatedAt;
    }

    /**
     * @notice Force-checkpoints the source's current value and the current timestamp as an observed update
     * @dev Covers the deviation blind spot: a source can update at an unchanged or sub-threshold value, which poke can never observe
     * @dev Re-baselines the checkpoint, so subsequent deviations are measured from the current value
     */
    function tick() external restricted {
        OracleClockBaseState storage $ = _getOracleClockBaseStorage();
        uint256 value = _getSourcePrice();
        ($.lastValue, $.lastUpdatedAt) = (value.toUint160(), uint32(block.timestamp));
        emit ClockTicked(value);
    }

    /// @notice Sets the minimum deviation threshold that counts as an update
    /// @param _minDeviationWAD The new minimum relative deviation, scaled to WAD precision (zero counts any change)
    function setMinDeviationWAD(uint256 _minDeviationWAD) external restricted {
        _setMinDeviationWAD(_minDeviationWAD);
    }

    /// @notice Returns the oracle checkpoint clock state
    /// @return state The oracle checkpoint clock state
    function getOracleCheckpointClockState() external view returns (OracleClockBaseState memory state) {
        return _getOracleClockBaseStorage();
    }

    /**
     * @notice Sets the new minimum deviation threshold
     * @dev A threshold at or above 100% would mute all downward updates (a downward deviation caps at exactly WAD), making the clock asymmetric
     * @param _minDeviationWAD The new minimum relative deviation, scaled to WAD precision
     */
    function _setMinDeviationWAD(uint256 _minDeviationWAD) internal {
        require(_minDeviationWAD < WAD, INVALID_MIN_DEVIATION_WAD());
        // The threshold is bounded strictly under WAD, so the narrowing cast can never truncate
        _getOracleClockBaseStorage().minDeviationWAD = uint64(_minDeviationWAD);
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

    /**
     * @notice Observes the source's current price against the checkpoint
     * @return value The source's current price
     * @return deviated Whether the observation deviated from the checkpointed value beyond the configured threshold
     */
    function _observe() internal view returns (uint256 value, bool deviated) {
        OracleClockBaseState storage $ = _getOracleClockBaseStorage();
        value = _getSourcePrice();
        deviated = _hasDeviated(value, $.lastValue, $.minDeviationWAD);
    }

    /// @notice Returns the source's current price, implemented by the concrete clock
    /// @return price The source's current price
    function _getSourcePrice() internal view virtual returns (uint256 price);

    /**
     * @notice Returns a storage pointer to the OracleClockBaseState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer
     */
    function _getOracleClockBaseStorage() internal pure returns (OracleClockBaseState storage $) {
        assembly ("memory-safe") {
            $.slot := ORACLE_CLOCK_BASE_STORAGE_SLOT
        }
    }
}
