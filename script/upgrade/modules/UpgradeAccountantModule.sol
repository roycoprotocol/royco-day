// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayAccountant } from "../../../src/accountant/RoycoDayAccountant.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT } from "../../../src/libraries/Units.sol";

import { UpgradeModuleBase } from "./UpgradeModuleBase.sol";

/**
 * @title UpgradeAccountantModule
 * @notice Module for upgrading `RoycoDayAccountant` proxies.
 *
 * @dev Payload schema (ABI-encoded by the orchestrator):
 *        abi.encode(string marketName)
 *
 *      The module:
 *        1. Resolves the proxy via `getMarketAddresses(chainId, marketName).accountant`
 *        2. Reads constructor immutable off the existing impl: `KERNEL()`
 *        3. Predicts the new impl address via CREATE2 using the SAME constructor arg
 *
 *      `snapshotState()` (post-warp) captures:
 *        - `KERNEL()` immutable
 *        - Full `getState()` (every storage field including fees, coverage, beta, ydm, last*NAV,
 *          lastJTCoverageImpermanentLoss, accrual/distribution timestamps, dust tolerances incl. effectiveNAVDustTolerance)
 *        - `previewSyncTrancheAccounting(stRawNAV, jtRawNAV)` at post-warp time using the kernel's
 *          current raw tranche NAVs — catches any drift in the sync math post-upgrade
 *
 *      `verify()` re-reads all of the above at the same `block.timestamp` and asserts equality.
 */
contract UpgradeAccountantModule is UpgradeModuleBase {
    error UpgradeAccountantModule__NotAnAccountantProxy(address proxy);
    error UpgradeAccountantModule__NewImplIdenticalToOld(address impl);
    error UpgradeAccountantModule__KernelImmutableChanged(address expected, address actual);
    error UpgradeAccountantModule__StateChanged();
    error UpgradeAccountantModule__PreviewSyncMismatch();

    /// @inheritdoc UpgradeModuleBase
    function prepare(uint256 _chainId, string memory _saltVersion, bytes memory _payload) external view override returns (PreparedUpgrade memory prepared) {
        string memory marketName = abi.decode(_payload, (string));

        MarketAddresses memory addrs = getMarketAddresses(_chainId, marketName);
        address proxy = addrs.accountant;

        IRoycoDayAccountant a = IRoycoDayAccountant(proxy);
        address kernel = a.KERNEL();
        require(kernel != address(0), UpgradeAccountantModule__NotAnAccountantProxy(proxy));

        // Strong type check: call an accountant-specific view. Reverts if the proxy is not actually
        // a `RoycoDayAccountant` (e.g. if an address was mis-entered in `UpgradeConfig`).
        NAV_UNIT stRawNAV = IRoycoVaultTranche(IRoycoDayKernel(kernel).SENIOR_TRANCHE()).getRawNAV();
        NAV_UNIT jtRawNAV = IRoycoVaultTranche(IRoycoDayKernel(kernel).JUNIOR_TRANCHE()).getRawNAV();
        a.previewSyncTrancheAccounting(stRawNAV, jtRawNAV);

        address oldImpl = _readImplementation(proxy);

        bytes memory creationCode = abi.encodePacked(type(RoycoDayAccountant).creationCode, abi.encode(kernel));
        bytes32 salt = keccak256(abi.encodePacked("ROYCO_ACCOUNTANT_IMPLEMENTATION_", _saltVersion));

        address newImpl = _predictImpl(salt, creationCode);
        require(newImpl != oldImpl, UpgradeAccountantModule__NewImplIdenticalToOld(newImpl));

        string memory label = string.concat("Accountant/", marketName);

        prepared = PreparedUpgrade({
            proxy: proxy,
            oldImpl: oldImpl,
            newImpl: newImpl,
            implSalt: salt,
            implCreationCode: creationCode,
            call: UpgradeCall({
                marketName: marketName,
                target: proxy,
                callData: _buildUpgradeCallData(newImpl),
                description: string.concat("Upgrade ", label, " implementation to ", vm.toString(newImpl))
            }),
            label: label
        });
    }

    /// @inheritdoc UpgradeModuleBase
    function snapshotState(address _proxy) external view override returns (bytes memory) {
        IRoycoDayAccountant a = IRoycoDayAccountant(_proxy);
        IRoycoDayKernel kernel = IRoycoDayKernel(a.KERNEL());

        NAV_UNIT stRawNAV = IRoycoVaultTranche(kernel.SENIOR_TRANCHE()).getRawNAV();
        NAV_UNIT jtRawNAV = IRoycoVaultTranche(kernel.JUNIOR_TRANCHE()).getRawNAV();

        IRoycoDayAccountant.RoycoDayAccountantState memory state = a.getState();
        SyncedAccountingState memory sync = a.previewSyncTrancheAccounting(stRawNAV, jtRawNAV);

        return abi.encode(address(kernel), state, sync, stRawNAV, jtRawNAV);
    }

    /// @inheritdoc UpgradeModuleBase
    function verify(address _proxy, bytes memory _preStateSnapshot) external view override {
        // Decode the exact tuple `snapshotState` encodes: (kernel, state, sync, stRawNAV, jtRawNAV)
        (
            address preKernel,
            IRoycoDayAccountant.RoycoDayAccountantState memory preState,
            SyncedAccountingState memory preSync,
            NAV_UNIT preStRawNAV,
            NAV_UNIT preJtRawNAV
        ) = abi.decode(_preStateSnapshot, (address, IRoycoDayAccountant.RoycoDayAccountantState, SyncedAccountingState, NAV_UNIT, NAV_UNIT));

        IRoycoDayAccountant a = IRoycoDayAccountant(_proxy);
        require(a.KERNEL() == preKernel, UpgradeAccountantModule__KernelImmutableChanged(preKernel, a.KERNEL()));

        _assertStateEqual(a.getState(), preState);

        // Use the SAME raw NAVs captured pre-upgrade so the sync preview is a pure function of
        // (storage, block.timestamp, inputs) and comparable across the upgrade.
        SyncedAccountingState memory postSync = a.previewSyncTrancheAccounting(preStRawNAV, preJtRawNAV);
        _assertSyncEqual(postSync, preSync);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EQUALITY HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Whole-struct hash comparison. Catches every field — including any field added later
    ///      to `RoycoDayAccountantState` without code changes here. The trade-off is the diagnostic
    ///      string is generic instead of naming the exact field that differs.
    function _assertStateEqual(IRoycoDayAccountant.RoycoDayAccountantState memory a, IRoycoDayAccountant.RoycoDayAccountantState memory b) internal pure {
        require(keccak256(abi.encode(a)) == keccak256(abi.encode(b)), UpgradeAccountantModule__StateChanged());
    }

    /// @dev Same approach as `_assertStateEqual` — catches every `SyncedAccountingState` field.
    function _assertSyncEqual(SyncedAccountingState memory a, SyncedAccountingState memory b) internal pure {
        require(keccak256(abi.encode(a)) == keccak256(abi.encode(b)), UpgradeAccountantModule__PreviewSyncMismatch());
    }
}
