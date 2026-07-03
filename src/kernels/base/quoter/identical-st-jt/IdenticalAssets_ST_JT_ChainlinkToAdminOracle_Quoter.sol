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
     * @notice The quoter-specific initialization parameters
     * @custom:field initialConversionRateWAD - The initial conversion rate as defined by the oracle, scaled to WAD precision
     * @custom:field trancheAssetToReferenceAssetOracle - The tranche asset to reference asset oracle
     * @custom:field stalenessThresholdSeconds - The staleness threshold in seconds
     */
    struct QuoterSpecificParams {
        uint256 initialConversionRateWAD;
        address trancheAssetToReferenceAssetOracle;
        uint48 stalenessThresholdSeconds;
    }

    /**
     * @notice Initializes the identical assets chainlink oracle quoter and the base identical assets oracle quoter
     * @param _params The quoter-specific initialization parameters
     */
    function __IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter_init(QuoterSpecificParams calldata _params) internal onlyInitializing {
        __IdenticalAssets_ST_JT_AdminOracle_Quoter_init(_params.initialConversionRateWAD);
        __IdenticalAssets_ST_JT_ChainlinkOracle_Quoter_init_unchained(_params.trancheAssetToReferenceAssetOracle, _params.stalenessThresholdSeconds);
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
