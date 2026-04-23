// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoAccountant } from "../../../src/accountant/RoycoAccountant.sol";
import { IRoycoAccountant } from "../../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoKernel } from "../../../src/interfaces/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT } from "../../../src/libraries/Units.sol";

import { UpgradeModuleBase } from "./UpgradeModuleBase.sol";

/**
 * @title UpgradeAccountantModule
 * @notice Module for upgrading `RoycoAccountant` proxies.
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
 *          last*ImpermanentLoss, accrual/distribution timestamps, dust tolerances)
 *        - `previewSyncTrancheAccounting(stRawNAV, jtRawNAV)` at post-warp time using the kernel's
 *          current raw tranche NAVs — catches any drift in the sync math post-upgrade
 *
 *      `verify()` re-reads all of the above at the same `block.timestamp` and asserts equality.
 */
contract UpgradeAccountantModule is UpgradeModuleBase {
    error UpgradeAccountantModule__NotAnAccountantProxy(address proxy);
    error UpgradeAccountantModule__NewImplIdenticalToOld(address impl);
    error UpgradeAccountantModule__KernelImmutableChanged(address expected, address actual);
    error UpgradeAccountantModule__StateChanged(string field);
    error UpgradeAccountantModule__PreviewSyncMismatch(string field);

    /// @inheritdoc UpgradeModuleBase
    function prepare(uint256 _chainId, string memory _saltVersion, bytes memory _payload) external view override returns (PreparedUpgrade memory prepared) {
        string memory marketName = abi.decode(_payload, (string));

        MarketAddresses memory addrs = getMarketAddresses(_chainId, marketName);
        address proxy = addrs.accountant;

        IRoycoAccountant a = IRoycoAccountant(proxy);
        address kernel = a.KERNEL();
        require(kernel != address(0), UpgradeAccountantModule__NotAnAccountantProxy(proxy));

        // Strong type check: call an accountant-specific view. Reverts if the proxy is not actually
        // a `RoycoAccountant` (e.g. if an address was mis-entered in `UpgradeConfig`).
        NAV_UNIT stRawNAV = IRoycoVaultTranche(IRoycoKernel(kernel).SENIOR_TRANCHE()).getRawNAV();
        NAV_UNIT jtRawNAV = IRoycoVaultTranche(IRoycoKernel(kernel).JUNIOR_TRANCHE()).getRawNAV();
        a.previewSyncTrancheAccounting(stRawNAV, jtRawNAV);

        address oldImpl = _readImplementation(proxy);

        bytes memory creationCode = abi.encodePacked(type(RoycoAccountant).creationCode, abi.encode(kernel));
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
        IRoycoAccountant a = IRoycoAccountant(_proxy);
        IRoycoKernel kernel = IRoycoKernel(a.KERNEL());

        NAV_UNIT stRawNAV = IRoycoVaultTranche(kernel.SENIOR_TRANCHE()).getRawNAV();
        NAV_UNIT jtRawNAV = IRoycoVaultTranche(kernel.JUNIOR_TRANCHE()).getRawNAV();

        IRoycoAccountant.RoycoAccountantState memory state = a.getState();
        SyncedAccountingState memory sync = a.previewSyncTrancheAccounting(stRawNAV, jtRawNAV);

        return abi.encode(address(kernel), state, sync, stRawNAV, jtRawNAV);
    }

    /// @inheritdoc UpgradeModuleBase
    function verify(address _proxy, bytes memory _preStateSnapshot) external view override {
        (
            address preKernel,
            IRoycoAccountant.RoycoAccountantState memory preState,
            SyncedAccountingState memory preSync,
            NAV_UNIT preStRawNAV,
            NAV_UNIT preJtRawNAV
        ) = abi.decode(_preStateSnapshot, (address, IRoycoAccountant.RoycoAccountantState, SyncedAccountingState, NAV_UNIT, NAV_UNIT));

        IRoycoAccountant a = IRoycoAccountant(_proxy);
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

    function _assertStateEqual(IRoycoAccountant.RoycoAccountantState memory a, IRoycoAccountant.RoycoAccountantState memory b) internal pure {
        require(a.lastMarketState == b.lastMarketState, UpgradeAccountantModule__StateChanged("lastMarketState"));
        require(a.fixedTermDurationSeconds == b.fixedTermDurationSeconds, UpgradeAccountantModule__StateChanged("fixedTermDurationSeconds"));
        require(a.fixedTermEndTimestamp == b.fixedTermEndTimestamp, UpgradeAccountantModule__StateChanged("fixedTermEndTimestamp"));
        require(a.coverageWAD == b.coverageWAD, UpgradeAccountantModule__StateChanged("coverageWAD"));
        require(a.betaWAD == b.betaWAD, UpgradeAccountantModule__StateChanged("betaWAD"));
        require(a.stProtocolFeeWAD == b.stProtocolFeeWAD, UpgradeAccountantModule__StateChanged("stProtocolFeeWAD"));
        require(a.jtProtocolFeeWAD == b.jtProtocolFeeWAD, UpgradeAccountantModule__StateChanged("jtProtocolFeeWAD"));
        require(a.yieldShareProtocolFeeWAD == b.yieldShareProtocolFeeWAD, UpgradeAccountantModule__StateChanged("yieldShareProtocolFeeWAD"));
        require(a.liquidationUtilizationWAD == b.liquidationUtilizationWAD, UpgradeAccountantModule__StateChanged("liquidationUtilizationWAD"));
        require(a.ydm == b.ydm, UpgradeAccountantModule__StateChanged("ydm"));
        require(NAV_UNIT.unwrap(a.lastSTRawNAV) == NAV_UNIT.unwrap(b.lastSTRawNAV), UpgradeAccountantModule__StateChanged("lastSTRawNAV"));
        require(NAV_UNIT.unwrap(a.lastJTRawNAV) == NAV_UNIT.unwrap(b.lastJTRawNAV), UpgradeAccountantModule__StateChanged("lastJTRawNAV"));
        require(NAV_UNIT.unwrap(a.lastSTEffectiveNAV) == NAV_UNIT.unwrap(b.lastSTEffectiveNAV), UpgradeAccountantModule__StateChanged("lastSTEffectiveNAV"));
        require(NAV_UNIT.unwrap(a.lastJTEffectiveNAV) == NAV_UNIT.unwrap(b.lastJTEffectiveNAV), UpgradeAccountantModule__StateChanged("lastJTEffectiveNAV"));
        require(
            NAV_UNIT.unwrap(a.lastSTImpermanentLoss) == NAV_UNIT.unwrap(b.lastSTImpermanentLoss), UpgradeAccountantModule__StateChanged("lastSTImpermanentLoss")
        );
        require(
            NAV_UNIT.unwrap(a.lastJTImpermanentLoss) == NAV_UNIT.unwrap(b.lastJTImpermanentLoss), UpgradeAccountantModule__StateChanged("lastJTImpermanentLoss")
        );
        require(a.twJTYieldShareAccruedWAD == b.twJTYieldShareAccruedWAD, UpgradeAccountantModule__StateChanged("twJTYieldShareAccruedWAD"));
        require(a.lastAccrualTimestamp == b.lastAccrualTimestamp, UpgradeAccountantModule__StateChanged("lastAccrualTimestamp"));
        require(a.lastDistributionTimestamp == b.lastDistributionTimestamp, UpgradeAccountantModule__StateChanged("lastDistributionTimestamp"));
        require(NAV_UNIT.unwrap(a.stNAVDustTolerance) == NAV_UNIT.unwrap(b.stNAVDustTolerance), UpgradeAccountantModule__StateChanged("stNAVDustTolerance"));
        require(NAV_UNIT.unwrap(a.jtNAVDustTolerance) == NAV_UNIT.unwrap(b.jtNAVDustTolerance), UpgradeAccountantModule__StateChanged("jtNAVDustTolerance"));
    }

    function _assertSyncEqual(SyncedAccountingState memory a, SyncedAccountingState memory b) internal pure {
        require(a.marketState == b.marketState, UpgradeAccountantModule__PreviewSyncMismatch("marketState"));
        require(NAV_UNIT.unwrap(a.stRawNAV) == NAV_UNIT.unwrap(b.stRawNAV), UpgradeAccountantModule__PreviewSyncMismatch("stRawNAV"));
        require(NAV_UNIT.unwrap(a.jtRawNAV) == NAV_UNIT.unwrap(b.jtRawNAV), UpgradeAccountantModule__PreviewSyncMismatch("jtRawNAV"));
        require(NAV_UNIT.unwrap(a.stEffectiveNAV) == NAV_UNIT.unwrap(b.stEffectiveNAV), UpgradeAccountantModule__PreviewSyncMismatch("stEffectiveNAV"));
        require(NAV_UNIT.unwrap(a.jtEffectiveNAV) == NAV_UNIT.unwrap(b.jtEffectiveNAV), UpgradeAccountantModule__PreviewSyncMismatch("jtEffectiveNAV"));
        require(NAV_UNIT.unwrap(a.stImpermanentLoss) == NAV_UNIT.unwrap(b.stImpermanentLoss), UpgradeAccountantModule__PreviewSyncMismatch("stImpermanentLoss"));
        require(NAV_UNIT.unwrap(a.jtImpermanentLoss) == NAV_UNIT.unwrap(b.jtImpermanentLoss), UpgradeAccountantModule__PreviewSyncMismatch("jtImpermanentLoss"));
        require(
            NAV_UNIT.unwrap(a.stProtocolFeeAccrued) == NAV_UNIT.unwrap(b.stProtocolFeeAccrued),
            UpgradeAccountantModule__PreviewSyncMismatch("stProtocolFeeAccrued")
        );
        require(
            NAV_UNIT.unwrap(a.jtProtocolFeeAccrued) == NAV_UNIT.unwrap(b.jtProtocolFeeAccrued),
            UpgradeAccountantModule__PreviewSyncMismatch("jtProtocolFeeAccrued")
        );
        require(a.utilizationWAD == b.utilizationWAD, UpgradeAccountantModule__PreviewSyncMismatch("utilizationWAD"));
        require(a.fixedTermEndTimestamp == b.fixedTermEndTimestamp, UpgradeAccountantModule__PreviewSyncMismatch("fixedTermEndTimestamp"));
        require(a.coverageWAD == b.coverageWAD, UpgradeAccountantModule__PreviewSyncMismatch("coverageWAD"));
        require(a.betaWAD == b.betaWAD, UpgradeAccountantModule__PreviewSyncMismatch("betaWAD"));
        require(a.liquidationUtilizationWAD == b.liquidationUtilizationWAD, UpgradeAccountantModule__PreviewSyncMismatch("liquidationUtilizationWAD"));
    }
}
