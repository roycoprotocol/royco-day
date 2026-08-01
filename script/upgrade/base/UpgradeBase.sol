// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { UUPSUpgradeable } from "../../../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

import { IBeacon } from "../../../lib/openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol";
import { UpgradeableBeacon } from "../../../lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { AccessManagerConfigUtils } from "../../utils/AccessManagerConfigUtils.sol";
import { Create2DeployUtils } from "../../utils/Create2DeployUtils.sol";
import { ChainlinkFreshness } from "./ChainlinkFreshness.sol";
import { UpgradeConfig } from "./UpgradeConfig.sol";

/**
 * @title UpgradeBase
 * @notice Base contract for generating Safe transaction batches that upgrade UUPS proxies
 *         (RoycoVaultTranche, Kernel, Accountant, Factory) through the AccessManager timelock.
 *
 * @dev Decoupled from the parameter-update system. Reads all deployed addresses from
 *      `UpgradeConfig`. Responsibilities:
 *        - Reading the ERC1967 implementation slot of a proxy
 *        - Building the `upgradeToAndCall` calldata
 *        - Pre-deploying every new implementation via CREATE2 (`vm.broadcast`)
 *        - Batched simulation that mirrors the production execution path:
 *            schedule all → capture oracle snapshots → warp 2 days → mock oracles fresh → execute each → verify each
 *        - Writing one Safe JSON per phase per chain
 */
abstract contract UpgradeBase is UpgradeConfig, AccessManagerConfigUtils, Create2DeployUtils {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant SIMULATION_WARP_DURATION = 2 days + 1;
    string internal constant UPGRADE_OUTPUT_DIRECTORY = "output/upgrade/";

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    struct UpgradeCall {
        string marketName;
        address target;
        bytes callData;
        string description;
    }

    /// @dev Pre-upgrade state is not stored — it's captured post-warp via `module.snapshotState`.
    /// @dev `beacon` is the component's upgrade beacon for a per-market component, or the proxy itself for a
    ///      self-upgrading singleton like the factory. A beacon upgrade moves every market of that type at once.
    struct PreparedUpgrade {
        address beacon;
        address oldImpl;
        address newImpl;
        bytes32 implSalt;
        bytes implCreationCode;
        UpgradeCall call;
        string label;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error UpgradeBase__LengthMismatch();
    error UpgradeBase__NoUpgrades();
    error UpgradeBase__DeploymentAddressMismatch(address expected, address actual);
    error UpgradeBase__UnknownChainId(uint256 chainId);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC1967 + UPGRADE CALLDATA HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Reads a self-upgrading singleton's implementation out of its ERC-1967 slot
    /// @dev Never point this at a beacon proxy: it writes the beacon slot and leaves the implementation slot empty,
    ///      so this would return the zero address silently rather than reverting
    function _readImplementation(address _proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(_proxy, ERC1967_IMPL_SLOT))));
    }

    /// @dev Reads the implementation a component beacon currently points every market's proxy at
    function _readBeaconImplementation(address _beacon) internal view returns (address) {
        return IBeacon(_beacon).implementation();
    }

    /// @dev The upgrade call for a component beacon: moves every market of that type in one call
    function _buildBeaconUpgradeCallData(address _newImpl) internal pure returns (bytes memory) {
        return abi.encodeCall(UpgradeableBeacon.upgradeTo, (_newImpl));
    }

    /// @dev The upgrade call for a self-upgrading singleton (the factory, entry point, and blacklist)
    function _buildUpgradeCallData(address _newImpl) internal pure returns (bytes memory) {
        return abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (_newImpl, ""));
    }

    function _predictImpl(bytes32 _salt, bytes memory _creationCode) internal pure returns (address newImpl) {
        newImpl = generateDeterminsticAddress(_salt, _creationCode);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORCHESTRATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _processChainUpgrades(uint256 _chainId, PreparedUpgrade[] memory _ups, address[] memory _modules) internal {
        require(_ups.length > 0, UpgradeBase__NoUpgrades());
        require(_ups.length == _modules.length, UpgradeBase__LengthMismatch());

        address factory = getFactory(_chainId);
        // Derive per-market sync kernels: for each upgrade, if it is the first one encountered for
        // its market in this chain's batch, capture the kernel address to be synced first. Sync
        // entries are emitted only in the execute phase, never in schedule or cancel.
        address[] memory syncKernelBefore = _deriveSyncKernelsBeforeUpgrades(_chainId, _ups);

        _logChainHeader(_chainId, factory, _ups);
        _deployImpls(_ups);
        _simulateBatchedUpgrades(factory, _ups, _modules, syncKernelBefore);
        _writeJsonsForChain(_chainId, factory, _ups, syncKernelBefore);
    }

    /// @dev Returns an array parallel to `_ups`. `syncKernelBefore[i]` is the kernel address whose
    ///      `syncTrancheAccounting()` must be invoked immediately before `_ups[i]` executes; `address(0)`
    ///      means no sync is needed for that position (either the market was already synced earlier in
    ///      the batch, or the upgrade is not market-scoped, e.g. a factory upgrade).
    function _deriveSyncKernelsBeforeUpgrades(uint256 _chainId, PreparedUpgrade[] memory _ups) internal view returns (address[] memory syncKernelBefore) {
        syncKernelBefore = new address[](_ups.length);
        // A component upgrade now moves every market of that type at once, so the accounting of every market on the
        // chain must be settled against the outgoing implementation first. Only the first such upgrade in the batch
        // carries the sync: the rest execute in the same transaction sequence with nothing having moved in between.
        for (uint256 i = 0; i < _ups.length; i++) {
            if (bytes(_ups[i].call.marketName).length == 0) continue; // singletons (the factory) have no market scope
            syncKernelBefore[i] = getMarketSyncer(_chainId);
            return syncKernelBefore;
        }
    }

    function _logChainHeader(uint256 _chainId, address _factory, PreparedUpgrade[] memory _ups) private view {
        console2.log("========================================");
        console2.log("Processing chain:", _chainId);
        console2.log("  Factory :", _factory);
        console2.log("  Upgrades:", _ups.length);
        console2.log("========================================");
        for (uint256 i = 0; i < _ups.length; i++) {
            _logOneUpgrade(_ups[i]);
        }
    }

    function _logOneUpgrade(PreparedUpgrade memory _up) private view {
        console2.log("  ", _up.label);
        console2.log("    beacon  :", _up.beacon);
        console2.log("    oldImpl :", _up.oldImpl);
        console2.log("    newImpl :", _up.newImpl, _up.newImpl.code.length != 0 ? "(already deployed)" : "(to deploy)");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IMPLEMENTATION DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    function _deployImpls(PreparedUpgrade[] memory _ups) internal {
        // Broadcast as the deployer key from env so the impls deploy from a known address when
        // run with `--broadcast`. Without `--broadcast` the calls still execute against the fork
        // but no on-chain tx is sent.
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        for (uint256 i = 0; i < _ups.length; i++) {
            _deployOneImpl(_ups[i]);
        }
        vm.stopBroadcast();
    }

    function _deployOneImpl(PreparedUpgrade memory _up) private {
        if (_up.newImpl.code.length != 0) return;
        (address deployed,) = deployWithSanityChecks(_up.implSalt, _up.implCreationCode, false);
        require(deployed == _up.newImpl, UpgradeBase__DeploymentAddressMismatch(_up.newImpl, deployed));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SIMULATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _simulateBatchedUpgrades(address _factory, PreparedUpgrade[] memory _ups, address[] memory _modules, address[] memory _syncKernelBefore) internal {
        _scheduleAll(_factory, _ups);
        console2.log("  [OK] Scheduled", _ups.length, "upgrades");

        // Snapshot Chainlink-style oracle data BEFORE the warp; mock back with
        // `updatedAt = block.timestamp` afterward to defeat downstream staleness checks.
        address[] memory oracles = getChainlinkOracles(block.chainid);
        bytes[] memory oraclePre = ChainlinkFreshness.capture(oracles);

        vm.warp(vm.getBlockTimestamp() + SIMULATION_WARP_DURATION);

        ChainlinkFreshness.mockFresh(oracles, oraclePre);

        _executeAndVerifyAll(_factory, _ups, _modules, _syncKernelBefore);
    }

    function _scheduleAll(address _factory, PreparedUpgrade[] memory _ups) private {
        for (uint256 i = 0; i < _ups.length; i++) {
            vm.prank(ROOT_MULTISIG);
            IAccessManager(_factory).schedule(_ups[i].call.target, _ups[i].call.callData, uint48(0));
        }
    }

    function _executeAndVerifyAll(address _factory, PreparedUpgrade[] memory _ups, address[] memory _modules, address[] memory _syncKernelBefore) private {
        for (uint256 i = 0; i < _ups.length; i++) {
            if (_syncKernelBefore[i] != address(0)) {
                _syncKernel(_factory, _ups[i].call.marketName, _syncKernelBefore[i]);
            }
            _executeAndVerifyOne(_factory, _ups[i], _modules[i]);
        }
    }

    function _executeAndVerifyOne(address _factory, PreparedUpgrade memory _up, address _module) private {
        bytes memory preSnapshot = IUpgradeVerifier(_module).snapshotState(_up.beacon);
        vm.prank(ROOT_MULTISIG);
        IAccessManager(_factory).execute(_up.call.target, _up.call.callData);
        IUpgradeVerifier(_module).verify(_up.beacon, preSnapshot);
        console2.log("  [OK] Executed + verified:", _up.label);
    }

    function _syncKernel(address _factory, string memory _marketName, address _syncer) private {
        vm.prank(ROOT_MULTISIG);
        IAccessManager(_factory).execute(_syncer, _buildSyncCallData());
        console2.log("  [OK] Synced every market on the chain before:", _marketName);
    }

    /// @dev Settles every registered market's accounting in one call. `false` so a market that cannot sync fails the
    ///      batch loudly rather than being upgraded on stale accounting
    function _buildSyncCallData() internal pure returns (bytes memory) {
        return abi.encodeCall(RoycoMarketSyncer.executeBatchAccountingSync, (false));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TRANSACTION BUILDERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildScheduleTx(address _factory, UpgradeCall memory _c) internal pure returns (SafeTransaction memory) {
        return SafeTransaction({ to: _factory, value: 0, data: abi.encodeCall(IAccessManager.schedule, (_c.target, _c.callData, uint48(0))) });
    }

    function _buildExecuteTx(address _factory, UpgradeCall memory _c) internal pure returns (SafeTransaction memory) {
        return SafeTransaction({ to: _factory, value: 0, data: abi.encodeCall(IAccessManager.execute, (_c.target, _c.callData)) });
    }

    function _buildCancelTx(address _factory, UpgradeCall memory _c) internal pure returns (SafeTransaction memory) {
        return SafeTransaction({ to: _factory, value: 0, data: abi.encodeCall(IAccessManager.cancel, (ROOT_MULTISIG, _c.target, _c.callData)) });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RPC URL RESOLUTION
    // ═══════════════════════════════════════════════════════════════════════════

    function _getRpcUrl(uint256 _chainId) internal view returns (string memory) {
        if (_chainId == MAINNET) return vm.envString("MAINNET_RPC_URL");
        if (_chainId == AVALANCHE) return vm.envString("AVALANCHE_RPC_URL");
        if (_chainId == ARBITRUM) return vm.envString("ARBITRUM_RPC_URL");
        if (_chainId == BASE) return vm.envString("BASE_RPC_URL");
        revert UpgradeBase__UnknownChainId(_chainId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // JSON OUTPUT
    // ═══════════════════════════════════════════════════════════════════════════

    function _writeJsonsForChain(uint256 _chainId, address _factory, PreparedUpgrade[] memory _ups, address[] memory _syncKernelBefore) private {
        vm.createDir(UPGRADE_OUTPUT_DIRECTORY, true);
        string memory fileBase = vm.toString(_chainId);
        _writeOnePhase(_factory, _ups, _syncKernelBefore, 0, fileBase, "schedule");
        _writeOnePhase(_factory, _ups, _syncKernelBefore, 1, fileBase, "execute");
        _writeOnePhase(_factory, _ups, _syncKernelBefore, 2, fileBase, "cancel");
    }

    /// @dev Builds and writes one phase batch JSON. Per-tx serialization (including the per-tx
    ///      description) happens inline via `_serializeOneUpgradeTx` so the parallel `txs` /
    ///      `descriptions` arrays from earlier never live simultaneously on the stack — this keeps
    ///      via-IR's stack budget happy.
    ///
    /// @dev Sync TXs are interleaved only into the execute phase (phase == 1). For the schedule
    ///      and cancel phases the sync calls are omitted: syncs run with no delay and have nothing
    ///      to roll back.
    function _writeOnePhase(
        address _factory,
        PreparedUpgrade[] memory _ups,
        address[] memory _syncKernelBefore,
        uint8 _phase,
        string memory _fileBase,
        string memory _suffix
    )
        private
    {
        string memory path = string.concat(UPGRADE_OUTPUT_DIRECTORY, _fileBase, "_", _suffix, ".json");
        string[] memory txJsons = _buildPhaseTxJsons(_factory, _ups, _syncKernelBefore, _phase, _suffix);
        vm.writeJson(_wrapTxsInRoot(txJsons, string.concat("Royco upgrade batch (chain ", _fileBase, ") - ", _suffix)), path);
    }

    /// @dev Materializes the per-phase array of serialized Safe TX JSONs. Sync TXs are interleaved
    ///      only when `_phase == 1` (execute).
    function _buildPhaseTxJsons(
        address _factory,
        PreparedUpgrade[] memory _ups,
        address[] memory _syncKernelBefore,
        uint8 _phase,
        string memory _suffix
    )
        private
        returns (string[] memory txJsons)
    {
        if (_phase != 1) {
            txJsons = new string[](_ups.length);
            for (uint256 i = 0; i < _ups.length; i++) {
                txJsons[i] = _serializeOneUpgradeTx(i, _factory, _ups[i], _phase, _suffix);
            }
            return txJsons;
        }
        txJsons = new string[](_countExecutePhaseTxs(_ups, _syncKernelBefore));
        _fillExecutePhaseTxJsons(txJsons, _factory, _ups, _syncKernelBefore, _suffix);
    }

    function _fillExecutePhaseTxJsons(
        string[] memory _txJsons,
        address _factory,
        PreparedUpgrade[] memory _ups,
        address[] memory _syncKernelBefore,
        string memory _suffix
    )
        private
    {
        uint256 outIdx;
        for (uint256 i = 0; i < _ups.length; i++) {
            address kernel = _syncKernelBefore[i];
            if (kernel != address(0)) {
                _txJsons[outIdx] = _serializeSyncTx(outIdx, _factory, _ups[i].call.marketName, kernel, _suffix);
                outIdx++;
            }
            _txJsons[outIdx] = _serializeOneUpgradeTx(outIdx, _factory, _ups[i], 1, _suffix);
            outIdx++;
        }
    }

    function _countExecutePhaseTxs(PreparedUpgrade[] memory _ups, address[] memory _syncKernelBefore) private pure returns (uint256 total) {
        total = _ups.length;
        for (uint256 i = 0; i < _ups.length; i++) {
            if (_syncKernelBefore[i] != address(0)) total++;
        }
    }

    /// @dev Serializes a `factory.execute(kernel, syncTrancheAccounting())` Safe TX. Used only in
    ///      the execute phase. The pre-upgrade sync flushes any pending PNL / fees through the
    ///      current accountant before its impl is swapped.
    function _serializeSyncTx(uint256 _i, address _factory, string memory _marketName, address _kernel, string memory _suffix) private returns (string memory) {
        SafeTransaction memory syncTx =
            SafeTransaction({ to: _factory, value: 0, data: abi.encodeCall(IAccessManager.execute, (_kernel, _buildSyncCallData())) });
        string memory key = string.concat("tx", vm.toString(_i));
        vm.serializeAddress(key, "to", syncTx.to);
        vm.serializeString(key, "value", vm.toString(syncTx.value));
        vm.serializeString(key, "description", string.concat("[", _suffix, "] Pre-upgrade sync of ", _marketName, " kernel ", vm.toString(_kernel)));
        return vm.serializeBytes(key, "data", syncTx.data);
    }

    /// @dev Each tx serializes as `{ to, value, data, description }`. The `description` is a
    ///      non-standard field (Safe Transaction Builder ignores unknown fields when importing) but
    ///      survives in the on-disk JSON so reviewers grepping the file can see per-tx intent.
    function _serializeOneUpgradeTx(
        uint256 _i,
        address _factory,
        PreparedUpgrade memory _up,
        uint8 _phase,
        string memory _suffix
    )
        private
        returns (string memory)
    {
        SafeTransaction memory phaseTx =
            _phase == 0 ? _buildScheduleTx(_factory, _up.call) : (_phase == 1 ? _buildExecuteTx(_factory, _up.call) : _buildCancelTx(_factory, _up.call));
        string memory key = string.concat("tx", vm.toString(_i));
        vm.serializeAddress(key, "to", phaseTx.to);
        vm.serializeString(key, "value", vm.toString(phaseTx.value));
        vm.serializeString(key, "description", string.concat("[", _suffix, "] ", _up.call.description));
        return vm.serializeBytes(key, "data", phaseTx.data);
    }

    function _wrapTxsInRoot(string[] memory _txJsons, string memory _name) private returns (string memory) {
        string memory root = "root";
        vm.serializeString(root, "version", "1.0");
        vm.serializeString(root, "chainId", vm.toString(block.chainid));
        vm.serializeUint(root, "createdAt", vm.getBlockTimestamp());

        string memory meta = "meta";
        vm.serializeString(meta, "name", _name);
        string memory metaJson = vm.serializeString(meta, "description", _name);
        vm.serializeString(root, "meta", metaJson);

        return vm.serializeString(root, "transactions", _txJsons);
    }
}

interface IUpgradeVerifier {
    function snapshotState(address proxy) external view returns (bytes memory snapshot);
    function verify(address proxy, bytes memory preStateSnapshot) external view;
}
