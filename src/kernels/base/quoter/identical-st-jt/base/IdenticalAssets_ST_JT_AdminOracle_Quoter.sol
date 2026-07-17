// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IdenticalAssets_ST_JT_Oracle_Quoter } from "./IdenticalAssets_ST_JT_Oracle_Quoter.sol";

/**
 * @title IdenticalAssets_ST_JT_AdminOracle_Quoter
 * @notice Quoter to convert tranche units to/from NAV units using an admin controlled oracle for markets where both tranches use the same tranche units
 * @dev The conversion rate is set purely by an admin
 */
abstract contract IdenticalAssets_ST_JT_AdminOracle_Quoter is IdenticalAssets_ST_JT_Oracle_Quoter {
    /// @notice Thrown when trying to call the oracle querying helper
    error MUST_USE_ADMIN_ORACLE_INPUT();

    /// @notice Thrown when trying to set the conversion rate to the sentinel value (0)
    error INVALID_CONVERSION_RATE();

    /**
     * @notice Initializes the identical assets admin oracle quoter
     * @dev The conversion rate cannot be set to the sentinel value (0)
     * @param _initialConversionRateWAD The initial reference asset to NAV unit conversion rate, scaled to WAD precision
     */
    function __IdenticalAssets_ST_JT_AdminOracle_Quoter_init(uint256 _initialConversionRateWAD) internal onlyInitializing {
        // Validate the conversion rate
        require(_initialConversionRateWAD != SENTINEL_CONVERSION_RATE, INVALID_CONVERSION_RATE());
        // Initialize the oracle quoter with the initial admin set rate
        __IdenticalAssets_ST_JT_Oracle_Quoter_init_unchained(_initialConversionRateWAD);
    }

    /// @inheritdoc IdenticalAssets_ST_JT_Oracle_Quoter
    /// @dev The conversion rate cannot be set to the sentinel value (0)
    /// @dev Access control is enforced by the root setter this dispatches to, a second restricted here would consume a delayed admin operation twice
    function setConversionRate(uint256 _conversionRateWAD, bool _syncBeforeUpdate) public virtual override(IdenticalAssets_ST_JT_Oracle_Quoter) {
        // Validate the conversion rate
        require(_conversionRateWAD != SENTINEL_CONVERSION_RATE, INVALID_CONVERSION_RATE());
        // Update the oracle quoter with the initial admin set rate
        IdenticalAssets_ST_JT_Oracle_Quoter.setConversionRate(_conversionRateWAD, _syncBeforeUpdate);
    }

    /// @inheritdoc IdenticalAssets_ST_JT_Oracle_Quoter
    function _getConversionRateFromOracleWAD() internal pure override(IdenticalAssets_ST_JT_Oracle_Quoter) returns (uint256) {
        revert MUST_USE_ADMIN_ORACLE_INPUT();
    }
}
