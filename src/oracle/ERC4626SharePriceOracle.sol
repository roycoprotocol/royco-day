// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20Metadata, IERC4626 } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { WAD_DECIMALS } from "../libraries/Constants.sol";
import { ChainlinkPriceOracleBase } from "./base/ChainlinkPriceOracleBase.sol";

/**
 * @title ERC4626SharePriceOracle
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Oracle to price ERC4626 vault shares in NAV units by converting the shares to base assets and pricing base assets using a Chainlink (compatible) oracle
 * @dev The collateral asset must be an ERC4626 vault share
 * @dev Use case: price sUSDe (collateral asset) in USDe (base assets) using ERC4626's convertToAssets and price USDe in USD (NAV unit) using its fundamental (solvency-based) price feed
 */
contract ERC4626SharePriceOracle is ChainlinkPriceOracleBase {
    /// @dev The share amount to pass to convertToAssets() such that the result is scaled to WAD precision
    uint256 internal immutable ERC4626_SHARES_TO_CONVERT_TO_ASSETS;

    /**
     * @notice Constructs the ERC4626 share price to Chainlink (compatible) oracle composed collateral oracle
     * @param _collateralAsset The ERC4626 vault share that is the collateral asset
     * @param _baseAssetToNavAssetOracle The Chainlink (compatible) oracle pricing the vault's base asset in NAV units
     */
    constructor(address _collateralAsset, address _baseAssetToNavAssetOracle) ChainlinkPriceOracleBase(_collateralAsset, _baseAssetToNavAssetOracle) {
        // Compute the share amount to pass to convertToAssets() such that the result is scaled to WAD precision
        // OUTPUT_DECIMALS = INPUT_DECIMALS + BASE_ASSET_DECIMALS - SHARE_DECIMALS
        // For OUTPUT_DECIMALS to have WAD_DECIMALS of precision:
        // INPUT_DECIMALS = WAD_DECIMALS + SHARE_DECIMALS - BASE_ASSET_DECIMALS
        // OUTPUT_DECIMALS = (WAD_DECIMALS + SHARE_DECIMALS - BASE_ASSET_DECIMALS) + BASE_ASSET_DECIMALS - SHARE_DECIMALS
        // OUTPUT_DECIMALS = WAD_DECIMALS
        ERC4626_SHARES_TO_CONVERT_TO_ASSETS =
            10 ** (WAD_DECIMALS + IERC4626(_collateralAsset).decimals() - IERC20Metadata(IERC4626(_collateralAsset).asset()).decimals());
    }

    /// @inheritdoc ChainlinkPriceOracleBase
    function _getCollateralToReferenceAssetConversionRateWAD()
        internal
        view
        override(ChainlinkPriceOracleBase)
        returns (uint256 collateralToReferenceAssetConversionRateWAD)
    {
        return IERC4626(COLLATERAL_ASSET).convertToAssets(ERC4626_SHARES_TO_CONVERT_TO_ASSETS);
    }
}
