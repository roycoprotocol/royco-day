// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast } from "../../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { NAV_UNIT } from "../../libraries/Units.sol";
import { ChainlinkPriceOracleBase } from "./ChainlinkPriceOracleBase.sol";

/**
 * @title DiscretePriceOracleBase
 * @author Shivaansh Kapoor, Ankur Dubey, Tomer Ganor
 * @notice Abstract composed oracle for conversion sources that reprice discretely at settlements: poke checkpoints the live source price whenever the source's checkpoint ID changes or the force signal holds and its price moves off the checkpoint, and the report's timestamp is the older of the checkpoint and the Chainlink leg
 * @dev An ID change is a settlement and always checkpoints, even at an unchanged price, so the entry point's execution gate opens on every settlement
 * @dev While the concrete's force signal holds, every price move off the checkpoint counts too, so repricings without an ID change (eg. a distressed source marking value down between settlements, and its later recoveries) land at the first poke that observes them
 * @dev Between checkpoints intra-cycle drift (eg. fees accruing against the source between settlements) never marks the market: the ID only changes at settlements and price moves only count under the force signal, so no poke timing grants price selection power
 * @dev Fully permissionless and admin-free: the only mutable state is the checkpoint triple poke advances mechanically, so the oracle has no authority, no upgrade path, and no configuration surface
 * @dev The concrete oracle supplies the source read (_getSourcePrice), which doubles as the conversion hop and the checkpoint payload so it MUST be scaled to WAD precision, the checkpoint ID (_getCheckpointId), and the force-checkpoint signal (_shouldForceCheckpoint)
 * @dev The deriving constructor seeds the baseline through the same commit path pokes use, so a fresh deployment prices from its construction read, and a missed settlement or a silently frozen source ages the checkpoint until pricing fails shut
 * @dev Neither a feed update nor a checkpoint alone advances the reported timestamp, so the entry point's execution gate opens only once BOTH hops have updated
 * @dev A market gating executions on oracle updates must size its request expiry to at least the settlement cadence, or requests queued between checkpoints expire before the gate can ever open for them
 */
abstract contract DiscretePriceOracleBase is ChainlinkPriceOracleBase {
    using SafeCast for uint256;

    /// @notice The maximum age of the source-price checkpoint before pricing fails shut
    uint32 public immutable SOURCE_PRICE_STALENESS_THRESHOLD_SECONDS;

    /// @dev The source price captured at the last checkpoint (the deriving constructor's seed until the first observed checkpoint)
    uint160 private _lastSourcePrice;

    /// @dev The timestamp of the last checkpoint (the construction timestamp until the first observed checkpoint)
    uint32 private _lastUpdatedAt;

    /// @dev The checkpoint ID observed at the last checkpoint (the construction ID until the first observed settlement)
    uint256 private _lastCheckpointId;

    /// @notice Thrown when the source-price checkpoint is older than the source-price staleness threshold
    error STALE_SOURCE_PRICE();

    /**
     * @notice Constructs the discrete Chainlink (compatible) composed oracle, forwarding the Chainlink leg's configuration to its base
     * @dev The deriving oracle seeds the baseline checkpoint via _checkpointSourcePrice once its immutables exist, so the seed flows through the same reads and commit every poke uses
     * @param _collateralAsset The collateral asset this oracle prices in NAV units
     * @param _chainlinkOracle The Chainlink (compatible) oracle pricing the reference asset in NAV units
     * @param _chainlinkOracleStalenessThresholdSeconds The maximum age of the Chainlink (compatible) oracle's report before pricing fails shut, sized to its heartbeat
     * @param _sourcePriceStalenessThresholdSeconds The maximum age of the source-price checkpoint before pricing fails shut, sized to the source's settlement cadence plus slack
     */
    constructor(
        address _collateralAsset,
        address _chainlinkOracle,
        uint32 _chainlinkOracleStalenessThresholdSeconds,
        uint32 _sourcePriceStalenessThresholdSeconds
    )
        ChainlinkPriceOracleBase(_collateralAsset, _chainlinkOracle, _chainlinkOracleStalenessThresholdSeconds)
    {
        // Conduct sanity checks on the source-price staleness threshold
        require(_sourcePriceStalenessThresholdSeconds > 0, INVALID_STALENESS_THRESHOLD_SECONDS());
        SOURCE_PRICE_STALENESS_THRESHOLD_SECONDS = _sourcePriceStalenessThresholdSeconds;
    }

    /**
     * @inheritdoc ChainlinkPriceOracleBase
     * @notice The price returned is the composed price and updatedAt is the oldest hop's last update
     * @dev Reports the older of the source-price checkpoint and the Chainlink leg's update timestamp, with the conversion hop priced at the checkpointed source price
     * @dev A pending checkpoint observation reads as the live price at the current timestamp, exactly what a poke would commit, so view and mutating paths can never disagree
     */
    function getPrice() public view virtual override(ChainlinkPriceOracleBase) returns (NAV_UNIT price, uint256 updatedAt) {
        (price, updatedAt) = ChainlinkPriceOracleBase.getPrice();
        uint256 sourcePriceUpdatedAt = (_shouldCheckpointPrice() ? block.timestamp : _lastUpdatedAt);
        require((sourcePriceUpdatedAt + SOURCE_PRICE_STALENESS_THRESHOLD_SECONDS) >= block.timestamp, STALE_SOURCE_PRICE());
        updatedAt = Math.min(updatedAt, sourcePriceUpdatedAt);
    }

    /**
     * @inheritdoc ChainlinkPriceOracleBase
     * @dev Commits any pending checkpoint observation, then the Chainlink base's canonical poke reports getPrice's oldest-hop timestamp
     * @dev The commit latches the live read at poke time: market traffic pokes on every request, execution, and sync, so the first market touch after an observed settlement commits it, and if several settlements elapse between pokes the single commit captures the latest one, the only one still priced into the source
     */
    function poke() public virtual override(ChainlinkPriceOracleBase) returns (uint256 updatedAt) {
        // Commit the observation through the same path the construction seed uses
        if (_shouldCheckpointPrice()) _checkpointSourcePrice();
        return ChainlinkPriceOracleBase.poke();
    }

    /**
     * @notice Returns the checkpoint triple
     * @return lastSourcePrice The source price captured at the last checkpoint
     * @return lastUpdatedAt The timestamp of the last checkpoint
     * @return lastCheckpointId The checkpoint ID observed at the last checkpoint
     */
    function getDiscretePriceOracleState() external view returns (uint160 lastSourcePrice, uint32 lastUpdatedAt, uint256 lastCheckpointId) {
        return (_lastSourcePrice, _lastUpdatedAt, _lastCheckpointId);
    }

    /**
     * @inheritdoc ChainlinkPriceOracleBase
     * @dev The conversion hop consumes exactly what a poke would checkpoint: a pending checkpoint observation prices the live source read, otherwise the stored
     *      checkpoint, so pricing between checkpoints never moves with the source's drift and view and mutating paths can never disagree on the price
     */
    function _getCollateralToReferenceAssetConversionRateWAD()
        internal
        view
        virtual
        override(ChainlinkPriceOracleBase)
        returns (uint256 collateralToReferenceAssetConversionRateWAD)
    {
        return (_shouldCheckpointPrice() ? _getSourcePrice() : _lastSourcePrice);
    }

    /**
     * @notice Returns whether a poke at this instant should commit a checkpoint
     * @dev An ID change is a settlement and always counts, even at an unchanged price, so the execution gate opens on every settlement rather than only on price-moving ones
     * @dev Any difference from the stored ID counts rather than requiring monotonic advance, so a source-side reset or upgrade that rewinds the ID still registers as a settlement
     * @dev Under the force signal a price move off the checkpoint counts too, while the signal alone never does, so an unchanged price manufactures no updates however long the signal holds
     * @return shouldCheckpoint Whether a poke would commit a checkpoint
     */
    function _shouldCheckpointPrice() internal view returns (bool shouldCheckpoint) {
        return ((_getCheckpointId() != _lastCheckpointId) || (_shouldForceCheckpoint() && (_getSourcePrice() != _lastSourcePrice)));
    }

    /**
     * @notice Commits the live source read, the current timestamp, and the current checkpoint ID as the checkpoint
     * @dev The single commit path: poke routes observed settlements through it and the deriving constructor calls it once its immutables are assigned, seeding the baseline through the same reads (a mid-cycle deployment seeds a slightly drifted price that the first observed settlement corrects)
     */
    function _checkpointSourcePrice() internal {
        (_lastSourcePrice, _lastUpdatedAt) = (_getSourcePrice().toUint160(), block.timestamp.toUint32());
        _lastCheckpointId = _getCheckpointId();
    }

    /**
     * @notice Returns the source's current price, implemented by the concrete oracle
     * @dev The read doubles as the conversion hop and the checkpoint payload, so it MUST be scaled to WAD precision
     * @return price The source's current price
     */
    function _getSourcePrice() internal view virtual returns (uint256 price);

    /**
     * @notice Returns the source's current checkpoint ID, implemented by the concrete oracle
     * @dev The settlement signal: the ID must change on every settlement and must never move with intra-cycle drift (eg. a settlement epoch counter that increments exactly once per settlement)
     * @return id The source's current checkpoint ID
     */
    function _getCheckpointId() internal view virtual returns (uint256 id);

    /**
     * @notice Returns whether every source price move should checkpoint, implemented by the concrete oracle
     * @dev The force signal covers repricings the ID cannot see (eg. a source in distress whose ID freezes while its value is marked down and later recovered), and the signal alone never checkpoints, only a price move under it
     * @dev A source with no such signal implements this as a constant false, keeping the decision visible in review
     * @return forceCheckpoint Whether every source price move should checkpoint
     */
    function _shouldForceCheckpoint() internal view virtual returns (bool forceCheckpoint);
}
