// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IdenticalAssets_ST_JT_AdminOracle_Quoter } from "./base/IdenticalAssets_ST_JT_AdminOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "./base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { IdenticalERC4626Shares_ST_JT_Oracle_Quoter } from "./base/IdenticalERC4626Shares_ST_JT_Oracle_Quoter.sol";

/**
 * @title IdenticalERC4626Shares_ST_JT_SharePriceToAdminOracle_Quoter
 * @dev Mandates that the base asset to NAV units uses an admin controlled oracle
 * @dev The senior and junior tranches must have the same ERC4626 vault share as its tranche unit
 * @dev Use case: Convert sUSDe (Tranche unit) to USDe (base assets) using ERC4626's convertToAssets and convert USDe to USD (NAV unit) using an admin set rate
 */
abstract contract IdenticalERC4626Shares_ST_JT_SharePriceToAdminOracle_Quoter is IdenticalERC4626Shares_ST_JT_Oracle_Quoter, IdenticalAssets_ST_JT_AdminOracle_Quoter {
    /**
     * @notice Initializes the identical ERC4626 shares admin oracle quoter and the base identical assets oracle quoter
     * @param _initialConversionRateWAD The initial conversion rate as defined by the oracle, scaled to WAD precision
     */
    function __IdenticalERC4626Shares_ST_JT_SharePriceToAdminOracle_Quoter_init(uint256 _initialConversionRateWAD) internal onlyInitializing {
        __IdenticalAssets_ST_JT_AdminOracle_Quoter_init(_initialConversionRateWAD);
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

    /// @inheritdoc IdenticalERC4626Shares_ST_JT_Oracle_Quoter
    function getTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        override(IdenticalAssets_ST_JT_Oracle_Quoter, IdenticalERC4626Shares_ST_JT_Oracle_Quoter)
        returns (uint256 trancheToNAVUnitConversionRateWAD)
    {
        return IdenticalERC4626Shares_ST_JT_Oracle_Quoter.getTrancheUnitToNAVUnitConversionRateWAD();
    }
}
