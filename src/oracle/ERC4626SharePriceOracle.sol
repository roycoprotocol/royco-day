// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20Metadata, IERC4626 } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { WAD_DECIMALS } from "../libraries/Constants.sol";
import { ChainlinkPriceOracleBase } from "./base/ChainlinkPriceOracleBase.sol";
import { ClockedChainlinkPriceOracleBase } from "./base/ClockedChainlinkPriceOracleBase.sol";
import { OracleClockBase } from "./base/clock/OracleClockBase.sol";

/**
 * @title ERC4626SharePriceOracle
 * @author Shivaansh Kapoor, Ankur Dubey, Tomer Ganor
 * @notice Oracle to price ERC4626 vault shares in NAV units by converting the shares to base assets and pricing base assets using a Chainlink (compatible) oracle, deriving the share hop's update clock from observed share-price deviations
 * @dev The collateral asset must be an ERC4626 vault share
 * @dev Use case: price sUSDe (collateral asset) in USDe (base assets) using ERC4626's convertToAssets and price USDe in USD (NAV unit) using its fundamental (solvency-based) price feed
 * @dev ERC4626 guarantees nothing about how convertToAssets evolves and exposes no accounting timestamp, so the clocked base checkpoints observed share-price deviations and reports the older of that clock and the feed's update timestamp
 * @dev A continuously-accruing vault deviates on every observation and keeps the clock transparently fresh, while a discretely-repriced vault holds the clock at its last observed accounting
 */
contract ERC4626SharePriceOracle is ClockedChainlinkPriceOracleBase {
    /// @dev The share amount to pass to convertToAssets() such that the result is scaled to WAD precision
    uint256 internal immutable _ERC4626_SHARES_TO_CONVERT_TO_ASSETS;

    /**
     * @notice Constructs the ERC4626 share price to Chainlink (compatible) oracle composed collateral oracle
     * @param _collateralAsset The ERC4626 vault share that is the collateral asset
     * @param _baseAssetToNavAssetOracle The Chainlink (compatible) oracle pricing the vault's base asset in NAV units
     * @param _minDeviationWAD The minimum relative deviation from the checkpointed share price that counts as an update, scaled to WAD precision (zero counts any change)
     * @param _lastUpdate The deployer-attested timestamp of the share price's last update (zero if unknown, which holds pricing and the execution gate shut until the first observed deviation)
     * @param _chainlinkOracleStalenessThresholdSeconds The maximum age of the Chainlink (compatible) oracle's report before pricing fails shut, sized to its heartbeat
     * @param _vaultSharePriceStalenessThresholdSeconds The maximum age of the share-price clock's checkpoint before pricing fails shut, sized past the vault's longest plausible flat stretch
     */
    constructor(
        address _collateralAsset,
        address _baseAssetToNavAssetOracle,
        uint256 _minDeviationWAD,
        uint32 _lastUpdate,
        uint32 _chainlinkOracleStalenessThresholdSeconds,
        uint32 _vaultSharePriceStalenessThresholdSeconds
    )
        ClockedChainlinkPriceOracleBase(
            _collateralAsset,
            _baseAssetToNavAssetOracle,
            _minDeviationWAD,
            _lastUpdate,
            _chainlinkOracleStalenessThresholdSeconds,
            _vaultSharePriceStalenessThresholdSeconds
        )
    {
        // Compute the share amount to pass to convertToAssets() such that the result is scaled to WAD precision
        // OUTPUT_DECIMALS = INPUT_DECIMALS + BASE_ASSET_DECIMALS - SHARE_DECIMALS
        // For OUTPUT_DECIMALS to have WAD_DECIMALS of precision:
        // INPUT_DECIMALS = WAD_DECIMALS + SHARE_DECIMALS - BASE_ASSET_DECIMALS
        // OUTPUT_DECIMALS = (WAD_DECIMALS + SHARE_DECIMALS - BASE_ASSET_DECIMALS) + BASE_ASSET_DECIMALS - SHARE_DECIMALS
        // OUTPUT_DECIMALS = WAD_DECIMALS
        _ERC4626_SHARES_TO_CONVERT_TO_ASSETS =
            10 ** (WAD_DECIMALS + IERC4626(_collateralAsset).decimals() - IERC20Metadata(IERC4626(_collateralAsset).asset()).decimals());

        // Checkpoint the construction baseline through the same source read every poke uses
        _initializeOracleClock(_getSourcePrice());
    }

    /// @inheritdoc OracleClockBase
    function _getSourcePrice() internal view override(OracleClockBase) returns (uint256 price) {
        return IERC4626(COLLATERAL_ASSET).convertToAssets(_ERC4626_SHARES_TO_CONVERT_TO_ASSETS);
    }
}
