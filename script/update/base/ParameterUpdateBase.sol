// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { ChainlinkFreshness } from "../../upgrade/base/ChainlinkFreshness.sol";
import { AccessManagerConfigUtils } from "../../utils/AccessManagerConfigUtils.sol";
import { UpdateConfig } from "./UpdateConfig.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/**
 * @title ParameterUpdateBase
 * @notice Base for generating Safe transaction batches for timelocked parameter updates through the AccessManager.
 */
abstract contract ParameterUpdateBase is AccessManagerConfigUtils, UpdateConfig {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Output base directory for update batches
    string internal constant UPDATE_OUTPUT_DIRECTORY = "output/update/";

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice One parameter update operation
    struct UpdateParams {
        /// @dev Market name
        string marketName;
        /// @dev The target contract to call
        address target;
        /// @dev ABI-encoded call to the setter
        bytes callData;
        /// @dev Human-readable description shown in the Safe UI
        string description;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error VerificationFailed(string reason);
    error NoUpdatesForChain(uint256 chainId);
    error SchedulerLacksRole(address scheduler, address target, bytes4 selector);

    // ═══════════════════════════════════════════════════════════════════════════
    // MULTI-CHAIN PROCESSING
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Forks `_chainId`, simulates each update in isolation, then writes the Safe batches for this chain.
     * @param _chainId The chain to process
     * @param _updates The updates for this chain
     * @param _outputSubdir Subdirectory under output/update/ (e.g. "accountant")
     * @param _outputPrefix File name prefix (e.g. "set_coverage")
     * @param _batchDescription Overall description shown in the Safe UI
     */
    function _processChain(
        uint256 _chainId,
        UpdateParams[] memory _updates,
        string memory _outputSubdir,
        string memory _outputPrefix,
        string memory _batchDescription
    )
        internal
    {
        require(_updates.length > 0, NoUpdatesForChain(_chainId));

        vm.createSelectFork(_getRpcUrl(_chainId));
        _prepareChain(_chainId);

        console2.log("");
        console2.log("========================================");
        console2.log("Processing chain:", _chainId);
        console2.log("  Updates:", _updates.length);
        console2.log("========================================");

        /// Simulate each update in isolation (snapshot/revert), validating authorization and effect
        for (uint256 i = 0; i < _updates.length; i++) {
            uint256 snapshot = vm.snapshotState();
            _simulate(_updates[i]);
            vm.revertToState(snapshot);
        }

        // Partition into scheduled (delayed role) and direct (immediate role) ops
        uint256 scheduledCount;
        for (uint256 i = 0; i < _updates.length; i++) {
            (, uint32 delay) = _classify(_updates[i]);
            if (delay != 0) scheduledCount++;
        }
        uint256 directCount = _updates.length - scheduledCount;

        SafeTransaction[] memory scheduleTxs = new SafeTransaction[](scheduledCount);
        SafeTransaction[] memory executeTxs = new SafeTransaction[](scheduledCount);
        SafeTransaction[] memory cancelTxs = new SafeTransaction[](scheduledCount);
        SafeTransaction[] memory directTxs = new SafeTransaction[](directCount);

        uint256 s;
        uint256 d;
        for (uint256 i = 0; i < _updates.length; i++) {
            (address scheduler, uint32 delay) = _classify(_updates[i]);
            if (delay == 0) {
                directTxs[d++] = SafeTransaction({ to: _updates[i].target, value: 0, data: _updates[i].callData });
            } else {
                scheduleTxs[s] = _buildScheduleTx(_updates[i]);
                executeTxs[s] = _buildExecuteTx(_updates[i]);
                cancelTxs[s] = _buildCancelTx(_updates[i], scheduler);
                s++;
            }
        }

        vm.createDir(string.concat(UPDATE_OUTPUT_DIRECTORY, _outputSubdir), true);
        string memory fileBase = string.concat(_outputSubdir, "/", vm.toString(_chainId), "_", _outputPrefix);

        if (scheduledCount > 0) {
            _writeUpdateSafeTransactionJson(
                scheduleTxs, string.concat(fileBase, "_schedule"), _batchDescription, string.concat(_batchDescription, " (schedule)")
            );
            _writeUpdateSafeTransactionJson(executeTxs, string.concat(fileBase, "_execute"), _batchDescription, string.concat(_batchDescription, " (execute)"));
            _writeUpdateSafeTransactionJson(cancelTxs, string.concat(fileBase, "_cancel"), _batchDescription, string.concat(_batchDescription, " (cancel)"));
        }
        if (directCount > 0) {
            _writeUpdateSafeTransactionJson(
                directTxs, string.concat(fileBase, "_direct"), _batchDescription, string.concat(_batchDescription, " (direct call)")
            );
        }

        console2.log("");
        console2.log("  Output:", string.concat(UPDATE_OUTPUT_DIRECTORY, fileBase, "_*.json"));
        console2.log("  Scheduled ops:", scheduledCount, " Direct ops:", directCount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CLASSIFICATION (role → scheduler → delay, read from the live AccessManager)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Resolves the multisig that submits `_p` and its execution delay for the target function.
     */
    function _classify(UpdateParams memory _p) internal view returns (address scheduler, uint32 delay) {
        bytes4 selector = bytes4(_p.callData);
        uint64 roleId = IAccessManager(ACCESS_MANAGER).getTargetFunctionRole(_p.target, selector);
        scheduler = _roleScheduler(roleId);
        bool isMember;
        (isMember, delay) = IAccessManager(ACCESS_MANAGER).hasRole(roleId, scheduler);
        require(isMember, SchedulerLacksRole(scheduler, _p.target, selector));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TRANSACTION BUILDERS (single tx; scheduled ops target the AccessManager)
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildScheduleTx(UpdateParams memory _p) internal pure returns (SafeTransaction memory) {
        return SafeTransaction({ to: ACCESS_MANAGER, value: 0, data: abi.encodeCall(IAccessManager.schedule, (_p.target, _p.callData, uint48(0))) });
    }

    function _buildExecuteTx(UpdateParams memory _p) internal pure returns (SafeTransaction memory) {
        return SafeTransaction({ to: ACCESS_MANAGER, value: 0, data: abi.encodeCall(IAccessManager.execute, (_p.target, _p.callData)) });
    }

    function _buildCancelTx(UpdateParams memory _p, address _scheduler) internal pure returns (SafeTransaction memory) {
        return SafeTransaction({ to: ACCESS_MANAGER, value: 0, data: abi.encodeCall(IAccessManager.cancel, (_scheduler, _p.target, _p.callData)) });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SIMULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Simulates one update the exact way it will be submitted: a direct call for an immediate-delay role, or
     *         schedule → warp to the AM's scheduled timestamp → execute for a delayed role. Runs the `_verify` hook.
     * @dev For delayed ops, Chainlink-style oracles registered in `UpdateConfig._chainlinkOracles` are captured before
     *      the warp and re-mocked afterward with `updatedAt = block.timestamp`, so downstream staleness checks pass.
     */
    function _simulate(UpdateParams memory _p) internal {
        console2.log("  Simulating:", _p.description);
        (address scheduler, uint32 delay) = _classify(_p);

        if (delay == 0) {
            vm.prank(scheduler);
            (bool ok, bytes memory ret) = _p.target.call(_p.callData);
            require(ok, _decodeDirectRevert(ret));
            console2.log("    [OK] Direct call");
        } else {
            vm.prank(scheduler);
            (bytes32 operationId,) = IAccessManager(ACCESS_MANAGER).schedule(_p.target, _p.callData, uint48(0));
            console2.log("    [OK] Schedule (authorization validated)");

            address[] memory oracles = getChainlinkOracles(block.chainid);
            bytes[] memory oraclePre = ChainlinkFreshness.capture(oracles);

            uint48 executableAt = IAccessManager(ACCESS_MANAGER).getSchedule(operationId);
            require(executableAt != 0, VerificationFailed("schedule did not register"));
            vm.warp(uint256(executableAt));

            ChainlinkFreshness.mockFresh(oracles, oraclePre);

            vm.prank(scheduler);
            IAccessManager(ACCESS_MANAGER).execute(_p.target, _p.callData);
            console2.log("    [OK] Execute (after the timelock elapses)");
        }

        _verify(_p);
        console2.log("    [OK] Verification");
    }

    function _decodeDirectRevert(bytes memory _ret) internal pure returns (string memory) {
        if (_ret.length >= 4) {
            bytes memory hexAlphabet = "0123456789abcdef";
            bytes memory out = new bytes(8);
            bytes4 sel = bytes4(_ret);
            for (uint256 i = 0; i < 4; i++) {
                uint8 b = uint8(sel[i]);
                out[2 * i] = hexAlphabet[b >> 4];
                out[2 * i + 1] = hexAlphabet[b & 0x0f];
            }
            return string.concat("Direct call reverted; selector=0x", string(out));
        }
        return "Direct call reverted";
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION HOOK
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Override in leaf scripts to assert the parameter landed. Called after each simulated op; must revert on failure.
    function _verify(UpdateParams memory _params) internal view virtual;

    /// @notice Hook invoked right after each chain's fork is created, before any classification or simulation.
    /// @dev Override in leaf scripts that must stage per-chain state the ops depend on — e.g. broadcasting
    ///      permissionless deployments the admin ops then reference, or pre-applying a pending governance op the
    ///      classification requires. Default is a no-op.
    function _prepareChain(uint256 _chainId) internal virtual { }

    // ═══════════════════════════════════════════════════════════════════════════
    // RPC URL RESOLUTION
    // ═══════════════════════════════════════════════════════════════════════════

    function _getRpcUrl(uint256 _chainId) internal view returns (string memory) {
        if (_chainId == MAINNET) return vm.envString("MAINNET_RPC_URL");
        if (_chainId == AVALANCHE) return vm.envString("AVALANCHE_RPC_URL");
        if (_chainId == ARBITRUM) return vm.envString("ARBITRUM_RPC_URL");
        if (_chainId == BASE) return vm.envString("BASE_RPC_URL");
        revert("Unknown chain ID");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // JSON OUTPUT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Writes a Safe Transaction Builder compatible JSON to the update output directory
    function _writeUpdateSafeTransactionJson(
        SafeTransaction[] memory _transactions,
        string memory _outputFileName,
        string memory _name,
        string memory _description
    )
        internal
    {
        string[] memory txJsons = new string[](_transactions.length);
        for (uint256 i = 0; i < _transactions.length; i++) {
            string memory key = string.concat("tx", vm.toString(i));
            vm.serializeAddress(key, "to", _transactions[i].to);
            vm.serializeString(key, "value", vm.toString(_transactions[i].value));
            txJsons[i] = vm.serializeBytes(key, "data", _transactions[i].data);
        }

        string memory root = "root";
        vm.serializeString(root, "version", "1.0");
        vm.serializeString(root, "chainId", vm.toString(block.chainid));
        vm.serializeUint(root, "createdAt", vm.getBlockTimestamp());

        string memory meta = "meta";
        vm.serializeString(meta, "name", _name);
        string memory metaJson = vm.serializeString(meta, "description", _description);
        vm.serializeString(root, "meta", metaJson);

        string memory finalJson = vm.serializeString(root, "transactions", txJsons);

        vm.writeJson(finalJson, string(abi.encodePacked(UPDATE_OUTPUT_DIRECTORY, _outputFileName, ".json")));
    }
}
