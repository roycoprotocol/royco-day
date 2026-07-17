// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ILPOracleFactoryBase } from "../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { GyroECLPPoolFactory } from "../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { UUPSUpgradeable } from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { AccessManager } from "../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { RoycoMarketSyncer } from "../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { RoycoDayAccountant } from "../src/accountant/RoycoDayAccountant.sol";
import { RoycoBlacklist } from "../src/auth/RoycoBlacklist.sol";
import { RoycoDayEntryPoint } from "../src/entrypoint/RoycoDayEntryPoint.sol";
import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_BALANCER_POOL_MANAGER_ROLE,
    ADMIN_BLACKLIST_ROLE,
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE,
    ADMIN_FACTORY_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_MARKET_OPS_ROLE,
    ADMIN_ORACLE_QUOTER_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    DEPLOYER_ROLE,
    DEPLOYER_ROLE_ADMIN_ROLE,
    GUARDIAN_ROLE,
    JT_LP_ROLE,
    LP_ROLE_ADMIN_ROLE,
    LT_LP_ROLE,
    PUBLIC_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE
} from "../src/factory/RolesConfiguration.sol";
import { RoycoFactory } from "../src/factory/RoycoFactory.sol";
import {
    Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3GyroECLP_LT_DeploymentTemplate
} from "../src/factory/templates/Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3GyroECLP_LT_DeploymentTemplate.sol";
import {
    Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3GyroECLP_LT_DeploymentTemplate
} from "../src/factory/templates/Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3GyroECLP_LT_DeploymentTemplate.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate
} from "../src/factory/templates/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate.sol";
import {
    Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate
} from "../src/factory/templates/Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate.sol";
import {
    COMPONENT_ID_ACCOUNTANT_IMPL,
    COMPONENT_ID_DAY_BALANCER_HOOKS,
    COMPONENT_ID_DAY_KERNEL_IDENTICAL_AA_IDLE_CDO_VIRTUAL_PRICE,
    COMPONENT_ID_DAY_KERNEL_IDENTICAL_CHAINLINK_TO_ADMIN,
    COMPONENT_ID_DAY_KERNEL_IDENTICAL_ERC4626_CHAINLINK,
    COMPONENT_ID_DAY_KERNEL_IDENTICAL_MAKINA_CHAINLINK,
    COMPONENT_ID_JUNIOR_TRANCHE_IMPL,
    COMPONENT_ID_LIQUIDITY_TRANCHE_IMPL,
    COMPONENT_ID_SENIOR_TRANCHE_IMPL,
    COMPONENT_ID_YDM_ADAPTIVE_CURVE_V1,
    COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2,
    COMPONENT_ID_YDM_STATIC_CURVE
} from "../src/factory/templates/base/Components.sol";
import { BalancerV3_GyroECLP_LT_DeploymentTemplate } from "../src/factory/templates/liquidity-tranche/BalancerV3_GyroECLP_LT_DeploymentTemplate.sol";
import { IRoycoAuth } from "../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayEntryPoint } from "../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../src/interfaces/IYDM.sol";
import { IBaseTemplate } from "../src/interfaces/factory/IBaseTemplate.sol";
import { IRoycoFactory } from "../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import {
    Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel
} from "../src/kernels/Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel
} from "../src/kernels/Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel
} from "../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel
} from "../src/kernels/Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel.sol";
import {
    IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter
} from "../src/kernels/base/quoter/identical-st-jt/IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.sol";
import {
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "../src/kernels/base/quoter/identical-st-jt/IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import {
    IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter
} from "../src/kernels/base/quoter/identical-st-jt/IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter.sol";
import {
    IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "../src/kernels/base/quoter/identical-st-jt/IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { RoycoDayBalancerV3Hooks } from "../src/kernels/base/quoter/liquidity-tranche/balancer-v3/hooks/RoycoDayBalancerV3Hooks.sol";
import { toNAVUnits } from "../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../src/tranches/RoycoJuniorTranche.sol";
import { RoycoLiquidityTranche } from "../src/tranches/RoycoLiquidityTranche.sol";
import { RoycoSeniorTranche } from "../src/tranches/RoycoSeniorTranche.sol";
import { AdaptiveCurveYDM_V1 } from "../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../src/ydm/AdaptiveCurveYDM_V2.sol";
import { StaticCurveYDM } from "../src/ydm/StaticCurveYDM.sol";
import { MarketDeploymentConfig } from "./config/MarketDeploymentConfig.sol";
import { Create2DeployUtils } from "./utils/Create2DeployUtils.sol";
import { Script } from "lib/forge-std/src/Script.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/// @title DeployScript
/// @notice Template-driven deployment script for Royco markets. Stands up a standalone AccessManager + the
///         template-driven RoycoFactory, registers the Day template for the requested kernel type, and deploys
///         the market via `executeMarketDeployment`.
/// @dev The public surface (`deploy`, `deployFromConfig`, `generateRolesAssignments`, `DeploymentResult`,
///      `RoleAssignmentAddresses`, `KernelType`/`YDMType`) is preserved so existing tests need minimal changes.
contract DeployScript is Script, Create2DeployUtils, MarketDeploymentConfig {
    error UnsupportedKernelType(KernelType kernelType);
    error UnsupportedYDMType(YDMType ydmType);
    error UNKNOWN_ROLE(uint64 role);
    error PredictedImplementationHasNoCode(bytes32 componentTag, address predicted);

    // CREATE2 salts for the singletons (AccessManager + factory) so reruns within a test reuse them.
    bytes32 constant ACCESS_MANAGER_SALT = keccak256("ROYCO_ACCESS_MANAGER_V2");
    bytes32 constant FACTORY_IMPL_SALT = keccak256("ROYCO_FACTORY_IMPLEMENTATION_V2");
    bytes32 constant FACTORY_PROXY_SALT = keccak256("ROYCO_FACTORY_PROXY_V2");
    bytes32 constant BLACKLIST_IMPL_SALT = keccak256("ROYCO_BLACKLIST_IMPLEMENTATION_V2");
    bytes32 constant BLACKLIST_PROXY_SALT = keccak256("ROYCO_BLACKLIST_PROXY_V2");
    bytes32 constant ENTRY_POINT_IMPL_SALT = keccak256("ROYCO_DAY_ENTRY_POINT_IMPLEMENTATION_V2");
    bytes32 constant ENTRY_POINT_PROXY_SALT = keccak256("ROYCO_DAY_ENTRY_POINT_PROXY_V2");
    bytes32 constant SYNCER_IMPL_SALT = keccak256("ROYCO_MARKET_SYNCER_IMPLEMENTATION_V2");
    bytes32 constant SYNCER_PROXY_SALT = keccak256("ROYCO_MARKET_SYNCER_PROXY_V2");

    bool ENABLE_LOGGING = false;

    /// @dev Per-DeployScript-instance cache of registered templates, keyed by kernel type.
    mapping(uint256 kernelType => address template) internal kernelTypeToTemplate;

    /// @notice Enum for the Day kernel types this script can deploy.
    /// @dev New Day kernel types are added here as they ship.
    enum KernelType {
        Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel,
        Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel,
        Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel,
        Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel
    }

    /// @notice Enum for YDM types
    enum YDMType {
        StaticCurve,
        AdaptiveCurve_V1,
        AdaptiveCurve_V2
    }

    /// @notice Per-role admin/guardian/delay configuration (ported from the legacy RolesConfiguration).
    struct RoleConfig {
        uint64 adminRole;
        uint64 guardianRole;
        uint32 executionDelay;
    }

    // ─── Kernel-specific param struct for the Day ERC4626-Chainlink-Balancer kernel (field-identical to the template's) ───

    struct IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_QuoterKernelParams {
        IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams stAndJTQuoterParams;
        BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams ltQuoterParams;
    }

    // ─── Kernel-specific param struct for the Day Makina-Chainlink-Balancer kernel (encoding-identical to the
    //     template's KernelSpecificParams wrapper, all fields static so flat and nested encodings agree) ───

    struct IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_QuoterKernelParams {
        address makinaMachine;
        IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams stAndJTQuoterParams;
        BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams ltQuoterParams;
    }

    // ─── Kernel-specific param struct for the Day Chainlink-to-admin-Balancer kernel (field-identical to the template's) ───

    struct IdenticalAssets_ST_JT_ChainlinkToAdminOracle_QuoterKernelParams {
        IdenticalAssets_ST_JT_ChainlinkToAdminOracle_Quoter.ST_JT_QuoterSpecificParams stAndJTQuoterParams;
        BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams ltQuoterParams;
    }

    // ─── Kernel-specific param struct for the Day IdleCDO-VirtualPrice-Balancer kernel (encoding-identical to the
    //     template's KernelSpecificParams wrapper, all fields static so flat and nested encodings agree) ───

    struct Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_QuoterKernelParams {
        address idleCDO;
        IdenticalIdleCDOAATranches_ST_JT_VirtualPriceOracle_Quoter.ST_JT_QuoterSpecificParams stAndJTQuoterParams;
        BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams ltQuoterParams;
    }

    // ─── YDM param structs ───

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

    /// @notice Complete deployment result. `accessManager` is new (the factory's separate AM).
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

    /// @notice Addresses for role assignments
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

    /// @notice Entry point for `forge script`. Reads DEPLOYER_PRIVATE_KEY and MARKET_NAME from env.
    function run() external virtual {
        ENABLE_LOGGING = true;
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory marketName = vm.envString("MARKET_NAME");
        console2.log("Deploying market from config:", marketName);
        deployFromConfig(marketName, deployerPrivateKey);
    }

    /// @notice Deploy a market using Solidity configuration.
    function deployFromConfig(string memory marketName, uint256 deployerPrivateKey) public returns (DeploymentResult memory) {
        ChainConfig memory chainConfig = getChainConfig(block.chainid);
        MarketConfig memory marketConfig = getMarketConfig(marketName);

        RoleAssignment[] memory roleAssignments = generateRolesAssignments(
            RoleAssignmentAddresses({
                pauserAddress: chainConfig.pauserAddress,
                unpauserAddress: chainConfig.unpauserAddress,
                upgraderAddress: chainConfig.upgraderAddress,
                syncRoleAddress: chainConfig.syncRoleAddress,
                adminKernelAddress: chainConfig.adminKernelAddress,
                adminAccountantAddress: chainConfig.adminAccountantAddress,
                adminProtocolFeeSetterAddress: chainConfig.adminProtocolFeeSetterAddress,
                adminOracleQuoterAddress: chainConfig.adminOracleQuoterAddress,
                lpRoleAdminAddress: chainConfig.lpRoleAdminAddress,
                guardianAddress: chainConfig.guardianAddress,
                deployerAddress: chainConfig.deployerAddress,
                deployerAdminAddress: chainConfig.deployerAdminAddress,
                protocolFeeRecipientAddress: chainConfig.protocolFeeRecipient,
                balancerPoolManagerAddress: chainConfig.balancerPoolManagerAddress,
                marketOpsAddress: chainConfig.marketOpsAddress,
                adminEntryPointAddress: chainConfig.adminEntryPointAddress,
                entryPointFeeCollectorAddress: chainConfig.entryPointFeeCollectorAddress
            })
        );

        return deploy(
            marketConfig,
            chainConfig.factoryAdmin,
            chainConfig.protocolFeeRecipient,
            chainConfig.scheduledOperationsExpirySeconds,
            roleAssignments,
            deployerPrivateKey
        );
    }

    /// @notice Deploys a complete Royco market via the template factory.
    function deploy(
        MarketConfig memory _config,
        address _factoryAdmin,
        address _protocolFeeRecipient,
        uint32 _scheduledOperationsExpirySeconds,
        RoleAssignment[] memory _roleAssignments,
        uint256 _deployerPrivateKey
    )
        public
        returns (DeploymentResult memory)
    {
        _scheduledOperationsExpirySeconds; // silence unused (template factory has no scheduled-ops expiry)
        vm.startBroadcast(_deployerPrivateKey);
        address deployer = vm.addr(_deployerPrivateKey);

        // 1. Stand up the AccessManager + factory (idempotent within a test via CREATE2).
        (AccessManager accessManager, RoycoFactory factory, bool amExisted) = _deployAccessManagerAndFactory(deployer);

        // 1.5. Deploy (or reuse) the periphery singletons (entry point + market syncer) the template configures per
        //      market. Runs BEFORE the role graph is applied: the entry point's LP role grants require the LP roles'
        //      admin to still be ADMIN_ROLE (held by the deployer), and pass 2 of the role graph re-points it.
        (address entryPoint, address marketSyncer) = _deployPeripherySingletons(accessManager, address(factory));

        // 1.75. Apply the role graph (grants + admin/guardian re-pointing) on a freshly deployed AccessManager.
        if (!amExisted) _applyRoleGraph(accessManager, _factoryAdmin, deployer, _roleAssignments);

        // 2. Deploy (or reuse) the chain's shared blacklist (governed by the AccessManager, not the factory).
        address roycoBlacklist = _deployBlacklist(address(accessManager));

        {
            bytes4[] memory blacklistSelectors = new bytes4[](3);
            blacklistSelectors[0] = RoycoBlacklist.blacklistAccounts.selector;
            blacklistSelectors[1] = RoycoBlacklist.unblacklistAccounts.selector;
            blacklistSelectors[2] = RoycoBlacklist.setSanctionsList.selector;
            accessManager.setTargetFunctionRole(roycoBlacklist, blacklistSelectors, ADMIN_BLACKLIST_ROLE);
        }

        // 3. Register (or reuse) the Day template for this kernel type.
        address template = _getOrRegisterTemplate(factory, _config.kernelType, entryPoint, marketSyncer);

        // 4. Deploy the market via the template.
        bytes32 marketId = keccak256(abi.encode(_config.seniorTrancheName, _config.juniorTrancheName, block.timestamp, block.chainid));
        BalancerV3_GyroECLP_LT_DeploymentTemplate.DayParams memory params = _buildDayParams(_config, marketId, _protocolFeeRecipient, roycoBlacklist);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(template, abi.encode(params));

        // Renounce the deployer's roles after deployment is complete.
        accessManager.renounceRole(ADMIN_FACTORY_ROLE, deployer);
        accessManager.renounceRole(ADMIN_ROLE, deployer);

        vm.stopBroadcast();

        return DeploymentResult({
            factory: factory,
            accessManager: accessManager,
            ydm: IYDM(r.ydm),
            seniorTranche: IRoycoVaultTranche(r.seniorTranche),
            juniorTranche: IRoycoVaultTranche(r.juniorTranche),
            accountant: IRoycoDayAccountant(r.accountant),
            kernel: IRoycoDayKernel(r.kernel),
            roycoBlacklist: roycoBlacklist,
            entryPoint: entryPoint,
            marketSyncer: marketSyncer
        });
    }

    /// @notice Builds the role assignments applied to the AccessManager (surface-compatible with the legacy helper).
    function generateRolesAssignments(RoleAssignmentAddresses memory _addresses) public pure returns (RoleAssignment[] memory roleAssignments) {
        roleAssignments = new RoleAssignment[](20);
        roleAssignments[0] = _assignment(ADMIN_PAUSER_ROLE, _addresses.pauserAddress);
        roleAssignments[1] = _assignment(ADMIN_UPGRADER_ROLE, _addresses.upgraderAddress);
        roleAssignments[2] = _assignment(SYNC_ROLE, _addresses.syncRoleAddress);
        roleAssignments[3] = _assignment(ADMIN_KERNEL_ROLE, _addresses.adminKernelAddress);
        roleAssignments[4] = _assignment(ADMIN_ACCOUNTANT_ROLE, _addresses.adminAccountantAddress);
        roleAssignments[5] = _assignment(ADMIN_PROTOCOL_FEE_SETTER_ROLE, _addresses.adminProtocolFeeSetterAddress);
        roleAssignments[6] = _assignment(ADMIN_ORACLE_QUOTER_ROLE, _addresses.adminOracleQuoterAddress);
        roleAssignments[7] = _assignment(LP_ROLE_ADMIN_ROLE, _addresses.lpRoleAdminAddress);
        roleAssignments[8] = _assignment(ST_LP_ROLE, _addresses.protocolFeeRecipientAddress);
        roleAssignments[9] = _assignment(JT_LP_ROLE, _addresses.protocolFeeRecipientAddress);
        roleAssignments[10] = _assignment(GUARDIAN_ROLE, _addresses.guardianAddress);
        roleAssignments[11] = _assignment(DEPLOYER_ROLE, _addresses.deployerAddress);
        roleAssignments[12] = _assignment(DEPLOYER_ROLE_ADMIN_ROLE, _addresses.deployerAdminAddress);
        roleAssignments[13] = _assignment(ADMIN_UNPAUSER_ROLE, _addresses.unpauserAddress);
        roleAssignments[14] = _assignment(LT_LP_ROLE, _addresses.protocolFeeRecipientAddress);
        roleAssignments[15] = _assignment(ADMIN_BALANCER_POOL_MANAGER_ROLE, _addresses.balancerPoolManagerAddress);
        roleAssignments[16] = _assignment(ADMIN_MARKET_OPS_ROLE, _addresses.marketOpsAddress);
        // The dedicated blacklist-management role (gates blacklistAccounts/unblacklistAccounts/setSanctionsList on
        // the shared RoycoBlacklist) is granted to the market-ops admin.
        roleAssignments[17] = _assignment(ADMIN_BLACKLIST_ROLE, _addresses.marketOpsAddress);
        // The entry point's config and fee-collection admin roles (the factory also self-grants the config role in
        // its initialize, the per-market template auto-configure path).
        roleAssignments[18] = _assignment(ADMIN_ENTRY_POINT_ROLE, _addresses.adminEntryPointAddress);
        roleAssignments[19] = _assignment(ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE, _addresses.entryPointFeeCollectorAddress);
    }

    function _assignment(uint64 _role, address _assignee) private pure returns (RoleAssignment memory) {
        RoleConfig memory cfg = getRoleConfig(_role);
        return RoleAssignment({ role: _role, roleAdminRole: cfg.adminRole, assignee: _assignee, executionDelay: cfg.executionDelay });
    }

    /// @notice Returns the admin/guardian/delay configuration for a role (ported from legacy RolesConfiguration).
    function getRoleConfig(uint64 role) public pure returns (RoleConfig memory) {
        if (role == ADMIN_PAUSER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_UPGRADER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 2 days });
        if (role == ST_LP_ROLE || role == JT_LP_ROLE) return RoleConfig({ adminRole: LP_ROLE_ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == LP_ROLE_ADMIN_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == SYNC_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_KERNEL_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 2 days });
        if (role == ADMIN_ACCOUNTANT_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 2 days });
        if (role == ADMIN_PROTOCOL_FEE_SETTER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 2 days });
        if (role == ADMIN_ORACLE_QUOTER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == GUARDIAN_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: ADMIN_ROLE, executionDelay: 0 });
        if (role == DEPLOYER_ROLE) return RoleConfig({ adminRole: DEPLOYER_ROLE_ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == DEPLOYER_ROLE_ADMIN_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_FACTORY_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_UNPAUSER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == LT_LP_ROLE) return RoleConfig({ adminRole: LP_ROLE_ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_BALANCER_POOL_MANAGER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_MARKET_OPS_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_BLACKLIST_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_ENTRY_POINT_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        revert UNKNOWN_ROLE(role);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: ACCESS MANAGER + FACTORY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys (or reuses) the standalone AccessManager + the template-driven factory.
    /// @dev The role graph is applied by the caller (when `amExisted` is false) AFTER the periphery singletons are
    ///      deployed, so grants that require default (ADMIN_ROLE) role admins can land before pass 2 re-points them.
    function _deployAccessManagerAndFactory(address _deployer) internal returns (AccessManager accessManager, RoycoFactory factory, bool amExisted) {
        // Deploy the AccessManager with the deployer as the initial admin so it can wire roles during this broadcast.
        address amAddr;
        (amAddr, amExisted) = deployWithSanityChecks(ACCESS_MANAGER_SALT, abi.encodePacked(type(AccessManager).creationCode, abi.encode(_deployer)), false);
        accessManager = AccessManager(amAddr);

        // Predict the factory proxy address so we can grant it ADMIN_ROLE before its constructor runs `initialize`.
        (address factoryImpl,) = deployWithSanityChecks(FACTORY_IMPL_SALT, type(RoycoFactory).creationCode, false);
        bytes memory factoryProxyCreationCode = getERC1967ProxyCreationCode(factoryImpl, abi.encodeCall(RoycoFactory.initialize, (amAddr)));
        address predictedFactory = generateDeterminsticAddress(FACTORY_PROXY_SALT, factoryProxyCreationCode);

        if (predictedFactory.code.length == 0) {
            accessManager.grantRole(ADMIN_ROLE, predictedFactory, 0);
            // The factory must be able to grant the tranche LP roles (admin'd by LP_ROLE_ADMIN_ROLE) so a market's
            // template can grant them to the kernel + fee recipient during deployment. Granted here,
            // before any `setRoleAdmin` re-points the LP roles' admin, while the deployer (ADMIN_ROLE) can still grant it.
            accessManager.grantRole(LP_ROLE_ADMIN_ROLE, predictedFactory, 0);
        }

        (address factoryProxy,) = deployWithSanityChecks(FACTORY_PROXY_SALT, factoryProxyCreationCode, false);
        require(factoryProxy == predictedFactory, "factory address mismatch");
        factory = RoycoFactory(factoryProxy);
    }

    /// @notice Applies role admins/guardians/grants on the AccessManager (mirrors the legacy factory.initialize role setup).
    function _applyRoleGraph(AccessManager _am, address _factoryAdmin, address _deployer, RoleAssignment[] memory _roleAssignments) internal {
        // Ensure the factory admin holds ADMIN_ROLE (role 0).
        if (_factoryAdmin != _deployer) _am.grantRole(ADMIN_ROLE, _factoryAdmin, 0);

        // The deployer needs DEPLOYER_ROLE (executeMarketDeployment) + ADMIN_FACTORY_ROLE (registerTemplate).
        _am.grantRole(DEPLOYER_ROLE, _deployer, 0);
        _am.grantRole(ADMIN_FACTORY_ROLE, _deployer, 0);

        // Pass 1: grant every assignment WHILE each role's admin is still ADMIN_ROLE (role 0), which the deployer holds.
        // (OZ AccessManager `grantRole` checks the caller against the role's CURRENT admin; once we re-point a role's
        //  admin in pass 2, role 0 can no longer grant it. So all grants must happen before any `setRoleAdmin`.)
        for (uint256 i; i < _roleAssignments.length; ++i) {
            RoleAssignment memory ra = _roleAssignments[i];
            if (ra.assignee != address(0)) _am.grantRole(ra.role, ra.assignee, ra.executionDelay);
        }

        // Pass 2: re-point role admins + guardians.
        for (uint256 i; i < _roleAssignments.length; ++i) {
            RoleAssignment memory ra = _roleAssignments[i];
            RoleConfig memory cfg = getRoleConfig(ra.role);
            if (cfg.adminRole != ADMIN_ROLE) _am.setRoleAdmin(ra.role, cfg.adminRole);
            _am.setRoleGuardian(ra.role, cfg.guardianRole);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: TEMPLATE REGISTRATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys + registers (or returns the cached) Day template for a kernel type.
    function _getOrRegisterTemplate(
        RoycoFactory _factory,
        KernelType _kernelType,
        address _entryPoint,
        address _marketSyncer
    )
        internal
        returns (address template)
    {
        template = kernelTypeToTemplate[uint256(_kernelType)];
        if (template != address(0)) return template;

        IRoycoFactory factoryIface = IRoycoFactory(address(_factory));
        bytes32 kernelComponentId;
        bytes memory kernelCreationCode;
        (template, kernelComponentId, kernelCreationCode) = _deployTemplate(factoryIface, _kernelType, _entryPoint, _marketSyncer);

        (bytes32[] memory ids, bytes[] memory codes) = _dayTemplateComponents(kernelComponentId, kernelCreationCode);
        IBaseTemplate(template).initialize(ids, codes);
        _factory.registerTemplate(template);
        kernelTypeToTemplate[uint256(_kernelType)] = template;
    }

    /// @notice The (component id, creation code) pairs a Day market template is registered with.
    /// @dev Extracted so tests (and tooling) can register a Day template on their own factory without re-listing the set.
    function _dayTemplateComponents(
        bytes32 _kernelComponentId,
        bytes memory _kernelCreationCode
    )
        internal
        pure
        returns (bytes32[] memory ids, bytes[] memory codes)
    {
        ids = new bytes32[](9);
        codes = new bytes[](9);
        ids[0] = COMPONENT_ID_SENIOR_TRANCHE_IMPL;
        codes[0] = type(RoycoSeniorTranche).creationCode;
        ids[1] = COMPONENT_ID_JUNIOR_TRANCHE_IMPL;
        codes[1] = type(RoycoJuniorTranche).creationCode;
        ids[2] = COMPONENT_ID_LIQUIDITY_TRANCHE_IMPL;
        codes[2] = type(RoycoLiquidityTranche).creationCode;
        ids[3] = COMPONENT_ID_ACCOUNTANT_IMPL;
        codes[3] = type(RoycoDayAccountant).creationCode;
        ids[4] = COMPONENT_ID_YDM_STATIC_CURVE;
        codes[4] = type(StaticCurveYDM).creationCode;
        ids[5] = COMPONENT_ID_YDM_ADAPTIVE_CURVE_V1;
        codes[5] = type(AdaptiveCurveYDM_V1).creationCode;
        ids[6] = COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2;
        codes[6] = type(AdaptiveCurveYDM_V2).creationCode;
        ids[7] = _kernelComponentId;
        codes[7] = _kernelCreationCode;
        ids[8] = COMPONENT_ID_DAY_BALANCER_HOOKS;
        codes[8] = type(RoycoDayBalancerV3Hooks).creationCode;
    }

    /// @notice Public helper: the component set for the Day template of a given kernel type (test/tooling use).
    function dayTemplateComponentsForKernelType(KernelType _kernelType) public pure returns (bytes32[] memory ids, bytes[] memory codes) {
        if (_kernelType == KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel) {
            return _dayTemplateComponents(
                COMPONENT_ID_DAY_KERNEL_IDENTICAL_ERC4626_CHAINLINK,
                type(Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel).creationCode
            );
        }
        if (_kernelType == KernelType.Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel) {
            return _dayTemplateComponents(
                COMPONENT_ID_DAY_KERNEL_IDENTICAL_MAKINA_CHAINLINK,
                type(Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel).creationCode
            );
        }
        if (_kernelType == KernelType.Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel) {
            return _dayTemplateComponents(
                COMPONENT_ID_DAY_KERNEL_IDENTICAL_CHAINLINK_TO_ADMIN,
                type(Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel).creationCode
            );
        }
        if (_kernelType == KernelType.Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel) {
            return _dayTemplateComponents(
                COMPONENT_ID_DAY_KERNEL_IDENTICAL_AA_IDLE_CDO_VIRTUAL_PRICE,
                type(Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel).creationCode
            );
        }
        revert UnsupportedKernelType(_kernelType);
    }

    /// @notice Public wrapper over `_buildDayParams` so tests can construct real template deploy params from a market config.
    function buildDayParams(
        MarketConfig memory _config,
        bytes32 _marketId,
        address _protocolFeeRecipient,
        address _roycoBlacklist
    )
        public
        pure
        returns (BalancerV3_GyroECLP_LT_DeploymentTemplate.DayParams memory)
    {
        return _buildDayParams(_config, _marketId, _protocolFeeRecipient, _roycoBlacklist);
    }

    /// @notice Deploys the concrete Day template for a kernel type and returns its kernel component id + creation code.
    function _deployTemplate(
        IRoycoFactory _factory,
        KernelType _kernelType,
        address _entryPoint,
        address _marketSyncer
    )
        internal
        returns (address template, bytes32 kernelComponentId, bytes memory kernelCreationCode)
    {
        // The concrete Balancer-V3 templates are constructed with the chain's Gyro E-CLP pool factory, Balancer's
        // E-CLP LP oracle factory (through which the template deploys each market's BPT oracle), and the pre-deployed
        // periphery singletons (entry point + market syncer) the template configures for each deployed market.
        ChainConfig memory chainConfig = getChainConfig(block.chainid);
        GyroECLPPoolFactory poolFactory = GyroECLPPoolFactory(chainConfig.gyroECLPPoolFactory);
        ILPOracleFactoryBase eclpLPOracleFactory = ILPOracleFactoryBase(chainConfig.eclpLPOracleFactory);

        if (_kernelType == KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel) {
            return (
                address(
                    new Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate(
                        _factory, poolFactory, eclpLPOracleFactory, _entryPoint, _marketSyncer
                    )
                ),
                COMPONENT_ID_DAY_KERNEL_IDENTICAL_ERC4626_CHAINLINK,
                type(Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel).creationCode
            );
        }
        if (_kernelType == KernelType.Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel) {
            return (
                address(
                    new Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate(
                        _factory, poolFactory, eclpLPOracleFactory, _entryPoint, _marketSyncer
                    )
                ),
                COMPONENT_ID_DAY_KERNEL_IDENTICAL_MAKINA_CHAINLINK,
                type(Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel).creationCode
            );
        }
        if (_kernelType == KernelType.Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel) {
            return (
                address(
                    new Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3GyroECLP_LT_DeploymentTemplate(
                        _factory, poolFactory, eclpLPOracleFactory, _entryPoint, _marketSyncer
                    )
                ),
                COMPONENT_ID_DAY_KERNEL_IDENTICAL_CHAINLINK_TO_ADMIN,
                type(Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel).creationCode
            );
        }
        if (_kernelType == KernelType.Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel) {
            return (
                address(
                    new Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3GyroECLP_LT_DeploymentTemplate(
                        _factory, poolFactory, eclpLPOracleFactory, _entryPoint, _marketSyncer
                    )
                ),
                COMPONENT_ID_DAY_KERNEL_IDENTICAL_AA_IDLE_CDO_VIRTUAL_PRICE,
                type(Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel).creationCode
            );
        }
        revert UnsupportedKernelType(_kernelType);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: PARAM BUILDING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Builds the template `DayParams` from a `MarketConfig`.
    function _buildDayParams(
        MarketConfig memory _config,
        bytes32 _marketId,
        address _protocolFeeRecipient,
        address _roycoBlacklist
    )
        internal
        pure
        returns (BalancerV3_GyroECLP_LT_DeploymentTemplate.DayParams memory params)
    {
        params.marketId = _marketId;

        // Tranche init params — the template overwrites `initialAuthority` with the market authority.
        params.stTranche =
            IRoycoVaultTranche.RoycoTrancheInitParams({ name: _config.seniorTrancheName, symbol: _config.seniorTrancheSymbol, initialAuthority: address(0) });
        params.jtTranche =
            IRoycoVaultTranche.RoycoTrancheInitParams({ name: _config.juniorTrancheName, symbol: _config.juniorTrancheSymbol, initialAuthority: address(0) });
        params.ltTranche = IRoycoVaultTranche.RoycoTrancheInitParams({
            name: _config.liquidityTrancheName, symbol: _config.liquidityTrancheSymbol, initialAuthority: address(0)
        });
        params.stAsset = _config.seniorAsset;
        params.jtAsset = _config.juniorAsset;
        params.jtCoinvested = _config.jtCoinvested;

        // Accountant init params. `jtYDM`/`ltYDM` are overwritten by the template with the deployed instances. BOTH YDMs get
        // initialization data so the accountant initializes each of them. The LT premium/liquidity overlay is at its zero
        // baseline (LT service off) — but the LDM is still deployed, initialized, and distinct from the JT YDM.
        params.accountant = IRoycoDayAccountant.RoycoDayAccountantInitParams({
            minCoverageWAD: _config.minCoverageWAD,
            coverageLiquidationUtilizationWAD: _config.coverageLiquidationUtilizationWAD,
            minLiquidityWAD: 0,
            jtYDM: address(0),
            jtYDMInitializationData: _buildYDMInitializationData(_config.ydmType, _config.ydmSpecificParams),
            ltYDM: address(0),
            ltYDMInitializationData: _buildYDMInitializationData(_config.ydmType, _config.ltYdmSpecificParams),
            maxJTYieldShareWAD: uint64(1e18), // uncapped at the WAD ceiling; the real JT cap comes from the JT YDM curve
            maxLTYieldShareWAD: 0, // LT liquidity premium disabled in the baseline
            fixedTermDurationSeconds: _config.fixedTermDurationSeconds,
            stNAVDustTolerance: toNAVUnits(_config.stDustTolerance),
            jtNAVDustTolerance: toNAVUnits(_config.jtDustTolerance),
            stProtocolFeeWAD: _config.stProtocolFeeWAD,
            jtProtocolFeeWAD: _config.jtProtocolFeeWAD,
            jtYieldShareProtocolFeeWAD: _config.jtYieldShareProtocolFeeWAD,
            ltYieldShareProtocolFeeWAD: 0
        });

        params.gyroECLPPoolParams = _config.gyroECLPPoolParams;
        params.jtYdmConstructorArgs = _ydmConstructorArgs(_config.ydmType, _config.jtYdmTargetUtilizationWAD);
        params.ltYdmConstructorArgs = _ydmConstructorArgs(_config.ydmType, _config.ltYdmTargetUtilizationWAD);
        // Select the YDM bytecode the template deploys from the configured model, so the deployed contract is the configured type (not a stand-in that shares a selector)
        params.ydmComponentId = _ydmComponentId(_config.ydmType);
        params.kernelSpecificParams = _config.kernelSpecificParams; // template KernelParams are field-identical to the config blobs
        params.protocolFeeRecipient = _protocolFeeRecipient;
        params.stSelfLiquidationBonusWAD = _config.stSelfLiquidationBonusWAD;
        params.roycoBlacklist = _roycoBlacklist;
        params.enforceVaultSharesTransferWhitelist = _config.enforceVaultSharesTransferWhitelist;
        // Per-tranche entry point configs applied by the template (via the factory) after the market is deployed.
        params.entryPointTrancheConfigs = BalancerV3_GyroECLP_LT_DeploymentTemplate.EntryPointTrancheConfigs({
            st: _config.stEntryPointConfig, jt: _config.jtEntryPointConfig, lt: _config.ltEntryPointConfig
        });
    }

    /// @notice Builds YDM initialization data based on YDM type.
    function _buildYDMInitializationData(YDMType _ydmType, bytes memory _ydmSpecificParams) internal pure returns (bytes memory ydmInitializationData) {
        if (_ydmType == YDMType.StaticCurve) {
            StaticCurveYDMParams memory ydmParams = abi.decode(_ydmSpecificParams, (StaticCurveYDMParams));
            ydmInitializationData = abi.encodeCall(
                StaticCurveYDM.initializeYDMForMarket,
                (ydmParams.yieldShareAtZeroUtilWAD, ydmParams.yieldShareAtTargetUtilWAD, ydmParams.yieldShareAtFullUtilWAD)
            );
        } else if (_ydmType == YDMType.AdaptiveCurve_V1) {
            AdaptiveCurveYDM_V1_Params memory ydmParams = abi.decode(_ydmSpecificParams, (AdaptiveCurveYDM_V1_Params));
            ydmInitializationData =
                abi.encodeCall(AdaptiveCurveYDM_V1.initializeYDMForMarket, (ydmParams.yieldShareAtTargetUtilWAD, ydmParams.yieldShareAtFullUtilWAD));
        } else if (_ydmType == YDMType.AdaptiveCurve_V2) {
            AdaptiveCurveYDM_V2_Params memory ydmParams = abi.decode(_ydmSpecificParams, (AdaptiveCurveYDM_V2_Params));
            ydmInitializationData = abi.encodeCall(
                AdaptiveCurveYDM_V2.initializeYDMForMarket,
                (ydmParams.yieldShareAtZeroUtilWAD, ydmParams.yieldShareAtTargetUtilWAD, ydmParams.yieldShareAtFullUtilWAD)
            );
        } else {
            revert UnsupportedYDMType(_ydmType);
        }
    }

    /// @notice The adaptive curve YDMs' canonical adaptation bounds: the yield share at target adapts within [0.01%, 100%]
    uint256 internal constant ADAPTIVE_YDM_MIN_YIELD_SHARE_AT_TARGET_WAD = 0.0001e18;
    uint256 internal constant ADAPTIVE_YDM_MAX_YIELD_SHARE_AT_TARGET_WAD = 1e18;

    /// @notice The adaptive curve YDMs' canonical boundary adaptation speeds, per second at 0% and 100% utilization
    uint256 internal constant ADAPTIVE_YDM_V1_ADAPTATION_SPEED_WAD = 50e18 / uint256(365 days);
    uint256 internal constant ADAPTIVE_YDM_V2_ADAPTATION_SPEED_WAD = 100e18 / uint256(365 days);

    /// @notice Builds the ABI-encoded constructor args for a YDM model at the given target utilization
    /// @dev Kept in lockstep with `_ydmComponentId` so the deployed contract type and its constructor args always agree
    function _ydmConstructorArgs(YDMType _ydmType, uint256 _targetUtilizationWAD) internal pure returns (bytes memory ydmConstructorArgs) {
        if (_ydmType == YDMType.StaticCurve) return abi.encode(_targetUtilizationWAD);
        if (_ydmType == YDMType.AdaptiveCurve_V1) {
            return abi.encode(
                _targetUtilizationWAD,
                ADAPTIVE_YDM_MIN_YIELD_SHARE_AT_TARGET_WAD,
                ADAPTIVE_YDM_MAX_YIELD_SHARE_AT_TARGET_WAD,
                ADAPTIVE_YDM_V1_ADAPTATION_SPEED_WAD
            );
        }
        if (_ydmType == YDMType.AdaptiveCurve_V2) {
            return abi.encode(
                _targetUtilizationWAD,
                ADAPTIVE_YDM_MIN_YIELD_SHARE_AT_TARGET_WAD,
                ADAPTIVE_YDM_MAX_YIELD_SHARE_AT_TARGET_WAD,
                ADAPTIVE_YDM_V2_ADAPTATION_SPEED_WAD
            );
        }
        revert UnsupportedYDMType(_ydmType);
    }

    /// @notice Maps a YDM model to the component id whose registered bytecode the template deploys for it
    /// @dev Kept in lockstep with `_buildYDMInitializationData` so the deployed contract type and its initialization data always agree
    function _ydmComponentId(YDMType _ydmType) internal pure returns (bytes32 ydmComponentId) {
        if (_ydmType == YDMType.StaticCurve) return COMPONENT_ID_YDM_STATIC_CURVE;
        if (_ydmType == YDMType.AdaptiveCurve_V1) return COMPONENT_ID_YDM_ADAPTIVE_CURVE_V1;
        if (_ydmType == YDMType.AdaptiveCurve_V2) return COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2;
        revert UnsupportedYDMType(_ydmType);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: BLACKLIST + HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys (or returns) the chain's periphery singletons via CREATE2: the Royco Day entry point and the
    ///         Royco market syncer, both deployed before any market and configured for each market by the template.
    /// @dev The entry point initializes with empty config arrays: every market's initial tranche configs flow through
    ///      the factory (which holds ADMIN_ENTRY_POINT_ROLE) at market deployment. The syncer initializes with no
    ///      kernels: the factory (which holds SYNC_ROLE) registers each market's kernel at deployment.
    /// @param _accessManager The AccessManager governing both singletons' restricted functions.
    /// @param _factory The Royco factory baked into the entry point's provenance validation.
    function _deployPeripherySingletons(AccessManager _accessManager, address _factory) internal returns (address entryPoint, address marketSyncer) {
        // Deploy the entry point implementation + proxy, initialized with no tranche configs.
        (address entryPointImpl,) =
            deployWithSanityChecks(ENTRY_POINT_IMPL_SALT, abi.encodePacked(type(RoycoDayEntryPoint).creationCode, abi.encode(_factory)), false);
        bytes memory entryPointInitData = abi.encodeCall(RoycoDayEntryPoint.initialize, (new address[](0), new IRoycoDayEntryPoint.TrancheConfig[](0)));
        bool entryPointExisted;
        (entryPoint, entryPointExisted) = deployWithSanityChecks(ENTRY_POINT_PROXY_SALT, getERC1967ProxyCreationCode(entryPointImpl, entryPointInitData), false);

        // Deploy the market syncer implementation + proxy, initialized with no registered kernels.
        (address syncerImpl,) = deployWithSanityChecks(SYNCER_IMPL_SALT, type(RoycoMarketSyncer).creationCode, false);
        bytes memory syncerInitData = abi.encodeCall(RoycoMarketSyncer.initialize, (address(_accessManager), new address[](0)));
        bool syncerExisted;
        (marketSyncer, syncerExisted) = deployWithSanityChecks(SYNCER_PROXY_SALT, getERC1967ProxyCreationCode(syncerImpl, syncerInitData), false);

        // Wire each singleton's full role surface on first deployment. Runs before the role graph re-points any
        // role admins, so the LP role grants below can be made by the deployer (ADMIN_ROLE).
        if (!entryPointExisted) _wireEntryPointRoles(_accessManager, entryPoint);
        if (!syncerExisted) _wireSyncerRoles(_accessManager, marketSyncer);
    }

    /// @notice Binds the entry point's selectors to their roles and grants it the tranche LP roles.
    /// @dev Mirrors the production access model: LP request/execute/cancel selectors are public (user compliance is
    ///      enforced by the tranches), config is ADMIN_ENTRY_POINT_ROLE-gated (held by the factory + admin multisig),
    ///      fee collection has its own role, and pause/unpause/upgrade follow the protocol-wide roles.
    function _wireEntryPointRoles(AccessManager _accessManager, address _entryPoint) internal {
        bytes4[] memory lpSelectors = new bytes4[](11);
        lpSelectors[0] = IRoycoDayEntryPoint.requestDeposit.selector;
        lpSelectors[1] = IRoycoDayEntryPoint.executeDeposit.selector;
        lpSelectors[2] = IRoycoDayEntryPoint.executeDeposits.selector;
        lpSelectors[3] = IRoycoDayEntryPoint.cancelDepositRequest.selector;
        lpSelectors[4] = IRoycoDayEntryPoint.cancelDepositRequests.selector;
        lpSelectors[5] = IRoycoDayEntryPoint.requestRedemption.selector;
        lpSelectors[6] = IRoycoDayEntryPoint.executeRedemption.selector;
        lpSelectors[7] = IRoycoDayEntryPoint.executeRedemptions.selector;
        lpSelectors[8] = IRoycoDayEntryPoint.cancelRedemptionRequest.selector;
        lpSelectors[9] = IRoycoDayEntryPoint.cancelRedemptionRequests.selector;
        lpSelectors[10] = IRoycoDayEntryPoint.pokeOracleClock.selector;
        _accessManager.setTargetFunctionRole(_entryPoint, lpSelectors, PUBLIC_ROLE);

        _accessManager.setTargetFunctionRole(_entryPoint, _sel(IRoycoDayEntryPoint.modifyTrancheConfigs.selector), ADMIN_ENTRY_POINT_ROLE);
        _accessManager.setTargetFunctionRole(_entryPoint, _sel(IRoycoDayEntryPoint.collectProtocolFees.selector), ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE);
        _accessManager.setTargetFunctionRole(_entryPoint, _sel(IRoycoAuth.pause.selector), ADMIN_PAUSER_ROLE);
        _accessManager.setTargetFunctionRole(_entryPoint, _sel(IRoycoAuth.unpause.selector), ADMIN_UNPAUSER_ROLE);
        _accessManager.setTargetFunctionRole(_entryPoint, _sel(UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE);

        // The entry point itself needs the LP roles to call tranche.deposit/redeem (and to receive escrowed shares
        // on whitelist-enforcing markets). MUST run while the LP roles' admin is still ADMIN_ROLE (the deployer).
        _accessManager.grantRole(ST_LP_ROLE, _entryPoint, 0);
        _accessManager.grantRole(JT_LP_ROLE, _entryPoint, 0);
        _accessManager.grantRole(LT_LP_ROLE, _entryPoint, 0);
    }

    /// @notice Binds the syncer's selectors to their roles and grants it SYNC_ROLE.
    /// @dev The batch-sync surface and kernel registration are SYNC_ROLE-gated (held by the factory, the sync
    ///      operators, and the syncer itself: each kernel's syncTrancheAccounting is also SYNC_ROLE-gated), and
    ///      pause/unpause/upgrade follow the protocol-wide roles (mirroring royco-periphery's syncer deployment).
    function _wireSyncerRoles(AccessManager _accessManager, address _marketSyncer) internal {
        bytes4[] memory syncerSelectors = new bytes4[](4);
        syncerSelectors[0] = RoycoMarketSyncer.addMarketKernels.selector;
        syncerSelectors[1] = RoycoMarketSyncer.removeMarketKernels.selector;
        syncerSelectors[2] = RoycoMarketSyncer.executeBatchAccountingSync.selector;
        syncerSelectors[3] = RoycoMarketSyncer.executeBatchAccountingSyncFor.selector;
        _accessManager.setTargetFunctionRole(_marketSyncer, syncerSelectors, SYNC_ROLE);

        _accessManager.setTargetFunctionRole(_marketSyncer, _sel(IRoycoAuth.pause.selector), ADMIN_PAUSER_ROLE);
        _accessManager.setTargetFunctionRole(_marketSyncer, _sel(IRoycoAuth.unpause.selector), ADMIN_UNPAUSER_ROLE);
        _accessManager.setTargetFunctionRole(_marketSyncer, _sel(UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE);

        // The syncer drives each registered kernel's SYNC_ROLE-gated syncTrancheAccounting
        _accessManager.grantRole(SYNC_ROLE, _marketSyncer, 0);
    }

    /// @notice Wraps a single selector into the one-element array `setTargetFunctionRole` expects.
    function _sel(bytes4 _selector) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = _selector;
    }

    /// @notice Deploys (or returns) the chain's shared RoycoBlacklist via CREATE2.
    /// @param _authority The AccessManager that governs the blacklist's restricted functions.
    function _deployBlacklist(address _authority) internal returns (address blacklist) {
        (address implAddr,) = deployWithSanityChecks(BLACKLIST_IMPL_SALT, type(RoycoBlacklist).creationCode, false);
        address[] memory initialBlacklistedAccounts = new address[](0);
        bytes memory initData = abi.encodeCall(RoycoBlacklist.initialize, (_authority, address(0), initialBlacklistedAccounts));
        (blacklist,) = deployWithSanityChecks(BLACKLIST_PROXY_SALT, getERC1967ProxyCreationCode(implAddr, initData), false);
    }

    /// @notice Predicts a market component implementation address from the template's `_marketComponentSalt` scheme.
    function _predictImpl(RoycoFactory _factory, bytes32 _marketId, bytes32 _componentTag) internal view returns (address impl) {
        bytes32 salt = keccak256(abi.encodePacked("ROYCO_MARKET_", _marketId, _componentTag));
        impl = _factory.predictDeterministicAddress(salt);
        require(impl.code.length > 0, PredictedImplementationHasNoCode(_componentTag, impl));
    }
}
