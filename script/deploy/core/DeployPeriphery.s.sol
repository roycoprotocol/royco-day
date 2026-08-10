// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { RoycoDayEntryPoint } from "../../../src/entrypoint/RoycoDayEntryPoint.sol";
import {
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE,
    ADMIN_PAUSER_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    JT_LP_ROLE,
    LPT_LP_ROLE,
    PUBLIC_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE
} from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { PeripheryUpstream } from "../../config/DeploymentTypes.sol";
import { EnvConfig } from "../config/EnvConfig.sol";
import { RoycoDeterministic } from "../utils/RoycoDeterministic.sol";
import { DeployScriptBase } from "./DeployScriptBase.sol";

/**
 * @title DeployPeripheryComponent
 * @notice Deploys (or reuses) the chain's periphery singletons — the Royco Day entry point and the market syncer,
 *         each impl + ERC1967 proxy — and wires their full role surface on first deployment.
 */
contract DeployPeripheryComponent is DeployScriptBase, EnvConfig {
    PeripheryUpstream internal UP;

    constructor(bool _isTestEnv, PeripheryUpstream memory _up) {
        isTestEnv = _isTestEnv;
        UP = _up;
    }

    /// @notice Deploys the periphery under its own broadcast
    function execute(uint256 _deployerPrivateKey) public returns (address entryPoint, address marketSyncer) {
        vm.startBroadcast(_deployerPrivateKey);
        (entryPoint, marketSyncer) = _execute();
        vm.stopBroadcast();
    }

    function _execute() internal returns (address entryPoint, address marketSyncer) {
        AccessManager accessManager = AccessManager(UP.accessManager);

        // Deploy the entry point implementation + proxy, initialized with no tranche configs.
        (address entryPointImpl, bool entryPointImplExisted) = deployWithSanityChecks(
            _singletonSalt("ROYCO_DAY_ENTRY_POINT_IMPLEMENTATION"), abi.encodePacked(type(RoycoDayEntryPoint).creationCode, abi.encode(UP.factory)), false
        );
        _logDeploy("EntryPoint (impl)  ", entryPointImpl, entryPointImplExisted);
        bool entryPointExisted;
        (entryPoint, entryPointExisted) = deployWithSanityChecks(
            _singletonSalt("ROYCO_DAY_ENTRY_POINT_PROXY"), getERC1967ProxyCreationCode(entryPointImpl, RoycoDeterministic.entryPointInitData()), false
        );
        _logDeploy("EntryPoint (proxy) ", entryPoint, entryPointExisted);

        // Deploy the market syncer implementation + proxy, initialized with no registered kernels.
        (address syncerImpl, bool syncerImplExisted) =
            deployWithSanityChecks(_singletonSalt("ROYCO_MARKET_SYNCER_IMPLEMENTATION"), type(RoycoMarketSyncer).creationCode, false);
        _logDeploy("MarketSyncer (impl)", syncerImpl, syncerImplExisted);
        bool syncerExisted;
        (marketSyncer, syncerExisted) = deployWithSanityChecks(
            _singletonSalt("ROYCO_MARKET_SYNCER_PROXY"), getERC1967ProxyCreationCode(syncerImpl, RoycoDeterministic.syncerInitData(UP.accessManager)), false
        );
        _logDeploy("MarketSyncer (proxy)", marketSyncer, syncerExisted);

        // Both must land on the addresses the core's gatekeeper was already built around, which is the check the
        // gatekeeper's constructor can no longer make
        (address predictedEntryPoint, address predictedMarketSyncer) = RoycoDeterministic.predictPeripherySingletons(UP.accessManager, UP.factory, isTestEnv);
        require(entryPoint == predictedEntryPoint && marketSyncer == predictedMarketSyncer, "periphery address mismatch");
        require(IRoycoDayEntryPoint(entryPoint).ROYCO_FACTORY() == UP.factory, "entry point bound to a different factory");

        // Wire each singleton's full role surface on first deployment. Runs before the role graph re-points any
        // role admins, so the LP role grants below can be made by the deployer (ADMIN_ROLE).
        if (!entryPointExisted) _wireEntryPointRoles(accessManager, entryPoint);
        if (!syncerExisted) _wireSyncerRoles(accessManager, marketSyncer);
    }

    /// @notice Binds the entry point's selectors to their roles and grants it the tranche LP roles.
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
        _accessManager.grantRole(ST_LP_ROLE, _entryPoint, 0);
        _accessManager.grantRole(JT_LP_ROLE, _entryPoint, 0);
        _accessManager.grantRole(LPT_LP_ROLE, _entryPoint, 0);

        // The entry point syncs each market before it acts on it. Granted here rather than per market deployment: the
        // role is market-agnostic and the entry point is an existing singleton, which a deployment may never touch.
        _accessManager.grantRole(SYNC_ROLE, _entryPoint, 0);
    }

    /// @notice Binds the syncer's selectors to their roles and grants it SYNC_ROLE.
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
}

/// @notice CLI entrypoint: upstream addresses default to the deterministic predictions for the env's deployer
contract DeployPeriphery is DeployPeripheryComponent {
    constructor() DeployPeripheryComponent(vm.envOr("IS_TEST_DEPLOYMENT", false), _predictUpstream()) { }

    function _predictUpstream() internal view returns (PeripheryUpstream memory) {
        bool isTest = vm.envOr("IS_TEST_DEPLOYMENT", false);
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        return PeripheryUpstream({
            accessManager: RoycoDeterministic.create2Address(
                RoycoDeterministic.singletonSalt("ROYCO_ACCESS_MANAGER", isTest),
                keccak256(abi.encodePacked(type(RoycoAccessManager).creationCode, abi.encode(deployer)))
            ),
            factory: RoycoDeterministic.predictFactoryProxy(deployer, isTest)
        });
    }

    function run() external {
        enableLogging();
        execute(vm.envUint("DEPLOYER_PRIVATE_KEY"));
    }
}
