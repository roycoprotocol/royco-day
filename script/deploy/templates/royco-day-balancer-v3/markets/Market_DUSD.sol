// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IBaseTemplate } from "../../../../../src/interfaces/factory/IBaseTemplate.sol";
import { AdaptiveCurveYDM_V2_Params, GyroECLPPoolParams, MakinaSharePriceOracleParams, OracleType, YDMType } from "../../../../config/DeploymentTypes.sol";
import { AccountantEconomics, CollateralOracleConfig, DayMarketConfig, KernelSettings, YDMSelection } from "../DayMarketTypes.sol";
import { DayMarketRegistryBase } from "./DayMarketRegistryBase.sol";

/// @title Market_DUSD
/// @notice DUSD, the Makina dUSD market. Economics MIRROR THE FALCONX SHEET ROW (DUSD has no dedicated sheet row
///         yet): min coverage 3%, min liquidity 10%, JT yield share 4.5% at target, LP yield share 9.1% at target,
///         7-day fixed term, protected exit at 2.99% coverage remaining, 1% self-liquidation bonus.
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
                        // Machines account periodically
                        makinaAccountingStalenessThresholdSeconds: 7 days
                    })
                )
            }),
            roycoBlacklist: address(0),
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
                dustTolerance: 5 * 10 ** 12 // the machine accounts in USDC (6 decimals): 5 * 10^(18-6), mirrors dawn
            }),
            kernel: KernelSettings({
                stSelfLiquidationBonusWAD: 0.01e18,
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
