// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title SetCollateralAssetOracle
 * @notice Generates a Safe transaction batch for updating a kernel's collateral asset oracle
 *         address + staleness threshold across multiple markets and chains.
 *
 * @dev `setCollateralAssetOracle` on the kernel is gated by `ADMIN_ORACLE_ROLE`, which has an
 *      execution delay of 0 (Immediate per `Roles`). So this uses the harness's
 *      direct-call flow (`_processChainDirect`) — one Safe JSON per chain, no schedule/execute
 *      split. `ROOT_MULTISIG` holds the role on production factories.
 *
 *      Usage:
 *      1. Add/update config entries in `_initializeConfigs()`.
 *      2. Run: forge script script/update/kernel/SetCollateralAssetOracle.s.sol
 *      3. Import the JSON from output/update/kernel/{chainId}_set_collateral_asset_oracle.json
 *         into the ROOT Safe (same multisig that holds ADMIN_ORACLE_ROLE).
 */
contract SetCollateralAssetOracle is ParameterUpdateBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    string internal constant OUTPUT_SUBDIR = "kernel";
    string internal constant OUTPUT_PREFIX = "set_collateral_asset_oracle";
    string internal constant BATCH_DESCRIPTION = "Royco Kernel: update collateral asset oracle + staleness threshold";

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    struct SetCollateralAssetOracleConfig {
        uint256 chainId;
        string marketName;
        address newOracle;
        uint48 newStalenessThresholdSeconds;
        /// @dev If true, the kernel will sync tranche accounting at the *old* oracle price
        ///      before swapping in the new one. Set to false when migrating to a feed that's
        ///      already broken/stale to avoid reverting on a final sync.
        bool syncBeforeUpdate;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    SetCollateralAssetOracleConfig[] internal _configs;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeConfigs();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Configure collateral-asset-oracle updates here.
     * @dev The new oracle must be an `IRoycoPriceOracle` whose `COLLATERAL_ASSET()` matches the
     *      kernel's collateral asset (the kernel validates this on-chain).
     *      Example:
     *      ```
     *      _configs.push(SetCollateralAssetOracleConfig({
     *          chainId: MAINNET,
     *          marketName: SNUSD,
     *          newOracle: 0x...,
     *          newStalenessThresholdSeconds: 48 hours,
     *          syncBeforeUpdate: true
     *      }));
     *      ```
     */
    function _initializeConfigs() internal {
        // Populate with Day markets as they ship. Empty by default.
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        require(_configs.length > 0, "No configs defined");

        uint256[] memory chainIds = _getUniqueChainIds();

        for (uint256 c = 0; c < chainIds.length; c++) {
            uint256 chainId = chainIds[c];

            uint256 count = 0;
            for (uint256 i = 0; i < _configs.length; i++) {
                if (_configs[i].chainId == chainId) count++;
            }

            string memory rpcUrl = _getRpcUrl(chainId);
            vm.createSelectFork(rpcUrl);

            UpdateParams[] memory updates = new UpdateParams[](count);
            uint256 idx = 0;
            for (uint256 i = 0; i < _configs.length; i++) {
                if (_configs[i].chainId != chainId) continue;
                SetCollateralAssetOracleConfig storage cfg = _configs[i];
                MarketAddresses memory addrs = getMarketAddresses(cfg.marketName);

                updates[idx] = UpdateParams({
                    marketName: cfg.marketName,
                    target: addrs.kernel,
                    callData: abi.encodeCall(IRoycoDayKernel.setCollateralAssetOracle, (cfg.newOracle, cfg.newStalenessThresholdSeconds, cfg.syncBeforeUpdate)),
                    description: string.concat(
                        "Set collateral asset oracle for ",
                        cfg.marketName,
                        " to ",
                        vm.toString(cfg.newOracle),
                        " (staleness=",
                        vm.toString(uint256(cfg.newStalenessThresholdSeconds)),
                        "s, sync=",
                        cfg.syncBeforeUpdate ? "true" : "false",
                        ")"
                    )
                });
                idx++;
            }

            _processChainDirect(chainId, ROOT_MULTISIG, updates, OUTPUT_SUBDIR, OUTPUT_PREFIX, BATCH_DESCRIPTION);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Decodes the calldata and asserts the kernel now returns the expected oracle + threshold.
    function _verify(UpdateParams memory _params) internal view override {
        (address expectedOracle, uint48 expectedStaleness,) = _decodeCallData(_params.callData);

        IRoycoDayKernel.RoycoDayKernelState memory state = IRoycoDayKernel(_params.target).getState();

        require(state.collateralAssetOracle == expectedOracle, VerificationFailed("Collateral asset oracle address mismatch after execution"));
        require(state.stalenessThresholdSeconds == expectedStaleness, VerificationFailed("Staleness threshold mismatch after execution"));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Strips the 4-byte selector and abi.decodes `(address, uint48, bool)` from the call.
    function _decodeCallData(bytes memory _cd) internal pure returns (address oracle, uint48 stalenessThresholdSeconds, bool syncBeforeUpdate) {
        bytes memory args = new bytes(_cd.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = _cd[i + 4];
        }
        (oracle, stalenessThresholdSeconds, syncBeforeUpdate) = abi.decode(args, (address, uint48, bool));
    }

    function _getUniqueChainIds() internal view returns (uint256[] memory) {
        uint256[] memory temp = new uint256[](_configs.length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < _configs.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (temp[j] == _configs[i].chainId) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                temp[uniqueCount] = _configs[i].chainId;
                uniqueCount++;
            }
        }

        uint256[] memory result = new uint256[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            result[i] = temp[i];
        }
        return result;
    }
}
