// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ILPOracleFactoryBase } from "../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { IRateProvider } from "../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IBasePool } from "../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IBasePool.sol";
import { IVault } from "../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import {
    PoolRoleAccounts as BalancerV3PoolRoleAccounts,
    TokenConfig as BalancerV3TokenConfig,
    TokenType as BalancerV3TokenType
} from "../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { ConstantPriceFeed } from "../lib/balancer-v3-monorepo/pkg/oracles/contracts/ConstantPriceFeed.sol";
import { GyroECLPPoolFactory } from "../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import {
    AggregatorV3Interface as BalancerAggregatorV3Interface
} from "../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { UUPSUpgradeable } from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { AccessManager } from "../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
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
    ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE,
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
} from "../src/factory/Roles.sol";
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
    TAG_ACCOUNTANT_IMPL,
    TAG_ACCOUNTANT_PROXY,
    TAG_BALANCER_HOOK_PROXY,
    TAG_BALANCER_V3_POOL,
    TAG_JT_IMPL,
    TAG_JT_PROXY,
    TAG_KERNEL_IMPL,
    TAG_KERNEL_PROXY,
    TAG_LDM,
    TAG_LT_IMPL,
    TAG_LT_PROXY,
    TAG_ST_IMPL,
    TAG_ST_PROXY,
    TAG_YDM
} from "../src/factory/templates/base/Constants.sol";
import { BalancerV3_GyroECLP_LT_DeploymentTemplate } from "../src/factory/templates/liquidity-tranche/BalancerV3_GyroECLP_LT_DeploymentTemplate.sol";
import { IRoycoAuth } from "../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayEntryPoint } from "../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../src/interfaces/IYDM.sol";
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
import { toNAVUnits } from "../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../src/tranches/RoycoJuniorTranche.sol";
import { RoycoLiquidityTranche } from "../src/tranches/RoycoLiquidityTranche.sol";
import { RoycoSeniorTranche } from "../src/tranches/RoycoSeniorTranche.sol";
import { AdaptiveCurveYDM_V1 } from "../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../src/ydm/AdaptiveCurveYDM_V2.sol";
import { StaticCurveYDM } from "../src/ydm/StaticCurveYDM.sol";
import {
    AdaptiveCurveYDM_V1_Params,
    AdaptiveCurveYDM_V2_Params,
    ChainConfig,
    DeploymentResult,
    GyroECLPPoolParams,
    IdenticalAssets_ST_JT_ChainlinkToAdminOracle_QuoterKernelParams,
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_QuoterKernelParams,
    IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_QuoterKernelParams,
    Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_QuoterKernelParams,
    KernelType,
    MarketConfig,
    ProtocolScaffolding,
    RoleAssignment,
    RoleAssignmentAddresses,
    RoleConfig,
    StaticCurveYDMParams,
    YDMType
} from "./config/DeploymentTypes.sol";
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
    error UnknownRole(uint64 role);
    error RateProviderRequiredWhenPayingYieldFees(address token);

    bool ENABLE_LOGGING = false;

    /// @dev Per-DeployScript-instance cache of registered templates, keyed by kernel type.
    mapping(uint256 kernelType => address template) internal kernelTypeToTemplate;

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
                marketReinvestLiquidityPremiumAddress: chainConfig.marketReinvestLiquidityPremiumAddress,
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

        // Stand up the chain-level scaffolding (AccessManager, factory, periphery, blacklist, template) and renounce
        // the deployer's admin roles, then deploy + wire the market itself.
        ProtocolScaffolding memory s = _setUpProtocolScaffolding(_config, _factoryAdmin, deployer, _roleAssignments);
        DeploymentResult memory result = _deployAndExecuteMarket(_config, s, _protocolFeeRecipient);

        vm.stopBroadcast();
        return result;
    }

    /// @notice Deploys (or reuses) the chain-level scaffolding a market is wired against and drops the deployer's admin.
    /// @dev Ordering matters: periphery is deployed BEFORE the role graph (its LP-role grants require those roles' admin
    ///      to still be ADMIN_ROLE, held by the deployer; pass 2 of the role graph re-points them). The deployer's admin
    ///      roles are renounced last, once the admin-gated setup is done — the market steps only need DEPLOYER_ROLE.
    function _setUpProtocolScaffolding(
        MarketConfig memory _config,
        address _factoryAdmin,
        address _deployer,
        RoleAssignment[] memory _roleAssignments
    )
        internal
        returns (ProtocolScaffolding memory s)
    {
        // AccessManager + factory (idempotent within a test via CREATE2).
        bool amExisted;
        (s.accessManager, s.factory, amExisted) = _deployAccessManagerAndFactory(_deployer);

        // Periphery singletons (entry point + market syncer) the template configures per market.
        (s.entryPoint, s.marketSyncer) = _deployPeripherySingletons(s.accessManager, address(s.factory));

        // Role graph (grants + admin/guardian re-pointing) on a freshly deployed AccessManager.
        if (!amExisted) _applyRoleGraph(s.accessManager, _factoryAdmin, _deployer, _roleAssignments);

        // Chain's shared blacklist (governed by the AccessManager, not the factory).
        s.roycoBlacklist = _deployBlacklist(address(s.accessManager));
        {
            bytes4[] memory blacklistSelectors = new bytes4[](3);
            blacklistSelectors[0] = RoycoBlacklist.blacklistAccounts.selector;
            blacklistSelectors[1] = RoycoBlacklist.unblacklistAccounts.selector;
            blacklistSelectors[2] = RoycoBlacklist.setSanctionsList.selector;
            s.accessManager.setTargetFunctionRole(s.roycoBlacklist, blacklistSelectors, ADMIN_BLACKLIST_ROLE);
        }

        // Register (or reuse) the Day template for this kernel type.
        s.template = _getOrRegisterTemplate(s.factory, _config.kernelType, s.entryPoint, s.marketSyncer);

        // Drop the deployer's admin roles now that the admin-gated setup is complete.
        _renounceDeployerAdminRoles(s.accessManager, _deployer, _factoryAdmin, amExisted);
    }

    /// @notice Builds the role assignments applied to the AccessManager (surface-compatible with the legacy helper).
    function generateRolesAssignments(RoleAssignmentAddresses memory _addresses) public pure returns (RoleAssignment[] memory roleAssignments) {
        roleAssignments = new RoleAssignment[](21);
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
        roleAssignments[17] = _assignment(ADMIN_BLACKLIST_ROLE, _addresses.marketOpsAddress);
        roleAssignments[18] = _assignment(ADMIN_ENTRY_POINT_ROLE, _addresses.adminEntryPointAddress);
        roleAssignments[19] = _assignment(ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE, _addresses.entryPointFeeCollectorAddress);
        roleAssignments[20] = _assignment(ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE, _addresses.marketReinvestLiquidityPremiumAddress);
    }

    function _assignment(uint64 _role, address _assignee) private pure returns (RoleAssignment memory) {
        RoleConfig memory cfg = getRoleConfig(_role);
        return RoleAssignment({ role: _role, roleAdminRole: cfg.adminRole, assignee: _assignee, executionDelay: cfg.executionDelay });
    }

    /// @notice Returns the admin/guardian/delay configuration for a role (ported from legacy Roles).
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
        if (role == ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_BLACKLIST_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_ENTRY_POINT_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        revert UnknownRole(role);
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

    /// @notice Deploys the market's off-factory contracts, executes the factory wiring transaction, and assembles the
    ///         full deployment result.
    /// @dev Extracted from `deploy` (and made to build the final result) to keep `deploy`'s stack frame under the
    ///      via-IR limit.
    function _deployAndExecuteMarket(
        MarketConfig memory _config,
        ProtocolScaffolding memory _s,
        address _protocolFeeRecipient
    )
        internal
        returns (DeploymentResult memory)
    {
        bytes32 marketId = keccak256(abi.encode(_config.seniorTrancheName, _config.juniorTrancheName, block.timestamp, block.chainid));
        BalancerV3_GyroECLP_LT_DeploymentTemplate.MarketContracts memory marketContracts =
            _deployMarketContracts(_config, marketId, _s.factory, _s.template, address(_s.accessManager));
        BalancerV3_GyroECLP_LT_DeploymentTemplate.DayParams memory params =
            _buildDayParams(_config, marketId, _protocolFeeRecipient, _s.roycoBlacklist, marketContracts);
        IRoycoProtocolTemplate.DeploymentResult memory r = _s.factory.executeMarketDeployment(_s.template, abi.encode(params));

        return DeploymentResult({
            factory: _s.factory,
            accessManager: _s.accessManager,
            ydm: IYDM(r.ydm),
            seniorTranche: IRoycoVaultTranche(r.seniorTranche),
            juniorTranche: IRoycoVaultTranche(r.juniorTranche),
            accountant: IRoycoDayAccountant(r.accountant),
            kernel: IRoycoDayKernel(r.kernel),
            roycoBlacklist: _s.roycoBlacklist,
            entryPoint: _s.entryPoint,
            marketSyncer: _s.marketSyncer
        });
    }

    /// @notice Renounces the deployer's admin roles after a deployment.
    /// @dev Only the fresh-AM path grants the deployer these roles (see `_applyRoleGraph`); when reusing an existing AM
    ///      the deployer no longer holds them, so there is nothing to renounce. The ADMIN_ROLE renounce is skipped when
    ///      the deployer IS the factory admin, otherwise the AccessManager would be left with no ADMIN_ROLE holder and
    ///      all future role administration would be permanently bricked.
    function _renounceDeployerAdminRoles(AccessManager _am, address _deployer, address _factoryAdmin, bool _amExisted) internal {
        if (_amExisted) return;
        _am.renounceRole(ADMIN_FACTORY_ROLE, _deployer);
        if (_factoryAdmin != _deployer) _am.renounceRole(ADMIN_ROLE, _deployer);
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
        template = _deployTemplate(factoryIface, _kernelType, _entryPoint, _marketSyncer);

        _factory.registerTemplate(template);
        kernelTypeToTemplate[uint256(_kernelType)] = template;
    }

    /// @notice Public wrapper over `_buildDayParams` so tests can construct real template deploy params from a market config.
    /// @dev The caller supplies the `MarketContracts` (externally deployed impls/YDMs/pool), typically via `deployMarketContractsForTest`.
    function buildDayParams(
        MarketConfig memory _config,
        bytes32 _marketId,
        address _protocolFeeRecipient,
        address _roycoBlacklist,
        BalancerV3_GyroECLP_LT_DeploymentTemplate.MarketContracts memory _marketContracts
    )
        public
        pure
        returns (BalancerV3_GyroECLP_LT_DeploymentTemplate.DayParams memory)
    {
        return _buildDayParams(_config, _marketId, _protocolFeeRecipient, _roycoBlacklist, _marketContracts);
    }

    /// @notice Public wrapper over `_deployMarketContracts` so tests can externally deploy a market's impls/YDMs/pool
    ///         and pre-deploy its ST + hook proxies, mirroring the production flow, before driving `executeMarketDeployment`.
    function deployMarketContractsForTest(
        MarketConfig memory _config,
        bytes32 _marketId,
        RoycoFactory _factory,
        address _template,
        address _accessManager
    )
        public
        returns (BalancerV3_GyroECLP_LT_DeploymentTemplate.MarketContracts memory)
    {
        return _deployMarketContracts(_config, _marketId, _factory, _template, _accessManager);
    }

    /// @notice Deploys the concrete Day template for a kernel type.
    function _deployTemplate(IRoycoFactory _factory, KernelType _kernelType, address _entryPoint, address _marketSyncer) internal returns (address template) {
        // The concrete Balancer-V3 templates are constructed with the chain's Gyro E-CLP pool factory and the
        // pre-deployed periphery singletons (entry point + market syncer) the template configures for each deployed market.
        ChainConfig memory chainConfig = getChainConfig(block.chainid);
        GyroECLPPoolFactory poolFactory = GyroECLPPoolFactory(chainConfig.gyroECLPPoolFactory);

        if (_kernelType == KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel) {
            return address(
                new Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate(
                    _factory, poolFactory, _entryPoint, _marketSyncer
                )
            );
        }
        if (_kernelType == KernelType.Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel) {
            return address(
                new Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3GyroECLP_LT_DeploymentTemplate(
                    _factory, poolFactory, _entryPoint, _marketSyncer
                )
            );
        }
        if (_kernelType == KernelType.Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel) {
            return address(
                new Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3GyroECLP_LT_DeploymentTemplate(_factory, poolFactory, _entryPoint, _marketSyncer)
            );
        }
        if (_kernelType == KernelType.Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel) {
            return address(
                new Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3GyroECLP_LT_DeploymentTemplate(_factory, poolFactory, _entryPoint, _marketSyncer)
            );
        }
        revert UnsupportedKernelType(_kernelType);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: PARAM BUILDING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Builds the template `DayParams` from a `MarketConfig` and the externally deployed `MarketContracts`.
    function _buildDayParams(
        MarketConfig memory _config,
        bytes32 _marketId,
        address _protocolFeeRecipient,
        address _roycoBlacklist,
        BalancerV3_GyroECLP_LT_DeploymentTemplate.MarketContracts memory _marketContracts
    )
        internal
        pure
        returns (BalancerV3_GyroECLP_LT_DeploymentTemplate.DayParams memory params)
    {
        params.marketId = _marketId;

        // JT/LT tranche init params — the template overwrites `initialAuthority` with the market authority. The senior
        // tranche proxy is pre-deployed by the script (its init data is built in `_deployMarketContracts`).
        params.jtTranche =
            IRoycoVaultTranche.RoycoTrancheInitParams({ name: _config.juniorTrancheName, symbol: _config.juniorTrancheSymbol, initialAuthority: address(0) });
        params.ltTranche = IRoycoVaultTranche.RoycoTrancheInitParams({
            name: _config.liquidityTrancheName, symbol: _config.liquidityTrancheSymbol, initialAuthority: address(0)
        });
        params.stAsset = _config.seniorAsset;
        params.jtAsset = _config.juniorAsset;
        params.marketContracts = _marketContracts;

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

    /// @notice Deploys a YDM model of the configured type at the given target utilization, via the canonical CREATE2 deployer
    /// @dev CREATE2's initcode-address binding means identical `(model, ctor args)` dedups to one instance, and distinct
    ///      args produce distinct addresses (so a market can never silently reuse another's curve params)
    function _deployYDM(YDMType _ydmType, uint256 _targetUtilizationWAD, bytes32 _ydmSalt) internal returns (address ydm) {
        bytes memory creationCode;
        if (_ydmType == YDMType.StaticCurve) {
            creationCode = type(StaticCurveYDM).creationCode;
        } else if (_ydmType == YDMType.AdaptiveCurve_V1) {
            creationCode = type(AdaptiveCurveYDM_V1).creationCode;
        } else if (_ydmType == YDMType.AdaptiveCurve_V2) {
            creationCode = type(AdaptiveCurveYDM_V2).creationCode;
        } else {
            revert UnsupportedYDMType(_ydmType);
        }
        (ydm,) = deployWithSanityChecks(_ydmSalt, abi.encodePacked(creationCode, _ydmConstructorArgs(_ydmType, _targetUtilizationWAD)), false);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: EXTERNAL MARKET-CONTRACT DEPLOYMENT (impls, YDMs, pool, pre-deployed proxies)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploys the market's implementations + YDMs, creates the Gyro E-CLP pool, and pre-deploys the senior
     *         tranche and pool-hook proxies through the factory, returning the addresses the template wires and verifies
     * @dev Ordering mirrors the dependency graph: predict the four template-deployed proxy addresses (kernel, JT, LT,
     *      accountant) so the implementations can pin them as immutables; deploy the ST impl and its proxy (the pool
     *      needs the ST share as a token); pre-deploy the hook proxy against the template's shared stand-in impl (the
     *      pool must register against a hook); create the pool (senior leg's rate provider = the predicted kernel, still
     *      codeless, which keeps the pool inert until the wiring tx); then deploy the remaining impls (LT pins the pool)
     *      and both YDMs.
     */
    function _deployMarketContracts(
        MarketConfig memory _config,
        bytes32 _marketId,
        RoycoFactory _factory,
        address _template,
        address _accessManager
    )
        internal
        returns (BalancerV3_GyroECLP_LT_DeploymentTemplate.MarketContracts memory mc)
    {
        // Predict the kernel proxy address the implementations pin as immutables (the template deploys the kernel proxy
        // at the same `_salt(marketId, TAG_KERNEL_PROXY)`, so its prediction matches)
        address kernelProxy = _factory.predictDeterministicAddress(_salt(_marketId, TAG_KERNEL_PROXY));

        // Pre-deploy the senior tranche proxy, then pre-deploy the pool-hook proxy and create the Gyro E-CLP pool, then
        // deploy the remaining implementations + YDMs (each stage is a helper, keeping every function under the stack limit)
        _predeploySeniorTrancheProxy(_config, _marketId, _factory, _accessManager, kernelProxy);
        (address balancerPool, address bptOracle) = _createPoolWithHookProxy(
            _config, _marketId, _factory, _template, _accessManager, kernelProxy, _factory.predictDeterministicAddress(_salt(_marketId, TAG_ST_PROXY))
        );
        mc = _deployImplsAndYdms(_config, _marketId, _factory, kernelProxy, balancerPool);
        mc.bptOracle = bptOracle;
    }

    /// @notice Deploys the market's JT/LT/accountant/kernel/real-hook implementations and both YDMs, returning them
    ///         (with the pre-created pool) as the `MarketContracts` the template consumes
    function _deployImplsAndYdms(
        MarketConfig memory _config,
        bytes32 _marketId,
        RoycoFactory _factory,
        address _kernelProxy,
        address _balancerPool
    )
        internal
        returns (BalancerV3_GyroECLP_LT_DeploymentTemplate.MarketContracts memory mc)
    {
        mc.balancerPool = _balancerPool;
        mc.jtImpl = _deployImplWithArgs(type(RoycoJuniorTranche).creationCode, abi.encode(_config.juniorAsset, _kernelProxy), _salt(_marketId, TAG_JT_IMPL));
        mc.ltImpl = _deployImplWithArgs(type(RoycoLiquidityTranche).creationCode, abi.encode(_balancerPool, _kernelProxy), _salt(_marketId, TAG_LT_IMPL));
        mc.accountantImpl = _deployImplWithArgs(type(RoycoDayAccountant).creationCode, abi.encode(_kernelProxy), _salt(_marketId, TAG_ACCOUNTANT_IMPL));
        mc.kernelImpl = _deployKernelImpl(_config, _factory, _marketId, _balancerPool);
        // The real kernel-bound hook implementation is deployed inside the template's wiring tx (its constructor reads
        // the kernel's LT_ASSET, so it cannot be deployed before the kernel proxy exists)
        (mc.jtYdm, mc.ltYdm) = _deployYDMs(_config);
    }

    /// @notice Deploys the market's JT YDM and LT LDM as market-agnostic shared singletons
    /// @dev Deployed separately from the per-market Constants and shared across markets: the salt is market-agnostic
    ///      and role-specific (`TAG_YDM` / `TAG_LDM`), so markets with the same model + params reuse one instance (their
    ///      per-market curve state is keyed per accountant). CREATE2's initcode binding still gives distinct params
    ///      distinct addresses (no silent first-writer-wins reuse) and keeps the JT YDM and LT LDM distinct
    function _deployYDMs(MarketConfig memory _config) internal returns (address jtYdm, address ltYdm) {
        jtYdm = _deployYDM(_config.ydmType, _config.jtYdmTargetUtilizationWAD, _ydmSalt(TAG_YDM));
        ltYdm = _deployYDM(_config.ydmType, _config.ltYdmTargetUtilizationWAD, _ydmSalt(TAG_LDM));
    }

    /// @notice Market-agnostic, role-specific CREATE2 salt for a shared YDM singleton (`TAG_YDM` for the JT YDM,
    ///         `TAG_LDM` for the LT LDM)
    function _ydmSalt(bytes32 _roleTag) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("ROYCO_YDM_", _roleTag));
    }

    /// @notice CREATE2-deploys an implementation from its creation code with ABI-encoded constructor args appended
    function _deployImplWithArgs(bytes memory _creationCode, bytes memory _ctorArgs, bytes32 _implSalt) internal returns (address impl) {
        (impl,) = deployWithSanityChecks(_implSalt, abi.encodePacked(_creationCode, _ctorArgs), false);
    }

    /// @notice Deploys the market's manipulation-resistant E-CLP BPT TVL oracle through Balancer's LP oracle factory
    /// @dev Each pool leg's live balance is already priced by its rate provider, so every leg uses the shared stateless
    ///      constant-1.0 price feed. The kernel's LT quoter verifies `oracle.pool() == LT_ASSET` on-chain at init
    function _deployBPTOracle(address _pool) internal returns (address bptOracle) {
        ChainConfig memory chainConfig = getChainConfig(block.chainid);
        IVault vault = IVault(address(GyroECLPPoolFactory(chainConfig.gyroECLPPoolFactory).getVault()));
        (address constantPriceFeed,) = deployWithSanityChecks(CONSTANT_PRICE_FEED_SALT, type(ConstantPriceFeed).creationCode, false);

        IERC20[] memory poolTokens = vault.getPoolTokens(_pool);
        BalancerAggregatorV3Interface[] memory feeds = new BalancerAggregatorV3Interface[](poolTokens.length);
        for (uint256 i; i < poolTokens.length; ++i) {
            feeds[i] = BalancerAggregatorV3Interface(constantPriceFeed);
        }

        bptOracle = address(
            ILPOracleFactoryBase(chainConfig.eclpLPOracleFactory)
                .create({ pool: IBasePool(_pool), shouldUseBlockTimeForOldestFeedUpdate: false, shouldRevertIfVaultUnlocked: false, feeds: feeds })
        );
    }

    /// @notice Deploys the senior tranche impl and its pre-deployed proxy (built with the market authority; the
    ///         template verifies it)
    function _predeploySeniorTrancheProxy(
        MarketConfig memory _config,
        bytes32 _marketId,
        RoycoFactory _factory,
        address _accessManager,
        address _kernelProxy
    )
        internal
    {
        (address stImpl,) = deployWithSanityChecks(
            _salt(_marketId, TAG_ST_IMPL), abi.encodePacked(type(RoycoSeniorTranche).creationCode, abi.encode(_config.seniorAsset, _kernelProxy)), false
        );
        bytes memory stInitData = abi.encodeCall(
            RoycoSeniorTranche.initialize,
            (IRoycoVaultTranche.RoycoTrancheInitParams({
                    name: _config.seniorTrancheName, symbol: _config.seniorTrancheSymbol, initialAuthority: _accessManager
                }))
        );
        _factory.deployDeterministicProxy(stImpl, stInitData, _salt(_marketId, TAG_ST_PROXY));
    }

    /// @notice Pre-deploys the pool-hook proxy against the stand-in impl, creates the market's Gyro E-CLP pool, and
    ///         deploys the pool's BPT oracle
    /// @dev The hook proxy's init data is a non-empty no-op: the hardened ERC1967Proxy rejects empty init data, and the
    ///      stand-in's fallback swallows the delegatecall (the proxy is upgraded to the real hook in the wiring tx).
    ///      The pool's senior leg rate provider is the predicted (still codeless) kernel; its role accounts are the AM.
    ///      The BPT oracle is deployed here (co-located with pool creation) to keep `_deployMarketContracts` under the stack limit
    function _createPoolWithHookProxy(
        MarketConfig memory _config,
        bytes32 _marketId,
        RoycoFactory _factory,
        address _template,
        address _accessManager,
        address _kernelProxy,
        address _seniorTranche
    )
        internal
        returns (address balancerPool, address bptOracle)
    {
        address hookProxy = _factory.deployDeterministicProxy(
            BalancerV3_GyroECLP_LT_DeploymentTemplate(_template).BALANCER_HOOK_STANDIN_IMPL(), bytes("no-op"), _salt(_marketId, TAG_BALANCER_HOOK_PROXY)
        );

        balancerPool =
            _createBalancerV3Pool(_config.gyroECLPPoolParams, _seniorTranche, _kernelProxy, hookProxy, _accessManager, _salt(_marketId, TAG_BALANCER_V3_POOL));
        bptOracle = _deployBPTOracle(balancerPool);
    }

    /// @notice Deploys the kernel implementation for a kernel type, appending the family's extra constructor arg(s)
    /// @dev Ports the per-kernel constructor-arg branching that previously lived in the templates' `_kernelConstructionArgs`.
    ///      The kernel construction params pin the predicted senior/junior/liquidity tranche and accountant proxy addresses
    function _deployKernelImpl(
        MarketConfig memory _config,
        RoycoFactory _factory,
        bytes32 _marketId,
        address _balancerPool
    )
        internal
        returns (address kernelImpl)
    {
        IRoycoDayKernel.RoycoDayKernelConstructionParams memory cp = IRoycoDayKernel.RoycoDayKernelConstructionParams({
            seniorTranche: _factory.predictDeterministicAddress(_salt(_marketId, TAG_ST_PROXY)),
            stAsset: _config.seniorAsset,
            juniorTranche: _factory.predictDeterministicAddress(_salt(_marketId, TAG_JT_PROXY)),
            jtAsset: _config.juniorAsset,
            accountant: _factory.predictDeterministicAddress(_salt(_marketId, TAG_ACCOUNTANT_PROXY)),
            liquidityTranche: _factory.predictDeterministicAddress(_salt(_marketId, TAG_LT_PROXY)),
            ltAsset: _balancerPool,
            enforceVaultSharesTransferWhitelist: _config.enforceVaultSharesTransferWhitelist
        });

        bytes memory creationCode;
        if (_config.kernelType == KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel) {
            creationCode =
                abi.encodePacked(type(Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel).creationCode, abi.encode(cp));
        } else if (_config.kernelType == KernelType.Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel) {
            IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_QuoterKernelParams memory p =
                abi.decode(_config.kernelSpecificParams, (IdenticalMakinaShares_ST_JT_SharePriceToChainlinkOracle_QuoterKernelParams));
            creationCode = abi.encodePacked(
                type(Identical_Makina_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel).creationCode, abi.encode(cp, p.makinaMachine)
            );
        } else if (_config.kernelType == KernelType.Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel) {
            creationCode = abi.encodePacked(type(Identical_Assets_ST_JT_ChainlinkToAdminOracle_BalancerV3_BPTOracle_LT_Kernel).creationCode, abi.encode(cp));
        } else if (_config.kernelType == KernelType.Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel) {
            Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_QuoterKernelParams memory p =
                abi.decode(_config.kernelSpecificParams, (Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_QuoterKernelParams));
            creationCode =
                abi.encodePacked(type(Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_BalancerV3_BPTOracle_LT_Kernel).creationCode, abi.encode(cp, p.idleCDO));
        } else {
            revert UnsupportedKernelType(_config.kernelType);
        }
        (kernelImpl,) = deployWithSanityChecks(_salt(_marketId, TAG_KERNEL_IMPL), creationCode, false);
    }

    /// @notice Creates the Gyro E-CLP pool with tokens `{ST_share, quote}` (ported from the template's former pool creation)
    /// @param _authority The market AccessManager, set as the pool's pause/swap-fee/creator role accounts
    function _createBalancerV3Pool(
        GyroECLPPoolParams memory _p,
        address _seniorTranche,
        address _seniorRateProvider,
        address _hook,
        address _authority,
        bytes32 _salt_
    )
        internal
        returns (address balancerV3Pool)
    {
        BalancerV3TokenConfig[] memory tokens = new BalancerV3TokenConfig[](2);

        // Balancer V3 requires a pool's tokens registered in ascending address order
        {
            uint256 seniorTrancheIndex = uint160(_seniorTranche) < uint160(_p.quoteAsset) ? 0 : 1;
            tokens[seniorTrancheIndex] = _buildTokenConfig(_seniorTranche, _seniorRateProvider, _p.chargeYieldFeeOnSeniorTrancheShares);
            tokens[1 - seniorTrancheIndex] = _buildTokenConfig(_p.quoteAsset, _p.quoteAssetRateProvider, _p.chargeYieldFeeOnQuoteAsset);
        }

        BalancerV3PoolRoleAccounts memory roleAccounts =
            BalancerV3PoolRoleAccounts({ pauseManager: _authority, swapFeeManager: _authority, poolCreator: _authority });

        balancerV3Pool = GyroECLPPoolFactory(getChainConfig(block.chainid).gyroECLPPoolFactory)
            .create({
            name: _p.name,
            symbol: _p.symbol,
            tokens: tokens,
            eclpParams: _p.eclpParams,
            derivedEclpParams: _p.derivedEclpParams,
            roleAccounts: roleAccounts,
            swapFeePercentage: _p.swapFeePercentage,
            poolHooksContract: _hook,
            enableDonation: false,
            disableUnbalancedLiquidity: false,
            salt: _salt_
        });
    }

    /// @notice Builds the token config for a pool leg (ported from the template)
    function _buildTokenConfig(address _token, address _rateProvider, bool _paysYieldFees) internal pure returns (BalancerV3TokenConfig memory) {
        require(!_paysYieldFees || _rateProvider != address(0), RateProviderRequiredWhenPayingYieldFees(_token));
        return BalancerV3TokenConfig({
            token: IERC20(_token),
            tokenType: _rateProvider == address(0) ? BalancerV3TokenType.STANDARD : BalancerV3TokenType.WITH_RATE,
            rateProvider: IRateProvider(_rateProvider),
            paysYieldFees: _paysYieldFees
        });
    }

    /// @notice The template's per-market component salt: `keccak256("ROYCO_MARKET_" ‖ marketId ‖ tag)`
    function _salt(bytes32 _marketId, bytes32 _componentTag) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("ROYCO_MARKET_", _marketId, _componentTag));
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
}
