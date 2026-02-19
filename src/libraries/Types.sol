// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoAccountant } from "../interfaces/IRoycoAccountant.sol";
import { IRoycoKernel } from "../interfaces/kernel/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../interfaces/tranche/IRoycoVaultTranche.sol";
import { BASE_UNIT, NAV_UNIT, TRANCHE_UNIT } from "./Units.sol";

/**
 * @title MarketState
 * @notice Defines the operational state of a Royco market
 * @custom:state PERPETUAL
 *      Normal operating state where market forces govern behavior
 *      - The market is healthy (no losses over dust tolerance) or it is severely undercollateralized (LLTV breach) or uncollateralized (ST IL != 0 or JT_EFFECTIVE_NAV == 0)
 *      - Both tranches liquid (within coverage constraints) unless ST impermanent loss exists (ST deposits are blocked)
 *      - Adaptive curve YDM adapts based on utilization
 * @custom:state FIXED_TERM
 *      Temporary recovery state triggered when JT provides coverage for ST drawdown
 *      - ST experienced a fully covered drawdown but the market is still healthy in terms of its LLTV
 *      - Fixed term that starts when JT coverage impermanent loss is first incurred
 *      - ST redemptions blocked: protects existing JT from realizing losses by ST withdrawing coverage on arbitrary volatility
 *      - JT deposits blocked: protects existing JT from realizing losses by new JT diluting them on arbitrary volatility
 *      - Adaptive curve YDM does not adapt (prevents adaption during recovery since market forces aren't influencing utilization, underlying PNL is)
 *      - Automatically transitions to PERPETUAL when term elapses, clearing JT coverage impermanent losses
 */
enum MarketState {
    PERPETUAL,
    FIXED_TERM
}

/**
 * @title AssetClaims
 * @dev A struct representing claims on senior tranche assets, junior tranche assets, and NAV
 * @custom:field stAssets - The claim on senior tranche assets denominated in ST's tranche units
 * @custom:field jtAssets - The claim on junior tranche assets denominated in JT's tranche units
 * @custom:field liquidationProceeds - Settlement received from liquidation events, in liquidation asset units (always 0 for JT claims)
 * @custom:field nav - The net asset value of these claims in NAV units
 */
struct AssetClaims {
    TRANCHE_UNIT stAssets;
    TRANCHE_UNIT jtAssets;
    BASE_UNIT liquidationProceeds;
    NAV_UNIT nav;
}

/**
 * @title SyncedAccountingState
 * @dev Contains all current mark to market NAV accounting data for the market's tranches
 * @custom:field marketState - The current state of the Royco market (perpetual or fixed term)
 * @custom:field stRawNAV - The senior tranche's current raw NAV: the pure value of its invested assets
 * @custom:field jtRawNAV - The junior tranche's current raw NAV: the pure value of its invested assets
 * @custom:field stEffectiveNAV - Senior tranche effective NAV: includes applied coverage, its share of ST yield, and uncovered losses
 * @custom:field jtEffectiveNAV - Junior tranche effective NAV: includes provided coverage, JT yield, its share of ST yield, and JT losses
 * @custom:field stImpermanentLoss - The impermanent loss that ST has suffered after exhausting JT's loss-absorption buffer
 *                                   This represents the first claim on capital that the senior tranche has on future ST and JT recoveries
 * @custom:field jtCoverageImpermanentLoss - The impermanent loss that JT has suffered after providing coverage for ST losses
 *                                           This represents the second claim on capital that the junior tranche has on future ST recoveries
 * @custom:field jtSelfImpermanentLoss - The impermanent loss that JT has suffered from depreciaiton of its own NAV
 *                                       This represents the first claim on capital that the junior tranche has on future JT recoveries
 * @custom:field stProtocolFeeAccrued - Protocol fee taken on ST yield on this sync
 * @custom:field jtProtocolFeeAccrued - Protocol fee taken on JT yield on this sync
 * @custom:field fixedTermDurationSeconds - The duration of the fixed term in seconds
 * @custom:field utilizationWAD - The current utilization of the market, scaled to WAD precision
 * @custom:field ltvWAD - The current loan to value of the market, scaled to WAD precision
 * @custom:field fixedTermEndTimestamp - The timestamp at which the fixed term ends. Set to 0 if the market is not in a fixed term state
 */
struct SyncedAccountingState {
    MarketState marketState;
    NAV_UNIT stRawNAV;
    NAV_UNIT jtRawNAV;
    NAV_UNIT stEffectiveNAV;
    NAV_UNIT jtEffectiveNAV;
    NAV_UNIT stImpermanentLoss;
    NAV_UNIT jtCoverageImpermanentLoss;
    NAV_UNIT jtSelfImpermanentLoss;
    NAV_UNIT stProtocolFeeAccrued;
    NAV_UNIT jtProtocolFeeAccrued;
    // Additional data about the market's post-sync state
    uint256 utilizationWAD;
    uint256 ltvWAD;
    uint32 fixedTermEndTimestamp;
}

/**
 * @title Operation
 * @dev Defines the type of operation being executed by the user
 * @custom:type ST_DEPOSIT - A senior tranche deposit that increases ST's effective NAV
 * @custom:type ST_REDEEM - A senior tranche redemption that decreases ST's effective NAV
 * @custom:type JT_DEPOSIT - A junior tranche deposit that increases JT's effective NAV
 * @custom:type JT_REDEEM - A junior tranche redemption that decreases JT's effective NAV
 */
enum Operation {
    ST_DEPOSIT,
    ST_REDEEM,
    JT_DEPOSIT,
    JT_REDEEM
}

/**
 * @title TrancheType
 * @dev Defines the two types of Royco tranches deployed per market.
 * @custom:type SENIOR - The identifier for the senior tranche (protected capital)
 * @custom:type JUNIOR - The identifier for the junior tranche (first-loss capital)
 */
enum TrancheType {
    SENIOR,
    JUNIOR
}

/**
 * @notice Parameters for deploying a new market
 * @custom:field seniorTrancheName - The name of the senior tranche
 * @custom:field seniorTrancheSymbol - The symbol of the senior tranche
 * @custom:field juniorTrancheName - The name of the junior tranche
 * @custom:field juniorTrancheSymbol - The symbol of the junior tranche
 * @custom:field seniorAsset - The underlying asset for the senior tranche
 * @custom:field juniorAsset - The underlying asset for the junior tranche
 * @custom:field marketId - The identifier of the Royco market
 * @custom:field kernelImplementation - The implementation address for the kernel
 * @custom:field accountantImplementation - The implementation address for the accountant
 * @custom:field seniorTrancheImplementation - The implementation address for the senior tranche
 * @custom:field juniorTrancheImplementation - The implementation address for the junior tranche
 * @custom:field kernelInitializationData - The initialization data for the kernel
 * @custom:field accountantInitializationData - The initialization data for the accountant
 * @custom:field seniorTrancheInitializationData - The initialization data for the senior tranche
 * @custom:field juniorTrancheInitializationData - The initialization data for the junior tranche
 * @custom:field seniorTrancheProxyDeploymentSalt - The salt for the senior tranche proxy deployment
 * @custom:field juniorTrancheProxyDeploymentSalt - The salt for the junior tranche proxy deployment
 * @custom:field kernelProxyDeploymentSalt - The salt for the kernel proxy deployment
 * @custom:field accountantProxyDeploymentSalt - The salt for the accountant proxy deployment
 */
struct MarketDeploymentParams {
    // Tranche Deployment Parameters
    string seniorTrancheName;
    string seniorTrancheSymbol;
    string juniorTrancheName;
    string juniorTrancheSymbol;
    bytes32 marketId;
    // Implementation Addresses
    IRoycoVaultTranche seniorTrancheImplementation;
    IRoycoVaultTranche juniorTrancheImplementation;
    IRoycoKernel kernelImplementation;
    IRoycoAccountant accountantImplementation;
    // Proxy Initialization Data
    bytes seniorTrancheInitializationData;
    bytes juniorTrancheInitializationData;
    bytes kernelInitializationData;
    bytes accountantInitializationData;
    // Create2 Salts
    bytes32 seniorTrancheProxyDeploymentSalt;
    bytes32 juniorTrancheProxyDeploymentSalt;
    bytes32 kernelProxyDeploymentSalt;
    bytes32 accountantProxyDeploymentSalt;
    // Initial Roles Configuration
    RolesTargetConfiguration[] roles;
}

/**
 * @custom:field name - The name of the tranche share token (should be prefixed with "Royco-ST" or "Royco-JT")
 * @custom:field symbol - The symbol of the tranche share token (should be prefixed with "ST" or "JT")
 * @custom:field kernel - The tranche kernel responsible for defining the execution model and core logic of the market
 */
struct TrancheDeploymentParams {
    string name;
    string symbol;
    address kernel;
}

/**
 * @notice For a given target address, the configuration for a role
 * @custom:field target - The target address of the role
 * @custom:field selectors - The selectors of the role
 * @custom:field roles - The roles of the role
 */
struct RolesTargetConfiguration {
    address target;
    bytes4[] selectors;
    uint64[] roles;
}

/**
 * @notice The contracts constituting a Royco market
 * @custom:field seniorTranche - The senior tranche contract
 * @custom:field juniorTranche - The junior tranche contract
 * @custom:field kernel - The kernel contract
 * @custom:field accountant - The accountant contract
 */
struct RoycoMarket {
    IRoycoVaultTranche seniorTranche;
    IRoycoVaultTranche juniorTranche;
    IRoycoKernel kernel;
    IRoycoAccountant accountant;
}
