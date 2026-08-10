// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IBaseTemplate } from "../../../../../src/interfaces/factory/IBaseTemplate.sol";
import { AdaptiveCurveYDM_V2_Params, GyroECLPPoolParams, MakinaSharePriceOracleParams, OracleType, YDMType } from "../../../../config/DeploymentTypes.sol";
import { AccountantEconomics, CollateralOracleConfig, DayMarketConfig, KernelSettings, YDMSelection } from "../DayMarketTypes.sol";
import { DayMarketRegistryBase } from "./DayMarketRegistryBase.sol";

/// @title Market_DUSD
/// @notice DUSD, the Makina dUSD market. Economics come from the dawn MakinaDUSD market, where they are still marked
///         TODO — treat every number here as provisional until the market sheet finalizes: min coverage 10%, JT yield
///         share 7% at target, 2-day fixed term, 3% self-liquidation bonus, LPT liquidity premium disabled.
///         Collateral is the dUSD machine share, priced machine->USDC via the machine's own accounting and USDC->NAV
///         via the Chainlink USDC/USD feed; the pool quotes in the srRoyUSDC senior tranche with the srRoyUSDC kernel
///         as the leg's rate provider.
abstract contract Market_DUSD is DayMarketRegistryBase {
    function _initializeDusdMarket() internal {
        _dayMarketConfigs[DUSD] = DayMarketConfig({
            marketName: DUSD,
            chainId: 1,
            stParams: IBaseTemplate.TrancheDeploymentParams({ name: "Senior Makina DUSD", symbol: "srDUSD" }),
            jtParams: IBaseTemplate.TrancheDeploymentParams({ name: "Junior Makina DUSD", symbol: "jrDUSD" }),
            lptParams: IBaseTemplate.TrancheDeploymentParams({ name: "Senior Liquidity Makina DUSD", symbol: "slDUSD" }),
            // The dUSD machine share token (18 decimals), per the dawn MakinaDUSD market
            collateralAsset: 0x1e33E98aF620F1D563fcD3cfd3C75acE841204ef,
            oracle: CollateralOracleConfig({
                deployed: address(0),
                oracleType: OracleType.MakinaSharePrice,
                specificParams: abi.encode(
                    MakinaSharePriceOracleParams({
                        // The dUSD Makina machine; its convertToAssets() quotes in USDC (6 decimals)
                        makinaMachine: 0x6b006870C83b1Cd49E766Ac9209f8d68763Df721,
                        // Chainlink USDC/USD (https://data.chain.link/feeds/ethereum/mainnet/usdc-usd)
                        accountingAssetToNavAssetFeed: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6,
                        chainlinkOracleStalenessThresholdSeconds: 48 hours, // USDC/USD heartbeat is 24h; doubled for safety
                        // Machines account periodically rather than per-block; 8 days covers any plausible flat
                        // stretch, mirroring the other discretely-updating source hops
                        makinaAccountingStalenessThresholdSeconds: 8 days
                    })
                )
            }),
            accountant: AccountantEconomics({
                fixedTermGracePeriodSeconds: 1 days,
                minCoverageWAD: 0.1e18, // dawn value, marked TODO there
                coverageLiquidationUtilizationWAD: 1.1111e18, // dawn literal, marked TODO there
                minLiquidityWAD: 0, // LPT liquidity premium disabled until the market sheet specifies otherwise
                jtYdm: YDMSelection({
                    ydmType: YDMType.AdaptiveCurve_V2,
                    // dawn curve, marked TODO there
                    curveParams: abi.encode(
                        AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.07e18, yieldShareAtTargetUtilWAD: 0.07e18, yieldShareAtFullUtilWAD: 0.45e18 })
                    )
                }),
                lptYdm: YDMSelection({
                    ydmType: YDMType.AdaptiveCurve_V2,
                    curveParams: abi.encode(
                        AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.07e18, yieldShareAtTargetUtilWAD: 0.07e18, yieldShareAtFullUtilWAD: 0.45e18 })
                    )
                }),
                maxJTYieldShareWAD: 1e18, // uncapped at the WAD ceiling; the real JT cap comes from the JT YDM curve
                maxLPTYieldShareWAD: 0, // LPT liquidity premium disabled
                fixedTermDurationSeconds: 2 days, // dawn value, marked TODO there
                dustTolerance: 5 * 10 ** 12 // the machine accounts in USDC (6 decimals): 5 * 10^(18-6), mirrors dawn
            }),
            kernel: KernelSettings({
                stSelfLiquidationBonusWAD: 0.03e18, // dawn value, marked TODO there
                // Ethereum mainnet has no L2 sequencer, so the sequencer-uptime check is disabled
                sequencerUptimeFeed: address(0),
                gracePeriodSeconds: 0,
                kernelSpecificParams: abi.encode(
                    RoycoDayBalancerV3MarketDeploymentTemplate.BalancerV3LiquidityVenueDeploymentParams({
                        maxReinvestmentSlippageWAD: 0.001e18 // 10 bps single-sided liquidity-premium reinvestment slippage gate
                    })
                )
            }),
            pool: GyroECLPPoolParams({
                name: "Senior Makina DUSD / Senior SrRoyUSDC",
                symbol: "srDUSD/srsrRoyUSDC",
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
