// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IBaseTemplate } from "../../../../../src/interfaces/factory/IBaseTemplate.sol";
import { ERC4626SharePriceOracle } from "../../../../../src/oracle/ERC4626SharePriceOracle.sol";
import { AdaptiveCurveYDM_V2_Params, ERC4626SharePriceOracleParams, GyroECLPPoolParams, OracleType, YDMType } from "../../../../config/DeploymentTypes.sol";
import { AccountantEconomics, CollateralOracleConfig, DayMarketConfig, KernelSettings, YDMSelection } from "../DayMarketTypes.sol";
import { DayMarketRegistryBase } from "./DayMarketRegistryBase.sol";

/// @title Market_SUSDai
/// @notice sUSDai, the USD.ai staked-USDai market on ARBITRUM (economics from the dawn sUSDai market): min coverage
///         10%, JT yield share 11% at target, 7-day fixed term, 1% self-liquidation bonus, LPT liquidity premium
///         disabled. Collateral is sUSDai (18-decimal ERC4626 over USDai) priced share->USDai via `convertToAssets`
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
            // sUSDai (18 decimals), USD.ai's ERC4626 over USDai, per the dawn sUSDai market
            collateralAsset: 0x0B2b2B2076d95dda7817e785989fE353fe955ef9,
            oracle: CollateralOracleConfig({
                deployed: address(0),
                oracleType: OracleType.ERC4626SharePrice,
                specificParams: abi.encode(
                    ERC4626SharePriceOracleParams({
                        // previewRedeem reverts on sUSDai (async redemption queue), so the nominal rate is the only
                        // readable share price
                        queryMode: ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS,
                        // The $1 identity recipe: USDai is attested at one NAV unit, composed with the always-fresh
                        // constant-1.0 feed the oracle deployer stands up (see CollateralOracleDeployer)
                        baseAssetToNavAssetFeed: address(0),
                        // The vault accrues periodically; any observed share-price change counts as an update
                        minDeviationWAD: 0,
                        // Attested share-price update timestamp as of deployment (2026-08-08; re-attest when deploying)
                        lastUpdate: 1_786_200_000,
                        chainlinkOracleStalenessThresholdSeconds: 48 hours, // moot for the constant feed (always fresh)
                        // Yield accrual moves the share price regularly; 8 days covers any plausible flat stretch
                        vaultSharePriceStalenessThresholdSeconds: 8 days
                    })
                )
            }),
            accountant: AccountantEconomics({
                fixedTermGracePeriodSeconds: 1 days,
                minCoverageWAD: 0.1e18,
                coverageLiquidationUtilizationWAD: 1.1e18, // dawn literal
                minLiquidityWAD: 0, // LPT liquidity premium disabled until the market sheet specifies otherwise
                jtYdm: YDMSelection({
                    ydmType: YDMType.AdaptiveCurve_V2,
                    curveParams: abi.encode(
                        AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.11e18, yieldShareAtTargetUtilWAD: 0.11e18, yieldShareAtFullUtilWAD: 0.31e18 })
                    )
                }),
                lptYdm: YDMSelection({
                    ydmType: YDMType.AdaptiveCurve_V2,
                    curveParams: abi.encode(
                        AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.11e18, yieldShareAtTargetUtilWAD: 0.11e18, yieldShareAtFullUtilWAD: 0.31e18 })
                    )
                }),
                maxJTYieldShareWAD: 1e18, // uncapped at the WAD ceiling; the real JT cap comes from the JT YDM curve
                maxLPTYieldShareWAD: 0, // LPT liquidity premium disabled
                fixedTermDurationSeconds: 7 days,
                dustTolerance: 5 // 18-decimal collateral over an 18-decimal base, mirrors dawn
            }),
            kernel: KernelSettings({
                stSelfLiquidationBonusWAD: 0.01e18,
                // Chainlink's Arbitrum sequencer uptime feed; pricing holds shut for the grace period after a restart
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
                eclpParams: _srRoyUsdcEclpParams(),
                derivedEclpParams: _srRoyUsdcDerivedEclpParams(),
                // frxUSD on Arbitrum (Frax's LayerZero OFT deployment — a DIFFERENT address than mainnet frxUSD).
                // A plain stablecoin: the leg registers STANDARD, there is no redemption rate to provide
                quoteAsset: 0x80Eede496655FB9047dd39d9f418d5483ED600df,
                quoteAssetRateProvider: address(0)
            }),
            poolInitialization: RoycoDayBalancerV3MarketDeploymentTemplate.PoolInitializationParams({
                collateralAmount: 0, // no collateral leg: the genesis liquidity is quote-only
                quoteAmount: 1e18, // 1 frxUSD ($1): the quote is 18 decimals, and the seed must cover the 1e12 dead-share lock
                minLPTAssetsOut: 0
            }),
            stEntryPointConfig: _defaultEntryPointTrancheConfig(),
            jtEntryPointConfig: _defaultEntryPointTrancheConfig(),
            lptEntryPointConfig: _defaultEntryPointTrancheConfig()
        });
    }
}
