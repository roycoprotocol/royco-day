// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { WAD } from "../../../libraries/Constants.sol";

/**
 * @title OracleClockBase
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Abstract oracle clock for pull-based pricing sources that expose only a current price with no update timestamp
 * @dev Each poke reads the source and checkpoints a new update timestamp when the price has deviated beyond the immutable threshold since the last checkpoint, deriving conservative update times for the source
 * @dev Fully permissionless and admin-free: the only mutable state is the checkpoint pair poke advances mechanically, so the clock has no authority, no upgrade path, and no configuration surface
 * @dev A source update the clock cannot observe (a republish at an identical or sub-threshold price) conservatively holds the entry point's execution gate shut until the next observable deviation, and reconfiguration is a redeploy plus a kernel oracle repoint
 */
abstract contract OracleClockBase {
    using Math for uint256;
    using SafeCast for uint256;

    /// @notice The minimum relative deviation from the checkpointed price that counts as an update, scaled to WAD precision (zero counts any change)
    uint256 public immutable MIN_DEVIATION_WAD;

    /// @dev The oracle price observed at the last checkpoint (the construction baseline before the first deviation)
    uint160 private _lastOraclePrice;

    /// @dev The timestamp of the last checkpoint (the deployer-attested initial checkpoint until the first observed deviation)
    uint32 private _lastUpdatedAt;

    /// @notice Thrown when the initial checkpoint timestamp is in the future
    error INVALID_LAST_UPDATE_TIMESTAMP();

    /// @notice Thrown when the minimum deviation threshold is not strictly less than 100% (WAD)
    error INVALID_MIN_DEVIATION_WAD();

    /// @notice Thrown when the clock baseline is written outside construction
    error CLOCK_BASELINE_ONLY_AT_CONSTRUCTION();

    /**
     * @notice Constructs the oracle clock, recording the deployer-attested initial checkpoint
     * @dev The deriving oracle checkpoints the baseline via _initializeOracleClock once its immutables exist, so the baseline flows through the same _getSourcePrice read every poke uses
     * @dev The deployer is responsible for the accuracy of the initial checkpoint: it must be the source's genuine last update time, and a zero conservatively reports no update yet (holding the entry point's execution gate shut)
     * @dev A threshold at or above 100% would mute all downward updates (a downward deviation caps at exactly WAD), making the clock asymmetric
     * @param _lastUpdate The deployer-attested timestamp of the source's last update (zero if unknown)
     * @param _minDeviationWAD The minimum relative deviation from the checkpointed price that counts as an update, scaled to WAD precision (zero counts any change)
     */
    constructor(uint32 _lastUpdate, uint256 _minDeviationWAD) {
        // The checkpoint must never start in the future: it would satisfy the execution gate without a genuine update
        require(_lastUpdate <= block.timestamp, INVALID_LAST_UPDATE_TIMESTAMP());
        require(_minDeviationWAD < WAD, INVALID_MIN_DEVIATION_WAD());
        MIN_DEVIATION_WAD = _minDeviationWAD;
        _lastUpdatedAt = _lastUpdate;
    }

    /**
     * @notice Observes the source, checkpointing a new update timestamp if its price deviated beyond the threshold
     * @dev Satisfies IRoycoPriceOracle.poke for pull-based sources: a zero (no deviation observed yet) conservatively holds the entry point's execution gate shut
     * @return lastUpdatedAt The timestamp of the last observed update of the source (zero if none observed yet)
     */
    function poke() public virtual returns (uint256 lastUpdatedAt) {
        // Observe the source, and update the checkpoint and clock if it deviated
        (uint256 price, bool deviated) = _observeOraclePriceDeviation();
        if (deviated) (_lastOraclePrice, _lastUpdatedAt) = (price.toUint160(), uint32(block.timestamp));
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
        (, bool deviated) = _observeOraclePriceDeviation();
        return deviated ? block.timestamp : _lastUpdatedAt;
    }

    /**
     * @notice Returns the clock's checkpoint pair
     * @return lastOraclePrice The oracle price observed at the last checkpoint
     * @return lastUpdatedAt The timestamp of the last checkpoint
     */
    function getOracleClockState() external view returns (uint160 lastOraclePrice, uint32 lastUpdatedAt) {
        return (_lastOraclePrice, _lastUpdatedAt);
    }

    /**
     * @notice Observes the source's current price against the checkpoint
     * @return price The source's current price
     * @return deviated Whether the observation deviated from the checkpointed price beyond the immutable threshold
     */
    function _observeOraclePriceDeviation() internal view returns (uint256 price, bool deviated) {
        price = _getSourcePrice();
        deviated = _hasOraclePriceDeviated(price, _lastOraclePrice);
    }

    /**
     * @notice Returns whether the observed oracle price deviated from the checkpointed price beyond the immutable threshold
     * @param _price The oracle price observed by this poke
     * @param _checkpointPrice The oracle price observed at the last checkpoint
     * @return deviated Whether the deviation counts as an update
     */
    function _hasOraclePriceDeviated(uint256 _price, uint256 _checkpointPrice) internal view returns (bool deviated) {
        if (_price == _checkpointPrice) return false;
        if (MIN_DEVIATION_WAD == 0) return true;
        // A zero checkpointed price has no relative scale to measure against, so any nonzero observation is a full deviation
        if (_checkpointPrice == 0) return true;
        uint256 delta = (_price > _checkpointPrice) ? (_price - _checkpointPrice) : (_checkpointPrice - _price);
        return (WAD.mulDiv(delta, _checkpointPrice) >= MIN_DEVIATION_WAD);
    }

    /**
     * @notice Checkpoints the construction-time oracle price as the baseline the first deviation is measured against
     * @dev Called once from the deriving oracle's constructor body after its immutables are assigned, so the baseline can flow through the same _getSourcePrice read every poke uses
     * @dev Construction-only: the account carries no code while its creation code runs, so a runtime call fails shut and the baseline can never be rewritten after deployment
     * @param _initialOraclePrice The oracle's price at construction, never a clock timestamp
     */
    function _initializeOracleClock(uint256 _initialOraclePrice) internal {
        require(address(this).code.length == 0, CLOCK_BASELINE_ONLY_AT_CONSTRUCTION());
        _lastOraclePrice = _initialOraclePrice.toUint160();
    }

    /// @notice Returns the source's current price, implemented by the concrete clock
    /// @return price The source's current price
    function _getSourcePrice() internal view virtual returns (uint256 price);
}
