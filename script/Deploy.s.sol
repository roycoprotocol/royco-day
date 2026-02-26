// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManager } from "../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { UUPSUpgradeable } from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import { RoycoAccountant } from "../src/accountant/RoycoAccountant.sol";
import { RolesConfiguration, RoycoFactory } from "../src/factory/RoycoFactory.sol";
import { IRoycoAccountant } from "../src/interfaces/IRoycoAccountant.sol";
import { IRoycoAuth } from "../src/interfaces/IRoycoAuth.sol";
import { IRoycoFactory } from "../src/interfaces/IRoycoFactory.sol";
import { IRoycoKernel } from "../src/interfaces/IRoycoKernel.sol";
import { IYDM } from "../src/interfaces/IYDM.sol";
import { IRoycoVaultTranche } from "../src/interfaces/tranche/IRoycoVaultTranche.sol";
import { IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel } from "../src/kernels/IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel.sol";
import { IdenticalERC4626SharesAdminOracleQuoter_Kernel } from "../src/kernels/IdenticalERC4626SharesAdminOracleQuoter_Kernel.sol";
import { IdleCdoAA_ST_IdleCdoAA_JT_Kernel } from "../src/kernels/IdleCdoAA_ST_IdleCdoAA_JT_Kernel.sol";
import { ReUSD_ST_ReUSD_JT_Kernel } from "../src/kernels/ReUSD_ST_ReUSD_JT_Kernel.sol";
import { IdenticalAssetsChainlinkOracleQuoter } from "../src/kernels/base/quoter/base/IdenticalAssetsChainlinkOracleQuoter.sol";
import { IdenticalAssetsOracleQuoter } from "../src/kernels/base/quoter/base/IdenticalAssetsOracleQuoter.sol";
import { NAV_UNIT, toNAVUnits } from "../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../src/tranches/RoycoJuniorTranche.sol";
import { RoycoSeniorTranche } from "../src/tranches/RoycoSeniorTranche.sol";
import { AdaptiveCurveYDM_V1 } from "../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../src/ydm/AdaptiveCurveYDM_V2.sol";
import { StaticCurveYDM } from "../src/ydm/StaticCurveYDM.sol";
import { DeploymentConfig } from "./config/DeploymentConfig.sol";
import { Create2DeployUtils } from "./utils/Create2DeployUtils.sol";
import { Script } from "lib/forge-std/src/Script.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/// @notice Interface for kernel oracle quoter admin functions
interface IKernelOracleQuoterAdmin {
    function setConversionRate(uint256 _conversionRateWAD) external;
    function setTrancheAssetToReferenceAssetOracle(address _trancheAssetToReferenceAssetOracle, uint48 _stalenessThresholdSeconds) external;
}

contract DeployScript is Script, Create2DeployUtils, RolesConfiguration, DeploymentConfig {
    // Custom errors
    error UnsupportedKernelType(KernelType kernelType);
    error UnsupportedYDMType(YDMType ydmType);
    error DeployerNotFactoryAdmin(address deployer);
    error RoleAssignmentAdminRoleNotFound(uint64 role);
    error RoleAssignmentAssigneeAddressIsZero(address assignee);

    // Deployment salts for CREATE2
    bytes32 constant ACCOUNTANT_IMPL_SALT = keccak256("ROYCO_ACCOUNTANT_IMPLEMENTATION_V2");
    bytes32 constant KERNEL_IMPL_SALT = keccak256("ROYCO_KERNEL_IMPLEMENTATION_V2");
    bytes32 constant ST_TRANCHE_IMPL_SALT = keccak256("ROYCO_ST_TRANCHE_IMPLEMENTATION_V2");
    bytes32 constant JT_TRANCHE_IMPL_SALT = keccak256("ROYCO_JT_TRANCHE_IMPLEMENTATION_V2");
    bytes32 constant YDM_SALT = keccak256("ROYCO_YDM_IMPLEMENTATION_V2");
    bytes32 constant FACTORY_SALT_BASE = keccak256("ROYCO_FACTORY_IMPLEMENTATION_V2");
    bytes32 constant MARKET_DEPLOYMENT_SALT = keccak256("ROYCO_MARKET_DEPLOYMENT_V2");

    /// @notice Enum for kernel types
    enum KernelType {
        ReUSD_ST_ReUSD_JT,
        IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel,
        IdenticalERC4626SharesAdminOracleQuoter_Kernel,
        IdleCdoAA_ST_IdleCdoAA_JT
    }

    /// @notice Enum for YDM types
    enum YDMType {
        StaticCurve,
        AdaptiveCurve_V1,
        AdaptiveCurve_V2
    }

    /// @notice Deployment parameters for ReUSD_ST_ReUSD_JT_Kernel
    struct ReUSDSTReUSDJTKernelParams {
        address reusd;
        address reusdUsdQuoteToken;
        address insuranceCapitalLayer;
    }

    /// @notice Deployment parameters for IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel
    struct IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams {
        address trancheAssetToReferenceAssetOracle;
        uint48 stalenessThresholdSeconds;
        uint256 initialConversionRateWAD;
    }

    /// @notice Deployment parameters for IdenticalERC4626SharesAdminOracleQuoter_Kernel
    struct IdenticalERC4626SharesAdminOracleQuoterKernelParams {
        uint256 initialConversionRateWAD;
    }

    /// @notice Deployment parameters for IdleCdoAA_ST_IdleCdoAA_JT_Kernel
    struct IdleCdoAASTIdleCdoAAJTKernelParams {
        address idleCDO;
    }

    /// @notice Deployment parameters for StaticCurveYDM
    struct StaticCurveYDMParams {
        uint64 jtYieldShareAtZeroUtilWAD;
        uint64 jtYieldShareAtTargetUtilWAD;
        uint64 jtYieldShareAtFullUtilWAD;
    }

    /// @notice Deployment parameters for AdaptiveCurveYDM_V1
    struct AdaptiveCurveYDM_V1_Params {
        uint64 jtYieldShareAtTargetUtilWAD;
        uint64 jtYieldShareAtFullUtilWAD;
    }

    /// @notice Deployment parameters for AdaptiveCurveYDM_V2
    struct AdaptiveCurveYDM_V2_Params {
        uint64 jtYieldShareAtZeroUtilWAD;
        uint64 jtYieldShareAtTargetUtilWAD;
        uint64 jtYieldShareAtFullUtilWAD;
        uint64 maxAdaptationSpeedWAD;
    }

    /// @notice Complete deployment result containing all deployed contracts
    struct DeploymentResult {
        RoycoFactory factory;
        RoycoAccountant accountantImplementation;
        RoycoSeniorTranche stTrancheImplementation;
        RoycoJuniorTranche jtTrancheImplementation;
        address kernelImplementation;
        IYDM ydm;
        IRoycoVaultTranche seniorTranche;
        IRoycoVaultTranche juniorTranche;
        IRoycoAccountant accountant;
        IRoycoKernel kernel;
        bytes32 marketId;
    }

    /// @notice Addresses for role assignments
    struct RoleAssignmentAddresses {
        address pauserAddress;
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
    }

    /// @notice Configuration for assigning a role to an address
    struct RoleAssignmentConfiguration {
        uint64 role; // The role to assign
        uint64 roleAdminRole; // The admin role that can assign the role, 0 if none
        address assignee; // The address to assign the role to
        uint32 executionDelay; // The delay after which the role can be assigned
    }

    /// @notice Main deployment parameters struct
    struct DeploymentParams {
        // Factory params
        address factoryAdmin;
        // Market params
        bytes32 marketId;
        string seniorTrancheName;
        string seniorTrancheSymbol;
        string juniorTrancheName;
        string juniorTrancheSymbol;
        address seniorAsset;
        address juniorAsset;
        NAV_UNIT stNAVDustTolerance;
        NAV_UNIT jtNAVDustTolerance;
        // Kernel params
        KernelType kernelType;
        bytes kernelSpecificParams; // Encoded kernel-specific params
        // Kernel initialization params
        address protocolFeeRecipient;
        // Accountant params
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 coverageWAD;
        uint96 betaWAD;
        uint64 lltvWAD;
        uint24 fixedTermDurationSeconds;
        // YDM params
        YDMType ydmType;
        bytes ydmSpecificParams; // Encoded YDM-specific params
        // Roles
        RoleAssignmentConfiguration[] roleAssignments;
    }

    function run() external virtual {
        // Read deployer private key
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Read market name from config
        string memory marketName = vm.envString("MARKET_NAME");

        console2.log("Deploying market from config:", marketName);
        deployFromConfig(marketName, deployerPrivateKey);
    }

    /// @notice Deploy a market using Solidity configuration
    /// @param marketName The name of the market to deploy (must match a config in DeploymentConfig)
    /// @param deployerPrivateKey The private key of the deployer
    /// @return result The deployment result containing all deployed contract addresses
    function deployFromConfig(string memory marketName, uint256 deployerPrivateKey) public returns (DeploymentResult memory) {
        ChainConfig memory chainConfig = getChainConfig(block.chainid);
        MarketDeploymentConfig memory marketConfig = getMarketConfig(marketName);

        // Build role assignments from chain config
        RoleAssignmentConfiguration[] memory roleAssignments = generateRolesAssignments(
            RoleAssignmentAddresses({
                pauserAddress: chainConfig.pauserAddress,
                upgraderAddress: chainConfig.upgraderAddress,
                syncRoleAddress: chainConfig.syncRoleAddress,
                adminKernelAddress: chainConfig.adminKernelAddress,
                adminAccountantAddress: chainConfig.adminAccountantAddress,
                adminProtocolFeeSetterAddress: chainConfig.adminProtocolFeeSetterAddress,
                adminOracleQuoterAddress: chainConfig.adminOracleQuoterAddress,
                lpRoleAdminAddress: chainConfig.lpRoleAdminAddress,
                guardianAddress: chainConfig.guardianAddress,
                deployerAddress: chainConfig.deployerAddress,
                deployerAdminAddress: chainConfig.deployerAdminAddress
            })
        );

        // Build DeploymentParams
        DeploymentParams memory params = DeploymentParams({
            factoryAdmin: chainConfig.factoryAdmin,
            marketId: keccak256(abi.encodePacked(marketConfig.marketName, "-", block.timestamp)),
            seniorTrancheName: marketConfig.seniorTrancheName,
            seniorTrancheSymbol: marketConfig.seniorTrancheSymbol,
            juniorTrancheName: marketConfig.juniorTrancheName,
            juniorTrancheSymbol: marketConfig.juniorTrancheSymbol,
            seniorAsset: marketConfig.seniorAsset,
            juniorAsset: marketConfig.juniorAsset,
            stNAVDustTolerance: toNAVUnits(marketConfig.stDustTolerance),
            jtNAVDustTolerance: toNAVUnits(marketConfig.jtDustTolerance),
            kernelType: marketConfig.kernelType,
            kernelSpecificParams: marketConfig.kernelSpecificParams,
            protocolFeeRecipient: chainConfig.protocolFeeRecipient,
            stProtocolFeeWAD: marketConfig.stProtocolFeeWAD,
            jtProtocolFeeWAD: marketConfig.jtProtocolFeeWAD,
            coverageWAD: marketConfig.coverageWAD,
            betaWAD: marketConfig.betaWAD,
            lltvWAD: marketConfig.lltvWAD,
            fixedTermDurationSeconds: marketConfig.fixedTermDurationSeconds,
            ydmType: marketConfig.ydmType,
            ydmSpecificParams: marketConfig.ydmSpecificParams,
            roleAssignments: roleAssignments
        });

        // Print all deployment parameters before deployment
        _printDeploymentParams(params, chainConfig);

        return deploy(params, deployerPrivateKey);
    }

    /// @notice Prints all deployment parameters for verification before deployment
    function _printDeploymentParams(DeploymentParams memory params, ChainConfig memory chainConfig) internal view {
        console2.log("=== DEPLOYMENT PARAMETERS ===");
        console2.log("");

        // Chain & Market Info
        console2.log("--- Chain & Market Info ---");
        console2.log("Chain ID:", block.chainid);
        console2.log("Market ID:");
        console2.logBytes32(params.marketId);
        console2.log("");

        // Factory Config
        console2.log("--- Factory Config ---");
        console2.log("Factory Admin:", params.factoryAdmin);
        console2.log("Protocol Fee Recipient:", params.protocolFeeRecipient);
        console2.log("");

        // Tranche Metadata
        console2.log("--- Tranche Metadata ---");
        console2.log("Senior Tranche Name:", params.seniorTrancheName);
        console2.log("Senior Tranche Symbol:", params.seniorTrancheSymbol);
        console2.log("Junior Tranche Name:", params.juniorTrancheName);
        console2.log("Junior Tranche Symbol:", params.juniorTrancheSymbol);
        console2.log("");

        // Assets
        console2.log("--- Assets ---");
        console2.log("Senior Asset:", params.seniorAsset);
        console2.log("Junior Asset:", params.juniorAsset);
        console2.log("ST Dust Tolerance (NAV):", NAV_UNIT.unwrap(params.stNAVDustTolerance));
        console2.log("JT Dust Tolerance (NAV):", NAV_UNIT.unwrap(params.jtNAVDustTolerance));
        console2.log("");

        // Kernel Config
        console2.log("--- Kernel Config ---");
        console2.log("Kernel Type:", uint256(params.kernelType));
        console2.log("");

        // Accountant Config
        console2.log("--- Accountant Config ---");
        console2.log("ST Protocol Fee (WAD):", uint256(params.stProtocolFeeWAD));
        console2.log("JT Protocol Fee (WAD):", uint256(params.jtProtocolFeeWAD));
        console2.log("Coverage (WAD):", uint256(params.coverageWAD));
        console2.log("Beta (WAD):", uint256(params.betaWAD));
        console2.log("LLTV (WAD):", uint256(params.lltvWAD));
        console2.log("Fixed Term Duration (seconds):", uint256(params.fixedTermDurationSeconds));
        console2.log("");

        // YDM Config
        console2.log("--- YDM Config ---");
        console2.log("YDM Type:", uint256(params.ydmType));
        console2.log("");

        // Role Assignments
        console2.log("--- Role Assignments ---");
        console2.log("Pauser:", chainConfig.pauserAddress);
        console2.log("Upgrader:", chainConfig.upgraderAddress);
        console2.log("Sync Role:", chainConfig.syncRoleAddress);
        console2.log("Admin Kernel:", chainConfig.adminKernelAddress);
        console2.log("Admin Accountant:", chainConfig.adminAccountantAddress);
        console2.log("Admin Protocol Fee Setter:", chainConfig.adminProtocolFeeSetterAddress);
        console2.log("Admin Oracle Quoter:", chainConfig.adminOracleQuoterAddress);
        console2.log("LP Role Admin:", chainConfig.lpRoleAdminAddress);
        console2.log("Guardian:", chainConfig.guardianAddress);
        console2.log("Deployer:", chainConfig.deployerAddress);
        console2.log("Deployer Admin:", chainConfig.deployerAdminAddress);
        console2.log("");

        console2.log("=============================");
        console2.log("");
    }

    /// @notice Main deployment function that accepts all parameters
    function deploy(DeploymentParams memory _params, uint256 _deployerPrivateKey) public returns (DeploymentResult memory) {
        vm.startBroadcast(_deployerPrivateKey);
        address deployer = vm.addr(_deployerPrivateKey);

        // Deploy implementations using CREATE2
        IYDM ydm = _deployYDM(_params.ydmType);

        // Deploy factory with deployer as admin and deployer as deployer
        RoycoFactory factory = _deployFactory(deployer, deployer);

        // Deploy all implementations. Then deploy the market using the factory
        (
            IRoycoFactory.RoycoMarket memory market,
            RoycoSeniorTranche stTrancheImpl,
            RoycoJuniorTranche jtTrancheImpl,
            address kernelImpl,
            RoycoAccountant accountantImpl
        ) = _deployMarket(factory, address(ydm), _params, deployer);

        // Transfer factory ownership to factory admin
        _transferFactoryOwnership(factory, deployer, _params.factoryAdmin);

        // Build deployment result
        DeploymentResult memory result = DeploymentResult({
            factory: factory,
            accountantImplementation: accountantImpl,
            stTrancheImplementation: stTrancheImpl,
            jtTrancheImplementation: jtTrancheImpl,
            kernelImplementation: kernelImpl,
            ydm: ydm,
            seniorTranche: market.seniorTranche,
            juniorTranche: market.juniorTranche,
            accountant: market.accountant,
            kernel: market.kernel,
            marketId: _params.marketId
        });

        // Log all deployed contracts
        console2.log("=== Deployment Summary ===");
        console2.log("Factory:", address(result.factory));
        console2.log("Factory Admin:", _params.factoryAdmin);
        console2.log("YDM:", address(result.ydm));
        console2.log("Accountant Implementation:", address(result.accountantImplementation));
        console2.log("ST Tranche Implementation:", address(result.stTrancheImplementation));
        console2.log("JT Tranche Implementation:", address(result.jtTrancheImplementation));
        console2.log("Kernel Implementation:", result.kernelImplementation);
        console2.log("Senior Tranche (Proxy):", address(result.seniorTranche));
        console2.log("Junior Tranche (Proxy):", address(result.juniorTranche));
        console2.log("Accountant (Proxy):", address(result.accountant));
        console2.log("Kernel (Proxy):", address(result.kernel));
        console2.log("Market ID:", uint256(_params.marketId));
        console2.log("========================");

        vm.stopBroadcast();

        return result;
    }

    /// @notice Builds the roles configuration for a market
    /// @param _seniorTranche The senior tranche address
    /// @param _juniorTranche The junior tranche address
    /// @param _kernel The kernel address
    /// @param _accountant The accountant address
    /// @return roles The roles configuration array
    function buildRolesTargetConfiguration(
        address _seniorTranche,
        address _juniorTranche,
        address _kernel,
        address _accountant
    )
        public
        pure
        returns (IRoycoFactory.RolesTargetConfiguration[] memory roles)
    {
        // Count how many role configurations we need
        uint256 roleCount = 4; // ST, JT, Kernel, Accountant

        roles = new IRoycoFactory.RolesTargetConfiguration[](roleCount);
        uint256 index = 0;

        // Senior Tranche roles
        bytes4[] memory stSelectors = new bytes4[](5);
        uint64[] memory stRoles = new uint64[](5);

        stSelectors[0] = IRoycoVaultTranche.deposit.selector;
        stRoles[0] = ST_LP_ROLE;
        stSelectors[1] = IRoycoVaultTranche.redeem.selector;
        stRoles[1] = ST_LP_ROLE;
        stSelectors[2] = IRoycoAuth.pause.selector;
        stRoles[2] = ADMIN_PAUSER_ROLE;
        stSelectors[3] = IRoycoAuth.unpause.selector;
        stRoles[3] = ADMIN_PAUSER_ROLE;
        stSelectors[4] = UUPSUpgradeable.upgradeToAndCall.selector;
        stRoles[4] = ADMIN_UPGRADER_ROLE;

        roles[index++] = IRoycoFactory.RolesTargetConfiguration({ target: _seniorTranche, selectors: stSelectors, roles: stRoles });

        // Junior Tranche roles (same as senior)
        bytes4[] memory jtSelectors = new bytes4[](5);
        uint64[] memory jtRoles = new uint64[](5);

        jtSelectors[0] = IRoycoVaultTranche.deposit.selector;
        jtRoles[0] = JT_LP_ROLE;
        jtSelectors[1] = IRoycoVaultTranche.redeem.selector;
        jtRoles[1] = JT_LP_ROLE;
        jtSelectors[2] = IRoycoAuth.pause.selector;
        jtRoles[2] = ADMIN_PAUSER_ROLE;
        jtSelectors[3] = IRoycoAuth.unpause.selector;
        jtRoles[3] = ADMIN_PAUSER_ROLE;
        jtSelectors[4] = UUPSUpgradeable.upgradeToAndCall.selector;
        jtRoles[4] = ADMIN_UPGRADER_ROLE;

        roles[index++] = IRoycoFactory.RolesTargetConfiguration({ target: _juniorTranche, selectors: jtSelectors, roles: jtRoles });

        // Kernel roles
        bytes4[] memory kernelSelectors = new bytes4[](7);
        uint64[] memory kernelRoleValues = new uint64[](7);

        kernelSelectors[0] = IRoycoKernel.setProtocolFeeRecipient.selector;
        kernelRoleValues[0] = ADMIN_KERNEL_ROLE;
        kernelSelectors[1] = IRoycoAuth.pause.selector;
        kernelRoleValues[1] = ADMIN_PAUSER_ROLE;
        kernelSelectors[2] = IRoycoAuth.unpause.selector;
        kernelRoleValues[2] = ADMIN_PAUSER_ROLE;
        kernelSelectors[3] = IdenticalAssetsOracleQuoter.setConversionRate.selector;
        kernelRoleValues[3] = ADMIN_ORACLE_QUOTER_ROLE;
        kernelSelectors[4] = IdenticalAssetsChainlinkOracleQuoter.setTrancheAssetToReferenceAssetOracle.selector;
        kernelRoleValues[4] = ADMIN_ORACLE_QUOTER_ROLE;
        kernelSelectors[5] = UUPSUpgradeable.upgradeToAndCall.selector;
        kernelRoleValues[5] = ADMIN_UPGRADER_ROLE;
        kernelSelectors[6] = IRoycoKernel.syncTrancheAccounting.selector;
        kernelRoleValues[6] = SYNC_ROLE;

        roles[index++] = IRoycoFactory.RolesTargetConfiguration({ target: _kernel, selectors: kernelSelectors, roles: kernelRoleValues });

        // Accountant roles
        bytes4[] memory accountantSelectors = new bytes4[](11);
        uint64[] memory accountantRoleValues = new uint64[](11);

        accountantSelectors[0] = IRoycoAccountant.setYDM.selector;
        accountantRoleValues[0] = ADMIN_ACCOUNTANT_ROLE;
        accountantSelectors[1] = IRoycoAccountant.setSeniorTrancheProtocolFee.selector;
        accountantRoleValues[1] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        accountantSelectors[2] = IRoycoAccountant.setJuniorTrancheProtocolFee.selector;
        accountantRoleValues[2] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        accountantSelectors[3] = IRoycoAccountant.setCoverage.selector;
        accountantRoleValues[3] = ADMIN_ACCOUNTANT_ROLE;
        accountantSelectors[4] = IRoycoAccountant.setBeta.selector;
        accountantRoleValues[4] = ADMIN_ACCOUNTANT_ROLE;
        accountantSelectors[5] = IRoycoAccountant.setLLTV.selector;
        accountantRoleValues[5] = ADMIN_ACCOUNTANT_ROLE;
        accountantSelectors[6] = IRoycoAccountant.setFixedTermDuration.selector;
        accountantRoleValues[6] = ADMIN_ACCOUNTANT_ROLE;
        accountantSelectors[7] = IRoycoAuth.pause.selector;
        accountantRoleValues[7] = ADMIN_PAUSER_ROLE;
        accountantSelectors[8] = IRoycoAuth.unpause.selector;
        accountantRoleValues[8] = ADMIN_PAUSER_ROLE;
        accountantSelectors[9] = UUPSUpgradeable.upgradeToAndCall.selector;
        accountantRoleValues[9] = ADMIN_UPGRADER_ROLE;
        accountantSelectors[10] = IRoycoAccountant.setSeniorTrancheDustTolerance.selector;
        accountantRoleValues[10] = ADMIN_ACCOUNTANT_ROLE;

        roles[index++] = IRoycoFactory.RolesTargetConfiguration({ target: _accountant, selectors: accountantSelectors, roles: accountantRoleValues });
    }

    /// @notice Generates role assignments from addresses
    /// @dev ST_LP_ROLE and JT_LP_ROLE are included with assignee=address(0) so their admin roles get configured
    /// @param _addresses The addresses for role assignments
    function generateRolesAssignments(RoleAssignmentAddresses memory _addresses) public pure returns (RoleAssignmentConfiguration[] memory roleAssignments) {
        roleAssignments = new RoleAssignmentConfiguration[](13);

        // Get role configs from RolesConfiguration
        RoleConfig memory pauserConfig = getRoleConfig(ADMIN_PAUSER_ROLE);
        RoleConfig memory upgraderConfig = getRoleConfig(ADMIN_UPGRADER_ROLE);
        RoleConfig memory syncConfig = getRoleConfig(SYNC_ROLE);
        RoleConfig memory kernelConfig = getRoleConfig(ADMIN_KERNEL_ROLE);
        RoleConfig memory accountantConfig = getRoleConfig(ADMIN_ACCOUNTANT_ROLE);
        RoleConfig memory feeSetterConfig = getRoleConfig(ADMIN_PROTOCOL_FEE_SETTER_ROLE);
        RoleConfig memory oracleQuoterConfig = getRoleConfig(ADMIN_ORACLE_QUOTER_ROLE);
        RoleConfig memory lpRoleAdminConfig = getRoleConfig(LP_ROLE_ADMIN_ROLE);
        RoleConfig memory stLpRoleConfig = getRoleConfig(ST_LP_ROLE);
        RoleConfig memory jtLpRoleConfig = getRoleConfig(JT_LP_ROLE);
        RoleConfig memory roleGuardianConfig = getRoleConfig(GUARDIAN_ROLE);
        RoleConfig memory deployerConfig = getRoleConfig(DEPLOYER_ROLE);
        RoleConfig memory deployerAdminConfig = getRoleConfig(DEPLOYER_ROLE_ADMIN_ROLE);

        roleAssignments[0] = RoleAssignmentConfiguration({
            role: ADMIN_PAUSER_ROLE, roleAdminRole: pauserConfig.adminRole, assignee: _addresses.pauserAddress, executionDelay: pauserConfig.executionDelay
        });

        roleAssignments[1] = RoleAssignmentConfiguration({
            role: ADMIN_UPGRADER_ROLE,
            roleAdminRole: upgraderConfig.adminRole,
            assignee: _addresses.upgraderAddress,
            executionDelay: upgraderConfig.executionDelay
        });

        roleAssignments[2] = RoleAssignmentConfiguration({
            role: SYNC_ROLE, roleAdminRole: syncConfig.adminRole, assignee: _addresses.syncRoleAddress, executionDelay: syncConfig.executionDelay
        });

        roleAssignments[3] = RoleAssignmentConfiguration({
            role: ADMIN_KERNEL_ROLE, roleAdminRole: kernelConfig.adminRole, assignee: _addresses.adminKernelAddress, executionDelay: kernelConfig.executionDelay
        });

        roleAssignments[4] = RoleAssignmentConfiguration({
            role: ADMIN_ACCOUNTANT_ROLE,
            roleAdminRole: accountantConfig.adminRole,
            assignee: _addresses.adminAccountantAddress,
            executionDelay: accountantConfig.executionDelay
        });

        roleAssignments[5] = RoleAssignmentConfiguration({
            role: ADMIN_PROTOCOL_FEE_SETTER_ROLE,
            roleAdminRole: feeSetterConfig.adminRole,
            assignee: _addresses.adminProtocolFeeSetterAddress,
            executionDelay: feeSetterConfig.executionDelay
        });

        roleAssignments[6] = RoleAssignmentConfiguration({
            role: ADMIN_ORACLE_QUOTER_ROLE,
            roleAdminRole: oracleQuoterConfig.adminRole,
            assignee: _addresses.adminOracleQuoterAddress,
            executionDelay: oracleQuoterConfig.executionDelay
        });

        roleAssignments[7] = RoleAssignmentConfiguration({
            role: LP_ROLE_ADMIN_ROLE,
            roleAdminRole: lpRoleAdminConfig.adminRole,
            assignee: _addresses.lpRoleAdminAddress,
            executionDelay: lpRoleAdminConfig.executionDelay
        });

        // ST_LP_ROLE with address(0) assignee - role admin will be set but no direct assignment
        // LP roles are granted separately per-provider
        roleAssignments[8] = RoleAssignmentConfiguration({
            role: ST_LP_ROLE, roleAdminRole: stLpRoleConfig.adminRole, assignee: address(0), executionDelay: stLpRoleConfig.executionDelay
        });

        // JT_LP_ROLE with address(0) assignee - role admin will be set but no direct assignment
        roleAssignments[9] = RoleAssignmentConfiguration({
            role: JT_LP_ROLE, roleAdminRole: jtLpRoleConfig.adminRole, assignee: address(0), executionDelay: jtLpRoleConfig.executionDelay
        });

        roleAssignments[10] = RoleAssignmentConfiguration({
            role: GUARDIAN_ROLE,
            roleAdminRole: roleGuardianConfig.adminRole,
            assignee: _addresses.guardianAddress,
            executionDelay: roleGuardianConfig.executionDelay
        });

        roleAssignments[11] = RoleAssignmentConfiguration({
            role: DEPLOYER_ROLE, roleAdminRole: deployerConfig.adminRole, assignee: _addresses.deployerAddress, executionDelay: deployerConfig.executionDelay
        });

        roleAssignments[12] = RoleAssignmentConfiguration({
            role: DEPLOYER_ROLE_ADMIN_ROLE,
            roleAdminRole: deployerAdminConfig.adminRole,
            assignee: _addresses.deployerAdminAddress,
            executionDelay: deployerAdminConfig.executionDelay
        });
    }

    /// @notice Grants all relevant roles to the addresses specified in the deployment parameters
    /// @param _factory The factory contract (which acts as the AccessManager)
    /// @param _params The deployment parameters containing role addresses
    function grantAllRoles(RoycoFactory _factory, DeploymentParams memory _params, address _deployer) public {
        IAccessManager accessManager = IAccessManager(address(_factory));

        (bool hasRole,) = accessManager.hasRole(_ADMIN_ROLE, _deployer);
        if (!hasRole) {
            console2.log("This script invoker does not have ADMIN_ROLE, skipping the role assignments step");
            return;
        }

        console2.log("Granting roles on AccessManager:", address(_factory));

        for (uint256 i = 0; i < _params.roleAssignments.length; i++) {
            RoleAssignmentConfiguration memory roleAssignment = _params.roleAssignments[i];

            // Get role config to set up admin and guardian
            RoleConfig memory roleConfig = getRoleConfig(roleAssignment.role);

            // Grant the role to the assignee (skip if assignee is zero, e.g., LP_ROLE which is handled separately)
            if (roleAssignment.assignee != address(0)) {
                (hasRole,) = accessManager.hasRole(roleAssignment.role, roleAssignment.assignee);
                if (!hasRole) {
                    console2.log("  - Granting role: %s to: %s with delay: %s", roleAssignment.role, roleAssignment.assignee, roleAssignment.executionDelay);
                    accessManager.grantRole(roleAssignment.role, roleAssignment.assignee, roleAssignment.executionDelay);
                } else {
                    console2.log("  - %s already granted to: %s skipping role grant", roleAssignment.role, roleAssignment.assignee);
                }
            } else {
                console2.log("  - Skipping role grant for %s: assignee is zero address", roleAssignment.role);
            }

            // Set the role admin if different from default (0)
            if (roleConfig.adminRole != _ADMIN_ROLE) {
                console2.log("  - Setting role admin for: %s to: %s", roleAssignment.role, roleConfig.adminRole);
                accessManager.setRoleAdmin(roleAssignment.role, roleConfig.adminRole);
            }

            // Set the role guardian
            console2.log("  - Setting role guardian for: %s to: %s", roleAssignment.role, roleConfig.guardianRole);
            accessManager.setRoleGuardian(roleAssignment.role, roleConfig.guardianRole);
        }

        console2.log("All roles granted successfully!");
    }

    /// @notice Deploys all contracts for a market
    /// @param factory The deployed factory
    /// @param ydmAddress The address of the deployed YDM
    /// @param _params The deployment parameters
    /// @return deployedContracts The deployed market contracts
    /// @return stImpl The deployed senior tranche implementation address
    /// @return jtImpl The deployed junior tranche implementation address
    /// @return kernelImpl The deployed kernel implementation address
    /// @return accountantImpl The deployed accountant implementation address
    function _deployMarket(
        RoycoFactory factory,
        address ydmAddress,
        DeploymentParams memory _params,
        address _deployer
    )
        internal
        returns (
            IRoycoFactory.RoycoMarket memory deployedContracts,
            RoycoSeniorTranche stImpl,
            RoycoJuniorTranche jtImpl,
            address kernelImpl,
            RoycoAccountant accountantImpl
        )
    {
        // Precompute expected proxy addresses using salt derived from market ID
        bytes32 salt = keccak256(abi.encodePacked(MARKET_DEPLOYMENT_SALT, _params.marketId));

        // Predict the deterministic addresses of the contracts
        // The salt is unique for each contract type to prevent CREATE3 collisions
        bytes32 seniorTrancheSalt = keccak256(abi.encodePacked(salt, "-ST"));
        bytes32 juniorTrancheSalt = keccak256(abi.encodePacked(salt, "-JT"));
        bytes32 accountantSalt = keccak256(abi.encodePacked(salt, "-ACCOUNTANT"));
        bytes32 kernelSalt = keccak256(abi.encodePacked(salt, "-KERNEL"));
        address expectedSeniorTrancheAddress = factory.predictDeterministicAddress(seniorTrancheSalt);
        address expectedJuniorTrancheAddress = factory.predictDeterministicAddress(juniorTrancheSalt);
        address expectedAccountantAddress = factory.predictDeterministicAddress(accountantSalt);
        address expectedKernelAddress = factory.predictDeterministicAddress(kernelSalt);

        // Deploy the senior tranche implementation
        stImpl = _deploySTTrancheImpl(_params.seniorAsset, expectedKernelAddress, _params.marketId);

        // Deploy the junior tranche implementation
        jtImpl = _deployJTTrancheImpl(_params.juniorAsset, expectedKernelAddress, _params.marketId);

        // Deploy the accountant implementation
        accountantImpl = _deployAccountantImpl(expectedKernelAddress);

        // Deploy the kernel implementation based on kernel type
        kernelImpl = _deployKernelImpl(
            _params.kernelType,
            _params.kernelSpecificParams,
            expectedSeniorTrancheAddress,
            expectedJuniorTrancheAddress,
            _params.seniorAsset,
            _params.juniorAsset,
            expectedAccountantAddress
        );

        console2.log("Expected Senior Tranche Address:", expectedSeniorTrancheAddress);
        console2.log("Expected Junior Tranche Address:", expectedJuniorTrancheAddress);
        console2.log("Expected Kernel Address:", expectedKernelAddress);
        console2.log("Expected Accountant Address:", expectedAccountantAddress);

        // Build initialization data
        address factoryAddress = address(factory);
        bytes memory kernelInitializationData =
            _buildKernelInitializationData(_params.kernelType, _params.kernelSpecificParams, expectedAccountantAddress, factoryAddress, _params);
        bytes memory accountantInitializationData = _buildAccountantInitializationData(expectedKernelAddress, ydmAddress, factoryAddress, _params);
        bytes memory seniorTrancheInitializationData = _buildSeniorTrancheInitializationData(factoryAddress, _params);
        bytes memory juniorTrancheInitializationData = _buildJuniorTrancheInitializationData(factoryAddress, _params);

        // Build roles configuration
        IRoycoFactory.RolesTargetConfiguration[] memory roles =
            buildRolesTargetConfiguration(expectedSeniorTrancheAddress, expectedJuniorTrancheAddress, expectedKernelAddress, expectedAccountantAddress);

        // Build market deployment params
        IRoycoFactory.MarketDeploymentParams memory marketParams = IRoycoFactory.MarketDeploymentParams({
            seniorTrancheName: _params.seniorTrancheName,
            seniorTrancheSymbol: _params.seniorTrancheSymbol,
            juniorTrancheName: _params.juniorTrancheName,
            juniorTrancheSymbol: _params.juniorTrancheSymbol,
            marketId: _params.marketId,
            seniorTrancheImplementation: IRoycoVaultTranche(address(stImpl)),
            juniorTrancheImplementation: IRoycoVaultTranche(address(jtImpl)),
            kernelImplementation: IRoycoKernel(address(kernelImpl)),
            accountantImplementation: IRoycoAccountant(address(accountantImpl)),
            seniorTrancheInitializationData: seniorTrancheInitializationData,
            juniorTrancheInitializationData: juniorTrancheInitializationData,
            kernelInitializationData: kernelInitializationData,
            accountantInitializationData: accountantInitializationData,
            seniorTrancheProxyDeploymentSalt: seniorTrancheSalt,
            juniorTrancheProxyDeploymentSalt: juniorTrancheSalt,
            kernelProxyDeploymentSalt: kernelSalt,
            accountantProxyDeploymentSalt: accountantSalt,
            roles: roles
        });

        // Deploy market
        console2.log("Deploying market...");
        deployedContracts = factory.deployMarket(marketParams);

        console2.log("Market deployed successfully!");
        console2.log("Senior Tranche:", address(deployedContracts.seniorTranche));
        console2.log("Junior Tranche:", address(deployedContracts.juniorTranche));
        console2.log("Kernel:", address(deployedContracts.kernel));
        console2.log("Accountant:", address(deployedContracts.accountant));

        // Grant all roles to the specified addresses
        grantAllRoles(factory, _params, _deployer);
    }

    /// @notice Deploys accountant implementation
    /// @return The deployed accountant implementation
    function _deployAccountantImpl(address _kernel) internal returns (RoycoAccountant) {
        bytes memory creationCode = abi.encodePacked(type(RoycoAccountant).creationCode, abi.encode(_kernel));

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(ACCOUNTANT_IMPL_SALT, creationCode, false);
        if (alreadyDeployed) {
            console2.log("Accountant implementation already deployed at:", addr);
        } else {
            console2.log("Accountant implementation deployed at:", addr);
        }
        return RoycoAccountant(addr);
    }

    /// @notice Deploys ST tranche implementation
    /// @return The deployed ST tranche implementation
    function _deploySTTrancheImpl(address _asset, address _kernel, bytes32 _marketId) internal returns (RoycoSeniorTranche) {
        bytes memory creationCode = abi.encodePacked(type(RoycoSeniorTranche).creationCode, abi.encode(_asset, _kernel, _marketId));

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(ST_TRANCHE_IMPL_SALT, creationCode, false);
        if (alreadyDeployed) {
            console2.log("ST tranche implementation already deployed at:", addr);
        } else {
            console2.log("ST tranche implementation deployed at:", addr);
        }
        return RoycoSeniorTranche(addr);
    }

    /// @notice Deploys JT tranche implementation
    /// @return The deployed JT tranche implementation
    function _deployJTTrancheImpl(address _asset, address _kernel, bytes32 _marketId) internal returns (RoycoJuniorTranche) {
        bytes memory creationCode = abi.encodePacked(type(RoycoJuniorTranche).creationCode, abi.encode(_asset, _kernel, _marketId));

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(JT_TRANCHE_IMPL_SALT, creationCode, false);
        if (alreadyDeployed) {
            console2.log("JT tranche implementation already deployed at:", addr);
        } else {
            console2.log("JT tranche implementation deployed at:", addr);
        }
        return RoycoJuniorTranche(addr);
    }

    /// @notice Deploys YDM implementation based on YDM type
    /// @param _ydmType The YDM type to deploy
    /// @return ydm The deployed YDM contract
    function _deployYDM(YDMType _ydmType) internal returns (IYDM) {
        bytes memory creationCode;
        bytes32 salt;

        if (_ydmType == YDMType.StaticCurve) {
            creationCode = type(StaticCurveYDM).creationCode;
            salt = keccak256(abi.encodePacked(YDM_SALT, "STATIC_CURVE"));
        } else if (_ydmType == YDMType.AdaptiveCurve_V1) {
            creationCode = type(AdaptiveCurveYDM_V1).creationCode;
            salt = keccak256(abi.encodePacked(YDM_SALT, "ADAPTIVE_CURVE_V1"));
        } else if (_ydmType == YDMType.AdaptiveCurve_V2) {
            creationCode = type(AdaptiveCurveYDM_V2).creationCode;
            salt = keccak256(abi.encodePacked(YDM_SALT, "ADAPTIVE_CURVE_V2"));
        } else {
            revert UnsupportedYDMType(_ydmType);
        }

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(salt, creationCode, false);
        if (alreadyDeployed) {
            console2.log("YDM already deployed at:", addr);
        } else {
            console2.log("YDM deployed at:", addr);
        }
        return IYDM(addr);
    }

    /// @notice Deploys factory implementation
    /// @param _factoryAdmin The address of the factory admin
    /// @return The deployed factory implementation
    function _deployFactory(address _factoryAdmin, address _deployer) internal returns (RoycoFactory) {
        bytes memory creationCode = abi.encodePacked(type(RoycoFactory).creationCode, abi.encode(_factoryAdmin, _deployer));

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(FACTORY_SALT_BASE, creationCode, false);
        if (alreadyDeployed) {
            console2.log("Factory already deployed at:", addr);
        } else {
            console2.log("Factory deployed at:", addr);
        }
        return RoycoFactory(addr);
    }

    /// @notice Deploys kernel implementation based on kernel type
    function _deployKernelImpl(
        KernelType _kernelType,
        bytes memory _kernelSpecificParams,
        address _expectedSeniorTrancheAddress,
        address _expectedJuniorTrancheAddress,
        address _seniorAsset,
        address _juniorAsset,
        address _expectedAccountantAddress
    )
        internal
        returns (address)
    {
        IRoycoKernel.RoycoKernelConstructionParams memory constructionParams = IRoycoKernel.RoycoKernelConstructionParams({
            seniorTranche: _expectedSeniorTrancheAddress,
            stAsset: _seniorAsset,
            juniorTranche: _expectedJuniorTrancheAddress,
            jtAsset: _juniorAsset,
            accountant: _expectedAccountantAddress
        });

        if (_kernelType == KernelType.ReUSD_ST_ReUSD_JT) {
            return address(_deployReUSDSTReUSDJTKernelImpl(constructionParams, _kernelSpecificParams));
        } else if (_kernelType == KernelType.IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel) {
            return address(_deployIdenticalAssetsChainlinkToAdminOracleQuoterKernelImpl(constructionParams));
        } else if (_kernelType == KernelType.IdenticalERC4626SharesAdminOracleQuoter_Kernel) {
            return address(_deployIdenticalERC4626SharesAdminOracleQuoterKernelImpl(constructionParams));
        } else if (_kernelType == KernelType.IdleCdoAA_ST_IdleCdoAA_JT) {
            return address(_deployIdleCdoAASTIdleCdoAAJTKernelImpl(constructionParams, _kernelSpecificParams));
        } else {
            revert UnsupportedKernelType(_kernelType);
        }
    }

    function _deployReUSDSTReUSDJTKernelImpl(
        IRoycoKernel.RoycoKernelConstructionParams memory _constructionParams,
        bytes memory _params
    )
        internal
        returns (ReUSD_ST_ReUSD_JT_Kernel)
    {
        ReUSDSTReUSDJTKernelParams memory kernelParams = abi.decode(_params, (ReUSDSTReUSDJTKernelParams));

        bytes memory creationCode = abi.encodePacked(
            type(ReUSD_ST_ReUSD_JT_Kernel).creationCode,
            abi.encode(_constructionParams, kernelParams.reusd, kernelParams.reusdUsdQuoteToken, kernelParams.insuranceCapitalLayer)
        );

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(KERNEL_IMPL_SALT, creationCode, false);
        if (alreadyDeployed) {
            console2.log("Kernel implementation already deployed at:", addr);
        } else {
            console2.log("Kernel implementation deployed at:", addr);
        }
        return ReUSD_ST_ReUSD_JT_Kernel(addr);
    }

    function _deployIdenticalAssetsChainlinkToAdminOracleQuoterKernelImpl(IRoycoKernel.RoycoKernelConstructionParams memory _constructionParams)
        internal
        returns (IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel)
    {
        bytes memory creationCode = abi.encodePacked(type(IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel).creationCode, abi.encode(_constructionParams));

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(KERNEL_IMPL_SALT, creationCode, false);
        if (alreadyDeployed) {
            console2.log("Kernel implementation already deployed at:", addr);
        } else {
            console2.log("Kernel implementation deployed at:", addr);
        }
        return IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel(addr);
    }

    function _deployIdenticalERC4626SharesAdminOracleQuoterKernelImpl(IRoycoKernel.RoycoKernelConstructionParams memory _constructionParams)
        internal
        returns (IdenticalERC4626SharesAdminOracleQuoter_Kernel)
    {
        bytes memory creationCode = abi.encodePacked(type(IdenticalERC4626SharesAdminOracleQuoter_Kernel).creationCode, abi.encode(_constructionParams));

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(KERNEL_IMPL_SALT, creationCode, false);
        if (alreadyDeployed) {
            console2.log("Kernel implementation already deployed at:", addr);
        } else {
            console2.log("Kernel implementation deployed at:", addr);
        }
        return IdenticalERC4626SharesAdminOracleQuoter_Kernel(addr);
    }

    function _deployIdleCdoAASTIdleCdoAAJTKernelImpl(
        IRoycoKernel.RoycoKernelConstructionParams memory _constructionParams,
        bytes memory _params
    )
        internal
        returns (IdleCdoAA_ST_IdleCdoAA_JT_Kernel)
    {
        IdleCdoAASTIdleCdoAAJTKernelParams memory kernelParams = abi.decode(_params, (IdleCdoAASTIdleCdoAAJTKernelParams));

        bytes memory creationCode = abi.encodePacked(type(IdleCdoAA_ST_IdleCdoAA_JT_Kernel).creationCode, abi.encode(_constructionParams, kernelParams.idleCDO));

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(KERNEL_IMPL_SALT, creationCode, false);
        if (alreadyDeployed) {
            console2.log("Kernel implementation already deployed at:", addr);
        } else {
            console2.log("Kernel implementation deployed at:", addr);
        }
        return IdleCdoAA_ST_IdleCdoAA_JT_Kernel(addr);
    }

    function _buildKernelInitializationData(
        KernelType _kernelType,
        bytes memory _kernelSpecificParams,
        address _expectedAccountantAddress,
        address _factoryAddress,
        DeploymentParams memory _params
    )
        internal
        pure
        returns (bytes memory)
    {
        IRoycoKernel.RoycoKernelInitParams memory kernelParams =
            IRoycoKernel.RoycoKernelInitParams({ initialAuthority: _factoryAddress, protocolFeeRecipient: _params.protocolFeeRecipient });

        if (_kernelType == KernelType.ReUSD_ST_ReUSD_JT) {
            return abi.encodeCall(ReUSD_ST_ReUSD_JT_Kernel.initialize, (kernelParams));
        } else if (_kernelType == KernelType.IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel) {
            IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams memory kernelParams2 =
                abi.decode(_kernelSpecificParams, (IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams));
            return abi.encodeCall(
                IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel.initialize,
                (
                    kernelParams,
                    kernelParams2.trancheAssetToReferenceAssetOracle,
                    kernelParams2.stalenessThresholdSeconds,
                    kernelParams2.initialConversionRateWAD
                )
            );
        } else if (_kernelType == KernelType.IdenticalERC4626SharesAdminOracleQuoter_Kernel) {
            IdenticalERC4626SharesAdminOracleQuoterKernelParams memory kernelParams2 =
                abi.decode(_kernelSpecificParams, (IdenticalERC4626SharesAdminOracleQuoterKernelParams));
            return abi.encodeCall(IdenticalERC4626SharesAdminOracleQuoter_Kernel.initialize, (kernelParams, kernelParams2.initialConversionRateWAD));
        } else if (_kernelType == KernelType.IdleCdoAA_ST_IdleCdoAA_JT) {
            return abi.encodeCall(IdleCdoAA_ST_IdleCdoAA_JT_Kernel.initialize, (kernelParams));
        } else {
            revert UnsupportedKernelType(_kernelType);
        }
    }

    /// @notice Builds YDM initialization data based on YDM type
    /// @param _ydmType The YDM type
    /// @param _ydmSpecificParams Encoded YDM-specific parameters
    /// @return ydmInitializationData The encoded YDM initialization data
    function _buildYDMInitializationData(YDMType _ydmType, bytes memory _ydmSpecificParams) internal pure returns (bytes memory ydmInitializationData) {
        if (_ydmType == YDMType.StaticCurve) {
            StaticCurveYDMParams memory ydmParams = abi.decode(_ydmSpecificParams, (StaticCurveYDMParams));
            ydmInitializationData = abi.encodeCall(
                StaticCurveYDM.initializeYDMForMarket,
                (ydmParams.jtYieldShareAtZeroUtilWAD, ydmParams.jtYieldShareAtTargetUtilWAD, ydmParams.jtYieldShareAtFullUtilWAD)
            );
        } else if (_ydmType == YDMType.AdaptiveCurve_V1) {
            AdaptiveCurveYDM_V1_Params memory ydmParams = abi.decode(_ydmSpecificParams, (AdaptiveCurveYDM_V1_Params));
            ydmInitializationData =
                abi.encodeCall(AdaptiveCurveYDM_V1.initializeYDMForMarket, (ydmParams.jtYieldShareAtTargetUtilWAD, ydmParams.jtYieldShareAtFullUtilWAD));
        } else if (_ydmType == YDMType.AdaptiveCurve_V2) {
            AdaptiveCurveYDM_V2_Params memory ydmParams = abi.decode(_ydmSpecificParams, (AdaptiveCurveYDM_V2_Params));
            ydmInitializationData = abi.encodeCall(
                AdaptiveCurveYDM_V2.initializeYDMForMarket,
                (
                    ydmParams.jtYieldShareAtZeroUtilWAD,
                    ydmParams.jtYieldShareAtTargetUtilWAD,
                    ydmParams.jtYieldShareAtFullUtilWAD,
                    ydmParams.maxAdaptationSpeedWAD
                )
            );
        } else {
            revert UnsupportedYDMType(_ydmType);
        }
    }

    function _buildAccountantInitializationData(
        address _expectedKernelAddress,
        address _ydmAddress,
        address _factoryAddress,
        DeploymentParams memory _params
    )
        internal
        pure
        returns (bytes memory)
    {
        IRoycoAccountant.RoycoAccountantInitParams memory accountantParams = IRoycoAccountant.RoycoAccountantInitParams({
            stProtocolFeeWAD: _params.stProtocolFeeWAD,
            jtProtocolFeeWAD: _params.jtProtocolFeeWAD,
            yieldShareProtocolFeeWAD: 0,
            coverageWAD: _params.coverageWAD,
            betaWAD: _params.betaWAD,
            ydm: _ydmAddress,
            ydmInitializationData: _buildYDMInitializationData(_params.ydmType, _params.ydmSpecificParams),
            fixedTermDurationSeconds: _params.fixedTermDurationSeconds,
            lltvWAD: _params.lltvWAD,
            stNAVDustTolerance: _params.stNAVDustTolerance,
            jtNAVDustTolerance: _params.jtNAVDustTolerance
        });

        return abi.encodeCall(RoycoAccountant.initialize, (accountantParams, _factoryAddress));
    }

    function _buildSeniorTrancheInitializationData(address _factoryAddress, DeploymentParams memory _params) internal pure returns (bytes memory) {
        IRoycoVaultTranche.TrancheDeploymentParams memory trancheParams = IRoycoVaultTranche.TrancheDeploymentParams({
            name: _params.seniorTrancheName, symbol: _params.seniorTrancheSymbol, initialAuthority: _factoryAddress
        });

        return abi.encodeCall(RoycoSeniorTranche.initialize, (trancheParams));
    }

    function _buildJuniorTrancheInitializationData(address _factoryAddress, DeploymentParams memory _params) internal pure returns (bytes memory) {
        IRoycoVaultTranche.TrancheDeploymentParams memory trancheParams = IRoycoVaultTranche.TrancheDeploymentParams({
            name: _params.juniorTrancheName, symbol: _params.juniorTrancheSymbol, initialAuthority: _factoryAddress
        });

        return abi.encodeCall(RoycoJuniorTranche.initialize, (trancheParams));
    }

    function _transferFactoryOwnership(RoycoFactory _factory, address _deployer, address _newAdmin) internal {
        // Check if new admin is already admin
        (bool isNewAdminAdmin,) = IAccessManager(address(_factory)).hasRole(0, _newAdmin);
        if (isNewAdminAdmin) {
            console2.log("New admin already has ADMIN_ROLE, skipping transfer");
            return;
        }

        console2.log("Transferring factory ownership to:", _newAdmin);

        // Grant ADMIN_ROLE to new admin (execution delay = 0 for immediate effect)
        IAccessManager(address(_factory)).grantRole(0, _newAdmin, 0);

        // Revoke ADMIN_ROLE from old admin (the deploy script itself)
        IAccessManager(address(_factory)).revokeRole(0, _deployer);

        console2.log("Factory ownership transferred successfully");
        console2.log("New factory admin:", _newAdmin);
    }
}
