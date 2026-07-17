// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20Metadata, IERC4626 } from "../../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { Math } from "../../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD, WAD_DECIMALS } from "../../../../libraries/Constants.sol";
import { IdenticalAssets_ST_JT_ChainlinkOracle_Quoter, IdenticalAssets_ST_JT_Oracle_Quoter } from "./base/IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol";

/**
 * @title IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter
 * @notice Quoter to convert tranche units (ERC4626 vault shares) to/from NAV units by converting the shares to base assets and converting base assets to NAV units using a Chainlink (compatible) oracle or an admin set rate
 * @dev Mandates that the base asset to NAV units uses a Chainlink (compatible) oracle with an admin set rate override
 * @dev The senior and junior tranches must have the same ERC4626 vault share as their tranche unit
 * @dev Use case: Convert sNUSD (Tranche unit) to NUSD (base assets) using ERC4626's convertToAssets and convert NUSD to USD (NAV unit) using its Redstone fundamental price feed or an admin set rate
 */
abstract contract IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter is IdenticalAssets_ST_JT_ChainlinkOracle_Quoter {
    using Math for uint256;

    /// @dev The share amount to pass to convertToAssets() such that the result is scaled to WAD precision
    uint256 internal immutable ERC4626_SHARES_TO_CONVERT_TO_ASSETS;

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

    /// @notice Constructs the ERC4626 vault shares oracle quoter
    constructor() {
        // NOTE: Both tranche assets are identical ERC4626 vault shares
        // Compute the share amount to pass to convertToAssets() such that the result is scaled to WAD precision
        // OUTPUT_DECIMALS = INPUT_DECIMALS + BASE_ASSET_DECIMALS - TRANCHE_DECIMALS
        // For OUTPUT_DECIMALS to have WAD_DECIMALS of precision:
        // INPUT_DECIMALS = WAD_DECIMALS + TRANCHE_DECIMALS - BASE_ASSET_DECIMALS
        // OUTPUT_DECIMALS = (WAD_DECIMALS + TRANCHE_DECIMALS - BASE_ASSET_DECIMALS) + BASE_ASSET_DECIMALS - TRANCHE_DECIMALS
        // OUTPUT_DECIMALS = WAD_DECIMALS
        ERC4626_SHARES_TO_CONVERT_TO_ASSETS = 10 ** (WAD_DECIMALS + IERC4626(ST_ASSET).decimals() - IERC20Metadata(IERC4626(ST_ASSET).asset()).decimals());
    }

    /// @notice Initializes the identical ERC4626 vault shares Chainlink (compatible) oracle quoter and its inherited contracts
    /// @param _params The quoter-specific initialization parameters
    function __IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter_init(ST_JT_QuoterSpecificParams calldata _params) internal onlyInitializing {
        __IdenticalAssets_ST_JT_Oracle_Quoter_init_unchained(_params.initialConversionRateWAD);
        __IdenticalAssets_ST_JT_ChainlinkOracle_Quoter_init_unchained(
            _params.baseAssetToNavAssetOracle, _params.stalenessThresholdSeconds, _params.sequencerUptimeFeed, _params.gracePeriodSeconds
        );
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
        override(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter)
        returns (uint256 trancheToNAVUnitConversionRateWAD)
    {
        // Fetch the conversion rate from the tranche asset (ERC4626 share) to its underlying asset, scaled to WAD precision
        uint256 trancheUnitToBaseAssetsConversionRateWAD = IERC4626(ST_ASSET).convertToAssets(ERC4626_SHARES_TO_CONVERT_TO_ASSETS);

        // Resolve the vault base asset to NAV unit conversion rate, scaled to WAD precision
        uint256 baseAssetToNAVUnitConversionRateWAD = getStoredConversionRateWAD();
        // If the stored conversion rate is the sentinel value, query the oracle for the rate
        if (baseAssetToNAVUnitConversionRateWAD == SENTINEL_CONVERSION_RATE) {
            baseAssetToNAVUnitConversionRateWAD = _getConversionRateFromOracleWAD();
        }

        // Calculate the conversion rate from tranche to NAV units, scaled to WAD precision
        trancheToNAVUnitConversionRateWAD = trancheUnitToBaseAssetsConversionRateWAD.mulDiv(baseAssetToNAVUnitConversionRateWAD, WAD, Math.Rounding.Floor);
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
