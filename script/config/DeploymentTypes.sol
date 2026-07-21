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
import {
    IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter
} from "../../src/kernels/base/quoter/identical-st-jt/IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.sol";
import {
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "../../src/kernels/base/quoter/identical-st-jt/IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import {
    IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter
} from "../../src/kernels/base/quoter/identical-st-jt/IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter.sol";
import {
    IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "../../src/kernels/base/quoter/identical-st-jt/IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";

// ═══════════════════════════════════════════════════════════════════════════
// ENUMS
// ═══════════════════════════════════════════════════════════════════════════

/// @notice Day kernel types the deployment path can deploy.
/// @dev New Day kernel types are added here as they ship.
enum KernelType {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel,
    Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel,
    Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel,
    Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel
}

/// @notice YDM types.
enum YDMType {
    StaticCurve,
    AdaptiveCurve_V1,
    AdaptiveCurve_V2
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
    address adminOracleQuoterAddress;
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
// KERNEL-SPECIFIC PARAM STRUCTS
// ═══════════════════════════════════════════════════════════════════════════

// ─── Day ERC4626-Chainlink-Balancer kernel (field-identical to the template's) ───
struct IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_QuoterKernelParams {
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams stAndJTQuoterParams;
    BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams ltQuoterParams;
}

// ─── Day Makina-Chainlink-Balancer kernel (encoding-identical to the template's KernelSpecificParams wrapper,
//     all fields static so flat and nested encodings agree) ───
struct IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_QuoterKernelParams {
    address makinaMachine;
    IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams stAndJTQuoterParams;
    BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams ltQuoterParams;
}

// ─── Day Chainlink-to-admin-Balancer kernel (field-identical to the template's) ───
struct IdenticalAssets_ST_JT_ChainlinkToAdminOracle_QuoterKernelParams {
    IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.ST_JT_QuoterSpecificParams stAndJTQuoterParams;
    BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams ltQuoterParams;
}

// ─── Day IdleCDO-VirtualPrice-Balancer kernel (encoding-identical to the template's KernelSpecificParams wrapper,
//     all fields static so flat and nested encodings agree) ───
struct Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_QuoterKernelParams {
    address idleCDO;
    IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter.ST_JT_QuoterSpecificParams stAndJTQuoterParams;
    BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams ltQuoterParams;
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
    address adminOracleQuoterAddress;
    address lpRoleAdminAddress;
    address guardianAddress;
    address deployerAddress;
    address deployerAdminAddress;
    uint32 scheduledOperationsExpirySeconds;
    // Day: the Balancer V3 Gyro E-CLP pool factory the LT pool is created against.
    address gyroECLPPoolFactory;
    // Day: Balancer's E-CLP LP oracle factory; the template deploys each market's BPT oracle through it.
    address eclpLPOracleFactory;
    // Foundation ("fndn") operational role holders.
    address balancerPoolManagerAddress;
    address marketOpsAddress;
    // Holder of the dedicated liquidity-premium reinvestment retry knob (split from market ops).
    address marketReinvestLiquidityPremiumAddress;
    // Entry point admins: config changes (delays, oracle clocks, enable flags) and protocol fee collection.
    address adminEntryPointAddress;
    address entryPointFeeCollectorAddress;
}

// ═══════════════════════════════════════════════════════════════════════════
// MARKET-SPECIFIC CONFIG
// ═══════════════════════════════════════════════════════════════════════════

/**
 * @notice Gyro E-CLP pool params for a market's LT `{ST_share, quote}` pool. The deployer's scripts create the pool
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
    string liquidityTrancheName;
    string liquidityTrancheSymbol;
    // Assets
    address seniorAsset;
    address juniorAsset;
    // Dust tolerances
    uint256 stDustTolerance;
    uint256 jtDustTolerance;
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
    bytes ltYdmSpecificParams; // LDM curve
    uint256 jtYdmTargetUtilizationWAD; // JT YDM target-utilization kink
    uint256 ltYdmTargetUtilizationWAD; // LDM target-utilization kink
    // Liquidity tranche: the Gyro E-CLP {ST_share, quote} pool the LT BPT is minted from.
    GyroECLPPoolParams gyroECLPPoolParams;
    // Entry point config per tranche
    IRoycoDayEntryPoint.TrancheConfig stEntryPointConfig;
    IRoycoDayEntryPoint.TrancheConfig jtEntryPointConfig;
    IRoycoDayEntryPoint.TrancheConfig ltEntryPointConfig;
}
