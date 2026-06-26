// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IdenticalAssets_ST_JT_AdminOracleQuoter } from "./base/IdenticalAssets_ST_JT_AdminOracleQuoter.sol";
import { IdenticalAssets_ST_JT_ChainlinkOracleQuoter } from "./base/IdenticalAssets_ST_JT_ChainlinkOracleQuoter.sol";
import { IdenticalAssets_ST_JT_OracleQuoter } from "./base/IdenticalAssets_ST_JT_OracleQuoter.sol";

/**
 * @title IdenticalAssets_ST_JT_ChainlinkToAdminOracleQuoter
 * @dev Mandates that the reference asset to NAV units uses an admin controlled oracle
 * @dev Use case: Convert PT-USDe (Tranche unit) to USDe (Reference asset) using a Chainlink (compatible) oracle and convert USDe to USD (NAV unit) using an admin set rate
 */
abstract contract IdenticalAssets_ST_JT_ChainlinkToAdminOracleQuoter is IdenticalAssets_ST_JT_ChainlinkOracleQuoter, IdenticalAssets_ST_JT_AdminOracleQuoter {
    /**
     * @notice Initializes the identical assets chainlink oracle quoter and the base identical assets oracle quoter
     * @param _initialConversionRateWAD The initial conversion rate as defined by the oracle, scaled to WAD precision
     * @param _trancheAssetToReferenceAssetOracle The tranche asset to reference asset oracle
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     */
    function __IdenticalAssets_ST_JT_ChainlinkToAdminOracleQuoter_init(
        uint256 _initialConversionRateWAD,
        address _trancheAssetToReferenceAssetOracle,
        uint48 _stalenessThresholdSeconds
    )
        internal
        onlyInitializing
    {
        __IdenticalAssets_ST_JT_AdminOracleQuoter_init(_initialConversionRateWAD);
        __IdenticalAssets_ST_JT_ChainlinkOracleQuoter_init_unchained(_trancheAssetToReferenceAssetOracle, _stalenessThresholdSeconds);
    }

    /// @inheritdoc IdenticalAssets_ST_JT_AdminOracleQuoter
    function setConversionRate(
        uint256 _conversionRateWAD,
        bool _syncBeforeUpdate
    )
        public
        override(IdenticalAssets_ST_JT_OracleQuoter, IdenticalAssets_ST_JT_AdminOracleQuoter)
        restricted
    {
        IdenticalAssets_ST_JT_AdminOracleQuoter.setConversionRate(_conversionRateWAD, _syncBeforeUpdate);
    }

    /// @inheritdoc IdenticalAssets_ST_JT_ChainlinkOracleQuoter
    function getTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        override(IdenticalAssets_ST_JT_OracleQuoter, IdenticalAssets_ST_JT_ChainlinkOracleQuoter)
        returns (uint256 trancheToNAVUnitConversionRateWAD)
    {
        return IdenticalAssets_ST_JT_ChainlinkOracleQuoter.getTrancheUnitToNAVUnitConversionRateWAD();
    }
}
