// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
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
} from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoleAssignment, RoleAssignmentAddresses, RoleConfig } from "../../config/DeploymentTypes.sol";
import { RoleGraphConfig } from "../config/RoleGraphConfig.sol";
import { RoycoDeterministic } from "../utils/RoycoDeterministic.sol";
import { DeployScriptBase } from "./DeployScriptBase.sol";

/**
 * @title ApplyRoleGraphComponent
 * @notice Applies the protocol's role graph to a FRESHLY deployed AccessManager: the grants pass first (while every
 *         role's admin is still ADMIN_ROLE, which the deployer holds), then the admin/guardian re-pointing pass.
 * @dev ORDERING: runs AFTER the periphery script (whose LP-role grants need the default role admins) and only when
 *      the core reported `amExisted == false` — re-running the two passes against a configured AccessManager would
 *      revert on the re-pointed role admins. The role delay table lives here; it is the single authority the
 *      assignment builder resolves against.
 */
contract ApplyRoleGraphComponent is DeployScriptBase, RoleGraphConfig {
    error UnknownRole(uint64 role);

    address internal ACCESS_MANAGER;

    constructor(address _accessManager) {
        ACCESS_MANAGER = _accessManager;
    }

    /// @notice Applies the role graph under its own broadcast; no-ops when the AccessManager was reused (`!_amFresh`)
    function applyRoleGraph(RoleAssignment[] memory _roleAssignments, address _factoryAdmin, bool _amFresh, uint256 _deployerPrivateKey) public {
        if (!_amFresh) return;
        vm.startBroadcast(_deployerPrivateKey);
        _apply(_roleAssignments, _factoryAdmin, vm.addr(_deployerPrivateKey));
        vm.stopBroadcast();
    }

    /// @notice Applies role admins/guardians/grants on the AccessManager (mirrors the legacy factory.initialize role setup).
    function _apply(RoleAssignment[] memory _roleAssignments, address _factoryAdmin, address _deployer) internal {
        AccessManager am = AccessManager(ACCESS_MANAGER);

        // Ensure the factory admin holds ADMIN_ROLE (role 0).
        if (_factoryAdmin != _deployer) am.grantRole(ADMIN_ROLE, _factoryAdmin, 0);

        // The deployer needs DEPLOYER_ROLE (executeMarketDeployment) + ADMIN_FACTORY_ROLE (registerTemplate).
        am.grantRole(DEPLOYER_ROLE, _deployer, 0);
        am.grantRole(ADMIN_FACTORY_ROLE, _deployer, 0);

        // Pass 1: grant every assignment WHILE each role's admin is still ADMIN_ROLE (role 0), which the deployer holds.
        // (OZ AccessManager `grantRole` checks the caller against the role's CURRENT admin; once we re-point a role's
        //  admin in pass 2, role 0 can no longer grant it. So all grants must happen before any `setRoleAdmin`.)
        for (uint256 i; i < _roleAssignments.length; ++i) {
            RoleAssignment memory ra = _roleAssignments[i];
            if (ra.assignee != address(0)) am.grantRole(ra.role, ra.assignee, ra.executionDelay);
        }

        // Pass 2: re-point role admins + guardians.
        for (uint256 i; i < _roleAssignments.length; ++i) {
            RoleAssignment memory ra = _roleAssignments[i];
            RoleConfig memory cfg = getRoleConfig(ra.role);
            if (cfg.adminRole != ADMIN_ROLE) am.setRoleAdmin(ra.role, cfg.adminRole);
            am.setRoleGuardian(ra.role, cfg.guardianRole);
        }
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
        if (role == ADMIN_UPGRADER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 72 hours });
        if (role == ST_LP_ROLE || role == JT_LP_ROLE) return RoleConfig({ adminRole: LP_ROLE_ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == LP_ROLE_ADMIN_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 72 hours });
        if (role == SYNC_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_KERNEL_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 72 hours });
        if (role == ADMIN_ACCOUNTANT_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 72 hours });
        if (role == ADMIN_PROTOCOL_FEE_SETTER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 72 hours });
        if (role == ADMIN_ORACLE_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 72 hours });
        if (role == GUARDIAN_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: ADMIN_ROLE, executionDelay: 0 });
        if (role == DEPLOYER_ROLE) return RoleConfig({ adminRole: DEPLOYER_ROLE_ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == DEPLOYER_ROLE_ADMIN_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_FACTORY_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 72 hours });
        if (role == ADMIN_UNPAUSER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == LPT_LP_ROLE) return RoleConfig({ adminRole: LP_ROLE_ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_BALANCER_POOL_MANAGER_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 72 hours });
        if (role == ADMIN_MARKET_OPS_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 72 hours });
        if (role == ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 0 });
        if (role == ADMIN_BLACKLIST_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 72 hours });
        if (role == ADMIN_ENTRY_POINT_ROLE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 72 hours });
        if (role == ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE) return RoleConfig({ adminRole: ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 72 hours });
        revert UnknownRole(role);
    }
}

/// @notice CLI entrypoint: applies the environment's canonical role graph to the predicted AccessManager
contract ApplyRoleGraph is ApplyRoleGraphComponent {
    constructor() ApplyRoleGraphComponent(_predictAccessManager()) { }

    function _predictAccessManager() internal view returns (address) {
        bool isTest = vm.envOr("IS_TEST_DEPLOYMENT", false);
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        return RoycoDeterministic.create2Address(
            RoycoDeterministic.singletonSalt("ROYCO_ACCESS_MANAGER", isTest),
            keccak256(abi.encodePacked(type(RoycoAccessManager).creationCode, abi.encode(deployer)))
        );
    }

    function run() external {
        enableLogging();
        bool isTest = vm.envOr("IS_TEST_DEPLOYMENT", false);
        testDeploymentAdmin = vm.envOr("TEST_ADMIN", testDeploymentAdmin);
        // A standalone run assumes a fresh AccessManager (the bootstrap composes the amFresh guard from core's result)
        applyRoleGraph(generateRolesAssignments(roleAssignmentAddresses(isTest)), factoryAdmin(isTest), true, vm.envUint("DEPLOYER_PRIVATE_KEY"));
    }
}
