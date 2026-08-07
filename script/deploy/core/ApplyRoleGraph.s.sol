// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ADMIN_FACTORY_ROLE, ADMIN_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoleAssignment, RoleConfig } from "../../config/DeploymentTypes.sol";
import { RoleGraphConfig } from "../config/RoleGraphConfig.sol";
import { RoycoDeterministic } from "../utils/RoycoDeterministic.sol";
import { DeployScriptBase } from "./DeployScriptBase.sol";

///  @title ApplyRoleGraphComponent
/// @notice Applies the protocol's role graph to a FRESHLY deployed AccessManager: the grants pass first (while every
///         role's admin is still ADMIN_ROLE, which the deployer holds), then the admin/guardian re-pointing pass.
contract ApplyRoleGraphComponent is DeployScriptBase, RoleGraphConfig {
    address internal ACCESS_MANAGER;

    constructor(address _accessManager) {
        ACCESS_MANAGER = _accessManager;
    }

    /// @notice Applies the role graph under its own broadcast; no-ops when the AccessManager was reused (`!_amFresh`)
    function applyRoleGraph(
        RoleAssignment[] memory _roleAssignments,
        address _factoryAdmin,
        uint32 _factoryAdminDelay,
        bool _amFresh,
        uint256 _deployerPrivateKey
    )
        public
    {
        if (!_amFresh) return;
        vm.startBroadcast(_deployerPrivateKey);
        _apply(_roleAssignments, _factoryAdmin, _factoryAdminDelay, vm.addr(_deployerPrivateKey));
        vm.stopBroadcast();
    }

    /// @notice Applies role admins/guardians/grants on the AccessManager (mirrors the legacy factory.initialize role setup).
    function _apply(RoleAssignment[] memory _roleAssignments, address _factoryAdmin, uint32 _factoryAdminDelay, address _deployer) internal {
        AccessManager am = AccessManager(ACCESS_MANAGER);

        // Ensure the factory admin holds ADMIN_ROLE (role 0). In production this is the kerchkoffs lockdown: FNDN's
        // admin ops run at a 72h execution delay and are intentionally non-cancellable by any other party.
        if (_factoryAdmin != _deployer) am.grantRole(ADMIN_ROLE, _factoryAdmin, _factoryAdminDelay);

        // The deployer needs ADMIN_FACTORY_ROLE for the bootstrap's admin-gated steps (registerTemplate, the
        // template's configuration-surface bindings, YDM registration); market deployment itself is PUBLIC.
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
        applyRoleGraph(
            generateRolesAssignments(roleAssignmentAddresses(isTest)),
            factoryAdmin(isTest),
            factoryAdminExecutionDelay(isTest),
            true,
            vm.envUint("DEPLOYER_PRIVATE_KEY")
        );
    }
}
