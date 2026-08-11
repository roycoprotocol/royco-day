// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IBaseTemplate } from "../../../../../src/interfaces/factory/IBaseTemplate.sol";
import { ERC4626SharePriceOracle } from "../../../../../src/oracle/ERC4626SharePriceOracle.sol";
import { AdaptiveCurveYDM_V2_Params, ERC4626SharePriceOracleParams, GyroECLPPoolParams, OracleType, YDMType } from "../../../../config/DeploymentTypes.sol";
import { AccountantEconomics, CollateralOracleConfig, DayMarketConfig, KernelSettings, YDMSelection } from "../DayMarketTypes.sol";
import { DayMarketRegistryBase } from "./DayMarketRegistryBase.sol";

/// @title Market_SUSDai
/// @notice sUSDai, the USD.ai staked-USDai market on ARBITRUM, per the market sheet: underlying 7.5%, min coverage
///         7%, min liquidity 10%, JT yield share 7% at target, LP yield share 8% at target, 7-day observation
///         period, protected exit at 5% coverage remaining, 1% self-liquidation bonus. 30-day redemption epoch.
///         Collateral is sUSDai (18-decimal ERC4626 over USDai) priced share->USDai via `convertToAssets`
///         — sUSDai's `previewRedeem` REVERTS (async redemption queue), so the redeem query is unusable — and
///         USDai->NAV via the $1 identity recipe (a zero feed address; dawn attested USDai at 1e18 through its admin
///         oracle the same way). The pool quotes in Arbitrum frxUSD, a plain stablecoin STANDARD leg.
abstract contract Market_SUSDai is DayMarketRegistryBase {
    function _initializeSUsdaiMarket() internal {
        _dayMarketConfigs[SUSDAI] = DayMarketConfig({
            marketName: SUSDAI,
            chainId: 42_161,
            stParams: IBaseTemplate.TrancheDeploymentParams({ name: "Senior Staked USDai", symbol: "srsUSDai" }),
            jtParams: IBaseTemplate.TrancheDeploymentParams({ name: "Junior Staked USDai", symbol: "jrsUSDai" }),
            lptParams: IBaseTemplate.TrancheDeploymentParams({ name: "Senior Liquidity Staked USDai", symbol: "slsUSDai" }),
            collateralAsset: 0x0B2b2B2076d95dda7817e785989fE353fe955ef9,
            oracle: CollateralOracleConfig({
                deployed: address(0),
                oracleType: OracleType.ERC4626SharePrice,
                specificParams: abi.encode(
                    ERC4626SharePriceOracleParams({
                        queryMode: ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS,
                        baseAssetToNavAssetFeed: address(0), // Replaced with a constant feed
                        minDeviationWAD: 0,
                        lastUpdate: 1_786_200_000,
                        chainlinkOracleStalenessThresholdSeconds: 48 hours, // moot for the constant feed (always fresh)
                        vaultSharePriceStalenessThresholdSeconds: 7 days
                    })
                )
            }),
            roycoBlacklist: address(0),
            accountant: AccountantEconomics({
                fixedTermGracePeriodSeconds: 1 days,
                minCoverageWAD: 0.07e18,
                coverageLiquidationUtilizationWAD: calculateCoverageLiquidationUtilizationWAD(0.07e18, 0.05e18),
                minLiquidityWAD: 0.1e18,
                jtYdm: YDMSelection({
                    ydmType: YDMType.AdaptiveCurve_V2,
                    curveParams: abi.encode(
                        AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.03e18, yieldShareAtTargetUtilWAD: 0.07e18, yieldShareAtFullUtilWAD: 0.31e18 })
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
                fixedTermDurationSeconds: 7 days,
                dustTolerance: 5
            }),
            kernel: KernelSettings({
                stSelfLiquidationBonusWAD: 0.01e18,
                sequencerUptimeFeed: 0xFdB631F5EE196F0ed6FAa767959853A9F217697D,
                gracePeriodSeconds: 1 hours,
                kernelSpecificParams: abi.encode(
                    RoycoDayBalancerV3MarketDeploymentTemplate.BalancerV3LiquidityVenueDeploymentParams({
                            maxReinvestmentSlippageWAD: 0.001e18 // 10 bps single-sided liquidity-premium reinvestment slippage gate
                        })
                )
            }),
            pool: GyroECLPPoolParams({
                name: "Senior Staked USDai / frxUSD",
                symbol: "srsUSDai/frxUSD",
                eclpParams: _exitLiquidityPrioritizedEclpParams(),
                derivedEclpParams: _exitLiquidityPrioritizedDerivedEclpParams(),
                quoteAsset: 0x80Eede496655FB9047dd39d9f418d5483ED600df,
                quoteAssetRateProvider: address(0)
            }),
            poolInitialization: RoycoDayBalancerV3MarketDeploymentTemplate.PoolInitializationParams({
                collateralAmount: 0, quoteAmount: 1e18, minLPTAssetsOut: 0
            }),
            stEntryPointConfig: _defaultEntryPointTrancheConfig(),
            jtEntryPointConfig: _defaultEntryPointTrancheConfig(),
            lptEntryPointConfig: _defaultEntryPointTrancheConfig()
        });
    }
}
