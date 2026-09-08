// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { Ownable, Ownable2Step } from "../../../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast } from "../../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { NAV_UNIT } from "../../libraries/Units.sol";
import { ChainlinkPriceOracleBase } from "./ChainlinkPriceOracleBase.sol";

/**
 * @title DiscretePriceOracleBase
 * @author Shivaansh Kapoor, Ankur Dubey, Tomer Ganor
 * @notice Abstract composed oracle for conversion sources that reprice discretely at settlements: the owner checkpoints the source price at each settlement, that checkpoint prices the conversion hop until the next one, and the report's timestamp is the older of the checkpoint and the Chainlink leg
 * @dev checkpointPrice reads the live source and latches it until the next call, so between checkpoints intra-settlement drift (eg. fee accrual checkpointed into the source on every request) never marks the market, and settlements, markdowns, and recoveries land when the owner checkpoints them
 * @dev The owner's only authority is choosing when to sample: the price always comes from the source read and latching is only sound for sources whose true value is a step function advancing at settlements, so a compromised owner can at worst latch a genuine mid-cycle reading
 * @dev The source-price staleness gate fails shut around the owner: a fresh deployment's zero checkpoint holds pricing and the execution gate shut until the first checkpointPrice call, a halted owner ages the checkpoint out, and renouncing ownership makes that fail-shut permanent
 * @dev The concrete oracle supplies the source read (_getSourcePrice), which doubles as the conversion hop and the checkpoint payload, so it MUST be scaled to WAD precision
 * @dev Neither a feed update nor a checkpoint alone advances the reported timestamp, so the entry point's execution gate opens only once BOTH hops have updated
 */
abstract contract DiscretePriceOracleBase is Ownable2Step, ChainlinkPriceOracleBase {
    using SafeCast for uint256;

    /// @notice The maximum age of the source-price checkpoint before pricing fails shut
    uint32 public immutable SOURCE_PRICE_STALENESS_THRESHOLD_SECONDS;

    /// @dev The source price captured at the last checkpoint (zero until the first checkpointPrice call)
    uint160 private _lastSourcePrice;

    /// @dev The timestamp of the last checkpoint (zero until the first checkpointPrice call, held shut by the staleness gate)
    uint32 private _lastUpdatedAt;

    /// @notice Thrown when the source price read at a checkpoint is zero, which only a misconfigured or wiped source can report
    error INVALID_SOURCE_PRICE();

    /// @notice Thrown when the source-price checkpoint is older than the source-price staleness threshold
    error STALE_SOURCE_PRICE();

    /// @notice Emitted when the owner checkpoints the source price, the only action that moves the conversion hop
    /// @param previousSourcePrice The source price the checkpoint replaced
    /// @param newSourcePrice The source price latched for the conversion hop until the next checkpoint
    event SourcePriceCheckpointed(uint256 previousSourcePrice, uint256 newSourcePrice);

    /**
     * @notice Constructs the discrete Chainlink (compatible) composed oracle, forwarding the Chainlink leg's configuration to its base
     * @param _owner The owner trusted to checkpoint the source price at each settlement
     * @param _collateralAsset The collateral asset this oracle prices in NAV units
     * @param _chainlinkOracle The Chainlink (compatible) oracle pricing the reference asset in NAV units
     * @param _chainlinkOracleStalenessThresholdSeconds The maximum age of the Chainlink (compatible) oracle's report before pricing fails shut, sized to its heartbeat
     * @param _sourcePriceStalenessThresholdSeconds The maximum age of the source-price checkpoint before pricing fails shut, sized to the source's settlement cadence plus slack so a missed checkpoint or a halted owner fails pricing shut
     */
    constructor(
        address _owner,
        address _collateralAsset,
        address _chainlinkOracle,
        uint32 _chainlinkOracleStalenessThresholdSeconds,
        uint32 _sourcePriceStalenessThresholdSeconds
    )
        Ownable(_owner)
        ChainlinkPriceOracleBase(_collateralAsset, _chainlinkOracle, _chainlinkOracleStalenessThresholdSeconds)
    {
        // Conduct sanity checks on the source-price staleness threshold
        require(_sourcePriceStalenessThresholdSeconds > 0, INVALID_STALENESS_THRESHOLD_SECONDS());
        SOURCE_PRICE_STALENESS_THRESHOLD_SECONDS = _sourcePriceStalenessThresholdSeconds;
    }

    /**
     * @notice Checkpoints the live source price as the conversion hop until the next call
     * @dev Called by the owner on every source settlement, and again on any distressed repricing (eg. a loss marked down after a borrower default), so the market books exactly the prices the source has settled
     * @dev Stamps the checkpoint's update timestamp, so each call advances the source hop for the entry point's execution gate
     * @dev A zero read fails shut like the Chainlink leg's non-positive answer instead of pricing the collateral at zero
     */
    function checkpointPrice() external onlyOwner {
        uint256 price = _getSourcePrice();
        require(price > 0, INVALID_SOURCE_PRICE());
        emit SourcePriceCheckpointed(_lastSourcePrice, price);
        (_lastSourcePrice, _lastUpdatedAt) = (price.toUint160(), block.timestamp.toUint32());
    }

    /**
     * @inheritdoc ChainlinkPriceOracleBase
     * @notice The price returned is the composed price and updatedAt is the oldest hop's last update
     * @dev Reports the older of the source-price checkpoint and the Chainlink leg's update timestamp, with the conversion hop priced at the checkpointed source price
     * @dev The Chainlink base's canonical poke and previewPoke both report this oldest-hop timestamp, so view and mutating paths can never disagree
     */
    function getPrice() public view virtual override(ChainlinkPriceOracleBase) returns (NAV_UNIT price, uint256 updatedAt) {
        (price, updatedAt) = ChainlinkPriceOracleBase.getPrice();
        uint256 sourcePriceUpdatedAt = _lastUpdatedAt;
        require((sourcePriceUpdatedAt + SOURCE_PRICE_STALENESS_THRESHOLD_SECONDS) >= block.timestamp, STALE_SOURCE_PRICE());
        updatedAt = Math.min(updatedAt, sourcePriceUpdatedAt);
    }

    /**
     * @notice Returns the checkpoint pair
     * @return lastSourcePrice The source price captured at the last checkpoint
     * @return lastUpdatedAt The timestamp of the last checkpoint
     */
    function getDiscretePriceOracleState() external view returns (uint160 lastSourcePrice, uint32 lastUpdatedAt) {
        return (_lastSourcePrice, _lastUpdatedAt);
    }

    /// @inheritdoc ChainlinkPriceOracleBase
    /// @dev The conversion hop replays exactly what the last checkpoint committed, so pricing between checkpoints never moves with the source's drift
    function _getCollateralToReferenceAssetConversionRateWAD()
        internal
        view
        virtual
        override(ChainlinkPriceOracleBase)
        returns (uint256 collateralToReferenceAssetConversionRateWAD)
    {
        return _lastSourcePrice;
    }

    /**
     * @notice Returns the source's current price, implemented by the concrete oracle
     * @dev The read doubles as the conversion hop and the checkpoint payload, so it MUST be scaled to WAD precision
     * @return price The source's current price
     */
    function _getSourcePrice() internal view virtual returns (uint256 price);
}
