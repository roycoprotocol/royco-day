// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { console2 } from "../../../lib/forge-std/src/console2.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { TrancheType } from "../../../src/libraries/Types.sol";
import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title UpdateTrancheConfigs
 * @notice Updates every configured market's entry-point tranche configurations (delays, yield routing, enablement)
 *         in one batched `modifyTrancheConfigs` call per chain.
 *
 * @dev Hooks into `ParameterUpdateBase`'s direct-call harness:
 *      - Resolves ST/JT addresses per market via `getMarketAddresses(name)` and the LT via the kernel's
 *        LIQUIDITY_TRANCHE immutable.
 *      - Auto-classifies each tranche via `TRANCHE_TYPE()` to pick the yield recipient per slot.
 *      - Encodes a single batched `modifyTrancheConfigs(tranches, configs)` call to the entry point per chain.
 *      - Runs the call via `_processChainDirect` pranking `WCE_MULTISIG` (immediate role).
 *      - Writes one Safe JSON per chain at `output/update/entrypoint/{chainId}_update_tranche_configs.json`.
 *
 *      No schedule/execute split: WCE holds `ADMIN_ENTRY_POINT_ROLE` with delay 0.
 */
contract UpdateTrancheConfigs is ParameterUpdateBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev CREATE3-deterministic entry-point proxy address (same on every chain).
    /// @dev TODO: set the deployed Day entry point address once DeployEntryPoint has run.
    address internal constant ENTRY_POINT = address(0);

    uint24 internal constant NEW_DEPOSIT_DELAY = 5 minutes;
    uint24 internal constant NEW_REDEMPTION_DELAY = 5 minutes;

    string internal constant OUTPUT_SUBDIR = "entrypoint";
    string internal constant OUTPUT_PREFIX = "update_tranche_configs";
    string internal constant BATCH_DESCRIPTION = "Royco Day Entry Point: update tranche configurations";

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    struct ChainEntryPointConfig {
        uint256 chainId;
        string[] markets;
    }

    ChainEntryPointConfig[] internal _entryPointConfigs;

    constructor() {
        _initializeConfigs();
    }

    function _initializeConfigs() internal {
        // TODO: register chains + markets once the first Day markets and the entry point are live, e.g.:
        //   ChainEntryPointConfig storage mainnet = _entryPointConfigs.push();
        //   mainnet.chainId = MAINNET;
        //   mainnet.markets.push(SNUSD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        for (uint256 i = 0; i < _entryPointConfigs.length; i++) {
            _processOneChain(_entryPointConfigs[i]);
        }
    }

    /// @dev Forks the chain, resolves tranche addresses, encodes the batched call, and
    ///      hands off to `_processChainDirect` for simulation + JSON write.
    function _processOneChain(ChainEntryPointConfig storage _cfg) internal {
        // Fork once up front so `getMarketAddresses` (which reads the kernel) works.
        // `_processChainDirect` re-forks the same chain — that's fine; calldata is in memory.
        vm.createSelectFork(_getRpcUrl(_cfg.chainId));

        uint256 nMarkets = _cfg.markets.length;
        uint256 nTranches = nMarkets * 3;

        address[] memory tranches = new address[](nTranches);
        IRoycoDayEntryPoint.TrancheConfig[] memory configs = new IRoycoDayEntryPoint.TrancheConfig[](nTranches);

        for (uint256 i = 0; i < nMarkets; i++) {
            MarketAddresses memory addrs = getMarketAddresses(_cfg.markets[i]);

            tranches[3 * i] = addrs.seniorTranche;
            tranches[3 * i + 1] = addrs.juniorTranche;
            tranches[3 * i + 2] = IRoycoDayKernel(addrs.kernel).LIQUIDITY_TRANCHE();
            for (uint256 j = 0; j < 3; j++) {
                configs[3 * i + j] = IRoycoDayEntryPoint.TrancheConfig({
                    enabled: true,
                    yieldRecipient: IRoycoDayEntryPoint.AccruedYieldRecipient.PROTOCOL,
                    depositDelaySeconds: NEW_DEPOSIT_DELAY,
                    redemptionDelaySeconds: NEW_REDEMPTION_DELAY
                });
            }
        }

        // Defensive: the registered ST/JT/LT slots must actually be SENIOR/JUNIOR/LIQUIDITY per the
        // tranche contract's TRANCHE_TYPE getter.
        for (uint256 i = 0; i < nTranches; i++) {
            TrancheType tt = IRoycoVaultTranche(tranches[i]).TRANCHE_TYPE();
            require(
                (i % 3 == 0 && tt == TrancheType.SENIOR) || (i % 3 == 1 && tt == TrancheType.JUNIOR) || (i % 3 == 2 && tt == TrancheType.LIQUIDITY),
                "ST/JT/LT slot mismatch"
            );
        }

        UpdateParams[] memory updates = new UpdateParams[](1);
        updates[0] = UpdateParams({
            marketName: "",
            target: ENTRY_POINT,
            callData: abi.encodeCall(IRoycoDayEntryPoint.modifyTrancheConfigs, (tranches, configs)),
            description: string.concat("Update entry-point tranche configs (", vm.toString(nTranches), " tranches)")
        });

        _processChainDirect(_cfg.chainId, WCE_MULTISIG, updates, OUTPUT_SUBDIR, OUTPUT_PREFIX, BATCH_DESCRIPTION);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION (read back getTrancheConfig for every tranche)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Decodes the batched calldata, then asserts every tranche's on-chain config matches.
    function _verify(UpdateParams memory _params) internal view override {
        // Skip the 4-byte selector and decode (address[], TrancheConfig[])
        bytes memory cd = _params.callData;
        bytes memory args = new bytes(cd.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = cd[i + 4];
        }
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = abi.decode(args, (address[], IRoycoDayEntryPoint.TrancheConfig[]));

        for (uint256 i = 0; i < tranches.length; i++) {
            IRoycoDayEntryPoint.EnrichedTrancheConfig memory ec = IRoycoDayEntryPoint(_params.target).getTrancheConfig(tranches[i]);
            require(ec.baseConfig.enabled == configs[i].enabled, VerificationFailed("enabled mismatch"));
            require(ec.baseConfig.yieldRecipient == configs[i].yieldRecipient, VerificationFailed("yieldRecipient mismatch"));
            require(ec.baseConfig.depositDelaySeconds == configs[i].depositDelaySeconds, VerificationFailed("depositDelay mismatch"));
            require(ec.baseConfig.redemptionDelaySeconds == configs[i].redemptionDelaySeconds, VerificationFailed("redemptionDelay mismatch"));
        }
        console2.log("    [OK] Post-state verified for", tranches.length, "tranches");
    }
}
