// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IBaseTemplate } from "../../../../../src/interfaces/factory/IBaseTemplate.sol";
import { ERC4626SharePriceOracle } from "../../../../../src/oracle/ERC4626SharePriceOracle.sol";
import { AdaptiveCurveYDM_V2_Params, ERC4626SharePriceOracleParams, GyroECLPPoolParams, OracleType, YDMType } from "../../../../config/DeploymentTypes.sol";
import { AccountantEconomics, CollateralOracleConfig, DayMarketConfig, KernelSettings, YDMSelection } from "../DayMarketTypes.sol";
import { DayMarketRegistryBase } from "./DayMarketRegistryBase.sol";

/// @title Market_APYX
/// @notice APYX, per the market sheet: underlying 10.23%, min coverage 15%, min liquidity 10%, JT yield share 15% @
///         target, LP yield share 8% @ target, 30-day observation period, protected exit at 3% coverage remaining,
///         NO self-liquidation bonus. 20-day redemption cooldown. Collateral is apyUSD (18-decimal ERC4626 over
///         apxUSD) priced through the 18-decimal Chainlink apxUSD/USD exchange-rate feed; the pool quotes in the
///         srRoyUSDC senior tranche with the srRoyUSDC kernel as the leg's rate provider.
abstract contract Market_APYX is DayMarketRegistryBase {
    function _initializeApyxMarket() internal {
        _dayMarketConfigs[APYX] = DayMarketConfig({
            marketName: APYX,
            chainId: 1,
            stParams: IBaseTemplate.TrancheDeploymentParams({ name: "Senior apyUSD", symbol: "srapyUSD" }),
            jtParams: IBaseTemplate.TrancheDeploymentParams({ name: "Junior apyUSD", symbol: "jrapyUSD" }),
            lptParams: IBaseTemplate.TrancheDeploymentParams({ name: "Senior Liquidity apyUSD", symbol: "slapyUSD" }),
            // apyUSD (18 decimals), APYX's ERC4626 vault over apxUSD, per the dawn apyUSD market
            collateralAsset: 0x38EEb52F0771140d10c4E9A9a72349A329Fe8a6A,
            oracle: CollateralOracleConfig({
                deployed: address(0),
                oracleType: OracleType.ERC4626SharePrice,
                specificParams: abi.encode(
                    // Chainlink apxUSD/USD exchange rate (https://data.chain.link/feeds/ethereum/mainnet/apxusd-usd-exchange-rate)
                    ERC4626SharePriceOracleParams({
                        queryMode: ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS,
                        baseAssetToNavAssetFeed: 0x651b101f72F82630cf59c68E6EE4305aFBd3B1F5,
                        // The vault accrues continuously, so any observed share-price change counts as an update
                        minDeviationWAD: 0,
                        // Attested share-price update timestamp as of deployment
                        lastUpdate: 1_782_400_000,
                        chainlinkOracleStalenessThresholdSeconds: 48 hours, // the feed pushes ~every 12 hours; 48h mirrors dawn
                        // Yield accrual moves the share price continuously; 8 days covers any plausible flat stretch
                        vaultSharePriceStalenessThresholdSeconds: 8 days
                    })
                )
            }),
            accountant: AccountantEconomics({
                fixedTermGracePeriodSeconds: 1 days,
                minCoverageWAD: 0.15e18,
                coverageLiquidationUtilizationWAD: calculateCoverageLiquidationUtilizationWAD(0.15e18, 0.03e18),
                minLiquidityWAD: 0.1e18,
                jtYdm: YDMSelection({
                    ydmType: YDMType.AdaptiveCurve_V2,
                    curveParams: abi.encode(
                        AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.11e18, yieldShareAtTargetUtilWAD: 0.15e18, yieldShareAtFullUtilWAD: 0.31e18 })
                    )
                }),
                lptYdm: YDMSelection({
                    ydmType: YDMType.AdaptiveCurve_V2,
                    curveParams: abi.encode(
                        AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.04e18, yieldShareAtTargetUtilWAD: 0.08e18, yieldShareAtFullUtilWAD: 0.31e18 })
                    )
                }),
                maxJTYieldShareWAD: 0.5e18,
                maxLPTYieldShareWAD: 0.5e18,
                fixedTermDurationSeconds: 30 days,
                dustTolerance: 5 // 18-decimal collateral, mirrors dawn
            }),
            kernel: KernelSettings({
                stSelfLiquidationBonusWAD: 0, // the sheet grants APYX no self-liquidation bonus
                sequencerUptimeFeed: address(0),
                gracePeriodSeconds: 0,
                kernelSpecificParams: abi.encode(
                    RoycoDayBalancerV3MarketDeploymentTemplate.BalancerV3LiquidityVenueDeploymentParams({ maxReinvestmentSlippageWAD: 0.001e18 })
                )
            }),
            pool: GyroECLPPoolParams({
                name: "Senior apyUSD / Senior SrRoyUSDC",
                symbol: "srapyUSD/srsrRoyUSDC",
                eclpParams: _srRoyUsdcEclpParams(),
                derivedEclpParams: _srRoyUsdcDerivedEclpParams(),
                quoteAsset: SRROYUSDC_SENIOR_TRANCHE,
                quoteAssetRateProvider: SRROYUSDC_KERNEL
            }),
            poolInitialization: RoycoDayBalancerV3MarketDeploymentTemplate.PoolInitializationParams({
                collateralAmount: 0, quoteAmount: 0.5e18, minLPTAssetsOut: 0
            }),
            stEntryPointConfig: _defaultEntryPointTrancheConfig(),
            jtEntryPointConfig: _defaultEntryPointTrancheConfig(),
            lptEntryPointConfig: _defaultEntryPointTrancheConfig()
        });
    }
}
