// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IRoycoPriceOracle } from "../interfaces/IRoycoPriceOracle.sol";
import { WAD } from "../libraries/Constants.sol";
import { ChainlinkPriceOracleBase } from "./base/ChainlinkPriceOracleBase.sol";

/**
 * @title ChainlinkPriceOracle
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Oracle to price a collateral asset in NAV units using a Chainlink (compatible) oracle that quotes it directly
 * @dev The collateral asset is its own reference asset, so the conversion rate is the identity and the answer is the feed's price rescaled to WAD
 * @dev Use case: price USDC (collateral asset) in USD (NAV unit) using its Chainlink (compatible) price feed
 */
contract ChainlinkPriceOracle is ChainlinkPriceOracleBase {
    /**
     * @notice Constructs the Chainlink (compatible) collateral oracle
     * @param _collateralAsset The collateral asset the feed directly prices in NAV units
     * @param _collateralToNavAssetOracle The Chainlink (compatible) oracle pricing the collateral asset in NAV units
     */
    constructor(address _collateralAsset, address _collateralToNavAssetOracle) ChainlinkPriceOracleBase(_collateralAsset, _collateralToNavAssetOracle) { }

    /// @inheritdoc IRoycoPriceOracle
    /// @dev The identity hop adds no pair segment, so the feed's own pair description passes through unchanged
    function description() external view override(ChainlinkPriceOracleBase) returns (string memory) {
        return ORACLE.description();
    }

    /// @inheritdoc ChainlinkPriceOracleBase
    /// @dev The collateral asset is the reference asset, so the conversion hop is the identity rate
    function _getCollateralToReferenceAssetConversionRateWAD()
        internal
        pure
        override(ChainlinkPriceOracleBase)
        returns (uint256 collateralToReferenceAssetConversionRateWAD)
    {
        return WAD;
    }
}
