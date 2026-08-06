// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IBaseTemplate } from "../../../../../src/interfaces/factory/IBaseTemplate.sol";
import { AdaptiveCurveYDM_V2_Params, ERC4626SharePriceOracleParams, GyroECLPPoolParams, OracleType, YDMType } from "../../../../config/DeploymentTypes.sol";
import { AccountantEconomics, CollateralOracleConfig, DayMarketConfig, KernelSettings, YDMSelection } from "../DayMarketTypes.sol";
import { DayMarketRegistryBase } from "./DayMarketRegistryBase.sol";

/// @title Market_SnUSD
/// @notice The snUSD market: Neutrl's staked NUSD (18-decimal ERC4626) senior/junior pair whose LPT pool quotes in
///         USDC — the baseline stable market with no fixed term and the LPT liquidity premium disabled.
abstract contract Market_SnUSD is DayMarketRegistryBase {
    /// @dev USDC per chain; the snUSD pool quotes in the chain's native (Circle) USDC
    mapping(uint256 chainId => address) internal USDC;

    function _initializeSnUsdMarket() internal {
        USDC[1] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        USDC[42_161] = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

        _dayMarketConfigs[SNUSD] = DayMarketConfig({
            marketName: SNUSD,
            chainId: 1,
            stParams: IBaseTemplate.TrancheDeploymentParams({ name: "Senior Staked NUSD", symbol: "srsNUSD" }),
            jtParams: IBaseTemplate.TrancheDeploymentParams({ name: "Junior Staked NUSD", symbol: "jrsNUSD" }),
            lptParams: IBaseTemplate.TrancheDeploymentParams({ name: "Senior Liquidity NUSD", symbol: "slsNUSD" }),
            collateralAsset: 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313,
            oracle: CollateralOracleConfig({
                deployed: address(0),
                oracleType: OracleType.ERC4626SharePrice,
                specificParams: abi.encode(
                    ERC4626SharePriceOracleParams({
                        baseAssetToNavAssetFeed: 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95,
                        // The vault accrues continuously, so any observed share-price change counts as an update
                        minDeviationWAD: 0,
                        // Attested share-price update timestamp as of deployment
                        lastUpdate: 1_782_400_000,
                        // RedStone pushes updates ~every 12 hours; 48h staleness threshold for safety
                        chainlinkOracleStalenessThresholdSeconds: 48 hours,
                        // Reward vesting moves the share price every block; 8 days covers any plausible flat stretch
                        vaultSharePriceStalenessThresholdSeconds: 8 days
                    })
                )
            }),
            accountant: AccountantEconomics({
                fixedTermGracePeriodSeconds: 0,
                minCoverageWAD: 0.1e18,
                coverageLiquidationUtilizationWAD: 1.0009009e18,
                minLiquidityWAD: 0, // no market-making depth requirement in the baseline
                jtYdm: YDMSelection({
                    deployed: address(0),
                    ydmType: YDMType.AdaptiveCurve_V2,
                    curveParams: abi.encode(
                        AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.11e18, yieldShareAtTargetUtilWAD: 0.11e18, yieldShareAtFullUtilWAD: 0.31e18 })
                    )
                }),
                lptYdm: YDMSelection({
                    deployed: address(0),
                    ydmType: YDMType.AdaptiveCurve_V2,
                    curveParams: abi.encode(
                        AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.11e18, yieldShareAtTargetUtilWAD: 0.11e18, yieldShareAtFullUtilWAD: 0.31e18 })
                    )
                }),
                maxJTYieldShareWAD: 1e18, // uncapped at the WAD ceiling; the real JT cap comes from the JT YDM curve
                maxLPTYieldShareWAD: 0, // LPT liquidity premium disabled in the baseline
                fixedTermDurationSeconds: 0, // stable market, no fixed term
                dustTolerance: 5
            }),
            kernel: KernelSettings({
                stSelfLiquidationBonusWAD: 0.005e18,
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
                name: "Senior Staked NUSD / USDC",
                symbol: "srsNUSD/USDC",
                eclpParams: _srRoyUsdcEclpParams(),
                derivedEclpParams: _srRoyUsdcDerivedEclpParams(),
                quoteAsset: USDC[block.chainid],
                quoteAssetRateProvider: address(0)
            }),
            poolInitialization: RoycoDayBalancerV3MarketDeploymentTemplate.PoolInitializationParams({
                collateralAmount: 0, // no collateral leg: the genesis liquidity is quote-only
                quoteAmount: 1e6, // $1
                minLPTAssetsOut: 0
            }),
            stEntryPointConfig: _defaultEntryPointTrancheConfig(),
            jtEntryPointConfig: _defaultEntryPointTrancheConfig(),
            lptEntryPointConfig: _defaultEntryPointTrancheConfig()
        });
    }
}
