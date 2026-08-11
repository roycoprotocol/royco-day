// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IRoycoDayEntryPoint } from "../../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IBaseTemplate } from "../../../../src/interfaces/factory/IBaseTemplate.sol";
import { GyroECLPPoolParams, OracleType, YDMType } from "../../../config/DeploymentTypes.sol";

/**
 * @title DayMarketTypes
 * @notice The market configuration for the Royco Day Balancer V3 template family, shaped to MIRROR the params the
 *         template itself accepts (`RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams`): the market script's
 *         job collapses to copying sub-structs, encoding the YDM curves, resolving the oracle, and mining the id.
 * @dev The shape is TEMPLATE-DEPENDENT by design — a different template family defines its own market config next to
 *      its own deployment scripts. Wherever the data is identical to what the template consumes, the template's own
 *      structs are reused directly (tranche params, pool initialization, entry point configs) so the two can never
 *      drift. Nothing SYSTEM appears here: protocol fees, the fee recipient, and the pool's swap-fee/yield-fee policy
 *      are template construction state, not the market deployer's to choose.
 */

/// @notice The market's collateral pricing stack: a pre-deployed adapter, or the recipe to deploy one
/// @custom:field deployed - The pre-deployed collateral oracle (the null address has the pipeline deploy it from the recipe below)
/// @custom:field oracleType - The adapter kind to deploy (one per `src/oracle/` adapter)
/// @custom:field specificParams - The ABI-encoded params struct for the adapter kind (feeds, thresholds, attestation)
struct CollateralOracleConfig {
    address deployed;
    OracleType oracleType;
    bytes specificParams;
}

/// @notice A market's yield-distribution-model selection: the registered shape plus its curve parameters
/// @custom:field ydmType - The model shape, resolved against the template's registry by canonical name
/// @custom:field curveParams - The ABI-encoded curve params struct for the shape (encoded into the accountant's init data)
struct YDMSelection {
    YDMType ydmType;
    bytes curveParams;
}

/// @notice The market's accountant economics, mirroring `IBaseTemplate.AccountantDeploymentParams` field-for-field
///         with the two YDM init blobs replaced by their script-side curve selections
struct AccountantEconomics {
    uint24 fixedTermGracePeriodSeconds;
    uint64 minCoverageWAD;
    uint256 coverageLiquidationUtilizationWAD;
    uint64 minLiquidityWAD;
    YDMSelection jtYdm;
    YDMSelection lptYdm;
    uint64 maxJTYieldShareWAD;
    uint64 maxLPTYieldShareWAD;
    uint24 fixedTermDurationSeconds;
    uint256 dustTolerance;
}

/// @notice The market's kernel-level settings the template threads into the kernel's initialization
struct KernelSettings {
    uint64 stSelfLiquidationBonusWAD;
    address sequencerUptimeFeed;
    uint48 gracePeriodSeconds;
    // ABI-encoded venue params blob (BalancerV3LiquidityVenueDeploymentParams for this family)
    bytes kernelSpecificParams;
}

/// @notice A Royco Day Balancer V3 market, fully specified
struct DayMarketConfig {
    // Script-level identity
    string marketName;
    uint256 chainId;
    // Tranche metadata (the template's own struct: name + symbol per tranche)
    IBaseTemplate.TrancheDeploymentParams stParams;
    IBaseTemplate.TrancheDeploymentParams jtParams;
    IBaseTemplate.TrancheDeploymentParams lptParams;
    // Collateral + its pricing stack
    address collateralAsset;
    CollateralOracleConfig oracle;
    // The market's pre-deployed blacklist
    address roycoBlacklist;
    // Economics
    AccountantEconomics accountant;
    KernelSettings kernel;
    // The LPT's Gyro E-CLP {ST share, quote} pool: curve + quote leg (+ its rate provider)
    GyroECLPPoolParams pool;
    // Genesis pool liquidity, pulled from the deployment caller (the template's own struct)
    RoycoDayBalancerV3MarketDeploymentTemplate.PoolInitializationParams poolInitialization;
    // Entry point config per tranche (the entry point's own struct)
    IRoycoDayEntryPoint.TrancheConfig stEntryPointConfig;
    IRoycoDayEntryPoint.TrancheConfig jtEntryPointConfig;
    IRoycoDayEntryPoint.TrancheConfig lptEntryPointConfig;
}
