// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IBaseTemplate } from "../../../../../src/interfaces/factory/IBaseTemplate.sol";
import { AdaptiveCurveYDM_V2_Params, GyroECLPPoolParams, MakinaSharePriceOracleParams, OracleType, YDMType } from "../../../../config/DeploymentTypes.sol";
import { AccountantEconomics, CollateralOracleConfig, DayMarketConfig, KernelSettings, YDMSelection } from "../DayMarketTypes.sol";
import { DayMarketRegistryBase } from "./DayMarketRegistryBase.sol";

/// @title Market_DMG
/// @notice DMG, the Makina mGLOBAL market (economics from the dawn DMG market): min coverage 10%, JT yield share 20%
///         at target, no fixed term, 1% self-liquidation bonus, LPT liquidity premium disabled. Collateral is the
///         mGLOBAL machine share, priced machine->USDC via the machine's own accounting and USDC->NAV via the
///         Chainlink USDC/USD feed; the pool quotes in the srRoyUSDC senior tranche with the srRoyUSDC kernel as the
///         leg's rate provider.
abstract contract Market_DMG is DayMarketRegistryBase {
    function _initializeDmgMarket() internal {
        _dayMarketConfigs[DMG] = DayMarketConfig({
            marketName: DMG,
            chainId: 1,
            stParams: IBaseTemplate.TrancheDeploymentParams({ name: "Senior Makina mGLOBAL", symbol: "srDMG" }),
            jtParams: IBaseTemplate.TrancheDeploymentParams({ name: "Junior Makina mGLOBAL", symbol: "jrDMG" }),
            lptParams: IBaseTemplate.TrancheDeploymentParams({ name: "Senior Liquidity Makina mGLOBAL", symbol: "slDMG" }),
            // The mGLOBAL machine share token (18 decimals), per the dawn DMG market
            collateralAsset: 0x761C3B16a5Afdd7A1869C4B979cFF3383d5Fe98B,
            oracle: CollateralOracleConfig({
                deployed: address(0),
                oracleType: OracleType.MakinaSharePrice,
                specificParams: abi.encode(
                    MakinaSharePriceOracleParams({
                        // The mGLOBAL Makina machine; its convertToAssets() quotes in USDC (6 decimals)
                        makinaMachine: 0xC4fFab8540AC27E40D4e2930517aA711e9C00c5b,
                        // Chainlink USDC/USD (https://data.chain.link/feeds/ethereum/mainnet/usdc-usd)
                        accountingAssetToNavAssetFeed: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6,
                        chainlinkOracleStalenessThresholdSeconds: 48 hours, // USDC/USD heartbeat is 24h; doubled for safety
                        // The mGLOBAL machine runs global accounting roughly MONTHLY (observed 33-day gap between
                        // updates on-chain); 45 days covers that cadence with margin. Pricing therefore tolerates
                        // month-old machine NAV — inherent to this collateral's accounting rhythm
                        makinaAccountingStalenessThresholdSeconds: 45 days
                    })
                )
            }),
            accountant: AccountantEconomics({
                fixedTermGracePeriodSeconds: 0,
                minCoverageWAD: 0.1e18,
                coverageLiquidationUtilizationWAD: 2e18, // dawn DMG literal
                minLiquidityWAD: 0, // LPT liquidity premium disabled until the market sheet specifies otherwise
                jtYdm: YDMSelection({
                    ydmType: YDMType.AdaptiveCurve_V2,
                    curveParams: abi.encode(
                        AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.2e18, yieldShareAtTargetUtilWAD: 0.2e18, yieldShareAtFullUtilWAD: 0.4e18 })
                    )
                }),
                lptYdm: YDMSelection({
                    ydmType: YDMType.AdaptiveCurve_V2,
                    curveParams: abi.encode(
                        AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.2e18, yieldShareAtTargetUtilWAD: 0.2e18, yieldShareAtFullUtilWAD: 0.4e18 })
                    )
                }),
                maxJTYieldShareWAD: 1e18, // uncapped at the WAD ceiling; the real JT cap comes from the JT YDM curve
                maxLPTYieldShareWAD: 0, // LPT liquidity premium disabled
                fixedTermDurationSeconds: 0, // dawn DMG: no fixed term
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
                name: "Senior Makina mGLOBAL / Senior SrRoyUSDC",
                symbol: "srDMG/srsrRoyUSDC",
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
