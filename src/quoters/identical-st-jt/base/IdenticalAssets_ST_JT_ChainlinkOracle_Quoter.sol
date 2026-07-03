// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { AggregatorV3Interface } from "../../../interfaces/external/chainlink/AggregatorV3Interface.sol";
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
    bytes32 private constant IDENTICAL_ASSETS_ST_JT_CHAINLINK_ORACLE_QUOTER_STORAGE_SLOT = 0x8e7ed06a76894329325a62f314422440f9b1abd4bff8ec1da566b06f1d6e5900;

    /// @dev Storage state for the Royco identical assets chainlink oracle quoter
    /// @custom:storage-location erc7201:Royco.storage.IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState
    struct IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState {
        address oracle;
        uint48 stalenessThresholdSeconds;
    }

    /// @notice Emitted when the identical assets chainlink oracle is updated
    event ChainlinkOracleUpdated(address indexed oracle, uint48 stalenessThresholdSeconds);

    /// @notice Thrown when the staleness threshold seconds is zero
    error INVALID_STALENESS_THRESHOLD_SECONDS();

    /// @notice Thrown when the price is stale
    error STALE_PRICE();

    /// @notice Thrown when the price is invalid
    error INVALID_PRICE();

    /// @notice Thrown when the price is incomplete
    error INCOMPLETE_PRICE();

    /**
     * @notice Initializes the identical assets chainlink oracle quoter
     * @param _oracle The chainlink (compatible) oracle used to price an asset
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     */
    function __IdenticalAssets_ST_JT_ChainlinkOracle_Quoter_init_unchained(address _oracle, uint48 _stalenessThresholdSeconds) internal onlyInitializing {
        _setChainlinkOracle(_oracle, _stalenessThresholdSeconds);
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

    /**
     * @notice Sets the chainlink oracle for pricing an asset
     * @param _oracle The new chainlink (compatible) oracle for pricing an asset
     * @param _stalenessThresholdSeconds The new staleness threshold seconds
     * @param _syncBeforeUpdate Whether to sync the tranche accounting before updating the chainlink oracle
     */
    function setChainlinkOracle(address _oracle, uint48 _stalenessThresholdSeconds, bool _syncBeforeUpdate) external restricted {
        // If specified, sync the tranche accounting before updating the chainlink oracle
        if (_syncBeforeUpdate) ROYCO_DAY_KERNEL.syncTrancheAccounting();
        // Update the chainlink oracle
        _setChainlinkOracle(_oracle, _stalenessThresholdSeconds);
        // Sync the tranche accounting after updating the chainlink oracle
        ROYCO_DAY_KERNEL.syncTrancheAccounting();
    }

    /// @dev Returns the chainlink oracle configuration for this quoter
    function getChainlinkOracleConfiguration() external pure returns (IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState memory) {
        return _getIdenticalAssets_ST_JT_ChainlinkOracle_QuoterStorage();
    }

    /**
     * @notice Queries the chainlink oracle for the price
     * @dev The price is returned as the answer from the latest round
     * @return price The price from the latest round
     * @return precision The precision of the price
     */
    function _queryChainlinkOracle() internal view returns (uint256 price, uint256 precision) {
        // Fetch the price of the asset
        IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState storage $ = _getIdenticalAssets_ST_JT_ChainlinkOracle_QuoterStorage();
        AggregatorV3Interface oracle = AggregatorV3Interface($.oracle);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();

        // Conduct sanity checks
        require(updatedAt + $.stalenessThresholdSeconds >= block.timestamp, STALE_PRICE());
        require(answer > 0, INVALID_PRICE());
        require(answeredInRound >= roundId, INCOMPLETE_PRICE());

        // Return the price and the scaled precision
        price = uint256(answer);
        precision = 10 ** uint256(oracle.decimals());
    }

    /**
     * @notice Sets the new chainlink oracle
     * @param _oracle The new tranche asset to reference asset oracle
     * @param _stalenessThresholdSeconds The new staleness threshold seconds
     */
    function _setChainlinkOracle(address _oracle, uint48 _stalenessThresholdSeconds) internal {
        require(_oracle != address(0), NULL_ADDRESS());
        require(_stalenessThresholdSeconds > 0, INVALID_STALENESS_THRESHOLD_SECONDS());

        IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState storage $ = _getIdenticalAssets_ST_JT_ChainlinkOracle_QuoterStorage();
        $.oracle = _oracle;
        $.stalenessThresholdSeconds = _stalenessThresholdSeconds;

        emit ChainlinkOracleUpdated(_oracle, _stalenessThresholdSeconds);
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
