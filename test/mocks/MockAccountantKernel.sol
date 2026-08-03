// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { Operation, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { NAV_UNIT } from "../../src/libraries/Units.sol";

/// @notice Mock kernel giving accountant tests full control over the onlyRoycoKernel surface
/// @dev Passthroughs make msg.sender the kernel, and syncTrancheAccounting supports NONE, SYNC, and REVERT modes with call counting and a pre-sync state snapshot
contract MockAccountantKernel {
    enum SyncMode {
        NONE,
        SYNC,
        REVERT
    }

    error KERNEL_SYNC_REVERTED();

    IRoycoDayAccountant public accountant;
    SyncMode public syncMode;
    uint256 public syncCallCount;
    NAV_UNIT public syncCollateralNAV;
    IRoycoDayAccountant.RoycoDayAccountantState internal _stateAtLastSync;

    /// @dev The accountant state hash observed at each sync, in call order, so a test can pin what the n-th sync saw
    bytes32[] public stateHashAtSync;

    function setAccountant(address _accountant) external {
        accountant = IRoycoDayAccountant(_accountant);
    }

    function setSyncMode(SyncMode _mode) external {
        syncMode = _mode;
    }

    /// @dev The collateral NAV a SYNC-mode syncTrancheAccounting will pre-op sync with
    function setSyncNAV(NAV_UNIT _collateralNAV) external {
        syncCollateralNAV = _collateralNAV;
    }

    /// @dev The accountant state snapshotted at the moment of the last syncTrancheAccounting call
    function stateAtLastSync() external view returns (IRoycoDayAccountant.RoycoDayAccountantState memory) {
        return _stateAtLastSync;
    }

    /// @dev Mirror of IRoycoDayKernel.syncTrancheAccountingFromAccountant, the entrypoint the accountant's
    ///      `withSyncedAccounting` modifier drives around every admin parameter change
    function syncTrancheAccountingFromAccountant() public returns (SyncedAccountingState memory state) {
        if (syncMode == SyncMode.REVERT) revert KERNEL_SYNC_REVERTED();
        syncCallCount++;
        _stateAtLastSync = accountant.getState();
        stateHashAtSync.push(keccak256(abi.encode(_stateAtLastSync)));
        if (syncMode == SyncMode.SYNC) state = accountant.preOpSyncTrancheAccounting(syncCollateralNAV);
    }

    /// @dev The kernel's own sync entrypoint, kept as a passthrough for tests that drive it as a raw call
    function syncTrancheAccounting() external returns (SyncedAccountingState memory state) {
        return syncTrancheAccountingFromAccountant();
    }

    /// @dev Passthrough so msg.sender == kernel for the pre-op sync
    function doPreOp(NAV_UNIT _collateralNAV) external returns (SyncedAccountingState memory) {
        return accountant.preOpSyncTrancheAccounting(_collateralNAV);
    }

    /// @dev Passthrough so msg.sender == kernel for the LPT raw NAV commit
    function doCommit(NAV_UNIT _lptRawNAV) external {
        accountant.commitLiquidityProviderTrancheRawNAV(_lptRawNAV);
    }

    /// @dev Passthrough so msg.sender == kernel for the post-op sync
    function doPostOp(
        Operation _op,
        NAV_UNIT _collateralNAV,
        NAV_UNIT _lptRawNAV,
        NAV_UNIT _stSelfLiquidationBonusNAV
    )
        external
        returns (SyncedAccountingState memory)
    {
        return accountant.postOpSyncTrancheAccounting(_op, _collateralNAV, _lptRawNAV, _stSelfLiquidationBonusNAV);
    }
}
