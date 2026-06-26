// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IdenticalAssets_ST_JT_AdminOracleQuoter } from "./base/IdenticalAssets_ST_JT_AdminOracleQuoter.sol";
import { IdenticalAssets_ST_JT_OracleQuoter } from "./base/IdenticalAssets_ST_JT_OracleQuoter.sol";
import { IdenticalERC4626Shares_ST_JT_OracleQuoter } from "./base/IdenticalERC4626Shares_ST_JT_OracleQuoter.sol";

/**
 * @title IdenticalERC4626Shares_ST_JT_ToAdminOracleQuoter
 * @dev Mandates that the base asset to NAV units uses an admin controlled oracle
 * @dev The senior and junior tranches must have the same ERC4626 vault share as its tranche unit
 * @dev Use case: Convert sUSDe (Tranche unit) to USDe (base assets) using ERC4626's convertToAssets and convert USDe to USD (NAV unit) using an admin set rate
 */
abstract contract IdenticalERC4626Shares_ST_JT_ToAdminOracleQuoter is IdenticalERC4626Shares_ST_JT_OracleQuoter, IdenticalAssets_ST_JT_AdminOracleQuoter {
    /**
     * @notice Initializes the identical ERC4626 shares admin oracle quoter and the base identical assets oracle quoter
     * @param _initialConversionRateWAD The initial conversion rate as defined by the oracle, scaled to WAD precision
     */
    function __IdenticalERC4626Shares_ST_JT_ToAdminOracleQuoter_init(uint256 _initialConversionRateWAD) internal onlyInitializing {
        __IdenticalAssets_ST_JT_AdminOracleQuoter_init(_initialConversionRateWAD);
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

    /// @inheritdoc IdenticalERC4626Shares_ST_JT_OracleQuoter
    function getTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        override(IdenticalAssets_ST_JT_OracleQuoter, IdenticalERC4626Shares_ST_JT_OracleQuoter)
        returns (uint256 trancheToNAVUnitConversionRateWAD)
    {
        return IdenticalERC4626Shares_ST_JT_OracleQuoter.getTrancheUnitToNAVUnitConversionRateWAD();
    }
}
