// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IBaseTemplate } from "../../../../../src/interfaces/factory/IBaseTemplate.sol";
import { AdaptiveCurveYDM_V2_Params, GyroECLPPoolParams, IdleCDOTranchePriceOracleParams, OracleType, YDMType } from "../../../../config/DeploymentTypes.sol";
import { AccountantEconomics, CollateralOracleConfig, DayMarketConfig, KernelSettings, YDMSelection } from "../DayMarketTypes.sol";
import { DayMarketRegistryBase } from "./DayMarketRegistryBase.sol";

/// @title Market_FalconX
/// @notice FalconX, per the market sheet: underlying 7.68%, min coverage 3%, min liquidity 10%, JT yield share 4.5%
///         at target, LP yield share 9.1% at target, 7-day observation period, protected exit at 2.99% coverage
///         remaining, 1% self-liquidation bonus. Monthly redemptions with 1-month notice. Collateral is the Pareto
///         FalconX Prime Brokerage Vault AA tranche behind the composed virtual-price x USDC/USD oracle; the pool
///         quotes in the srRoyUSDC senior tranche with the srRoyUSDC kernel as the leg's rate provider.
abstract contract Market_FalconX is DayMarketRegistryBase {
    function _initializeFalconXMarket() internal {
        _dayMarketConfigs[FALCONX] = DayMarketConfig({
            marketName: FALCONX,
            chainId: 1,
            stParams: IBaseTemplate.TrancheDeploymentParams({ name: "Senior FalconX", symbol: "srFalconX" }),
            jtParams: IBaseTemplate.TrancheDeploymentParams({ name: "Junior FalconX", symbol: "jrFalconX" }),
            lptParams: IBaseTemplate.TrancheDeploymentParams({ name: "Senior Liquidity FalconX", symbol: "slFalconX" }),
            collateralAsset: 0xC26A6Fa2C37b38E549a4a1807543801Db684f99C,
            oracle: CollateralOracleConfig({
                deployed: address(0),
                oracleType: OracleType.IdleCDOTranchePrice,
                specificParams: abi.encode(
                    IdleCDOTranchePriceOracleParams({
                        idleCDO: 0x433D5B175148dA32Ffe1e1A37a939E1b7e79be4d,
                        underlyingTokenToNavAssetFeed: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6,
                        minDeviationWAD: 0.001e18,
                        lastUpdate: 1_785_769_583,
                        // Per-hop thresholds, each sized to ITS source: the Chainlink USDC/USD leg keeps its tight 48h
                        // gate (24h heartbeat, doubled), while the virtual-price clock gets 8 days for Pareto's ~WEEKLY
                        // cadence — the slow CDO no longer loosens the feed
                        chainlinkOracleStalenessThresholdSeconds: 48 hours,
                        cdoPriceStalenessThresholdSeconds: 8 days
                    })
                )
            }),
            accountant: AccountantEconomics({
                fixedTermGracePeriodSeconds: 7 days,
                minCoverageWAD: 0.03e18,
                coverageLiquidationUtilizationWAD: calculateCoverageLiquidationUtilizationWAD(0.03e18, 0.0299e18),
                minLiquidityWAD: 0.1e18,
                jtYdm: YDMSelection({
                    ydmType: YDMType.AdaptiveCurve_V2,
                    curveParams: abi.encode(
                        AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.005e18, yieldShareAtTargetUtilWAD: 0.045e18, yieldShareAtFullUtilWAD: 0.31e18 })
                    )
                }),
                lptYdm: YDMSelection({
                    ydmType: YDMType.AdaptiveCurve_V2,
                    curveParams: abi.encode(
                        AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.051e18, yieldShareAtTargetUtilWAD: 0.091e18, yieldShareAtFullUtilWAD: 0.31e18 })
                    )
                }),
                // The caps must SUM to at most WAD; an even split never binds, both V2 curves top out at 0.31
                maxJTYieldShareWAD: 0.5e18,
                maxLPTYieldShareWAD: 0.5e18,
                fixedTermDurationSeconds: 7 days,
                dustTolerance: 5 * 10 ** 12
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
                name: "Senior FalconX / Senior SrRoyUSDC",
                symbol: "srFalconX/srsrRoyUSDC",
                eclpParams: _exitLiquidityPrioritizedEclpParams(),
                derivedEclpParams: _exitLiquidityPrioritizedDerivedEclpParams(),
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
