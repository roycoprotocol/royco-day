// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { AggregatorV3Interface } from "../../../../interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IdenticalAssetsOracleQuoter } from "./IdenticalAssetsOracleQuoter.sol";

/**
 * @title IdenticalAssetsChainlinkOracleQuoter
 * @notice Quoter to convert tranche units to/from NAV units using a Chainlink (compatible) oracle to convert tranche units to reference assets which uses an admin or oracle set rate to convert to NAV units
 * @dev Use case: Convert PT-USDE (Tranche unit) to USDE (Reference asset) using a Chainlink (compatible) oracle and convert USDE to USD (NAV unit) using an admin or oracle set rate
 */
abstract contract IdenticalAssetsChainlinkOracleQuoter is IdenticalAssetsOracleQuoter {
    using Math for uint256;

    /// @dev Storage slot for IdenticalAssetsChainlinkOracleQuoterState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.IdenticalAssetsChainlinkOracleQuoterState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant IDENTICAL_ASSETS_CHAINLINK_ORACLE_QUOTER_STORAGE_SLOT = 0x36321e8ea9ef16a1b272d9cece1e9b80ed6532a47572ae703d9c65a3a5fa1800;

    /// @dev Storage state for the Royco identical assets chainlink oracle quoter
    /// @custom:storage-location erc7201:Royco.storage.IdenticalAssetsChainlinkOracleQuoterState
    struct IdenticalAssetsChainlinkOracleQuoterState {
        address trancheAssetToReferenceAssetOracle;
        uint8 trancheAssetToReferenceAssetOracleDecimalPrecision;
        uint48 stalenessThresholdSeconds;
    }

    /// @notice Emitted when the identical assets chainlink oracle quoter is updated
    event IdenticalAssetsChainlinkOracleUpdated(
        address indexed trancheAssetToReferenceAssetOracle, uint8 trancheAssetToReferenceAssetOracleDecimalPrecision, uint48 stalenessThresholdSeconds
    );

    /// @notice Thrown when the tranche asset to reference asset oracle is the zero address
    error INVALID_TRANCHE_ASSET_TO_REFERENCE_ASSET_ORACLE();

    /// @notice Thrown when the staleness threshold seconds is zero
    error INVALID_STALENESS_THRESHOLD_SECONDS();

    /// @notice Thrown when the price is stale
    error PRICE_STALE();

    /// @notice Thrown when the price is invalid
    error PRICE_INVALID();

    /// @notice Thrown when the price is incomplete
    error PRICE_INCOMPLETE();

    /**
     * @notice Initializes the identical assets chainlink oracle quoter and the base identical assets oracle quoter
     * @param _initialConversionRateWAD The initial conversion rate as defined by the oracle, scaled to WAD precision
     * @param _trancheAssetToReferenceAssetOracle The tranche asset to reference asset oracle
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     */
    function __IdenticalAssetsChainlinkOracleQuoter_init(
        uint256 _initialConversionRateWAD,
        address _trancheAssetToReferenceAssetOracle,
        uint48 _stalenessThresholdSeconds
    )
        internal
        onlyInitializing
    {
        __IdenticalAssetsOracleQuoter_init_unchained(_initialConversionRateWAD);
        __IdenticalAssetsChainlinkOracleQuoter_init_unchained(_trancheAssetToReferenceAssetOracle, _stalenessThresholdSeconds);
    }

    /**
     * @notice Initializes the identical assets chainlink oracle quoter
     * @param _trancheAssetToReferenceAssetOracle The tranche asset to reference asset oracle
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     */
    function __IdenticalAssetsChainlinkOracleQuoter_init_unchained(
        address _trancheAssetToReferenceAssetOracle,
        uint48 _stalenessThresholdSeconds
    )
        internal
        onlyInitializing
    {
        _setTrancheAssetToReferenceAssetOracle(_trancheAssetToReferenceAssetOracle, _stalenessThresholdSeconds);
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
        override(IdenticalAssetsOracleQuoter)
        returns (uint256 trancheToNAVUnitConversionRateWAD)
    {
        // Fetch the Tranche Asset to the reference asset
        IdenticalAssetsChainlinkOracleQuoterState storage $ = _getIdenticalAssetsChainlinkOracleQuoterStorage();
        (uint256 trancheAssetPriceInReferenceAsset, uint256 precision) =
            _queryChainlinkOracle($.trancheAssetToReferenceAssetOracle, $.stalenessThresholdSeconds, $.trancheAssetToReferenceAssetOracleDecimalPrecision);

        // Resolve the reference asset to NAV unit conversion rate, scaled to WAD precision
        uint256 referenceAssetToNAVUnitConversionRateWAD = getStoredConversionRateWAD();
        // If the stored conversion rate is the sentinel value, the cache hasn't been warmed, so query the oracle for the rate
        if (referenceAssetToNAVUnitConversionRateWAD == SENTINEL_CONVERSION_RATE) referenceAssetToNAVUnitConversionRateWAD = _getConversionRateFromOracleWAD();

        // Calculate the conversion rate from tranche to NAV units, scaled to WAD precision
        trancheToNAVUnitConversionRateWAD = trancheAssetPriceInReferenceAsset.mulDiv(referenceAssetToNAVUnitConversionRateWAD, precision, Math.Rounding.Floor);
    }

    /**
     * @notice Sets the tranche asset to reference asset oracle
     * @param _trancheAssetToReferenceAssetOracle The new tranche asset to reference asset oracle
     * @param _stalenessThresholdSeconds The new staleness threshold seconds
     */
    function setTrancheAssetToReferenceAssetOracle(address _trancheAssetToReferenceAssetOracle, uint48 _stalenessThresholdSeconds) external restricted {
        _setTrancheAssetToReferenceAssetOracle(_trancheAssetToReferenceAssetOracle, _stalenessThresholdSeconds);
    }

    /// @dev Returns the chainlink oracle configuration for this quoter
    function getChainlinkOracleConfiguration() external pure returns (IdenticalAssetsChainlinkOracleQuoterState memory) {
        return _getIdenticalAssetsChainlinkOracleQuoterStorage();
    }

    /**
     * @notice Queries the chainlink oracle for the price
     * @dev The price is returned as the answer from the latest round
     * @param _oracle The oracle to query
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     * @param _decimalPrecision The decimal precision of the price, typically Oracle.decimals()
     * @return price The price from the latest round
     * @return precision The precision of the price
     */
    function _queryChainlinkOracle(
        address _oracle,
        uint256 _stalenessThresholdSeconds,
        uint256 _decimalPrecision
    )
        internal
        view
        returns (uint256 price, uint256 precision)
    {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = AggregatorV3Interface(_oracle).latestRoundData();

        require(updatedAt + _stalenessThresholdSeconds >= block.timestamp, PRICE_STALE());
        require(answer > 0, PRICE_INVALID());
        require(answeredInRound >= roundId, PRICE_INCOMPLETE());

        price = uint256(answer);
        precision = 10 ** uint256(_decimalPrecision);
    }

    /**
     * @notice Sets the tranche asset to reference asset oracle
     * @param _trancheAssetToReferenceAssetOracle The new tranche asset to reference asset oracle
     * @param _stalenessThresholdSeconds The new staleness threshold seconds
     */
    function _setTrancheAssetToReferenceAssetOracle(address _trancheAssetToReferenceAssetOracle, uint48 _stalenessThresholdSeconds) internal {
        require(_trancheAssetToReferenceAssetOracle != address(0), INVALID_TRANCHE_ASSET_TO_REFERENCE_ASSET_ORACLE());
        require(_stalenessThresholdSeconds > 0, INVALID_STALENESS_THRESHOLD_SECONDS());

        IdenticalAssetsChainlinkOracleQuoterState storage $ = _getIdenticalAssetsChainlinkOracleQuoterStorage();
        $.trancheAssetToReferenceAssetOracle = _trancheAssetToReferenceAssetOracle;
        $.trancheAssetToReferenceAssetOracleDecimalPrecision = AggregatorV3Interface(_trancheAssetToReferenceAssetOracle).decimals();
        $.stalenessThresholdSeconds = _stalenessThresholdSeconds;

        emit IdenticalAssetsChainlinkOracleUpdated(
            _trancheAssetToReferenceAssetOracle, $.trancheAssetToReferenceAssetOracleDecimalPrecision, _stalenessThresholdSeconds
        );
    }

    /**
     * @notice Returns a storage pointer to the IdenticalAssetsChainlinkOracleQuoterState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer
     */
    function _getIdenticalAssetsChainlinkOracleQuoterStorage() private pure returns (IdenticalAssetsChainlinkOracleQuoterState storage $) {
        assembly ("memory-safe") {
            $.slot := IDENTICAL_ASSETS_CHAINLINK_ORACLE_QUOTER_STORAGE_SLOT
        }
    }
}
