// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IMachine } from "../interfaces/external/makina/IMachine.sol";
import { WAD_DECIMALS } from "../libraries/Constants.sol";
import { ChainlinkPriceOracleBase } from "./base/ChainlinkPriceOracleBase.sol";

/**
 * @title MakinaSharePriceOracle
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Oracle to price Makina machine shares in NAV units by converting the shares to accounting assets and pricing accounting assets using a Chainlink (compatible) oracle
 * @dev The collateral asset is the machine's share token, resolved from the machine at construction
 * @dev Use case: price DUSD (collateral asset) in USDC (accounting assets) using the machine's convertToAssets and price USDC in USD (NAV unit) using its Chainlink (compatible) fundamental price feed
 */
contract MakinaSharePriceOracle is ChainlinkPriceOracleBase {
    /// @notice The Makina machine whose share token is the collateral asset
    address public immutable MAKINA_MACHINE;

    /// @dev The share amount to pass to convertToAssets() such that the result is scaled to WAD precision
    uint256 internal immutable MACHINE_SHARES_TO_CONVERT_TO_ASSETS;

    /**
     * @notice Constructs the Makina share price to Chainlink (compatible) oracle composed collateral oracle
     * @param _makinaMachine The Makina machine whose share token is the collateral asset
     * @param _accountingAssetToNavAssetOracle The Chainlink (compatible) oracle pricing the machine's accounting asset in NAV units
     */
    constructor(
        address _makinaMachine,
        address _accountingAssetToNavAssetOracle
    )
        ChainlinkPriceOracleBase(IMachine(_makinaMachine).shareToken(), _accountingAssetToNavAssetOracle)
    {
        MAKINA_MACHINE = _makinaMachine;

        // Compute the share amount to pass to convertToAssets() such that the result is scaled to WAD precision
        // OUTPUT_DECIMALS = INPUT_DECIMALS + ACCOUNTING_ASSET_DECIMALS - SHARE_DECIMALS
        // For OUTPUT_DECIMALS to have WAD_DECIMALS of precision:
        // INPUT_DECIMALS = WAD_DECIMALS + SHARE_DECIMALS - ACCOUNTING_ASSET_DECIMALS
        // OUTPUT_DECIMALS = (WAD_DECIMALS + SHARE_DECIMALS - ACCOUNTING_ASSET_DECIMALS) + ACCOUNTING_ASSET_DECIMALS - SHARE_DECIMALS
        // OUTPUT_DECIMALS = WAD_DECIMALS
        MACHINE_SHARES_TO_CONVERT_TO_ASSETS =
            10 ** (WAD_DECIMALS + IERC20Metadata(COLLATERAL_ASSET).decimals() - IERC20Metadata(IMachine(_makinaMachine).accountingToken()).decimals());
    }

    /// @inheritdoc ChainlinkPriceOracleBase
    function _getCollateralToReferenceAssetConversionRateWAD()
        internal
        view
        override(ChainlinkPriceOracleBase)
        returns (uint256 collateralToReferenceAssetConversionRateWAD)
    {
        return IMachine(MAKINA_MACHINE).convertToAssets(MACHINE_SHARES_TO_CONVERT_TO_ASSETS);
    }
}
