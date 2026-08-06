// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IBaseTemplate } from "../../../../../src/interfaces/factory/IBaseTemplate.sol";
import { ERC4626SharePriceOracle } from "../../../../../src/oracle/ERC4626SharePriceOracle.sol";
import { AdaptiveCurveYDM_V2_Params, ERC4626SharePriceOracleParams, GyroECLPPoolParams, OracleType, YDMType } from "../../../../config/DeploymentTypes.sol";
import { AccountantEconomics, CollateralOracleConfig, DayMarketConfig, KernelSettings, YDMSelection } from "../DayMarketTypes.sol";
import { DayMarketRegistryBase } from "./DayMarketRegistryBase.sol";

/// @title Market_SrRoyUSDC
/// @notice The srRoyUSDC market: an srRoyUSDC (6-decimal ERC4626 over USDC) senior/junior pair whose LPT pool quotes
///         in sUSDe — the only market whose quote leg is an external rate-bearing token, and the upstream market the
///         sheet markets' pools quote against.
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
                        queryMode: ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS,
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
                // The caps must SUM to at most WAD (both premiums are carved out of the same senior gain, enforced by
                // the accountant and the deployment validation). An even split never binds: both curves top out at 0.31
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
                    RoycoDayBalancerV3MarketDeploymentTemplate.BalancerV3LiquidityVenueDeploymentParams({
                        maxReinvestmentSlippageWAD: 0.001e18 // 10 bps single-sided liquidity-premium reinvestment slippage gate
                    })
                )
            }),
            pool: GyroECLPPoolParams({
                name: "Senior SrRoyUSDC / sUSDe",
                symbol: "srsrRoyUSDC/sUSDe",
                eclpParams: _srRoyUsdcEclpParams(),
                derivedEclpParams: _srRoyUsdcDerivedEclpParams(),
                quoteAsset: 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497,
                quoteAssetRateProvider: 0x3A244e6B3cfed21593a5E5B347B593C0B48C7dA1
            }),
            poolInitialization: RoycoDayBalancerV3MarketDeploymentTemplate.PoolInitializationParams({
                collateralAmount: 0, // no collateral leg: the genesis liquidity is quote-only
                quoteAmount: 1e18, // 1 sUSDe (~$1.24): the quote is 18 decimals, and the seed must cover the 1e12 dead-share lock
                minLPTAssetsOut: 0
            }),
            stEntryPointConfig: _defaultEntryPointTrancheConfig(),
            jtEntryPointConfig: _defaultEntryPointTrancheConfig(),
            lptEntryPointConfig: _defaultEntryPointTrancheConfig()
        });
    }
}
