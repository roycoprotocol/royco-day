// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Create2DeployUtils } from "../../utils/Create2DeployUtils.sol";
import { Script } from "lib/forge-std/src/Script.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/**
 * @title DeployScriptBase
 * @notice The shared plumbing every component deployment script builds on: idempotent CREATE2 deployment (via
 *         Create2DeployUtils), disposition logging, and the selector-array helper for role bindings.
 * @dev Each component script BROADCASTS ITS OWN transactions (`vm.startBroadcast` inside its `execute`), so an
 *      orchestrator composes components without ever broadcasting itself — nested broadcasts revert.
 */
abstract contract DeployScriptBase is Script, Create2DeployUtils {
    /// @notice Gates the per-contract disposition logging (CLI entrypoints turn it on)
    bool internal ENABLE_LOGGING = false;

    /// @dev Prints a phase header (gated on `ENABLE_LOGGING`).
    function _logSection(string memory _title) internal view {
        if (ENABLE_LOGGING) console2.log(string.concat("\n== ", _title, " =="));
    }

    /// @dev Prints one contract's disposition: `[deployed]` (freshly created) or `[reused]` (found at its
    ///      deterministic address). `_reused` is the `isAlreadyDeployed` flag the deterministic deployers return.
    function _logDeploy(string memory _name, address _addr, bool _reused) internal view {
        if (ENABLE_LOGGING) console2.log(string.concat(_reused ? "  [reused]   " : "  [deployed] ", _name), _addr);
    }

    /// @dev Prints a contract that is always freshly created (no deterministic reuse), e.g. the pool / BPT oracle.
    function _logCreated(string memory _name, address _addr) internal view {
        if (ENABLE_LOGGING) console2.log(string.concat("  [deployed] ", _name), _addr);
    }

    /// @notice Enables disposition logging (called by CLI entrypoints and orchestrators)
    function enableLogging() public {
        ENABLE_LOGGING = true;
    }

    /// @notice Wraps a single selector into the one-element array `setTargetFunctionRole` expects.
    function _sel(bytes4 _selector) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = _selector;
    }
}
