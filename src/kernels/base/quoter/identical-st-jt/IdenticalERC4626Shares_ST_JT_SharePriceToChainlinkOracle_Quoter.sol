// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IdenticalAssets_ST_JT_ChainlinkOracle_Quoter } from "./base/IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol";
import { IdenticalAssets_ST_JT_Oracle_Quoter } from "./base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { IdenticalERC4626Shares_ST_JT_Oracle_Quoter, Math, WAD } from "./base/IdenticalERC4626Shares_ST_JT_Oracle_Quoter.sol";

/**
 * @title IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter
 * @dev The senior and junior tranches must have the same ERC4626 vault share as its tranche unit
 * @dev Use case: Convert sNUSD (Tranche unit) to NUSD (base assets) using ERC4626's convertToAssets and convert NUSD to USD (NAV unit) using its Redstone fundamental price feed or an admin set rate
 */
abstract contract IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter is
    IdenticalERC4626Shares_ST_JT_Oracle_Quoter,
    IdenticalAssets_ST_JT_ChainlinkOracle_Quoter
{
    using Math for uint256;

    /**
     * @notice The quoter-specific initialization parameters
     * @custom:field initialConversionRateWAD - The initial conversion rate as defined by the oracle, scaled to WAD precision
     * @custom:field baseAssetToNavAssetOracle - The ERC4626 base asset to NAV accounting asset oracle
     * @custom:field stalenessThresholdSeconds - The staleness threshold in seconds
     * @custom:field sequencerUptimeFeed - The L2 sequencer uptime feed used to gate price queries (null to disable the check)
     * @custom:field gracePeriodSeconds - The grace period that must elapse after the L2 sequencer is restored before trusting the price
     */
    struct ST_JT_QuoterSpecificParams {
        uint256 initialConversionRateWAD;
        address baseAssetToNavAssetOracle;
        uint48 stalenessThresholdSeconds;
        address sequencerUptimeFeed;
        uint48 gracePeriodSeconds;
    }

    /// @notice Thrown when the stored conversion rate is the sentinel but no usable chainlink oracle is configured
    /// @dev A usable oracle has a non-null address and a positive staleness threshold
    error SENTINEL_RATE_REQUIRES_CHAINLINK_ORACLE();

    /// @notice Initializes the identical ERC4626 shares chainlink oracle quoter and its inherited contracts
    /// @param _params The quoter-specific initialization parameters
    function __IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter_init(ST_JT_QuoterSpecificParams calldata _params) internal onlyInitializing {
        __IdenticalAssets_ST_JT_Oracle_Quoter_init_unchained(_params.initialConversionRateWAD);
        __IdenticalAssets_ST_JT_ChainlinkOracle_Quoter_init_unchained(
            _params.baseAssetToNavAssetOracle, _params.stalenessThresholdSeconds, _params.sequencerUptimeFeed, _params.gracePeriodSeconds
        );

        // A rate matching the sentinel means this market reads its price from the chainlink oracle, so the oracle must be
        // usable: a non-null address and a positive staleness threshold. The setters already reject a broken oracle
        // (their post-write sync reads it and reverts); initialize does not sync, so check it here instead.
        if (getStoredConversionRateWAD() == SENTINEL_CONVERSION_RATE) {
            (address oracle, uint48 stalenessThresholdSeconds) = _getChainlinkOracle();
            require(oracle != address(0) && stalenessThresholdSeconds > 0, SENTINEL_RATE_REQUIRES_CHAINLINK_ORACLE());
        }
    }

    /**
     * @notice Returns the conversion rate from tranche units to NAV units, scaled to WAD precision
     * @dev This function assumes that the tranche token is an ERC4626 compliant vault
     * @dev The conversion rate is calculated as the value of tranche asset in base asset * value of base asset in NAV units
     * @return trancheToNAVUnitConversionRateWAD The conversion rate from tranche token units to NAV units, scaled to WAD precision
     */
    function getTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        virtual
        override(IdenticalERC4626Shares_ST_JT_Oracle_Quoter, IdenticalAssets_ST_JT_ChainlinkOracle_Quoter)
        returns (uint256 trancheToNAVUnitConversionRateWAD)
    {
        return IdenticalERC4626Shares_ST_JT_Oracle_Quoter.getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /// @notice Returns the conversion rate from the ERC4626 base asset to NAV units, scaled to WAD precision
    /// @return baseAssetToNAVUnitConversionRateWAD The conversion rate from the ERC4626 base asset to NAV units, scaled to WAD precision
    function _getConversionRateFromOracleWAD()
        internal
        view
        override(IdenticalAssets_ST_JT_Oracle_Quoter)
        returns (uint256 baseAssetToNAVUnitConversionRateWAD)
    {
        // Fetch the ERC4626 base asset price in NAV accounting assets and its precision
        (uint256 baseAssetPriceInNavAssets, uint256 pricePrecision) = _queryChainlinkOracle();
        // Convert the price to be in WAD precision
        return baseAssetPriceInNavAssets.mulDiv(WAD, pricePrecision, Math.Rounding.Floor);
    }
}
