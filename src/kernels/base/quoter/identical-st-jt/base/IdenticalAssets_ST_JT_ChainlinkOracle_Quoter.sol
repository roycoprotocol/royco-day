// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { Math } from "../../../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { AggregatorV3Interface } from "../../../../../interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "./IdenticalAssets_ST_JT_Oracle_Quoter.sol";

/**
 * @title IdenticalAssets_ST_JT_ChainlinkOracle_Quoter
 * @notice Quoter to convert tranche units to/from NAV units using a Chainlink (compatible) oracle to convert tranche units to reference assets which uses an admin or oracle set rate to convert to NAV units
 * @dev Use case: Convert PT-USDE (Tranche unit) to USDE (Reference asset) using a Chainlink (compatible) oracle and convert USDE to USD (NAV unit) using an admin or oracle set rate
 */
abstract contract IdenticalAssets_ST_JT_ChainlinkOracle_Quoter is IdenticalAssets_ST_JT_Oracle_Quoter {
    using Math for uint256;

    /// @dev Storage slot for IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant IDENTICAL_ASSETS_ST_JT_CHAINLINK_ORACLE_QUOTER_STORAGE_SLOT = 0xb0795a7ad2e3ad817ec4fc7509f77aa60bf4acf71fcb8429fdf758cf457db600;

    /**
     * @dev Storage state for the Royco identical assets Chainlink (compatible) oracle quoter
     * @custom:storage-location erc7201:Royco.storage.IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState
     * @custom:field oracle - The Chainlink (compatible) tranche asset to reference asset price oracle
     * @custom:field stalenessThresholdSeconds - The maximum age in seconds an oracle price may have before it is considered stale
     * @custom:field sequencerUptimeFeed - The L2 sequencer uptime feed used to gate price queries (the null address when not applicable)
     * @custom:field gracePeriodSeconds - The grace period in seconds after the L2 sequencer is back up before oracle prices are trusted again
     */
    struct IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState {
        address oracle;
        uint48 stalenessThresholdSeconds;
        address sequencerUptimeFeed;
        uint48 gracePeriodSeconds;
    }

    /// @notice Emitted when the identical assets Chainlink (compatible) oracle is updated
    event ChainlinkOracleUpdated(address indexed oracle, uint48 stalenessThresholdSeconds);

    /// @notice Emitted when the L2 sequencer uptime feed (and its grace period) used to gate price queries is updated
    event SequencerUptimeFeedUpdated(address indexed sequencerUptimeFeed, uint48 gracePeriodSeconds);

    /// @notice Thrown when the staleness threshold seconds is zero
    error INVALID_STALENESS_THRESHOLD_SECONDS();

    /// @notice Thrown when the price is stale
    error STALE_PRICE();

    /// @notice Thrown when the price is invalid
    error INVALID_PRICE();

    /// @notice Thrown when the price is incomplete
    error INCOMPLETE_PRICE();

    /// @notice Thrown when the L2 sequencer is reported down by the configured sequencer uptime feed
    error SEQUENCER_DOWN();

    /// @notice Thrown when the L2 sequencer's grace period has not fully elapsed since it was last restored
    error GRACE_PERIOD_NOT_OVER();

    /// @notice Thrown when a sequencer uptime feed is configured with a non-positive grace period
    error INVALID_GRACE_PERIOD_SECONDS();

    /// @notice Thrown when the oracle is set to the null address without a stored conversion rate to price through
    error NULL_ORACLE_WITHOUT_STORED_RATE();

    /// @notice Thrown when the conversion rate is set to the sentinel value (0) without an oracle to resume
    error SENTINEL_RATE_WITHOUT_ORACLE();

    /**
     * @notice Initializes the identical assets Chainlink (compatible) oracle quoter
     * @dev Must run after the stored conversion rate is initialized so a null oracle can be validated against it
     * @param _oracle The Chainlink (compatible) oracle used to price an asset
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     * @param _sequencerUptimeFeed The L2 sequencer uptime feed to check before trusting the price (set to the null address to disable the check)
     * @param _gracePeriodSeconds The grace period in seconds that must elapse after the L2 sequencer is restored before trusting the price
     */
    function __IdenticalAssets_ST_JT_ChainlinkOracle_Quoter_init_unchained(
        address _oracle,
        uint48 _stalenessThresholdSeconds,
        address _sequencerUptimeFeed,
        uint48 _gracePeriodSeconds
    )
        internal
        onlyInitializing
    {
        _setChainlinkOracle(_oracle, _stalenessThresholdSeconds);
        _setSequencerUptimeFeed(_sequencerUptimeFeed, _gracePeriodSeconds);
    }

    /**
     * @notice Returns the conversion rate from tranche units to NAV units, scaled to WAD precision
     * @dev The conversion rate is calculated as Tranche Asset Price in Reference Asset * Reference Asset Price in NAV units
     * @return trancheToNAVUnitConversionRateWAD The conversion rate from tranche token units to NAV units, scaled to WAD precision
     */
    function getTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        virtual
        override(IdenticalAssets_ST_JT_Oracle_Quoter)
        returns (uint256 trancheToNAVUnitConversionRateWAD)
    {
        // Fetch the tranche asset price in reference assets and its precision
        (uint256 trancheAssetPriceInReferenceAsset, uint256 pricePrecision) = _queryChainlinkOracle();

        // Resolve the reference asset to NAV unit conversion rate, scaled to WAD precision
        uint256 referenceAssetToNAVUnitConversionRateWAD = getStoredConversionRateWAD();
        // If the stored conversion rate is the sentinel value, query the oracle for the rate
        if (referenceAssetToNAVUnitConversionRateWAD == SENTINEL_CONVERSION_RATE) referenceAssetToNAVUnitConversionRateWAD = _getConversionRateFromOracleWAD();

        // Calculate the conversion rate from tranche to NAV units, scaled to WAD precision
        trancheToNAVUnitConversionRateWAD =
            trancheAssetPriceInReferenceAsset.mulDiv(referenceAssetToNAVUnitConversionRateWAD, pricePrecision, Math.Rounding.Floor);
    }

    /// @inheritdoc IdenticalAssets_ST_JT_Oracle_Quoter
    /// @dev The sentinel value (0) routes pricing back to the Chainlink (compatible) oracle, so it is only accepted while an oracle is configured
    /// @dev Access control is enforced by the root setter this dispatches to, a second restricted here would consume a delayed admin operation twice
    function setConversionRate(uint256 _conversionRateWAD, bool _syncBeforeUpdate) public virtual override(IdenticalAssets_ST_JT_Oracle_Quoter) {
        // Storing the sentinel without an oracle would leave the market with no price source
        require(
            _conversionRateWAD != SENTINEL_CONVERSION_RATE || _getIdenticalAssets_ST_JT_ChainlinkOracle_QuoterStorage().oracle != address(0),
            SENTINEL_RATE_WITHOUT_ORACLE()
        );
        IdenticalAssets_ST_JT_Oracle_Quoter.setConversionRate(_conversionRateWAD, _syncBeforeUpdate);
    }

    /**
     * @notice Sets the Chainlink (compatible) oracle for pricing an asset
     * @param _oracle The new Chainlink (compatible) oracle for pricing an asset
     * @param _stalenessThresholdSeconds The new staleness threshold seconds
     * @param _syncBeforeUpdate Whether to sync the tranche accounting before updating the Chainlink (compatible) oracle
     */
    function setChainlinkOracle(address _oracle, uint48 _stalenessThresholdSeconds, bool _syncBeforeUpdate) external restricted {
        // If specified, sync the tranche accounting before updating the Chainlink (compatible) oracle
        if (_syncBeforeUpdate) _preOpSyncTrancheAccounting();
        // Update the Chainlink (compatible) oracle
        _setChainlinkOracle(_oracle, _stalenessThresholdSeconds);
        // Sync the tranche accounting after updating the Chainlink (compatible) oracle
        _preOpSyncTrancheAccounting();
    }

    /**
     * @notice Sets the L2 sequencer uptime feed and grace period used to gate price queries
     * @dev The sequencer uptime feed and grace period do not affect the conversion rate, so no accounting sync is performed
     * @param _sequencerUptimeFeed The new L2 sequencer uptime feed (set to the null address to disable the check)
     * @param _gracePeriodSeconds The new grace period in seconds that must elapse after the L2 sequencer is restored before trusting the price
     */
    function setSequencerUptimeFeed(address _sequencerUptimeFeed, uint48 _gracePeriodSeconds) external restricted {
        _setSequencerUptimeFeed(_sequencerUptimeFeed, _gracePeriodSeconds);
    }

    /// @dev Returns the Chainlink (compatible) oracle configuration for this quoter
    function getChainlinkOracleConfiguration() external view returns (IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState memory) {
        return _getIdenticalAssets_ST_JT_ChainlinkOracle_QuoterStorage();
    }

    /**
     * @notice Queries the Chainlink (compatible) oracle for the price
     * @dev The price is returned as the answer from the latest round
     * @return price The price from the latest round
     * @return precision The precision of the price
     */
    function _queryChainlinkOracle() internal view returns (uint256 price, uint256 precision) {
        // Fetch the price of the asset
        IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState storage $ = _getIdenticalAssets_ST_JT_ChainlinkOracle_QuoterStorage();

        // If a sequencer uptime feed is set, ensure the L2 sequencer is up and its grace period has elapsed before trusting the price
        address sequencerUptimeFeed = $.sequencerUptimeFeed;
        if (sequencerUptimeFeed != address(0)) {
            (, int256 sequencerStatus, uint256 sequencerStartedAt,,) = AggregatorV3Interface(sequencerUptimeFeed).latestRoundData();
            // A sequencer status of 0 indicates that the sequencer is up, and 1 indicates that it is down
            require(sequencerStatus == 0, SEQUENCER_DOWN());
            // Ensure the round is initialized (startedAt is 0 only for an uninitialized uptime feed) and that the grace
            // period has fully elapsed since the sequencer was last restored
            require(sequencerStartedAt != 0 && (block.timestamp - sequencerStartedAt) > $.gracePeriodSeconds, GRACE_PERIOD_NOT_OVER());
        }

        AggregatorV3Interface oracle = AggregatorV3Interface($.oracle);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();

        // Conduct sanity checks
        require(updatedAt + $.stalenessThresholdSeconds >= block.timestamp, STALE_PRICE());
        require(answer > 0, INVALID_PRICE());
        require(answeredInRound >= roundId, INCOMPLETE_PRICE());

        // Return the price and the scaled precision
        price = uint256(answer);
        precision = (10 ** uint256(oracle.decimals()));
    }

    /**
     * @notice Sets the new Chainlink (compatible) oracle
     * @param _oracle The new tranche asset to reference asset oracle
     * @param _stalenessThresholdSeconds The new staleness threshold seconds
     */
    function _setChainlinkOracle(address _oracle, uint48 _stalenessThresholdSeconds) internal {
        // Oracle can be set to the null address since upstream contracts may use an admin set price with the Chainlink (compatible) oracle as a fallback
        require(_oracle == address(0) || _stalenessThresholdSeconds > 0, INVALID_STALENESS_THRESHOLD_SECONDS());
        // A null oracle is only configurable while a stored rate is set, so a composition using the oracle as the stored rate's fallback can never lose both price sources
        // A composition where the oracle prices a mandatory hop must additionally reject a null oracle at its own initializer
        require(_oracle != address(0) || getStoredConversionRateWAD() != SENTINEL_CONVERSION_RATE, NULL_ORACLE_WITHOUT_STORED_RATE());

        IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState storage $ = _getIdenticalAssets_ST_JT_ChainlinkOracle_QuoterStorage();
        $.oracle = _oracle;
        $.stalenessThresholdSeconds = _stalenessThresholdSeconds;

        emit ChainlinkOracleUpdated(_oracle, _stalenessThresholdSeconds);
    }

    /**
     * @notice Sets the new L2 sequencer uptime feed and grace period
     * @dev A null sequencer uptime feed disables the L2 sequencer check
     *      When a feed is set, the grace period must be a positive
     *      duration (mirroring the treatment of the staleness threshold for the price feed)
     * @param _sequencerUptimeFeed The new L2 sequencer uptime feed (set to the null address to disable the check)
     * @param _gracePeriodSeconds The new grace period seconds
     */
    function _setSequencerUptimeFeed(address _sequencerUptimeFeed, uint48 _gracePeriodSeconds) internal {
        require(_sequencerUptimeFeed == address(0) || _gracePeriodSeconds > 0, INVALID_GRACE_PERIOD_SECONDS());

        IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState storage $ = _getIdenticalAssets_ST_JT_ChainlinkOracle_QuoterStorage();
        $.sequencerUptimeFeed = _sequencerUptimeFeed;
        $.gracePeriodSeconds = _gracePeriodSeconds;

        emit SequencerUptimeFeedUpdated(_sequencerUptimeFeed, _gracePeriodSeconds);
    }

    /**
     * @notice Returns a storage pointer to the IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer
     */
    function _getIdenticalAssets_ST_JT_ChainlinkOracle_QuoterStorage() private pure returns (IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState storage $) {
        assembly ("memory-safe") {
            $.slot := IDENTICAL_ASSETS_ST_JT_CHAINLINK_ORACLE_QUOTER_STORAGE_SLOT
        }
    }
}
