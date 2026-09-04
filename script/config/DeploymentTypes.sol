// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { ERC4626SharePriceOracle } from "../../src/oracle/ERC4626SharePriceOracle.sol";

// ═══════════════════════════════════════════════════════════════════════════
// ENUMS
// ═══════════════════════════════════════════════════════════════════════════

/// @notice The yield distribution model shapes the deployment path can deploy
/// @dev The template keys its model registry by name rather than by this enum, so a new shape can be registered on a
///      live template. This enum stays script-side, where it selects the model's creation code and initialization data
enum YDMType {
    StaticCurve,
    AdaptiveCurve_V1,
    AdaptiveCurve_V2,
    Fixed
}

/// @notice Collateral asset oracle kinds the deployment path can deploy (one per `src/oracle/` adapter).
/// @dev New oracle adapters are added here as they ship. Each kind decodes its own params struct from
///      `CollateralOracleConfig.specificParams` (typed by `oracleType`, mirroring the YDM selections).
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
    address adminFactoryAddress;
    address syncRoleAddress;
    address adminKernelAddress;
    address adminAccountantAddress;
    address adminProtocolFeeSetterAddress;
    address adminOracleAddress;
    address adminOracleEmergencyAddress;
    address lpRoleAdminAddress;
    address lpRoleAdminOperatorAddress;
    address guardianAddress;
    address guardianVetoAddress;
    address lpRoleHolderAddress;
    address balancerPoolManagerAddress;
    address marketOpsAddress;
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

/// @notice Initialization params for the fixed YDM: the constant yield share paid at every utilization (zero is a valid fixed share)
struct FixedYDMParams {
    uint64 fixedYieldShareWAD;
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
/// @dev Staleness thresholds are oracle CONSTRUCTION IMMUTABLES: each adapter judges every timestamped hop against its
///      own threshold inside `getPrice` and fails shut, so retuning a threshold means redeploying the adapter.
struct ChainlinkPriceOracleParams {
    address collateralToNavAssetFeed;
    // The maximum age of the feed's report before pricing fails shut, sized to the feed's heartbeat
    uint32 chainlinkOracleStalenessThresholdSeconds;
}

/// @notice Params for `OracleType.ERC4626SharePrice`: share price via `convertToAssets` x the base-asset-to-NAV feed.
/// @dev The vault is the market's collateral asset itself.
struct ERC4626SharePriceOracleParams {
    // The ERC4626 query used to read the vault's share price (previewRedeem prices shares at their realizable redemption value)
    ERC4626SharePriceOracle.ERC4626QueryMode queryMode;
    address baseAssetToNavAssetFeed;
    // The minimum relative deviation from the checkpointed share price that counts as an update (zero counts any change)
    uint256 minDeviationWAD;
    // Deployer-attested timestamp of the share price's last update (zero holds pricing shut until the first observed deviation)
    uint32 lastUpdate;
    // The maximum age of the feed's report before pricing fails shut, sized to the feed's heartbeat
    uint32 chainlinkOracleStalenessThresholdSeconds;
    // The maximum age of the share-price clock's checkpoint before pricing fails shut, sized past the vault's longest plausible flat stretch
    uint32 vaultSharePriceStalenessThresholdSeconds;
}

/// @notice Params for `OracleType.MakinaSharePrice`: machine share price via `convertToAssets` x the accounting-asset-to-NAV feed.
/// @dev The machine's share token must be the market's collateral asset (the oracle resolves it at construction).
struct MakinaSharePriceOracleParams {
    address makinaMachine;
    address accountingAssetToNavAssetFeed;
    // The maximum age of the feed's report before pricing fails shut, sized to the feed's heartbeat
    uint32 chainlinkOracleStalenessThresholdSeconds;
    // The maximum age of the machine's last global accounting before pricing fails shut, sized to the machine's accounting cadence
    uint32 makinaAccountingStalenessThresholdSeconds;
}

/// @notice Params for `OracleType.IdleCDOTranchePrice`: CDO virtual price x the underlying-token-to-NAV feed
/// @dev The market's collateral asset must be one of the CDO's two tranche tokens (AA or BB).
struct IdleCDOTranchePriceOracleParams {
    address idleCDO;
    address underlyingTokenToNavAssetFeed;
    uint256 minDeviationWAD;
    // Admin-attested timestamp of the virtual price's last update (zero holds pricing shut until the first observed deviation)
    uint32 lastUpdate;
    // The maximum age of the feed's report before pricing fails shut, sized to the feed's heartbeat
    uint32 chainlinkOracleStalenessThresholdSeconds;
    // The maximum age of the virtual-price clock's checkpoint before pricing fails shut, sized to the CDO's update cadence
    uint32 cdoPriceStalenessThresholdSeconds;
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

// ═══════════════════════════════════════════════════════════════════════════
// PIPELINE STRUCTS (upstream address handover between component scripts)
// ═══════════════════════════════════════════════════════════════════════════

/// @notice The core script's output: the chain's auth + factory backbone (predicted periphery included)
struct CoreDeployment {
    address accessManager;
    address create3Deployer;
    address gatekeeper;
    address factory;
    address entryPoint;
    address marketSyncer;
    bool amExisted;
    bool factoryExisted;
}

/// @notice Upstream addresses the periphery script is constructed with
struct PeripheryUpstream {
    address accessManager;
    address factory;
}

/// @notice The chain-wide component beacons + the BPT oracle feed the template is constructed against
struct ImplementationSet {
    address seniorTrancheBeacon;
    address juniorTrancheBeacon;
    address liquidityProviderTrancheBeacon;
    address accountantBeacon;
    address kernelBeacon;
    address bptOracleConstantPriceFeed;
}

/// @notice Upstream addresses the template script is constructed with
struct TemplateUpstream {
    address accessManager;
    address factory;
    ImplementationSet impls;
}

/// @notice Upstream addresses the market script is constructed with (the fully bootstrapped chain)
struct MarketUpstream {
    address accessManager;
    address factory;
    address entryPoint;
    address marketSyncer;
    address template;
}

/// @notice The bootstrap orchestrator's output: everything a chain needs before any market exists
struct ChainDeployment {
    address accessManager;
    address gatekeeper;
    address factory;
    address entryPoint;
    address marketSyncer;
    address template;
    ImplementationSet impls;
    bool amExisted;
}

// ═══════════════════════════════════════════════════════════════════════════
// TEMPLATE POLICY (SYSTEM configuration the template is constructed with)
// ═══════════════════════════════════════════════════════════════════════════

struct TemplatePolicy {
    address protocolFeeRecipient;
    uint64 stProtocolFeeWAD;
    uint64 jtProtocolFeeWAD;
    uint64 jtYieldShareProtocolFeeWAD;
    uint64 lptYieldShareProtocolFeeWAD;
    bool chargeYieldFeeOnSTShares;
    bool chargeYieldFeeOnQuoteAssets;
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
 * @custom:field swapFeePercentage - The pool's static swap fee, scaled to WAD precision
 * @custom:field quoteAsset - The quote asset (stablecoin) paired against the senior tranche share in the pool
 * @custom:field quoteAssetRateProvider - The rate provider supplying the quote leg's rate to the pool
 */
struct GyroECLPPoolParams {
    string name;
    string symbol;
    IGyroECLPPool.EclpParams eclpParams;
    IGyroECLPPool.DerivedEclpParams derivedEclpParams;
    uint64 swapFeePercentage;
    address quoteAsset;
    address quoteAssetRateProvider;
}
