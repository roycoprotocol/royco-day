// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { RoycoBlacklist } from "../../../src/auth/RoycoBlacklist.sol";
import { ADMIN_BLACKLIST_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { BlacklistConfig } from "../config/BlacklistConfig.sol";
import { RoycoDeterministic } from "../utils/RoycoDeterministic.sol";
import { DeployScriptBase } from "./DeployScriptBase.sol";

/**
 * @title DeployBlacklistComponent
 * @notice Deploys (or reuses) the chain's shared RoycoBlacklist (impl + ERC1967 proxy) and binds its admin surface
 *         to ADMIN_BLACKLIST_ROLE on first deployment.
 * @dev The sanctions list initializes NULL and is wired later by the ops script from `getChainalysisSanctionsList` —
 *      a deliberate two-step so the deployment carries no live-screening dependency.
 */
contract DeployBlacklistComponent is DeployScriptBase, BlacklistConfig {
    address internal ACCESS_MANAGER;

    constructor(bool _isTestEnv, address _accessManager) {
        isTestEnv = _isTestEnv;
        ACCESS_MANAGER = _accessManager;
    }

    /// @notice Deploys the blacklist under its own broadcast
    function execute(uint256 _deployerPrivateKey) public returns (address blacklist) {
        vm.startBroadcast(_deployerPrivateKey);
        blacklist = _execute();
        vm.stopBroadcast();
    }

    function _execute() internal returns (address blacklist) {
        (address implAddr, bool implExisted) =
            deployWithSanityChecks(_singletonSalt("ROYCO_BLACKLIST_IMPLEMENTATION"), type(RoycoBlacklist).creationCode, false);
        _logDeploy("Blacklist (impl)   ", implAddr, implExisted);
        address[] memory initialBlacklistedAccounts = new address[](0);
        bytes memory initData = abi.encodeCall(RoycoBlacklist.initialize, (ACCESS_MANAGER, address(0), initialBlacklistedAccounts));
        bool blacklistExisted;
        (blacklist, blacklistExisted) = deployWithSanityChecks(_singletonSalt("ROYCO_BLACKLIST_PROXY"), getERC1967ProxyCreationCode(implAddr, initData), false);
        _logDeploy("Blacklist (proxy)  ", blacklist, blacklistExisted);

        if (!blacklistExisted) {
            bytes4[] memory blacklistSelectors = new bytes4[](3);
            blacklistSelectors[0] = RoycoBlacklist.blacklistAccounts.selector;
            blacklistSelectors[1] = RoycoBlacklist.unblacklistAccounts.selector;
            blacklistSelectors[2] = RoycoBlacklist.setSanctionsList.selector;
            AccessManager(ACCESS_MANAGER).setTargetFunctionRole(blacklist, blacklistSelectors, ADMIN_BLACKLIST_ROLE);
        }
    }
}

/// @notice CLI entrypoint: deploys against the predicted AccessManager for the env's deployer
contract DeployBlacklist is DeployBlacklistComponent {
    constructor() DeployBlacklistComponent(vm.envOr("IS_TEST_DEPLOYMENT", false), _predictAccessManager()) { }

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
        execute(vm.envUint("DEPLOYER_PRIVATE_KEY"));
    }
}
