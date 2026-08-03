// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { WAD } from "../../../libraries/Constants.sol";

/**
 * @title OracleClockBase
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Abstract oracle clock for pull-based pricing sources that expose only a current value with no update timestamp
 * @dev Each poke reads the source and checkpoints a new update timestamp when the value has deviated beyond the immutable threshold since the last checkpoint, deriving conservative update times for the source
 * @dev Fully permissionless and admin-free: the only mutable state is the checkpoint pair poke advances mechanically, so the clock has no authority, no upgrade path, and no configuration surface
 * @dev A source update the clock cannot observe (a republish at an identical or sub-threshold value) conservatively holds the entry point's execution gate shut until the next observable deviation, and reconfiguration is a redeploy plus a kernel oracle repoint
 */
abstract contract OracleClockBase {
    using Math for uint256;
    using SafeCast for uint256;

    /// @notice The minimum relative deviation from the checkpointed value that counts as an update, scaled to WAD precision (zero counts any change)
    uint256 public immutable MIN_DEVIATION_WAD;

    /// @dev The value observed at the last checkpoint (the construction baseline before the first deviation)
    uint160 private _lastValue;

    /// @dev The timestamp of the last checkpoint (the deployer-attested initial checkpoint until the first observed deviation)
    uint32 private _lastUpdatedAt;

    /// @notice Thrown when the initial checkpoint timestamp is in the future
    error INVALID_LAST_UPDATE_TIMESTAMP();

    /// @notice Thrown when the minimum deviation threshold is not strictly less than 100% (WAD)
    error INVALID_MIN_DEVIATION_WAD();

    /**
     * @notice Constructs the oracle clock, recording the source's current value as the baseline and the deployer-attested initial checkpoint
     * @dev The baseline arrives as an argument because a base constructor cannot read the concrete clock's immutables through the _getSourcePrice virtual yet
     * @dev The deployer is responsible for the accuracy of the initial checkpoint: it must be the source's genuine last update time, and a zero conservatively reports no update yet (holding the entry point's execution gate shut)
     * @dev A threshold at or above 100% would mute all downward updates (a downward deviation caps at exactly WAD), making the clock asymmetric
     * @param _lastUpdate The deployer-attested timestamp of the source's last update (zero if unknown)
     * @param _minDeviationWAD The minimum relative deviation from the checkpointed value that counts as an update, scaled to WAD precision (zero counts any change)
     * @param _baselineValue The source's value at construction, the checkpoint the first deviation is measured against
     */
    constructor(uint32 _lastUpdate, uint256 _minDeviationWAD, uint256 _baselineValue) {
        // The checkpoint must never start in the future: it would satisfy the execution gate without a genuine update
        require(_lastUpdate <= block.timestamp, INVALID_LAST_UPDATE_TIMESTAMP());
        require(_minDeviationWAD < WAD, INVALID_MIN_DEVIATION_WAD());
        MIN_DEVIATION_WAD = _minDeviationWAD;
        (_lastValue, _lastUpdatedAt) = (_baselineValue.toUint160(), _lastUpdate);
    }

    /**
     * @notice Observes the source, checkpointing a new update timestamp if its value deviated beyond the threshold
     * @dev Satisfies IRoycoPriceOracle.poke for pull-based sources: a zero (no deviation observed yet) conservatively holds the entry point's execution gate shut
     * @return lastUpdatedAt The timestamp of the last observed update of the source (zero if none observed yet)
     */
    function poke() public virtual returns (uint256 lastUpdatedAt) {
        // Observe the source, and update the checkpoint and clock if it deviated
        (uint256 value, bool deviated) = _observeDeviation();
        if (deviated) (_lastValue, _lastUpdatedAt) = (value.toUint160(), uint32(block.timestamp));
        return _lastUpdatedAt;
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
        (, bool deviated) = _observeDeviation();
        return deviated ? block.timestamp : _lastUpdatedAt;
    }

    /**
     * @notice Returns the clock's checkpoint pair
     * @return lastValue The value observed at the last checkpoint
     * @return lastUpdatedAt The timestamp of the last checkpoint
     */
    function getOracleClockState() external view returns (uint160 lastValue, uint32 lastUpdatedAt) {
        return (_lastValue, _lastUpdatedAt);
    }

    /**
     * @notice Returns whether the observed value deviated from the checkpointed value beyond the immutable threshold
     * @param _value The value observed by this poke
     * @param _checkpointValue The value observed at the last checkpoint
     * @return deviated Whether the deviation counts as an update
     */
    function _hasDeviated(uint256 _value, uint256 _checkpointValue) internal view returns (bool deviated) {
        if (_value == _checkpointValue) return false;
        if (MIN_DEVIATION_WAD == 0) return true;
        // A zero checkpoint has no relative scale to measure against, so any nonzero observation is a full deviation
        if (_checkpointValue == 0) return true;
        uint256 delta = (_value > _checkpointValue) ? (_value - _checkpointValue) : (_checkpointValue - _value);
        return (WAD.mulDiv(delta, _checkpointValue) >= MIN_DEVIATION_WAD);
    }

    /**
     * @notice Observes the source's current price against the checkpoint
     * @return value The source's current price
     * @return deviated Whether the observation deviated from the checkpointed value beyond the immutable threshold
     */
    function _observeDeviation() internal view returns (uint256 value, bool deviated) {
        value = _getSourcePrice();
        deviated = _hasDeviated(value, _lastValue);
    }

    /// @notice Returns the source's current price, implemented by the concrete clock
    /// @return price The source's current price
    function _getSourcePrice() internal view virtual returns (uint256 price);
}
