// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayEntryPoint } from "../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";

// ═══════════════════════════════════════════════════════════════════════════
// ENUMS
// ═══════════════════════════════════════════════════════════════════════════

/// @notice Day kernel types the deployment path can deploy.
/// @dev New Day kernel types are added here as they ship.
enum KernelType {
    RoycoDayBalancerV3Kernel
}

/// @notice YDM types.
enum YDMType {
    StaticCurve,
    AdaptiveCurve_V1,
    AdaptiveCurve_V2
}

/// @notice Collateral asset oracle kinds the deployment path can deploy (one per `src/oracle/` adapter).
/// @dev New oracle adapters are added here as they ship. Each kind decodes its own params struct from
///      `MarketConfig.collateralAssetOracleSpecificParams` (mirroring how `ydmSpecificParams` is typed by `ydmType`).
enum OracleType {
    ChainlinkPrice,
    ERC4626SharePrice,
    MakinaSharePrice,
    IdleCDOTranchePrice
}

// ═══════════════════════════════════════════════════════════════════════════
// ROLE CONFIG / ASSIGNMENT
// ═══════════════════════════════════════════════════════════════════════════

/// @notice Per-role admin/guardian/delay configuration (ported from the legacy Roles).
struct RoleConfig {
    uint64 adminRole;
    uint64 guardianRole;
    uint32 executionDelay;
}

/// @notice Addresses for role assignments.
struct RoleAssignmentAddresses {
    address pauserAddress;
    address unpauserAddress;
    address upgraderAddress;
    address syncRoleAddress;
    address adminKernelAddress;
    address adminAccountantAddress;
    address adminProtocolFeeSetterAddress;
    address adminOracleAddress;
    address lpRoleAdminAddress;
    address guardianAddress;
    address deployerAddress;
    address deployerAdminAddress;
    address protocolFeeRecipientAddress;
    address balancerPoolManagerAddress;
    address marketOpsAddress;
    address marketReinvestLiquidityPremiumAddress;
    address adminEntryPointAddress;
    address entryPointFeeCollectorAddress;
}

/// @notice A single role assignment applied to the AccessManager.
struct RoleAssignment {
    uint64 role;
    uint64 roleAdminRole;
    address assignee;
    uint32 executionDelay;
}

// ═══════════════════════════════════════════════════════════════════════════
// YDM PARAM STRUCTS
// ═══════════════════════════════════════════════════════════════════════════

struct StaticCurveYDMParams {
    uint64 yieldShareAtZeroUtilWAD;
    uint64 yieldShareAtTargetUtilWAD;
    uint64 yieldShareAtFullUtilWAD;
}

struct AdaptiveCurveYDM_V1_Params {
    uint64 yieldShareAtTargetUtilWAD;
    uint64 yieldShareAtFullUtilWAD;
}

struct AdaptiveCurveYDM_V2_Params {
    uint64 yieldShareAtZeroUtilWAD;
    uint64 yieldShareAtTargetUtilWAD;
    uint64 yieldShareAtFullUtilWAD;
}

// ═══════════════════════════════════════════════════════════════════════════
// COLLATERAL ASSET ORACLE PARAM STRUCTS (one per OracleType)
// ═══════════════════════════════════════════════════════════════════════════

/// @notice Params for `OracleType.ChainlinkPrice`: identity hop, the feed prices the collateral asset in NAV units directly.
struct ChainlinkPriceOracleParams {
    address collateralToNavAssetFeed;
}

/// @notice Params for `OracleType.ERC4626SharePrice`: share price via `convertToAssets` x the base-asset-to-NAV feed.
/// @dev The vault is the market's collateral asset itself.
struct ERC4626SharePriceOracleParams {
    address baseAssetToNavAssetFeed;
}

/// @notice Params for `OracleType.MakinaSharePrice`: machine share price via `convertToAssets` x the accounting-asset-to-NAV feed.
/// @dev The machine's share token must be the market's collateral asset (the oracle resolves it at construction).
struct MakinaSharePriceOracleParams {
    address makinaMachine;
    address accountingAssetToNavAssetFeed;
}

/// @notice Params for `OracleType.IdleCDOTranchePrice`: CDO virtual price x the underlying-token-to-NAV feed, deployed
///         behind an ERC1967 proxy and initialized with the market AccessManager and the deviation-clock threshold.
/// @dev The market's collateral asset must be one of the CDO's two tranche tokens (AA or BB).
struct IdleCDOTranchePriceOracleParams {
    address idleCDO;
    address underlyingTokenToNavAssetFeed;
    uint256 minDeviationWAD;
    // Admin-attested timestamp of the virtual price's last update (zero holds pricing shut until the first observed deviation)
    uint32 lastUpdate;
}

// ═══════════════════════════════════════════════════════════════════════════
// DEPLOYMENT RESULT
// ═══════════════════════════════════════════════════════════════════════════

/// @notice Complete deployment result. `accessManager` is the factory's separate AM.
struct DeploymentResult {
    RoycoFactory factory;
    AccessManager accessManager;
    IYDM ydm;
    IRoycoVaultTranche seniorTranche;
    IRoycoVaultTranche juniorTranche;
    IRoycoDayAccountant accountant;
    IRoycoDayKernel kernel;
    address roycoBlacklist;
    address entryPoint;
    address marketSyncer;
}

/// @notice The chain-level protocol scaffolding a market is deployed against (shared singletons + the market's template).
/// @dev Bundled into one struct so the deploy script can pass it around as a single stack slot (via-IR stack budget).
struct ProtocolScaffolding {
    AccessManager accessManager;
    RoycoFactory factory;
    address entryPoint;
    address marketSyncer;
    address roycoBlacklist;
    address template;
    bytes32 marketId;
}

// ═══════════════════════════════════════════════════════════════════════════
// CHAIN-SPECIFIC CONFIG (defined once per chain)
// ═══════════════════════════════════════════════════════════════════════════

struct ChainConfig {
    address factoryAdmin;
    address protocolFeeRecipient;
    address pauserAddress;
    address unpauserAddress;
    address upgraderAddress;
    address syncRoleAddress;
    address adminKernelAddress;
    address adminAccountantAddress;
    address adminProtocolFeeSetterAddress;
    address adminOracleAddress;
    address lpRoleAdminAddress;
    address guardianAddress;
    address deployerAddress;
    address deployerAdminAddress;
    uint32 scheduledOperationsExpirySeconds;
    // Day: the Balancer V3 Gyro E-CLP pool factory the LPT pool is created against.
    address gyroECLPPoolFactory;
    // Day: Balancer's E-CLP LP oracle factory; the template deploys each market's BPT oracle through it.
    address eclpLPOracleFactory;
    // Foundation ("fndn") operational role holders.
    address balancerPoolManagerAddress;
    address marketOpsAddress;
    // Holder of the dedicated liquidity-premium reinvestment retry knob (split from market ops).
    address marketReinvestLiquidityPremiumAddress;
    // Entry point admins: config changes (delays, oracle gate flags, enable flags) and protocol fee collection.
    address adminEntryPointAddress;
    address entryPointFeeCollectorAddress;
}

// ═══════════════════════════════════════════════════════════════════════════
// MARKET-SPECIFIC CONFIG
// ═══════════════════════════════════════════════════════════════════════════

/**
 * @notice Gyro E-CLP pool params for a market's LPT `{ST_share, quote}` pool. The deployer's scripts create the pool
 *         from these params (under EIP-7825 the pool is created outside the market's wiring transaction), and the
 *         template verifies the resulting pool
 * @custom:field name - The name of the Gyro E-CLP BPT
 * @custom:field symbol - The symbol of the Gyro E-CLP BPT
 * @custom:field eclpParams - The E-CLP curve parameters (price bounds and rotation) defining the pool's rate-scaled AMM
 * @custom:field derivedEclpParams - The high-precision derived E-CLP parameters computed off-chain from `eclpParams`
 * @custom:field swapFeePercentage - The pool's swap fee, scaled to WAD (1e18 = 100%)
 * @custom:field quoteAsset - The quote asset (stablecoin) paired against the senior tranche share in the pool
 * @custom:field quoteAssetRateProvider - The rate provider supplying the quote leg's rate to the pool
 * @custom:field chargeYieldFeeOnSeniorTrancheShares - Whether Balancer charges yield fees on the senior leg's rate growth
 * @custom:field chargeYieldFeeOnQuoteAsset - Whether Balancer charges yield fees on the quote leg's rate growth (requires a quote rate provider)
 */
struct GyroECLPPoolParams {
    string name;
    string symbol;
    IGyroECLPPool.EclpParams eclpParams;
    IGyroECLPPool.DerivedEclpParams derivedEclpParams;
    uint256 swapFeePercentage;
    address quoteAsset;
    address quoteAssetRateProvider;
    bool chargeYieldFeeOnSeniorTrancheShares;
    bool chargeYieldFeeOnQuoteAsset;
}

struct MarketConfig {
    // Market identification
    string marketName;
    uint256 chainId;
    // Tranche metadata
    string seniorTrancheName;
    string seniorTrancheSymbol;
    string juniorTrancheName;
    string juniorTrancheSymbol;
    string liquidityProviderTrancheName;
    string liquidityProviderTrancheSymbol;
    // Assets
    address collateralAsset;
    // Collateral asset pricing: the IRoycoPriceOracle wired into the kernel at initialization. When
    // `collateralAssetOracle` is unset the deploy script deploys the `collateralAssetOracleType` adapter from its
    // kind-specific params (each OracleType decodes its own struct from the bytes blob).
    address collateralAssetOracle;
    OracleType collateralAssetOracleType;
    bytes collateralAssetOracleSpecificParams;
    uint48 stalenessThresholdSeconds;
    address sequencerUptimeFeed;
    uint48 gracePeriodSeconds;
    // Dust tolerance
    uint256 dustTolerance;
    // Kernel
    KernelType kernelType;
    bytes kernelSpecificParams;
    uint64 stSelfLiquidationBonusWAD;
    bool enforceVaultSharesTransferWhitelist;
    // Accountant
    uint64 stProtocolFeeWAD;
    uint64 jtProtocolFeeWAD;
    uint64 jtYieldShareProtocolFeeWAD;
    uint64 minCoverageWAD;
    uint256 coverageLiquidationUtilizationWAD;
    uint24 fixedTermDurationSeconds;
    YDMType ydmType;
    bytes ydmSpecificParams; // JT YDM curve
    bytes lptYdmSpecificParams; // LDM curve
    uint256 jtYdmTargetUtilizationWAD; // JT YDM target-utilization kink
    uint256 lptYdmTargetUtilizationWAD; // LDM target-utilization kink
    // Liquidity provider tranche: the Gyro E-CLP {ST_share, quote} pool the LPT BPT is minted from.
    GyroECLPPoolParams gyroECLPPoolParams;
    // Whether to deploy the Balancer pool hook
    bool deployPoolHook;
    // Entry point config per tranche
    IRoycoDayEntryPoint.TrancheConfig stEntryPointConfig;
    IRoycoDayEntryPoint.TrancheConfig jtEntryPointConfig;
    IRoycoDayEntryPoint.TrancheConfig lptEntryPointConfig;
}
