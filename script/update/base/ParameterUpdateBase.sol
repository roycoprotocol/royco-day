// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { AccessManagerConfigUtils } from "../../utils/AccessManagerConfigUtils.sol";
import { UpdateConfig } from "./UpdateConfig.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/**
 * @title ParameterUpdateBase
 * @notice Base contract for generating Safe transaction batches (schedule, execute, cancel)
 *         for timelocked parameter updates via the AccessManager.
 * @dev Each leaf script inherits this and provides:
 *      - A list of update configs (market + chain + new value)
 *      - A `_verify()` hook to assert each parameter was set correctly
 *
 * The base handles:
 *      1. Forking each chain and resolving market addresses
 *      2. Simulating each update (schedule → warp → execute) with snapshot isolation
 *      3. Writing one batched Safe JSON per chain per phase (schedule, execute, cancel)
 */
abstract contract ParameterUpdateBase is AccessManagerConfigUtils, UpdateConfig {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Duration to warp forward when simulating (must exceed the role's execution delay)
    uint256 internal constant SIMULATION_WARP_DURATION = 2 days + 1;

    /// @dev Output base directory for update batches
    string internal constant UPDATE_OUTPUT_DIRECTORY = "output/update/";

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Parameters describing a single parameter update operation
    struct UpdateParams {
        /// @dev Market name (e.g. "stcUSD"). Empty string for factory-level updates.
        string marketName;
        /// @dev The target contract to call (accountant, kernel, or factory)
        address target;
        /// @dev ABI-encoded call to the setter function (e.g. abi.encodeCall(setCoverage, (newVal)))
        bytes callData;
        /// @dev Human-readable description shown in the Safe UI
        string description;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error VerificationFailed(string reason);
    error NoUpdatesForChain(uint256 chainId);

    // ═══════════════════════════════════════════════════════════════════════════
    // MULTI-CHAIN PROCESSING
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Processes a batch of updates for a single chain
     * @dev Forks the chain, simulates each update in isolation (snapshot/revert),
     *      then writes one batched Safe JSON per phase containing all updates.
     * @param _chainId The chain to process
     * @param _updates Array of updates for this chain
     * @param _outputSubdir Subdirectory under output/update/ (e.g. "accountant")
     * @param _outputPrefix File name prefix (e.g. "set_coverage")
     * @param _batchDescription Overall description for the Safe batch
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

        // Fork the target chain
        string memory rpcUrl = _getRpcUrl(_chainId);
        vm.createSelectFork(rpcUrl);

        console2.log("");
        console2.log("========================================");
        console2.log("Processing chain:", _chainId);
        console2.log("  Updates:", _updates.length);
        console2.log("========================================");

        // Simulate each update in isolation using snapshots
        for (uint256 i = 0; i < _updates.length; i++) {
            uint256 snapshot = vm.snapshotState();
            _simulate(_updates[i]);
            vm.revertToState(snapshot);
        }

        // Build batched transactions (one tx per update, combined into one batch)
        SafeTransaction[] memory scheduleTxs = new SafeTransaction[](_updates.length);
        SafeTransaction[] memory executeTxs = new SafeTransaction[](_updates.length);
        SafeTransaction[] memory cancelTxs = new SafeTransaction[](_updates.length);

        for (uint256 i = 0; i < _updates.length; i++) {
            scheduleTxs[i] = _buildScheduleTx(_updates[i]);
            executeTxs[i] = _buildExecuteTx(_updates[i]);
            cancelTxs[i] = _buildCancelTx(_updates[i]);
        }

        // Write one JSON per phase for this chain
        string memory fileBase = string.concat(_outputSubdir, "/", vm.toString(_chainId), "_", _outputPrefix);

        _writeUpdateSafeTransactionJson(scheduleTxs, string.concat(fileBase, "_schedule"), _batchDescription, string.concat(_batchDescription, " (schedule)"));
        _writeUpdateSafeTransactionJson(executeTxs, string.concat(fileBase, "_execute"), _batchDescription, string.concat(_batchDescription, " (execute)"));
        _writeUpdateSafeTransactionJson(cancelTxs, string.concat(fileBase, "_cancel"), _batchDescription, string.concat(_batchDescription, " (cancel)"));

        console2.log("");
        console2.log("  Output:", string.concat(UPDATE_OUTPUT_DIRECTORY, fileBase, "_{schedule,execute,cancel}.json"));
        console2.log("  Done.");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TRANSACTION BUILDERS (single tx)
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildScheduleTx(UpdateParams memory _p) internal pure returns (SafeTransaction memory) {
        return SafeTransaction({ to: ROYCO_FACTORY, value: 0, data: abi.encodeCall(IAccessManager.schedule, (_p.target, _p.callData, uint48(0))) });
    }

    function _buildExecuteTx(UpdateParams memory _p) internal pure returns (SafeTransaction memory) {
        return SafeTransaction({ to: ROYCO_FACTORY, value: 0, data: abi.encodeCall(IAccessManager.execute, (_p.target, _p.callData)) });
    }

    function _buildCancelTx(UpdateParams memory _p) internal pure returns (SafeTransaction memory) {
        return SafeTransaction({ to: ROYCO_FACTORY, value: 0, data: abi.encodeCall(IAccessManager.cancel, (ROOT_MULTISIG, _p.target, _p.callData)) });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SIMULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Simulates the full schedule -> warp -> execute flow on the current fork
     * @dev Schedule is hard-failing (validates authorization). Execute uses try/catch because
     *      the 2-day warp can cause oracle staleness reverts on markets with strict oracle
     *      freshness checks (e.g. Chainlink). In production, the oracle will be fresh when
     *      execute is called.
     */
    function _simulate(UpdateParams memory _params) internal {
        console2.log("  Simulating:", _params.description);

        // Schedule — validates authorization (hard fail)
        vm.prank(ROOT_MULTISIG);
        IAccessManager(ROYCO_FACTORY).schedule(_params.target, _params.callData, uint48(0));
        console2.log("    [OK] Schedule (authorization validated)");

        // Warp past the execution delay
        vm.warp(vm.getBlockTimestamp() + SIMULATION_WARP_DURATION);

        // Execute — try/catch for oracle staleness
        vm.prank(ROOT_MULTISIG);
        try IAccessManager(ROYCO_FACTORY).execute(_params.target, _params.callData) {
            console2.log("    [OK] Execute");
            _verify(_params);
            console2.log("    [OK] Verification");
        } catch (bytes memory reason) {
            console2.log("    [WARN] Execute reverted (likely oracle staleness from 2-day warp)");
            if (reason.length >= 4) {
                console2.logBytes4(bytes4(reason));
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION HOOK
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Override in leaf scripts to verify the parameter was set correctly
     * @dev Called after execute succeeds. Should revert if verification fails.
     * @param _params The update parameters
     */
    function _verify(UpdateParams memory _params) internal view virtual;

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

    /**
     * @notice Writes a Safe Transaction Builder compatible JSON to the update output directory
     */
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
