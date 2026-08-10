// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_FACTORY_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    LPT_LP_ROLE,
    PUBLIC_ROLE,
    SYNC_ROLE
} from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoCreate3Deployer } from "../../../src/factory/RoycoCreate3Deployer.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { RoycoFactoryGatekeeper } from "../../../src/factory/RoycoFactoryGatekeeper.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { CoreDeployment } from "../../config/DeploymentTypes.sol";
import { EnvConfig } from "../config/EnvConfig.sol";
import { RoycoDeterministic } from "../utils/RoycoDeterministic.sol";
import { DeployScriptBase } from "./DeployScriptBase.sol";

/**
 * @title DeployCoreComponent
 * @notice Deploys (or reuses) the chain's auth + factory core: the standalone RoycoAccessManager (deployer as initial
 *         admin), the protocol CREATE3 deployer, the factory gatekeeper (built against the PREDICTED periphery
 *         addresses — the circular dependency is resolved purely by deterministic prediction), the factory
 *         implementation + CREATE3 proxy, and the factory's own role wiring.
 * @dev The root of the deployment DAG: no upstream addresses. Everything is idempotent via CREATE2, so re-running
 *      against a live chain reuses what exists and reports it through the `existed` flags downstream scripts guard on.
 */
contract DeployCoreComponent is DeployScriptBase, EnvConfig {
    constructor(bool _isTestEnv) {
        isTestEnv = _isTestEnv;
    }

    /// @notice Deploys the core under its own broadcast
    function execute(uint256 _deployerPrivateKey) public returns (CoreDeployment memory core) {
        vm.startBroadcast(_deployerPrivateKey);
        core = _execute(vm.addr(_deployerPrivateKey));
        vm.stopBroadcast();
    }

    /// @notice Deploys the core inside the CALLER's active broadcast/prank context
    function _execute(address _deployer) internal returns (CoreDeployment memory core) {
        _logSection("Protocol scaffolding");

        // Deploy the AccessManager with the deployer as the initial admin so it can wire roles during this broadcast.
        (core.accessManager, core.amExisted) = deployWithSanityChecks(
            _singletonSalt("ROYCO_ACCESS_MANAGER"), abi.encodePacked(type(RoycoAccessManager).creationCode, abi.encode(_deployer)), false
        );
        _logDeploy("AccessManager      ", core.accessManager, core.amExisted);

        // Deploy the CREATE3 deployer
        bool create3DeployerExisted;
        (core.create3Deployer, create3DeployerExisted) =
            deployWithSanityChecks(_singletonSalt("ROYCO_CREATE3_DEPLOYER"), type(RoycoCreate3Deployer).creationCode, false);
        _logDeploy("CREATE3 deployer   ", core.create3Deployer, create3DeployerExisted);

        bytes32 factoryProxySalt = hex"18ca7fd2b42a32780000000000000002000000000942129a0000000000000000";
        core.factory = RoycoCreate3Deployer(core.create3Deployer).predict(_deployer, factoryProxySalt);

        // Predict the periphery singletons
        (core.entryPoint, core.marketSyncer) = RoycoDeterministic.predictPeripherySingletons(core.accessManager, core.factory, isTestEnv);

        // Deploy the factory gatekeeper against the factory address the CREATE3 salt has already fixed
        (address gatekeeper, bool gatekeeperExisted) = deployWithSanityChecks(
            _singletonSalt("ROYCO_FACTORY_GATEKEEPER"),
            abi.encodePacked(type(RoycoFactoryGatekeeper).creationCode, abi.encode(core.accessManager, core.factory, core.entryPoint, core.marketSyncer)),
            false
        );
        core.gatekeeper = gatekeeper;
        _logDeploy("Gatekeeper         ", gatekeeper, gatekeeperExisted);

        // Wire the gatekeeper roles
        if (!gatekeeperExisted) {
            RoycoAccessManager am = RoycoAccessManager(core.accessManager);
            am.grantRole(ADMIN_ROLE, gatekeeper, 0);
            am.grantRole(ADMIN_ENTRY_POINT_ROLE, gatekeeper, 0);
            am.grantRole(SYNC_ROLE, gatekeeper, 0);
        }

        (address factoryImpl, bool factoryImplExisted) = deployWithSanityChecks(
            _singletonSalt("ROYCO_FACTORY_IMPLEMENTATION"), abi.encodePacked(type(RoycoFactory).creationCode, abi.encode(gatekeeper)), false
        );
        _logDeploy("Factory (impl)     ", factoryImpl, factoryImplExisted);

        core.factoryExisted = core.factory.code.length > 0;
        if (!core.factoryExisted) {
            address deployedProxy = RoycoCreate3Deployer(core.create3Deployer)
                .deploy(factoryProxySalt, getERC1967ProxyCreationCode(factoryImpl, abi.encodeCall(RoycoFactory.initialize, (core.accessManager))));
            require(deployedProxy == core.factory, "factory address mismatch");
        }
        _logDeploy("Factory (proxy)    ", core.factory, core.factoryExisted);

        // Wire the factory roles on first deployment
        if (!core.factoryExisted) _wireFactoryRoles(RoycoAccessManager(core.accessManager), core.factory);
    }

    /// @notice Binds the factory's own gated selectors and grants it the narrow role set it retains.
    function _wireFactoryRoles(RoycoAccessManager _accessManager, address _factory) internal {
        bytes4[] memory deployerSelectors = new bytes4[](1);
        deployerSelectors[0] = IRoycoFactory.executeMarketDeployment.selector;
        _accessManager.setTargetFunctionRole(_factory, deployerSelectors, PUBLIC_ROLE);

        bytes4[] memory adminFactorySelectors = new bytes4[](2);
        adminFactorySelectors[0] = IRoycoFactory.registerTemplate.selector;
        adminFactorySelectors[1] = IRoycoFactory.disableTemplate.selector;
        _accessManager.setTargetFunctionRole(_factory, adminFactorySelectors, ADMIN_FACTORY_ROLE);

        _accessManager.setTargetFunctionRole(_factory, _sel(UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE);
        _accessManager.setTargetFunctionRole(_factory, _sel(IRoycoAuth.pause.selector), ADMIN_PAUSER_ROLE);
        _accessManager.setTargetFunctionRole(_factory, _sel(IRoycoAuth.unpause.selector), ADMIN_UNPAUSER_ROLE);

        _accessManager.grantRole(LPT_LP_ROLE, _factory, 0);
    }
}

/// @notice CLI entrypoint: `forge script script/deploy/core/DeployCore.s.sol` — env-driven, standalone-runnable
contract DeployCore is DeployCoreComponent {
    constructor() DeployCoreComponent(vm.envOr("IS_TEST_DEPLOYMENT", false)) { }

    function run() external {
        enableLogging();
        execute(vm.envUint("DEPLOYER_PRIVATE_KEY"));
    }
}
