// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IBaseTemplate } from "../../../../../src/interfaces/factory/IBaseTemplate.sol";
import { ERC4626SharePriceOracle } from "../../../../../src/oracle/ERC4626SharePriceOracle.sol";
import { AdaptiveCurveYDM_V2_Params, ERC4626SharePriceOracleParams, GyroECLPPoolParams, OracleType, YDMType } from "../../../../config/DeploymentTypes.sol";
import { AccountantEconomics, CollateralOracleConfig, DayMarketConfig, KernelSettings, YDMSelection } from "../DayMarketTypes.sol";
import { DayMarketRegistryBase } from "./DayMarketRegistryBase.sol";

/// @title Market_SrRoyUSDC
/// @notice The srRoyUSDC market: an srRoyUSDC (6-decimal ERC4626 over USDC) senior/junior pair whose LPT pool quotes in frxUSD
abstract contract Market_SrRoyUSDC is DayMarketRegistryBase {
    function _initializeSrRoyUsdcMarket() internal {
        _dayMarketConfigs[SRROYUSDC] = DayMarketConfig({
            marketName: SRROYUSDC,
            chainId: 1,
            stParams: IBaseTemplate.TrancheDeploymentParams({ name: "Senior SrRoyUSDC", symbol: "srsrRoyUSDC" }),
            jtParams: IBaseTemplate.TrancheDeploymentParams({ name: "Junior SrRoyUSDC", symbol: "jrsrRoyUSDC" }),
            lptParams: IBaseTemplate.TrancheDeploymentParams({ name: "Senior Liquidity SrRoyUSDC", symbol: "slsrRoyUSDC" }),
            collateralAsset: 0xcD9f5907F92818bC06c9Ad70217f089E190d2a32,
            oracle: CollateralOracleConfig({
                deployed: address(0),
                oracleType: OracleType.ERC4626SharePrice,
                specificParams: abi.encode(
                    ERC4626SharePriceOracleParams({
                        queryMode: ERC4626SharePriceOracle.ERC4626QueryMode.PREVIEW_REDEEM,
                        baseAssetToNavAssetFeed: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6,
                        // The vault accrues continuously, so any observed share-price change counts as an update
                        minDeviationWAD: 0,
                        // Attested share-price update timestamp as of deployment
                        lastUpdate: 1_782_400_000,
                        chainlinkOracleStalenessThresholdSeconds: 48 hours, // USDC/USD heartbeat is 24h; doubled for safety
                        // Yield accrual moves the share price continuously; 8 days covers any plausible flat stretch
                        vaultSharePriceStalenessThresholdSeconds: 8 days
                    })
                )
            }),
            accountant: AccountantEconomics({
                fixedTermGracePeriodSeconds: 1 days,
                minCoverageWAD: 0.2e18,
                coverageLiquidationUtilizationWAD: calculateCoverageLiquidationUtilizationWAD(0.2e18, 0.02e18),
                minLiquidityWAD: 0.5e18,
                jtYdm: YDMSelection({
                    ydmType: YDMType.AdaptiveCurve_V2,
                    curveParams: abi.encode(
                        AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.1e18, yieldShareAtTargetUtilWAD: 0.14e18, yieldShareAtFullUtilWAD: 0.31e18 })
                    )
                }),
                lptYdm: YDMSelection({
                    ydmType: YDMType.AdaptiveCurve_V2,
                    curveParams: abi.encode(
                        AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.18e18, yieldShareAtTargetUtilWAD: 0.22e18, yieldShareAtFullUtilWAD: 0.31e18 })
                    )
                }),
                maxJTYieldShareWAD: 0.5e18,
                maxLPTYieldShareWAD: 0.5e18,
                fixedTermDurationSeconds: 7 days,
                dustTolerance: 5 * 10 ** 10
            }),
            kernel: KernelSettings({
                stSelfLiquidationBonusWAD: 0.01e18,
                sequencerUptimeFeed: address(0),
                gracePeriodSeconds: 0,
                kernelSpecificParams: abi.encode(
                    RoycoDayBalancerV3MarketDeploymentTemplate.BalancerV3LiquidityVenueDeploymentParams({ maxReinvestmentSlippageWAD: 0.001e18 })
                )
            }),
            pool: GyroECLPPoolParams({
                name: "Senior SrRoyUSDC / frxUSD",
                symbol: "srsrRoyUSDC/frxUSD",
                eclpParams: _exitLiquidityPrioritizedEclpParams(),
                derivedEclpParams: _exitLiquidityPrioritizedDerivedEclpParams(),
                quoteAsset: 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29, // frxUSD (18 decimals)
                quoteAssetRateProvider: address(0)
            }),
            poolInitialization: RoycoDayBalancerV3MarketDeploymentTemplate.PoolInitializationParams({
                collateralAmount: 0,
                quoteAmount: 1e18, // 1 frxUSD ($1)
                minLPTAssetsOut: 0
            }),
            stEntryPointConfig: _defaultEntryPointTrancheConfig(),
            jtEntryPointConfig: _defaultEntryPointTrancheConfig(),
            lptEntryPointConfig: _defaultEntryPointTrancheConfig()
        });
    }
}
