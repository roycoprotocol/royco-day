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
import { BeaconProxy } from "../lib/openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "../lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoMarketSyncer } from "../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { CREATE3 } from "../lib/solady/src/utils/CREATE3.sol";
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
    ADMIN_ORACLE_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    DEPLOYER_ROLE,
    DEPLOYER_ROLE_ADMIN_ROLE,
    GUARDIAN_ROLE,
    JT_LP_ROLE,
    LPT_LP_ROLE,
    LP_ROLE_ADMIN_ROLE,
    PUBLIC_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE
} from "../src/factory/Roles.sol";
import { RoycoAccessManager } from "../src/factory/RoycoAccessManager.sol";
import { RoycoCreate3Deployer } from "../src/factory/RoycoCreate3Deployer.sol";
import { RoycoFactory } from "../src/factory/RoycoFactory.sol";
import { RoycoFactoryGatekeeper } from "../src/factory/RoycoFactoryGatekeeper.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import {
    TAG_ACCOUNTANT_IMPL,
    TAG_ACCOUNTANT_PROXY,
    TAG_BALANCER_V3_POOL,
    TAG_JT_IMPL,
    TAG_JT_PROXY,
    TAG_KERNEL_IMPL,
    TAG_KERNEL_PROXY,
    TAG_LDM,
    TAG_LPT_IMPL,
    TAG_LPT_PROXY,
    TAG_ST_IMPL,
    TAG_ST_PROXY,
    TAG_YDM
} from "../src/factory/templates/base/Constants.sol";
import { IRoycoAuth } from "../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayEntryPoint } from "../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../src/interfaces/IYDM.sol";
import { IBaseTemplate } from "../src/interfaces/factory/IBaseTemplate.sol";
import { IRoycoAccessManager } from "../src/interfaces/factory/IRoycoAccessManager.sol";
import { IRoycoFactory } from "../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { IBalancerV3LiquidityVenue } from "../src/interfaces/liquidity-venue/IBalancerV3LiquidityVenue.sol";
import { RoycoDayBalancerV3Kernel } from "../src/kernels/RoycoDayBalancerV3Kernel.sol";
import { toNAVUnits } from "../src/libraries/Units.sol";
import { BalancerV3PoolCreationParams } from "../src/libraries/logic/liquidity-venue/BalancerV3VenueCreationLogic.sol";
import { ChainlinkPriceOracle } from "../src/oracle/ChainlinkPriceOracle.sol";
import { ERC4626SharePriceOracle } from "../src/oracle/ERC4626SharePriceOracle.sol";
import { IdleCDOTranchePriceOracle } from "../src/oracle/IdleCDOTranchePriceOracle.sol";
import { MakinaSharePriceOracle } from "../src/oracle/MakinaSharePriceOracle.sol";
import { OracleClockBase } from "../src/oracle/base/clock/OracleClockBase.sol";
import { RoycoJuniorTranche } from "../src/tranches/RoycoJuniorTranche.sol";
import { RoycoLiquidityProviderTranche } from "../src/tranches/RoycoLiquidityProviderTranche.sol";
import { RoycoSeniorTranche } from "../src/tranches/RoycoSeniorTranche.sol";
import { AdaptiveCurveYDM_V1 } from "../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../src/ydm/AdaptiveCurveYDM_V2.sol";
import { StaticCurveYDM } from "../src/ydm/StaticCurveYDM.sol";
import {
    AdaptiveCurveYDM_V1_Params,
    AdaptiveCurveYDM_V2_Params,
    ChainConfig,
    ChainlinkPriceOracleParams,
    DeploymentResult,
    ERC4626SharePriceOracleParams,
    GyroECLPPoolParams,
    IdleCDOTranchePriceOracleParams,
    KernelType,
    MakinaSharePriceOracleParams,
    MarketConfig,
    OracleType,
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
    error UnsupportedOracleType(OracleType oracleType);
    error UnknownRole(uint64 role);
    error RateProviderRequiredWhenPayingYieldFees(address token);
    error SeniorTrancheNotFirstPoolToken(address seniorTranche, address quoteAsset);

    bool ENABLE_LOGGING = false;

    /// @dev Per-DeployScript-instance cache of registered templates, keyed by kernel type.
    mapping(uint256 kernelType => address template) internal kernelTypeToTemplate;

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT LOGGING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Prints a phase header (gated on `ENABLE_LOGGING`).
    function _logSection(string memory _title) internal view {
        if (ENABLE_LOGGING) console2.log(string.concat("\n== ", _title, " =="));
    }

    /// @dev Prints one contract's disposition: `[deployed]` (freshly created) or `[reused]` (found at its
    ///      deterministic address). `_reused` is the `isAlreadyDeployed` flag the deterministic deployers return.
    function _logDeploy(string memory _name, address _addr, bool _reused) internal view {
        if (ENABLE_LOGGING) console2.log(string.concat(_reused ? "  [reused]   " : "  [deployed] ", _name), _addr);
    }

    /// @dev Prints a contract that is always freshly created (no deterministic reuse), e.g. the pool / BPT oracle.
    function _logCreated(string memory _name, address _addr) internal view {
        if (ENABLE_LOGGING) console2.log(string.concat("  [deployed] ", _name), _addr);
    }

    /// @notice Entry point for `forge script`. Reads DEPLOYER_PRIVATE_KEY, MARKET_NAME, and the test/prod flag from env.
    /// @dev `IS_TEST_DEPLOYMENT=true` selects the test environment (single-admin roles + `_TEST` salt suffix);
    ///      anything else (or unset) is a production deployment. `TEST_ADMIN` overrides the single test admin address.
    function run() external virtual {
        ENABLE_LOGGING = true;
        isTestEnv = vm.envOr("IS_TEST_DEPLOYMENT", false);
        testDeploymentAdmin = vm.envOr("TEST_ADMIN", testDeploymentAdmin);
        console2.log(isTestEnv ? "Environment: TEST" : "Environment: PRODUCTION");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory marketName = vm.envString("MARKET_NAME");
        console2.log("Deploying market from config:", marketName);
        deployFromConfig(marketName, deployerPrivateKey);
    }

    /// @notice Deploy a market using Solidity configuration for the current environment (`isTestEnv`).
    function deployFromConfig(string memory marketName, uint256 deployerPrivateKey) public returns (DeploymentResult memory) {
        ChainConfig memory chainConfig = getChainConfig(block.chainid, isTestEnv);
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
                adminOracleAddress: chainConfig.adminOracleAddress,
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
        DeploymentResult memory result = _deployAndExecuteMarket(_config, s, _protocolFeeRecipient, deployer);

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
        (s.accessManager, s.factory, s.entryPoint, s.marketSyncer, amExisted) = _deployAccessManagerAndFactory(_deployer);

        // Role graph (grants + admin/guardian re-pointing) on a freshly deployed AccessManager.
        if (!amExisted) _applyRoleGraph(s.accessManager, _factoryAdmin, _deployer, _roleAssignments);
        if (ENABLE_LOGGING) console2.log(amExisted ? "  [reused]    AccessManager role graph (already applied)" : "  [applied]   AccessManager role graph");

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
        s.template = _getOrRegisterTemplate(s.factory, _config, s.roycoBlacklist);

        // Register the yield distribution models on the template and open its admin surface. Both are chain-wide and
        // must land before the deployer renounces its admin roles.
        _registerYieldDistributionModels(s.accessManager, s.template, _config);

        // Bind each component beacon's upgrade entrypoint. A beacon governs every market of its type, so this is wired
        // once per chain rather than per market, and it replaces the per-proxy upgrade bindings the components carried
        // while they were UUPS.
        _bindBeaconUpgradeRoles(s.accessManager, s.template);

        // The pre-mined marketId for this market against this exact factory (its senior-tranche proxy sorts before the
        // quote asset, so the ST is pool token0).
        s.marketId = getMarketId(_config.marketName, address(s.factory));
        if (ENABLE_LOGGING) {
            console2.log(string.concat("  marketId (", _config.marketName, "):"));
            console2.logBytes32(s.marketId);
        }

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
        roleAssignments[6] = _assignment(ADMIN_ORACLE_ROLE, _addresses.adminOracleAddress);
        roleAssignments[7] = _assignment(LP_ROLE_ADMIN_ROLE, _addresses.lpRoleAdminAddress);
        roleAssignments[8] = _assignment(ST_LP_ROLE, _addresses.protocolFeeRecipientAddress);
        roleAssignments[9] = _assignment(JT_LP_ROLE, _addresses.protocolFeeRecipientAddress);
        roleAssignments[10] = _assignment(GUARDIAN_ROLE, _addresses.guardianAddress);
        roleAssignments[11] = _assignment(DEPLOYER_ROLE, _addresses.deployerAddress);
        roleAssignments[12] = _assignment(DEPLOYER_ROLE_ADMIN_ROLE, _addresses.deployerAdminAddress);
        roleAssignments[13] = _assignment(ADMIN_UNPAUSER_ROLE, _addresses.unpauserAddress);
        roleAssignments[14] = _assignment(LPT_LP_ROLE, _addresses.protocolFeeRecipientAddress);
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
        if (role == ADMIN_ORACLE_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == GUARDIAN_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: ADMIN_ROLE, executionDelay: 0 });
        if (role == DEPLOYER_ROLE) return RoleConfig({ adminRole: DEPLOYER_ROLE_ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == DEPLOYER_ROLE_ADMIN_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_FACTORY_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_UNPAUSER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == LPT_LP_ROLE) return RoleConfig({ adminRole: LP_ROLE_ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
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

    /// @notice Deploys (or reuses) the standalone RoycoAccessManager, its factory gatekeeper, and the factory.
    /// @dev The role graph is applied by the caller (when `amExisted` is false) AFTER the periphery singletons are
    ///      deployed, so grants that require default (ADMIN_ROLE) role admins can land before pass 2 re-points them.
    function _deployAccessManagerAndFactory(address _deployer)
        internal
        returns (RoycoAccessManager accessManager, RoycoFactory factory, address entryPoint, address marketSyncer, bool amExisted)
    {
        _logSection("Protocol scaffolding");

        // Deploy the AccessManager with the deployer as the initial admin so it can wire roles during this broadcast.
        address amAddr;
        (amAddr, amExisted) = deployWithSanityChecks(
            _singletonSalt("ROYCO_ACCESS_MANAGER"), abi.encodePacked(type(RoycoAccessManager).creationCode, abi.encode(_deployer)), false
        );
        accessManager = RoycoAccessManager(amAddr);
        _logDeploy("AccessManager      ", amAddr, amExisted);

        // Deploy the CREATE3 deployer
        (address create3Deployer, bool create3DeployerExisted) =
            deployWithSanityChecks(_singletonSalt("ROYCO_CREATE3_DEPLOYER"), type(RoycoCreate3Deployer).creationCode, false);
        _logDeploy("CREATE3 deployer   ", create3Deployer, create3DeployerExisted);

        bytes32 factoryProxySalt = _singletonSalt("ROYCO_FACTORY_PROXY");
        address factoryProxy = RoycoCreate3Deployer(create3Deployer).predict(_deployer, factoryProxySalt);

        // The gatekeeper pins both periphery singletons as immutables, but neither can exist yet: an entry point's
        // initializer reads its authority off the factory, and the factory in turn is built against this gatekeeper.
        // All three addresses are deterministic though, so the gatekeeper takes the periphery predicted and the
        // deployment below asserts each one landed where it was promised
        (address predictedEntryPoint, address predictedMarketSyncer) = _predictPeripherySingletons(accessManager, factoryProxy);

        // Deploy the factory gatekeeper against the factory address the CREATE3 salt has already fixed
        (address gatekeeper, bool gatekeeperExisted) = deployWithSanityChecks(
            _singletonSalt("ROYCO_FACTORY_GATEKEEPER"),
            abi.encodePacked(type(RoycoFactoryGatekeeper).creationCode, abi.encode(amAddr, factoryProxy, predictedEntryPoint, predictedMarketSyncer)),
            false
        );
        _logDeploy("Gatekeeper         ", gatekeeper, gatekeeperExisted);

        // Hand it the ADMIN_ROLE the factory used to hold
        if (!gatekeeperExisted) {
            accessManager.grantRole(ADMIN_ROLE, gatekeeper, 0);
            accessManager.grantRole(ADMIN_ENTRY_POINT_ROLE, gatekeeper, 0);
            accessManager.grantRole(SYNC_ROLE, gatekeeper, 0);
        }

        (address factoryImpl, bool factoryImplExisted) = deployWithSanityChecks(
            _singletonSalt("ROYCO_FACTORY_IMPLEMENTATION"), abi.encodePacked(type(RoycoFactory).creationCode, abi.encode(gatekeeper)), false
        );
        _logDeploy("Factory (impl)     ", factoryImpl, factoryImplExisted);

        bool factoryProxyExisted = factoryProxy.code.length > 0;
        if (!factoryProxyExisted) {
            address deployedProxy = RoycoCreate3Deployer(create3Deployer)
                .deploy(factoryProxySalt, getERC1967ProxyCreationCode(factoryImpl, abi.encodeCall(RoycoFactory.initialize, (amAddr))));
            require(deployedProxy == factoryProxy, "factory address mismatch");
        }
        factory = RoycoFactory(factoryProxy);
        _logDeploy("Factory (proxy)    ", factoryProxy, factoryProxyExisted);

        // The factory is live, so the periphery can finally initialize against it. Both must land on the addresses the
        // gatekeeper was already built around, which is the check the gatekeeper's constructor can no longer make
        (entryPoint, marketSyncer) = _deployPeripherySingletons(accessManager, factoryProxy);
        require(entryPoint == predictedEntryPoint && marketSyncer == predictedMarketSyncer, "periphery address mismatch");
        require(IRoycoDayEntryPoint(entryPoint).ROYCO_FACTORY() == factoryProxy, "entry point bound to a different factory");

        // Wire the factory roles
        if (!factoryProxyExisted) _wireFactoryRoles(accessManager, factoryProxy);
    }

    /// @notice Binds the factory's own gated selectors and grants it the narrow role set it retains.
    /// @dev Moved out of `RoycoFactory.initialize`, which can no longer perform these writes now that the factory does
    ///      not hold ADMIN_ROLE. MUST run before `_applyRoleGraph`, whose second pass re-points SYNC_ROLE's admin away
    ///      from ADMIN_ROLE and would leave the deployer unable to make the SYNC_ROLE grant below.
    function _wireFactoryRoles(AccessManager _accessManager, address _factory) internal {
        bytes4[] memory deployerSelectors = new bytes4[](1);
        deployerSelectors[0] = IRoycoFactory.executeMarketDeployment.selector;
        _accessManager.setTargetFunctionRole(_factory, deployerSelectors, DEPLOYER_ROLE);

        bytes4[] memory adminFactorySelectors = new bytes4[](2);
        adminFactorySelectors[0] = IRoycoFactory.registerTemplate.selector;
        adminFactorySelectors[1] = IRoycoFactory.disableTemplate.selector;
        _accessManager.setTargetFunctionRole(_factory, adminFactorySelectors, ADMIN_FACTORY_ROLE);

        _accessManager.setTargetFunctionRole(_factory, _sel(UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE);
        _accessManager.setTargetFunctionRole(_factory, _sel(IRoycoAuth.pause.selector), ADMIN_PAUSER_ROLE);
        _accessManager.setTargetFunctionRole(_factory, _sel(IRoycoAuth.unpause.selector), ADMIN_UNPAUSER_ROLE);

        _accessManager.grantRole(LPT_LP_ROLE, _factory, 0);
    }

    /// @notice Deploys the market's off-factory contracts, executes the factory wiring transaction, and assembles the
    ///         full deployment result.
    /// @dev Extracted from `deploy` (and made to build the final result) to keep `deploy`'s stack frame under the
    ///      via-IR limit.
    function _deployAndExecuteMarket(
        MarketConfig memory _config,
        ProtocolScaffolding memory _s,
        address _protocolFeeRecipient,
        address _deployer
    )
        internal
        returns (DeploymentResult memory)
    {
        bytes32 marketId = _s.marketId;
        // Resolve the kernel's collateral asset oracle before params are built (deployed here when the config leaves it unset)
        if (_config.collateralAssetOracle == address(0)) {
            _config.collateralAssetOracle = _deployCollateralAssetOracle(_config, marketId);
        }
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory params =
            _buildMarketParams(_config, marketId, _protocolFeeRecipient, address(_s.factory), _deployer);

        // The template pulls the market's genesis pool liquidity from the account calling the factory's deployment
        // entrypoint (the broadcasting deployer here), so approve the template from inside the broadcast
        IERC20(_config.gyroECLPPoolParams.quoteAsset).approve(_s.template, _config.poolInitialization.quoteAmount);
        uint256 collateralSeed = _config.poolInitialization.collateralAmount;
        if (collateralSeed != 0) IERC20(_config.collateralAsset).approve(_s.template, collateralSeed);

        IRoycoProtocolTemplate.DeploymentResult memory r = _s.factory.executeMarketDeployment(_s.template, abi.encode(params));

        // The template deploys the entire market in this one transaction: every tranche proxy, the Gyro E-CLP pool and
        // its BPT oracle, the accountant, and the kernel, all against the implementations it was constructed with.
        _logSection("Market deployment transaction (executeMarketDeployment)");
        _logCreated("SeniorTranche (proxy)  ", r.seniorTranche);
        _logCreated("JuniorTranche (proxy)  ", r.juniorTranche);
        _logCreated("LiquidityProviderTranche (proxy)", r.liquidityProviderTranche);
        _logCreated("Accountant (proxy)     ", r.accountant);
        _logCreated("Kernel (proxy)         ", r.kernel);
        {
            RoycoDayBalancerV3MarketDeploymentTemplate.ExtraContractsDeployedResult memory extras =
                abi.decode(r.extras, (RoycoDayBalancerV3MarketDeploymentTemplate.ExtraContractsDeployedResult));
            _logCreated("Balancer E-CLP pool    ", extras.balancerPool);
            _logCreated("BPT oracle             ", extras.bptOracle);
        }

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

    /**
     * @notice Deploys (or reuses) and registers the Day template for a market's kernel type
     * @dev CREATE2-deployed at a salt derived from its construction params, so a chain reaches the same template for
     *      the same factory, periphery, and beacon set, and a genuinely different wiring gets its own template rather
     *      than silently reusing one. The yield distribution models are NOT construction params: they live in the
     *      template's own storage and are registered separately, so shipping a new model shape does not move it
     */
    function _getOrRegisterTemplate(RoycoFactory _factory, MarketConfig memory _config, address _roycoBlacklist) internal returns (address template) {
        bool existed;
        (template, existed) = _deployTemplate(IRoycoFactory(address(_factory)), _config, _roycoBlacklist);
        if (!_factory.isTemplateEnabled(template)) _factory.registerTemplate(template);
        _logDeploy("Template           ", template, existed);
    }

    /**
     * @notice Public wrapper over `_deployTemplate` so tests can stand up a real, fully-wired template
     * @dev Deploys (or reuses) the chain's implementation set and the six yield distribution models, then the template
     *      pinned to them, exactly as the production scaffolding phase does
     */
    function deployTemplateForTest(IRoycoFactory _factory, MarketConfig memory _config, address _roycoBlacklist) public returns (address template) {
        (template,) = _deployTemplate(_factory, _config, _roycoBlacklist);
    }

    /**
     * @notice Deploys and registers the yield distribution models on a template, for tests standing one up by hand
     * @param _template The template to register the models on
     * @param _config The market config supplying the model shape and both slots' target utilizations
     */
    function registerYieldDistributionModelsForTest(address _template, MarketConfig memory _config) public {
        RoycoDayBalancerV3MarketDeploymentTemplate t = RoycoDayBalancerV3MarketDeploymentTemplate(_template);
        for (uint256 i; i < 3; ++i) {
            YDMType ydmType = YDMType(i);
            string memory ydmTypeName_ = ydmTypeName(ydmType);
            address jtYdm = _deployModel("JT model  ", ydmType, _config.jtYdmTargetUtilizationWAD, TAG_YDM);
            address lptYdm = _deployModel("LPT model ", ydmType, _config.lptYdmTargetUtilizationWAD, TAG_LDM);
            if (t.jtYdms(ydmTypeName_) == jtYdm && t.lptYdms(ydmTypeName_) == lptYdm) continue;
            t.setYieldDistributionModels(ydmTypeName_, jtYdm, lptYdm);
        }
    }

    /// @notice Public wrapper over `_buildMarketParams` so tests can construct real template deploy params from a market config
    /// @dev Every market contract is deployed by the template itself, so the params are a pure function of the config
    /**
     * @notice Mines the market id that places the market's senior tranche below the quote asset in address order
     * @dev The Vault registers a pool's tokens in ascending address order, and the market is wired against the senior
     *      leg being token0, so the id is searched until the predicted senior proxy sorts below the quote asset
     * @dev Every component salt derives from a hash of the ENTIRE params struct, so a mined id is valid only for the
     *      exact params it was mined against: change any other field and it must be re-mined
     * @param _params The market's fully built params, whose `marketId` this search fills in
     * @param _seed The caller's stable seed, mixed with the search nonce so distinct seeds yield distinct markets
     * @param _factory The factory whose CREATE3 namespace the proxies land in
     * @param _deployer The account that will call `executeMarketDeployment`, which the template mixes into the base salt
     */
    function _mineMarketId(
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory _params,
        bytes32 _seed,
        address _factory,
        address _deployer
    )
        internal
        pure
        returns (bytes32 marketId)
    {
        for (uint64 nonce;; ++nonce) {
            marketId = keccak256(abi.encodePacked(_seed, nonce));
            _params.marketId = marketId;
            // Mirrors the template's derivation exactly: params + deployer, then the per-component tag
            bytes32 baseSalt = keccak256(abi.encode(_params, _deployer));
            bytes32 stSalt = keccak256(abi.encodePacked("ROYCO_MARKET_", baseSalt, TAG_ST_PROXY));
            if (uint160(CREATE3.predictDeterministicAddress(stSalt, _factory)) < uint160(_params.quoteAsset)) return marketId;
        }
    }

    function buildMarketParams(
        MarketConfig memory _config,
        bytes32 _marketIdSeed,
        address _protocolFeeRecipient,
        address _factory,
        address _deployer
    )
        public
        pure
        returns (RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory)
    {
        return _buildMarketParams(_config, _marketIdSeed, _protocolFeeRecipient, _factory, _deployer);
    }

    /**
     * @notice Deploys the concrete Day template, pinned to the chain's implementation and yield-distribution-model set
     * @dev The implementations and models are deployed (or reused) first, then handed to the template as construction
     *      params. Every market this template deploys shares them
     */
    function _deployTemplate(IRoycoFactory _factory, MarketConfig memory _config, address _roycoBlacklist) internal returns (address template, bool existed) {
        if (_config.kernelType != KernelType.RoycoDayBalancerV3Kernel) revert UnsupportedKernelType(_config.kernelType);
        ChainConfig memory chainConfig = getChainConfig(block.chainid, isTestEnv);

        RoycoDayBalancerV3MarketDeploymentTemplate.TemplateConstructionParams memory cp =
            _deployImplementationsAndModels(_config, chainConfig, _factory.ROYCO_AUTHORITY());
        cp.factory = _factory;
        cp.balancerV3PoolFactory = GyroECLPPoolFactory(chainConfig.gyroECLPPoolFactory);
        cp.eclpLPOracleFactory = ILPOracleFactoryBase(chainConfig.eclpLPOracleFactory);
        cp.roycoBlacklist = _roycoBlacklist;

        (template, existed) = deployWithSanityChecks(
            _singletonSalt(string.concat("ROYCO_DAY_BALANCER_V3_TEMPLATE_", vm.toString(keccak256(abi.encode(cp))))),
            abi.encodePacked(type(RoycoDayBalancerV3MarketDeploymentTemplate).creationCode, abi.encode(cp)),
            false
        );
    }

    /**
     * @notice Deploys (or reuses) the chain-wide implementation set and the six yield distribution model instances
     * @dev Every one of these is market-independent, so CREATE2 makes the whole phase idempotent: a second market on
     *      the same chain redeploys nothing. The models are deployed per shape AND per tranche slot because the
     *      accountant rejects a market whose junior and liquidity provider models are the same instance
     * @dev Both slots' target utilizations are constructor immutables on the models, so they are fixed for every market
     *      this template deploys. A market needing different ones produces a different template address
     */
    function _deployImplementationsAndModels(
        MarketConfig memory _config,
        ChainConfig memory _chainConfig,
        address _authority
    )
        internal
        returns (RoycoDayBalancerV3MarketDeploymentTemplate.TemplateConstructionParams memory cp)
    {
        _logSection("Chain-wide implementations, beacons, and yield distribution models");
        bool existed;

        cp.seniorTrancheBeacon = _deployBeacon("SeniorTranche", _singletonSalt("ROYCO_SENIOR_TRANCHE"), type(RoycoSeniorTranche).creationCode, _authority);
        cp.juniorTrancheBeacon = _deployBeacon("JuniorTranche", _singletonSalt("ROYCO_JUNIOR_TRANCHE"), type(RoycoJuniorTranche).creationCode, _authority);
        cp.liquidityProviderTrancheBeacon =
            _deployBeacon("LPTranche    ", _singletonSalt("ROYCO_LIQUIDITY_PROVIDER_TRANCHE"), type(RoycoLiquidityProviderTranche).creationCode, _authority);
        cp.accountantBeacon = _deployBeacon("Accountant   ", _singletonSalt("ROYCO_ACCOUNTANT"), type(RoycoDayAccountant).creationCode, _authority);

        // The kernel implementation's only construction input is the chain's Balancer Vault, which is not market-specific
        cp.kernelBeacon = _deployBeacon(
            "Kernel       ",
            _singletonSalt("ROYCO_DAY_BALANCER_V3_KERNEL"),
            abi.encodePacked(type(RoycoDayBalancerV3Kernel).creationCode, abi.encode(GyroECLPPoolFactory(_chainConfig.gyroECLPPoolFactory).getVault())),
            _authority
        );

        (cp.bptOracleConstantPriceFeed, existed) =
            deployWithSanityChecks(_singletonSalt("ROYCO_BPT_ORACLE_CONSTANT_PRICE_FEED"), type(ConstantPriceFeed).creationCode, false);
        _logDeploy("ConstantPriceFeed     ", cp.bptOracleConstantPriceFeed, existed);
    }

    /**
     * @notice Deploys (or reuses) one component's implementation and the beacon that points at it
     * @dev Both are CREATE2-deployed at derived singleton salts, so the whole phase is idempotent across re-runs. The
     *      beacon's address is stable across implementation upgrades, which is what keeps the template address stable
     * @param _label The log label for this component
     * @param _baseSalt The component's singleton salt, extended per artifact
     * @param _implementationCreationCode The implementation's creation code, with constructor args already appended
     * @param _authority The access manager, set as the beacon's owner so upgrades route through its role and delay machinery
     * @return beacon The component's beacon
     */
    function _deployBeacon(
        string memory _label,
        bytes32 _baseSalt,
        bytes memory _implementationCreationCode,
        address _authority
    )
        internal
        returns (address beacon)
    {
        (address implementation, bool implementationExisted) =
            deployWithSanityChecks(keccak256(abi.encodePacked(_baseSalt, "_IMPLEMENTATION")), _implementationCreationCode, false);
        _logDeploy(string.concat(_label, " (impl)  "), implementation, implementationExisted);

        bool beaconExisted;
        (beacon, beaconExisted) = deployWithSanityChecks(
            keccak256(abi.encodePacked(_baseSalt, "_BEACON")),
            abi.encodePacked(type(UpgradeableBeacon).creationCode, abi.encode(implementation, _authority)),
            false
        );
        _logDeploy(string.concat(_label, " (beacon)"), beacon, beaconExisted);
    }

    /// @notice Deploys (or reuses) one yield distribution model instance for a shape and tranche slot
    /// @dev The slot tag keeps the junior and liquidity provider instances at distinct addresses even when their shape
    ///      and target utilization coincide, which the accountant requires
    function _deployModel(string memory _label, YDMType _ydmType, uint256 _targetUtilizationWAD, bytes32 _slotTag) internal returns (address model) {
        bytes memory creationCode;
        if (_ydmType == YDMType.StaticCurve) creationCode = type(StaticCurveYDM).creationCode;
        else if (_ydmType == YDMType.AdaptiveCurve_V1) creationCode = type(AdaptiveCurveYDM_V1).creationCode;
        else if (_ydmType == YDMType.AdaptiveCurve_V2) creationCode = type(AdaptiveCurveYDM_V2).creationCode;
        else revert UnsupportedYDMType(_ydmType);

        bool existed;
        (model, existed) = deployWithSanityChecks(
            keccak256(abi.encodePacked("ROYCO_YDM_", _slotTag, uint8(_ydmType))),
            abi.encodePacked(creationCode, _ydmConstructorArgs(_ydmType, _targetUtilizationWAD)),
            false
        );
        _logDeploy(string.concat(_label, vm.toString(uint8(_ydmType))), model, existed);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: PARAM BUILDING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Builds the template `MarketParams` from a `MarketConfig`; every market contract is deployed by the template.
    function _buildMarketParams(
        MarketConfig memory _config,
        bytes32 _marketIdSeed,
        address _protocolFeeRecipient,
        address _factory,
        address _deployer
    )
        internal
        pure
        returns (RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory params)
    {
        params.stParams = IBaseTemplate.TrancheDeploymentParams({ name: _config.seniorTrancheName, symbol: _config.seniorTrancheSymbol });
        params.jtParams = IBaseTemplate.TrancheDeploymentParams({ name: _config.juniorTrancheName, symbol: _config.juniorTrancheSymbol });
        params.lptParams = IBaseTemplate.TrancheDeploymentParams({ name: _config.liquidityProviderTrancheName, symbol: _config.liquidityProviderTrancheSymbol });
        params.collateralAsset = _config.collateralAsset;
        params.quoteAsset = _config.gyroECLPPoolParams.quoteAsset;

        // The Gyro E-CLP pool the template creates for this market's liquidity venue
        params.poolCreationParams = BalancerV3PoolCreationParams({
            name: _config.gyroECLPPoolParams.name,
            symbol: _config.gyroECLPPoolParams.symbol,
            eclpParams: _config.gyroECLPPoolParams.eclpParams,
            derivedEclpParams: _config.gyroECLPPoolParams.derivedEclpParams,
            swapFeePercentage: _config.gyroECLPPoolParams.swapFeePercentage,
            quoteAssetRateProvider: _config.gyroECLPPoolParams.quoteAssetRateProvider,
            chargeYieldFeeOnSeniorTrancheShares: _config.gyroECLPPoolParams.chargeYieldFeeOnSeniorTrancheShares,
            chargeYieldFeeOnQuoteAsset: _config.gyroECLPPoolParams.chargeYieldFeeOnQuoteAsset
        });

        // Genesis pool liquidity, seeded by the template as a multi-asset deposit once the market is wired
        params.poolInitializationParams = _config.poolInitialization;

        // The model shapes this market selects from the template's per-slot instances
        params.jtYdmType = ydmTypeName(_config.ydmType);
        params.lptYdmType = ydmTypeName(_config.ydmType);

        // Accountant params. The template resolves both model instances from its registry by shape name. BOTH YDMs get
        // initialization data so the accountant initializes each of them. The LPT premium/liquidity overlay is at its zero
        // baseline (LPT service off) — but the LDM is still deployed, initialized, and distinct from the JT YDM.
        params.accountantParams = IBaseTemplate.AccountantDeploymentParams({
            fixedTermGracePeriodSeconds: _config.fixedTermGracePeriodSeconds,
            minCoverageWAD: _config.minCoverageWAD,
            coverageLiquidationUtilizationWAD: _config.coverageLiquidationUtilizationWAD,
            minLiquidityWAD: 0,
            jtYDMInitializationData: _buildYDMInitializationData(_config.ydmType, _config.ydmSpecificParams),
            lptYDMInitializationData: _buildYDMInitializationData(_config.ydmType, _config.lptYdmSpecificParams),
            maxJTYieldShareWAD: uint64(1e18), // uncapped at the WAD ceiling; the real JT cap comes from the JT YDM curve
            maxLPTYieldShareWAD: 0, // LPT liquidity premium disabled in the baseline
            fixedTermDurationSeconds: _config.fixedTermDurationSeconds,
            dustTolerance: toNAVUnits(_config.dustTolerance),
            stProtocolFeeWAD: _config.stProtocolFeeWAD,
            jtProtocolFeeWAD: _config.jtProtocolFeeWAD,
            jtYieldShareProtocolFeeWAD: _config.jtYieldShareProtocolFeeWAD,
            lptYieldShareProtocolFeeWAD: 0
        });

        params.kernelSpecificParams = _config.kernelSpecificParams; // the venue params blob (BalancerV3LiquidityVenueDeploymentParams)
        params.protocolFeeRecipient = _protocolFeeRecipient;
        params.stSelfLiquidationBonusWAD = _config.stSelfLiquidationBonusWAD;
        params.collateralAssetOracle = _config.collateralAssetOracle;
        params.stalenessThresholdSeconds = _config.stalenessThresholdSeconds;
        params.sequencerUptimeFeed = _config.sequencerUptimeFeed;
        params.gracePeriodSeconds = _config.gracePeriodSeconds;
        // The oracle's restricted surface bindings are declared per oracle kind here and applied by the template
        // Per-tranche entry point configs applied by the template (via the factory) after the market is deployed.
        params.entryPointTrancheConfigs = RoycoDayBalancerV3MarketDeploymentTemplate.EntryPointTrancheConfigs({
            st: _config.stEntryPointConfig, jt: _config.jtEntryPointConfig, lpt: _config.lptEntryPointConfig
        });

        // The component salts hash the WHOLE params struct, so the id can only be mined once every other field is
        // settled: it is what makes the senior tranche's CREATE3 proxy sort below the quote asset, and so pool token0
        params.marketId = _mineMarketId(params, _marketIdSeed, _factory, _deployer);
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

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: EXTERNAL MARKET-CONTRACT DEPLOYMENT (impls, YDMs, pool, pre-deployed proxies)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice CREATE2-deploys an implementation from its creation code with ABI-encoded constructor args appended
    function _deployImplWithArgs(string memory _name, bytes memory _creationCode, bytes memory _ctorArgs, bytes32 _implSalt) internal returns (address impl) {
        bool existed;
        (impl, existed) = deployWithSanityChecks(_implSalt, abi.encodePacked(_creationCode, _ctorArgs), false);
        _logDeploy(_name, impl, existed);
    }

    /**
     * @notice Deploys the yield distribution models and registers them on the template, one pair per model shape
     * @dev Idempotent: the models are CREATE2-deployed at derived salts, and a shape already registered on the
     *      template is skipped, so a re-run of the script writes nothing
     * @dev Binds the template's registration surface first, since the deployer needs it to register at all and its
     *      admin roles are renounced at the end of the scaffolding phase
     */
    function _registerYieldDistributionModels(AccessManager _accessManager, address _template, MarketConfig memory _config) internal {
        RoycoDayBalancerV3MarketDeploymentTemplate t = RoycoDayBalancerV3MarketDeploymentTemplate(_template);

        if (!IRoycoAccessManager(address(_accessManager)).wasEverConfigured(_template)) {
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = RoycoDayBalancerV3MarketDeploymentTemplate.setYieldDistributionModels.selector;
            _accessManager.setTargetFunctionRole(_template, selectors, ADMIN_FACTORY_ROLE);
        }

        registerYieldDistributionModelsForTest(_template, _config);
        t;
    }

    /// @notice The canonical registry name for a model shape, shared by registration and market params
    /// @dev The template keys its registry by name, so this is the single place the enum crosses into that namespace
    function ydmTypeName(YDMType _ydmType) public pure returns (string memory) {
        if (_ydmType == YDMType.StaticCurve) return "STATIC_CURVE";
        if (_ydmType == YDMType.AdaptiveCurve_V1) return "ADAPTIVE_CURVE_V1";
        if (_ydmType == YDMType.AdaptiveCurve_V2) return "ADAPTIVE_CURVE_V2";
        revert UnsupportedYDMType(_ydmType);
    }

    /// @notice Binds `upgradeTo` on every component beacon to ADMIN_UPGRADER_ROLE, skipping any already configured
    /// @dev Beacons are chain-wide, so a second market deployment finds them already bound and skips them: the
    ///      access manager records every configured target and the gatekeeper rejects reconfiguring one
    function _bindBeaconUpgradeRoles(AccessManager _accessManager, address _template) internal {
        RoycoDayBalancerV3MarketDeploymentTemplate t = RoycoDayBalancerV3MarketDeploymentTemplate(_template);
        address[5] memory beacons =
            [t.SENIOR_TRANCHE_BEACON(), t.JUNIOR_TRANCHE_BEACON(), t.LIQUIDITY_PROVIDER_TRANCHE_BEACON(), t.KERNEL_BEACON(), t.ACCOUNTANT_BEACON()];
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = UpgradeableBeacon.upgradeTo.selector;
        for (uint256 i; i < beacons.length; ++i) {
            if (IRoycoAccessManager(address(_accessManager)).wasEverConfigured(beacons[i])) continue;
            _accessManager.setTargetFunctionRole(beacons[i], selectors, ADMIN_UPGRADER_ROLE);
        }
    }

    /**
     * @notice A market-scoped CREATE2 salt for the one market contract still deployed outside the template
     * @dev Shares the template's `keccak256("ROYCO_MARKET_" ‖ marketId ‖ tag)` preimage so a previously deployed oracle
     *      keeps its address, but the tags used with it are disjoint from the template's component tags
     */
    function _marketScopedSalt(bytes32 _marketId, bytes32 _componentTag) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("ROYCO_MARKET_", _marketId, _componentTag));
    }

    /// @notice CREATE2-deploys the market's collateral asset oracle adapter selected by `collateralAssetOracleType`,
    ///         decoding the kind-specific constructor params from `collateralAssetOracleSpecificParams`
    /// @dev Only runs when the config leaves `collateralAssetOracle` unset; a pre-deployed oracle address bypasses this.
    ///      Every kind is a fully immutable direct deployment with no authority, so reconfiguration is a redeploy
    ///      plus a kernel oracle repoint
    function _deployCollateralAssetOracle(MarketConfig memory _config, bytes32 _marketId) internal returns (address oracle) {
        _logSection("Collateral asset oracle");
        bytes memory ctorArgs;
        bytes memory creationCode;
        if (_config.collateralAssetOracleType == OracleType.ChainlinkPrice) {
            ChainlinkPriceOracleParams memory p = abi.decode(_config.collateralAssetOracleSpecificParams, (ChainlinkPriceOracleParams));
            creationCode = type(ChainlinkPriceOracle).creationCode;
            ctorArgs = abi.encode(_config.collateralAsset, p.collateralToNavAssetFeed);
        } else if (_config.collateralAssetOracleType == OracleType.ERC4626SharePrice) {
            ERC4626SharePriceOracleParams memory p = abi.decode(_config.collateralAssetOracleSpecificParams, (ERC4626SharePriceOracleParams));
            creationCode = type(ERC4626SharePriceOracle).creationCode;
            ctorArgs = abi.encode(_config.collateralAsset, p.baseAssetToNavAssetFeed);
        } else if (_config.collateralAssetOracleType == OracleType.MakinaSharePrice) {
            MakinaSharePriceOracleParams memory p = abi.decode(_config.collateralAssetOracleSpecificParams, (MakinaSharePriceOracleParams));
            creationCode = type(MakinaSharePriceOracle).creationCode;
            ctorArgs = abi.encode(p.makinaMachine, p.accountingAssetToNavAssetFeed);
        } else if (_config.collateralAssetOracleType == OracleType.IdleCDOTranchePrice) {
            IdleCDOTranchePriceOracleParams memory p = abi.decode(_config.collateralAssetOracleSpecificParams, (IdleCDOTranchePriceOracleParams));
            creationCode = type(IdleCDOTranchePriceOracle).creationCode;
            ctorArgs = abi.encode(p.idleCDO, _config.collateralAsset, p.underlyingTokenToNavAssetFeed, p.minDeviationWAD, p.lastUpdate);
        } else {
            revert UnsupportedOracleType(_config.collateralAssetOracleType);
        }
        bool existed;
        (oracle, existed) = deployWithSanityChecks(_marketScopedSalt(_marketId, "COLLATERAL_ASSET_ORACLE"), abi.encodePacked(creationCode, ctorArgs), false);
        _logDeploy("CollateralAssetOracle  ", oracle, existed);
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
    /// @notice Predicts both periphery singletons' CREATE2 addresses, which the gatekeeper is built against before
    ///         either can be deployed (an entry point initializes against the factory, which is built against the gatekeeper)
    /// @dev Must derive each address from EXACTLY the creation code `_deployPeripherySingletons` deploys
    function _predictPeripherySingletons(AccessManager _accessManager, address _factory) internal view returns (address entryPoint, address marketSyncer) {
        address entryPointImpl = generateDeterminsticAddress(
            _singletonSalt("ROYCO_DAY_ENTRY_POINT_IMPLEMENTATION"), abi.encodePacked(type(RoycoDayEntryPoint).creationCode, abi.encode(_factory))
        );
        entryPoint =
            generateDeterminsticAddress(_singletonSalt("ROYCO_DAY_ENTRY_POINT_PROXY"), getERC1967ProxyCreationCode(entryPointImpl, _entryPointInitData()));

        address syncerImpl = generateDeterminsticAddress(_singletonSalt("ROYCO_MARKET_SYNCER_IMPLEMENTATION"), type(RoycoMarketSyncer).creationCode);
        marketSyncer = generateDeterminsticAddress(
            _singletonSalt("ROYCO_MARKET_SYNCER_PROXY"), getERC1967ProxyCreationCode(syncerImpl, _syncerInitData(address(_accessManager)))
        );
    }

    /// @dev The entry point initializes with no tranche configs: every market's flow through the gatekeeper at deployment
    function _entryPointInitData() internal pure returns (bytes memory) {
        return abi.encodeCall(RoycoDayEntryPoint.initialize, (new address[](0), new IRoycoDayEntryPoint.TrancheConfig[](0)));
    }

    /// @dev The syncer initializes with no registered kernels: every market's kernel is registered at deployment
    function _syncerInitData(address _accessManager) internal pure returns (bytes memory) {
        return abi.encodeCall(RoycoMarketSyncer.initialize, (_accessManager, new address[](0)));
    }

    function _deployPeripherySingletons(AccessManager _accessManager, address _factory) internal returns (address entryPoint, address marketSyncer) {
        // Deploy the entry point implementation + proxy, initialized with no tranche configs.
        (address entryPointImpl, bool entryPointImplExisted) = deployWithSanityChecks(
            _singletonSalt("ROYCO_DAY_ENTRY_POINT_IMPLEMENTATION"), abi.encodePacked(type(RoycoDayEntryPoint).creationCode, abi.encode(_factory)), false
        );
        _logDeploy("EntryPoint (impl)  ", entryPointImpl, entryPointImplExisted);
        bool entryPointExisted;
        (entryPoint, entryPointExisted) =
            deployWithSanityChecks(_singletonSalt("ROYCO_DAY_ENTRY_POINT_PROXY"), getERC1967ProxyCreationCode(entryPointImpl, _entryPointInitData()), false);
        _logDeploy("EntryPoint (proxy) ", entryPoint, entryPointExisted);

        // Deploy the market syncer implementation + proxy, initialized with no registered kernels.
        (address syncerImpl, bool syncerImplExisted) =
            deployWithSanityChecks(_singletonSalt("ROYCO_MARKET_SYNCER_IMPLEMENTATION"), type(RoycoMarketSyncer).creationCode, false);
        _logDeploy("MarketSyncer (impl)", syncerImpl, syncerImplExisted);
        bool syncerExisted;
        (marketSyncer, syncerExisted) = deployWithSanityChecks(
            _singletonSalt("ROYCO_MARKET_SYNCER_PROXY"), getERC1967ProxyCreationCode(syncerImpl, _syncerInitData(address(_accessManager))), false
        );
        _logDeploy("MarketSyncer (proxy)", marketSyncer, syncerExisted);

        // Wire each singleton's full role surface on first deployment. Runs before the role graph re-points any
        // role admins, so the LP role grants below can be made by the deployer (ADMIN_ROLE).
        if (!entryPointExisted) _wireEntryPointRoles(_accessManager, entryPoint);
        if (!syncerExisted) _wireSyncerRoles(_accessManager, marketSyncer);
    }

    /// @notice Binds the entry point's selectors to their roles and grants it the tranche LP roles.
    /// @dev Mirrors the production access model: LP request/execute/cancel selectors are public (user compliance is
    ///      enforced by the tranches), config is ADMIN_ENTRY_POINT_ROLE-gated (held by the factory + admin multisig),
    ///      fee collection has its own role, and pause/unpause/upgrade follow the protocol-wide roles.
    /// @dev The array executors carry no `restricted` of their own: they self-delegatecall into `executeDeposit` and
    ///      `executeRedemption`, so the bindings on those two selectors govern every batched request against the real
    ///      caller. Binding the array selectors here would gate nothing.
    function _wireEntryPointRoles(AccessManager _accessManager, address _entryPoint) internal {
        bytes4[] memory lpSelectors = new bytes4[](9);
        lpSelectors[0] = IRoycoDayEntryPoint.requestDeposit.selector;
        lpSelectors[1] = IRoycoDayEntryPoint.executeDeposit.selector;
        lpSelectors[2] = IRoycoDayEntryPoint.cancelDepositRequest.selector;
        lpSelectors[3] = IRoycoDayEntryPoint.cancelDepositRequests.selector;
        lpSelectors[4] = IRoycoDayEntryPoint.requestRedemption.selector;
        lpSelectors[5] = IRoycoDayEntryPoint.executeRedemption.selector;
        lpSelectors[6] = IRoycoDayEntryPoint.cancelRedemptionRequest.selector;
        lpSelectors[7] = IRoycoDayEntryPoint.cancelRedemptionRequests.selector;
        lpSelectors[8] = IRoycoDayEntryPoint.pokeCollateralAssetOracle.selector;
        _accessManager.setTargetFunctionRole(_entryPoint, lpSelectors, PUBLIC_ROLE);

        _accessManager.setTargetFunctionRole(_entryPoint, _sel(IRoycoDayEntryPoint.modifyTrancheConfigs.selector), ADMIN_ENTRY_POINT_ROLE);
        _accessManager.setTargetFunctionRole(_entryPoint, _sel(IRoycoDayEntryPoint.collectProtocolFees.selector), ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE);
        _accessManager.setTargetFunctionRole(_entryPoint, _sel(IRoycoAuth.pause.selector), ADMIN_PAUSER_ROLE);
        _accessManager.setTargetFunctionRole(_entryPoint, _sel(IRoycoAuth.unpause.selector), ADMIN_UNPAUSER_ROLE);
        _accessManager.setTargetFunctionRole(_entryPoint, _sel(UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE);

        // The entry point itself needs the LP roles to call tranche.deposit/redeem on behalf of its users.
        // MUST run while the LP roles' admin is still ADMIN_ROLE (the deployer).
        _accessManager.grantRole(ST_LP_ROLE, _entryPoint, 0);
        _accessManager.grantRole(JT_LP_ROLE, _entryPoint, 0);
        _accessManager.grantRole(LPT_LP_ROLE, _entryPoint, 0);

        // The entry point syncs each market before it acts on it. Granted here rather than per market deployment: the
        // role is market-agnostic and the entry point is an existing singleton, which a deployment may never touch.
        _accessManager.grantRole(SYNC_ROLE, _entryPoint, 0);
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
        (address implAddr, bool implExisted) =
            deployWithSanityChecks(_singletonSalt("ROYCO_BLACKLIST_IMPLEMENTATION"), type(RoycoBlacklist).creationCode, false);
        _logDeploy("Blacklist (impl)   ", implAddr, implExisted);
        address[] memory initialBlacklistedAccounts = new address[](0);
        bytes memory initData = abi.encodeCall(RoycoBlacklist.initialize, (_authority, address(0), initialBlacklistedAccounts));
        bool blacklistExisted;
        (blacklist, blacklistExisted) = deployWithSanityChecks(_singletonSalt("ROYCO_BLACKLIST_PROXY"), getERC1967ProxyCreationCode(implAddr, initData), false);
        _logDeploy("Blacklist (proxy)  ", blacklist, blacklistExisted);
    }
}
