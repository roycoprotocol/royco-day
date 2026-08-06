// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { NAV_UNIT } from "../../libraries/Units.sol";
import { ChainlinkPriceOracleBase } from "./ChainlinkPriceOracleBase.sol";
import { OracleClockBase } from "./clock/OracleClockBase.sol";

/**
 * @title ClockedChainlinkPriceOracleBase
 * @author Shivaansh Kapoor, Ankur Dubey, Tomer Ganor
 * @notice Abstract composed oracle whose conversion source exposes no update timestamp: the deviation clock derives the source hop's update times and the report's timestamp is the older of that clock and the Chainlink leg
 * @dev The concrete oracle supplies the source read (_getSourcePrice), which doubles as the conversion hop and the clock's observation
 * @dev Neither a feed update nor a source-price move alone advances the reported timestamp, so the entry point's execution gate opens only once BOTH hops have updated
 */
abstract contract ClockedChainlinkPriceOracleBase is OracleClockBase, ChainlinkPriceOracleBase {
    /// @notice The maximum age of the source-price clock's checkpoint before pricing fails shut
    uint32 public immutable SOURCE_PRICE_STALENESS_THRESHOLD_SECONDS;

    /// @notice Thrown when the source-price clock's checkpoint is older than the source-price staleness threshold
    error STALE_SOURCE_PRICE();

    /**
     * @notice Constructs the clocked Chainlink (compatible) composed oracle, forwarding each hop's configuration to its base
     * @param _collateralAsset The collateral asset this oracle prices in NAV units
     * @param _chainlinkOracle The Chainlink (compatible) oracle pricing the reference asset in NAV units
     * @param _minDeviationWAD The minimum relative deviation from the checkpointed source price that counts as an update, scaled to WAD precision (zero counts any change)
     * @param _lastUpdate The deployer-attested timestamp of the source price's last update (zero if unknown, which holds pricing and the execution gate shut until the first observed deviation)
     * @param _chainlinkOracleStalenessThresholdSeconds The maximum age of the Chainlink (compatible) oracle's report before pricing fails shut, sized to its heartbeat
     * @param _sourcePriceStalenessThresholdSeconds The maximum age of the source-price clock's checkpoint before pricing fails shut, sized to the source's update cadence
     */
    constructor(
        address _collateralAsset,
        address _chainlinkOracle,
        uint256 _minDeviationWAD,
        uint32 _lastUpdate,
        uint32 _chainlinkOracleStalenessThresholdSeconds,
        uint32 _sourcePriceStalenessThresholdSeconds
    )
        ChainlinkPriceOracleBase(_collateralAsset, _chainlinkOracle, _chainlinkOracleStalenessThresholdSeconds)
        OracleClockBase(_lastUpdate, _minDeviationWAD)
    {
        // Conduct sanity checks on the source-price staleness threshold
        require(_sourcePriceStalenessThresholdSeconds > 0, INVALID_STALENESS_THRESHOLD_SECONDS());
        SOURCE_PRICE_STALENESS_THRESHOLD_SECONDS = _sourcePriceStalenessThresholdSeconds;
    }

    /**
     * @inheritdoc ChainlinkPriceOracleBase
     * @notice The price returned is the composed price and updatedAt is the oldest hop's last update
     * @dev Reports the older of the checkpointed source price clock and the Chainlink leg's update timestamp
     * @dev An uncommitted clock deviation reads as current, so freeze detection is driven by poking traffic and lags at most one staleness window past the first post-freeze operation
     */
    function getPrice() public view virtual override(ChainlinkPriceOracleBase) returns (NAV_UNIT price, uint256 updatedAt) {
        (price, updatedAt) = ChainlinkPriceOracleBase.getPrice();
        uint256 sourcePriceUpdatedAt = OracleClockBase.previewPoke();
        require((sourcePriceUpdatedAt + SOURCE_PRICE_STALENESS_THRESHOLD_SECONDS) >= block.timestamp, STALE_SOURCE_PRICE());
        updatedAt = Math.min(updatedAt, sourcePriceUpdatedAt);
    }

    /// @inheritdoc ChainlinkPriceOracleBase
    /// @dev Commits any observed source-price deviation, then the Chainlink base's canonical poke reports getPrice's oldest-hop timestamp
    function poke() public virtual override(OracleClockBase, ChainlinkPriceOracleBase) returns (uint256 updatedAt) {
        OracleClockBase.poke();
        return ChainlinkPriceOracleBase.poke();
    }

    /// @inheritdoc ChainlinkPriceOracleBase
    /// @dev The Chainlink base's canonical previewPoke reports getPrice's oldest-hop timestamp without committing, so view and mutating paths can never disagree
    function previewPoke() public view virtual override(OracleClockBase, ChainlinkPriceOracleBase) returns (uint256 updatedAt) {
        return ChainlinkPriceOracleBase.previewPoke();
    }

    /// @inheritdoc ChainlinkPriceOracleBase
    /// @dev The conversion hop and the clock source are the same reading by construction: the deviation clock is an
    ///      honest update-time proxy for the conversion only if it observes exactly what the conversion consumes
    function _getCollateralToReferenceAssetConversionRateWAD()
        internal
        view
        virtual
        override(ChainlinkPriceOracleBase)
        returns (uint256 collateralToReferenceAssetConversionRateWAD)
    {
        return _getSourcePrice();
    }
}
