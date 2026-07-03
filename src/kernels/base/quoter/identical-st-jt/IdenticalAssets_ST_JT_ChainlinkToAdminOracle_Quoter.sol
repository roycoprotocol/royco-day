// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IdenticalAssets_ST_JT_AdminOracle_Quoter } from "./base/IdenticalAssets_ST_JT_AdminOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_ChainlinkOracle_Quoter } from "./base/IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "./base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";

/**
 * @title IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter
 * @dev Mandates that the reference asset to NAV units uses an admin controlled oracle
 * @dev Use case: Convert PT-USDe (Tranche unit) to USDe (Reference asset) using a Chainlink (compatible) oracle and convert USDe to USD (NAV unit) using an admin set rate
 */
abstract contract IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter is IdenticalAssets_ST_JT_ChainlinkOracle_Quoter, IdenticalAssets_ST_JT_AdminOracle_Quoter {
    /**
     * @notice Initializes the identical assets chainlink oracle quoter and the base identical assets oracle quoter
     * @param _initialConversionRateWAD The initial conversion rate as defined by the oracle, scaled to WAD precision
     * @param _trancheAssetToReferenceAssetOracle The tranche asset to reference asset oracle
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     */
    function __IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter_init(
        uint256 _initialConversionRateWAD,
        address _trancheAssetToReferenceAssetOracle,
        uint48 _stalenessThresholdSeconds
    )
        internal
        onlyInitializing
    {
        __IdenticalAssets_ST_JT_AdminOracle_Quoter_init(_initialConversionRateWAD);
        __IdenticalAssets_ST_JT_ChainlinkOracle_Quoter_init_unchained(_trancheAssetToReferenceAssetOracle, _stalenessThresholdSeconds);
    }

    /// @inheritdoc IdenticalAssets_ST_JT_AdminOracle_Quoter
    function setConversionRate(
        uint256 _conversionRateWAD,
        bool _syncBeforeUpdate
    )
        public
        override(IdenticalAssets_ST_JT_Oracle_Quoter, IdenticalAssets_ST_JT_AdminOracle_Quoter)
        restricted
    {
        IdenticalAssets_ST_JT_AdminOracle_Quoter.setConversionRate(_conversionRateWAD, _syncBeforeUpdate);
    }

    /// @inheritdoc IdenticalAssets_ST_JT_ChainlinkOracle_Quoter
    function getTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        override(IdenticalAssets_ST_JT_Oracle_Quoter, IdenticalAssets_ST_JT_ChainlinkOracle_Quoter)
        returns (uint256 trancheToNAVUnitConversionRateWAD)
    {
        return IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.getTrancheUnitToNAVUnitConversionRateWAD();
    }
}
