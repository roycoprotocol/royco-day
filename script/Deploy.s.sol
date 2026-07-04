// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { GyroECLPPoolFactory } from "../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { AccessManager } from "../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { RoycoDayAccountant } from "../src/accountant/RoycoDayAccountant.sol";
import { RoycoBlacklist } from "../src/auth/RoycoBlacklist.sol";
import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_FACTORY_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_ORACLE_QUOTER_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_ROLE,
    ADMIN_UPGRADER_ROLE,
    DEPLOYER_ROLE,
    DEPLOYER_ROLE_ADMIN_ROLE,
    GUARDIAN_ROLE,
    JT_LP_ROLE,
    LP_ROLE_ADMIN_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE
} from "../src/factory/RolesConfiguration.sol";
import { RoycoFactory } from "../src/factory/RoycoFactory.sol";
import { BalancerV3DeploymentTemplate } from "../src/factory/templates/BalancerV3DeploymentTemplate.sol";
import { DayIdenticalERC4626ChainlinkDeploymentTemplate } from "../src/factory/templates/DayIdenticalERC4626ChainlinkDeploymentTemplate.sol";
import { BaseDeploymentTemplate } from "../src/factory/templates/base/BaseDeploymentTemplate.sol";
import {
    COMPONENT_ID_ACCOUNTANT_IMPL,
    COMPONENT_ID_DAY_KERNEL_IDENTICAL_ERC4626_CHAINLINK,
    COMPONENT_ID_JUNIOR_TRANCHE_IMPL,
    COMPONENT_ID_LIQUIDITY_TRANCHE_IMPL,
    COMPONENT_ID_SENIOR_TRANCHE_IMPL,
    COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2
} from "../src/factory/templates/base/Components.sol";
import { IRoycoDayAccountant } from "../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../src/interfaces/IYDM.sol";
import { IRoycoFactory } from "../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Kernel
} from "../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Kernel.sol";
import {
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "../src/kernels/base/quoter/identical-st-jt/IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
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

    // CREATE2 salts for the singletons (AccessManager + factory) so reruns within a test reuse them.
    bytes32 constant ACCESS_MANAGER_SALT = keccak256("ROYCO_ACCESS_MANAGER_V2");
    bytes32 constant FACTORY_IMPL_SALT = keccak256("ROYCO_FACTORY_IMPLEMENTATION_V2");
    bytes32 constant FACTORY_PROXY_SALT = keccak256("ROYCO_FACTORY_PROXY_V2");
    bytes32 constant BLACKLIST_IMPL_SALT = keccak256("ROYCO_BLACKLIST_IMPLEMENTATION_V2");
    bytes32 constant BLACKLIST_PROXY_SALT = keccak256("ROYCO_BLACKLIST_PROXY_V2");

    bool ENABLE_LOGGING = false;

    /// @dev Per-DeployScript-instance cache of registered templates, keyed by kernel type.
    mapping(uint256 kernelType => address template) internal kernelTypeToTemplate;

    /// @notice Enum for the Day kernel types this script can deploy.
    /// @dev The Dawn-era kernel zoo was removed in the Day fork. New Day kernels are added here as they ship.
    enum KernelType {
        Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Kernel
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

    // ─── Legacy kernel-specific param structs (kept: tests encode against these; the template KernelParams are field-identical) ───

    struct IdleAACdoSTCdoJTKernelParams {
        address idleCDO;
    }

    struct ReUSDSTReUSDJTKernelParams {
        address reusd;
        address reusdUsdQuoteToken;
        address insuranceCapitalLayer;
    }

    struct IdenticalMakinaSTMakinaJTKernelParams {
        address makinaMachine;
        uint256 initialConversionRateWAD;
    }

    struct IdenticalAssets_ST_JT_ChainlinkToAdminOracle_QuoterKernelParams {
        uint256 initialConversionRateWAD;
        address trancheAssetToReferenceAssetOracle;
        uint48 stalenessThresholdSeconds;
    }

    struct IdenticalERC4626Shares_ST_JT_SharePriceToAdminOracle_QuoterKernelParams {
        uint256 initialConversionRateWAD;
    }

    struct IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_QuoterKernelParams {
        IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams stAndJTQuoterParams;
        BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams ltQuoterParams;
    }

    struct IdenticalAssets_ST_JT_AdminOracle_QuoterKernelParams {
        uint256 initialConversionRateWAD;
    }

    struct LockedIUSDKernelParams {
        address infiniFiGateway;
        uint32 unwindingEpochs;
        uint256 initialConversionRateWAD;
        address iUSDToNavAssetOracle;
        uint48 stalenessThresholdSeconds;
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
        uint64 maxAdaptationSpeedWAD;
    }

    /// @notice Complete deployment result. `accessManager` is new (the factory's separate AM).
    struct DeploymentResult {
        RoycoFactory factory;
        AccessManager accessManager;
        RoycoDayAccountant accountantImplementation;
        RoycoSeniorTranche stTrancheImplementation;
        RoycoJuniorTranche jtTrancheImplementation;
        address kernelImplementation;
        IYDM ydm;
        IRoycoVaultTranche seniorTranche;
        IRoycoVaultTranche juniorTranche;
        IRoycoDayAccountant accountant;
        IRoycoDayKernel kernel;
        address roycoBlacklist;
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
                protocolFeeRecipientAddress: chainConfig.protocolFeeRecipient
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
        (AccessManager accessManager, RoycoFactory factory) = _deployAccessManagerAndFactory(deployer, _factoryAdmin, _roleAssignments);

        // 2. Deploy (or reuse) the chain's shared blacklist (governed by the AccessManager, not the factory).
        address roycoBlacklist = _deployBlacklist(address(accessManager));

        // 3. Register (or reuse) the Day template for this kernel type.
        address template = _getOrRegisterTemplate(factory, _config.kernelType);

        // 4. Deploy the market via the template.
        bytes32 marketId = keccak256(abi.encodePacked(_config.seniorTrancheName, _config.juniorTrancheName, block.timestamp, block.chainid));
        BalancerV3DeploymentTemplate.DayParams memory params = _buildDayParams(_config, marketId, _protocolFeeRecipient, roycoBlacklist);
        IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(template, abi.encode(params));

        vm.stopBroadcast();

        return DeploymentResult({
            factory: factory,
            accessManager: accessManager,
            accountantImplementation: RoycoDayAccountant(_predictImpl(factory, marketId, "ACCOUNTANT_IMPL")),
            stTrancheImplementation: RoycoSeniorTranche(_predictImpl(factory, marketId, "ST_IMPL")),
            jtTrancheImplementation: RoycoJuniorTranche(_predictImpl(factory, marketId, "JT_IMPL")),
            kernelImplementation: _predictImpl(factory, marketId, "KERNEL_IMPL"),
            ydm: IYDM(r.ydm),
            seniorTranche: IRoycoVaultTranche(r.seniorTranche),
            juniorTranche: IRoycoVaultTranche(r.juniorTranche),
            accountant: IRoycoDayAccountant(r.accountant),
            kernel: IRoycoDayKernel(r.kernel),
            roycoBlacklist: roycoBlacklist
        });
    }

    /// @notice Builds the role assignments applied to the AccessManager (surface-compatible with the legacy helper).
    function generateRolesAssignments(RoleAssignmentAddresses memory _addresses) public pure returns (RoleAssignment[] memory roleAssignments) {
        roleAssignments = new RoleAssignment[](13);
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
        revert UNKNOWN_ROLE(role);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: ACCESS MANAGER + FACTORY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys (or reuses) the standalone AccessManager + the template-driven factory, and wires the role graph.
    function _deployAccessManagerAndFactory(
        address _deployer,
        address _factoryAdmin,
        RoleAssignment[] memory _roleAssignments
    )
        internal
        returns (AccessManager accessManager, RoycoFactory factory)
    {
        // Deploy the AccessManager with the deployer as the initial admin so it can wire roles during this broadcast.
        (address amAddr, bool amExisted) =
            deployWithSanityChecks(ACCESS_MANAGER_SALT, abi.encodePacked(type(AccessManager).creationCode, abi.encode(_deployer)), false);
        accessManager = AccessManager(amAddr);

        // Predict the factory proxy address so we can grant it ADMIN_ROLE before its constructor runs `initialize`.
        (address factoryImpl,) = deployWithSanityChecks(FACTORY_IMPL_SALT, type(RoycoFactory).creationCode, false);
        bytes memory factoryProxyCreationCode = getERC1967ProxyCreationCode(factoryImpl, abi.encodeCall(RoycoFactory.initialize, (amAddr)));
        address predictedFactory = generateDeterminsticAddress(FACTORY_PROXY_SALT, factoryProxyCreationCode);

        // The factory's `initialize` (run in the proxy ctor) requires it to already hold ADMIN_ROLE on the AM.
        if (!amExisted) accessManager.grantRole(ADMIN_ROLE, predictedFactory, 0);

        (address factoryProxy,) = deployWithSanityChecks(FACTORY_PROXY_SALT, factoryProxyCreationCode, false);
        require(factoryProxy == predictedFactory, "factory address mismatch");
        factory = RoycoFactory(factoryProxy);

        // Wire the role graph + assignments on the AM.
        if (!amExisted) _applyRoleGraph(accessManager, _factoryAdmin, _deployer, _roleAssignments);
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
    function _getOrRegisterTemplate(RoycoFactory _factory, KernelType _kernelType) internal returns (address template) {
        template = kernelTypeToTemplate[uint256(_kernelType)];
        if (template != address(0)) return template;

        IRoycoFactory factoryIface = IRoycoFactory(address(_factory));
        bytes32 kernelComponentId;
        bytes memory kernelCreationCode;
        (template, kernelComponentId, kernelCreationCode) = _deployTemplate(factoryIface, _kernelType);

        bytes32[] memory ids = new bytes32[](6);
        bytes[] memory codes = new bytes[](6);
        ids[0] = COMPONENT_ID_SENIOR_TRANCHE_IMPL;
        codes[0] = type(RoycoSeniorTranche).creationCode;
        ids[1] = COMPONENT_ID_JUNIOR_TRANCHE_IMPL;
        codes[1] = type(RoycoJuniorTranche).creationCode;
        ids[2] = COMPONENT_ID_LIQUIDITY_TRANCHE_IMPL;
        codes[2] = type(RoycoLiquidityTranche).creationCode;
        ids[3] = COMPONENT_ID_ACCOUNTANT_IMPL;
        codes[3] = type(RoycoDayAccountant).creationCode;
        ids[4] = COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2;
        // The template deploys the YDM singleton verbatim (no ctor args appended), so bake the target-utilization
        // (JT coverage kink at 90%) constructor arg into the registered creation code.
        codes[4] = abi.encodePacked(type(AdaptiveCurveYDM_V2).creationCode, abi.encode(uint256(0.9e18)));
        ids[5] = kernelComponentId;
        codes[5] = kernelCreationCode;

        _factory.registerTemplate(template, ids, codes);
        kernelTypeToTemplate[uint256(_kernelType)] = template;
    }

    /// @notice Deploys the concrete Day template for a kernel type and returns its kernel component id + creation code.
    function _deployTemplate(
        IRoycoFactory _factory,
        KernelType _kernelType
    )
        internal
        returns (address template, bytes32 kernelComponentId, bytes memory kernelCreationCode)
    {
        // The concrete Balancer-V3 templates are constructed with the chain's Gyro E-CLP pool factory.
        GyroECLPPoolFactory poolFactory = GyroECLPPoolFactory(getChainConfig(block.chainid).gyroECLPPoolFactory);

        if (_kernelType == KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Kernel) {
            return (
                address(new DayIdenticalERC4626ChainlinkDeploymentTemplate(_factory, poolFactory)),
                COMPONENT_ID_DAY_KERNEL_IDENTICAL_ERC4626_CHAINLINK,
                type(Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_LT_Kernel).creationCode
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
        returns (BalancerV3DeploymentTemplate.DayParams memory params)
    {
        params.marketId = _marketId;
        params.st =
            BaseDeploymentTemplate.SeniorTrancheParams({ name: _config.seniorTrancheName, symbol: _config.seniorTrancheSymbol, asset: _config.seniorAsset });
        params.jt =
            BaseDeploymentTemplate.JuniorTrancheParams({ name: _config.juniorTrancheName, symbol: _config.juniorTrancheSymbol, asset: _config.juniorAsset });
        params.accountant = BaseDeploymentTemplate.AccountantParams({
            stProtocolFeeWAD: _config.stProtocolFeeWAD,
            jtProtocolFeeWAD: _config.jtProtocolFeeWAD,
            yieldShareProtocolFeeWAD: _config.jtYieldShareProtocolFeeWAD,
            coverageWAD: _config.minCoverageWAD,
            jtCoinvested: _config.jtCoinvested,
            liquidationUtilizationWAD: _config.coverageLiquidationUtilizationWAD,
            fixedTermDurationSeconds: _config.fixedTermDurationSeconds,
            stNAVDustTolerance: toNAVUnits(_config.stDustTolerance),
            jtNAVDustTolerance: toNAVUnits(_config.jtDustTolerance),
            ydmInitializationData: _buildYDMInitializationData(_config.ydmType, _config.ydmSpecificParams)
        });
        // Liquidity tranche (holds the Gyro E-CLP BPT) and the pool params it is created against.
        params.lt = BalancerV3DeploymentTemplate.LiquidityTrancheParams({ name: _config.liquidityTrancheName, symbol: _config.liquidityTrancheSymbol });
        params.gyroECLPPoolParams = _config.gyroECLPPoolParams;
        // The JT YDM and a distinct LT YDM (the LDM placeholder). Same registered creation code, distinct `version`
        // so they resolve to different addresses and satisfy the accountant's `YDMS_CANNOT_BE_IDENTICAL` guard.
        params.ydm = BaseDeploymentTemplate.YDMParams({ componentTag: bytes32("YDM_ADAPTIVE_CURVE_V2"), version: bytes32("V1") });
        params.ltYdm = BaseDeploymentTemplate.YDMParams({ componentTag: bytes32("YDM_ADAPTIVE_CURVE_V2"), version: bytes32("LT_V1") });
        params.kernelSpecificParams = _config.kernelSpecificParams; // template KernelParams are field-identical to the config blobs
        params.protocolFeeRecipient = _protocolFeeRecipient;
        params.stSelfLiquidationBonusWAD = _config.stSelfLiquidationBonusWAD;
        params.roycoBlacklist = _roycoBlacklist;
        params.enforceVaultSharesTransferWhitelist = _config.enforceVaultSharesTransferWhitelist;
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
                (ydmParams.yieldShareAtZeroUtilWAD, ydmParams.yieldShareAtTargetUtilWAD, ydmParams.yieldShareAtFullUtilWAD, ydmParams.maxAdaptationSpeedWAD)
            );
        } else {
            revert UnsupportedYDMType(_ydmType);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL: BLACKLIST + HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys (or returns) the chain's shared RoycoBlacklist via CREATE2.
    /// @param _authority The AccessManager that governs the blacklist's restricted functions.
    function _deployBlacklist(address _authority) internal returns (address blacklist) {
        (address implAddr,) = deployWithSanityChecks(BLACKLIST_IMPL_SALT, type(RoycoBlacklist).creationCode, false);
        address[] memory initialBlacklistedAccounts = new address[](0);
        bytes memory initData = abi.encodeCall(RoycoBlacklist.initialize, (_authority, address(0), initialBlacklistedAccounts));
        (blacklist,) = deployWithSanityChecks(BLACKLIST_PROXY_SALT, getERC1967ProxyCreationCode(implAddr, initData), false);
    }

    /// @notice Predicts a market component implementation address from the template's `_marketComponentSalt` scheme.
    function _predictImpl(RoycoFactory _factory, bytes32 _marketId, bytes32 _componentTag) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked("ROYCO_MARKET_", _marketId, _componentTag));
        return _factory.predictDeterministicAddress(salt);
    }
}
