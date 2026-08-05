// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IMachine } from "../interfaces/external/makina/IMachine.sol";
import { WAD_DECIMALS } from "../libraries/Constants.sol";
import { NAV_UNIT } from "../libraries/Units.sol";
import { ChainlinkPriceOracleBase } from "./base/ChainlinkPriceOracleBase.sol";

/**
 * @title MakinaSharePriceOracle
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Oracle to price Makina machine shares in NAV units by converting the shares to accounting assets and pricing accounting assets using a Chainlink (compatible) oracle
 * @dev The collateral asset is the machine's share token, resolved from the machine at construction
 * @dev Use case: price DUSD (collateral asset) in USDC (accounting assets) using the machine's convertToAssets and price USDC in USD (NAV unit) using its Chainlink (compatible) fundamental price feed
 * @dev The machine's convertToAssets reads the AUM committed at its last global accounting, so the report's clock is the older of that accounting time and the feed's update timestamp
 */
contract MakinaSharePriceOracle is ChainlinkPriceOracleBase {
    /// @notice The Makina machine whose share token is the collateral asset
    address public immutable MAKINA_MACHINE;

    /// @dev The share amount to pass to convertToAssets() such that the result is scaled to WAD precision
    uint256 internal immutable _MACHINE_SHARES_TO_CONVERT_TO_ASSETS;

    /**
     * @notice Constructs the Makina share price to Chainlink (compatible) oracle composed collateral oracle
     * @param _makinaMachine The Makina machine whose share token is the collateral asset
     * @param _accountingAssetToNavAssetOracle The Chainlink (compatible) oracle pricing the machine's accounting asset in NAV units
     * @param _feedStalenessThresholdSeconds The maximum age of the feed's report before pricing fails shut, sized to the feed's heartbeat
     */
    constructor(
        address _makinaMachine,
        address _accountingAssetToNavAssetOracle,
        uint48 _feedStalenessThresholdSeconds
    )
        ChainlinkPriceOracleBase(IMachine(_makinaMachine).shareToken(), _accountingAssetToNavAssetOracle, _feedStalenessThresholdSeconds)
    {
        MAKINA_MACHINE = _makinaMachine;

        // Compute the share amount to pass to convertToAssets() such that the result is scaled to WAD precision
        // OUTPUT_DECIMALS = INPUT_DECIMALS + ACCOUNTING_ASSET_DECIMALS - SHARE_DECIMALS
        // For OUTPUT_DECIMALS to have WAD_DECIMALS of precision:
        // INPUT_DECIMALS = WAD_DECIMALS + SHARE_DECIMALS - ACCOUNTING_ASSET_DECIMALS
        // OUTPUT_DECIMALS = (WAD_DECIMALS + SHARE_DECIMALS - ACCOUNTING_ASSET_DECIMALS) + ACCOUNTING_ASSET_DECIMALS - SHARE_DECIMALS
        // OUTPUT_DECIMALS = WAD_DECIMALS
        _MACHINE_SHARES_TO_CONVERT_TO_ASSETS =
            10 ** (WAD_DECIMALS + IERC20Metadata(COLLATERAL_ASSET).decimals() - IERC20Metadata(IMachine(_makinaMachine).accountingToken()).decimals());
    }

    /**
     * @inheritdoc ChainlinkPriceOracleBase
     * @notice The price returned is the composed share price and updatedAt is the oldest hop's last update
     * @dev Reports the older of the machine's last global accounting time and the Chainlink leg's update timestamp, so a feed update alone never advances the clock while the machine's AUM report stays stale
     */
    function getPrice() public view override(ChainlinkPriceOracleBase) returns (NAV_UNIT price, uint256 updatedAt) {
        (price, updatedAt) = ChainlinkPriceOracleBase.getPrice();
        updatedAt = Math.min(updatedAt, IMachine(MAKINA_MACHINE).lastGlobalAccountingTime());
    }

    /// @inheritdoc ChainlinkPriceOracleBase
    function _getCollateralToReferenceAssetConversionRateWAD()
        internal
        view
        override(ChainlinkPriceOracleBase)
        returns (uint256 collateralToReferenceAssetConversionRateWAD)
    {
        return IMachine(MAKINA_MACHINE).convertToAssets(_MACHINE_SHARES_TO_CONVERT_TO_ASSETS);
    }
}
