// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ADMIN_FACTORY_ROLE, ADMIN_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { EnvConfig } from "../config/EnvConfig.sol";
import { RoycoDeterministic } from "../utils/RoycoDeterministic.sol";
import { DeployScriptBase } from "./DeployScriptBase.sol";

/**
 * @title RenounceDeployerRolesComponent
 * @notice The pipeline's EXPLICIT FINALIZE step: the deployer renounces the admin roles the bootstrap granted it.
 * @dev MUST be the LAST admin-gated call of the whole runbook — template registration, template configuration-surface
 *      bindings, YDM registration, and beacon bindings all require the roles renounced here. Markets can still be
 *      deployed afterwards: `executeMarketDeployment` is PUBLIC and the collateral-oracle deployment is
 *      unpermissioned. Only the fresh-AccessManager path grants the deployer these roles, so the caller supplies
 *      that flag; the ADMIN_ROLE renounce is skipped when the deployer IS the factory admin, otherwise the
 *      AccessManager would be left with no ADMIN_ROLE holder and permanently bricked.
 */
contract RenounceDeployerRolesComponent is DeployScriptBase, EnvConfig {
    address internal ACCESS_MANAGER;

    constructor(address _accessManager) {
        ACCESS_MANAGER = _accessManager;
    }

    /// @notice Renounces the deployer's admin roles under its own broadcast; no-ops when the AccessManager was reused
    function execute(address _factoryAdmin, bool _amFresh, uint256 _deployerPrivateKey) public {
        if (!_amFresh) return;
        vm.startBroadcast(_deployerPrivateKey);
        address deployer = vm.addr(_deployerPrivateKey);
        AccessManager am = AccessManager(ACCESS_MANAGER);
        am.renounceRole(ADMIN_FACTORY_ROLE, deployer);
        if (_factoryAdmin != deployer) am.renounceRole(ADMIN_ROLE, deployer);
        vm.stopBroadcast();
    }
}

/// @notice CLI entrypoint: renounces against the predicted AccessManager for the env's deployer
contract RenounceDeployerRoles is RenounceDeployerRolesComponent {
    constructor() RenounceDeployerRolesComponent(_predictAccessManager()) { }

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
        address admin = isTest ? testDeploymentAdmin : ROOT_MULTISIG;
        execute(admin, true, vm.envUint("DEPLOYER_PRIVATE_KEY"));
    }
}
