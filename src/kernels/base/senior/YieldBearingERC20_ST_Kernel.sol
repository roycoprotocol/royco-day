// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionModel, IRoycoKernel, SharesRedemptionModel } from "../../../interfaces/kernel/IRoycoKernel.sol";
import { MAX_TRANCHE_UNITS } from "../../../libraries/Constants.sol";
import { AssetClaims, SyncedAccountingState } from "../../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toUint256 } from "../../../libraries/Units.sol";
import { YieldBearingERC20KernelState, YieldBearingERC20KernelStorageLib } from "../../../libraries/kernels/YieldBearingERC20KernelStorageLib.sol";
import { RoycoKernel, TrancheType } from "../RoycoKernel.sol";

/**
 * @title YieldBearingERC20_ST_Kernel
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Senior tranche kernel for yield-bearing ERC20 tokens
 * @dev Manages senior tranche deposits, withdrawals, and redemptions using yield-bearing ERC20 assets
 *      Assets are held directly by the kernel and tracked via storage
 */
abstract contract YieldBearingERC20_ST_Kernel is RoycoKernel {
    using SafeERC20 for IERC20;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant ST_DEPOSIT_EXECUTION_MODEL = ExecutionModel.SYNC;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant ST_REDEEM_EXECUTION_MODEL = ExecutionModel.SYNC;

    /// @inheritdoc IRoycoKernel
    SharesRedemptionModel public constant ST_REQUEST_REDEEM_SHARES_BEHAVIOR = SharesRedemptionModel.BURN_ON_CLAIM_REDEEM;

    /// @inheritdoc IRoycoKernel
    function stPreviewDeposit(TRANCHE_UNIT _stAssets)
        external
        view
        override
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated)
    {
        // Preview a sync to get the current NAV to mint shares at for the senior tranche
        stateBeforeDeposit = _previewSyncTrancheAccounting();
        // Convert the yield bearing assets deposited to NAV units
        valueAllocated = stConvertTrancheUnitsToNAVUnits(_stAssets);
    }

    /// @inheritdoc IRoycoKernel
    function stPreviewRedeem(uint256 _shares) external view override returns (AssetClaims memory userClaim) {
        userClaim = _previewRedeem(_shares, TrancheType.SENIOR);
    }

    /// @inheritdoc RoycoKernel
    function _getSeniorTrancheRawNAV() internal view override(RoycoKernel) returns (NAV_UNIT) {
        // Get the yield bearing assets owned by ST and convert them to NAV units via the configured quoter
        return stConvertTrancheUnitsToNAVUnits(YieldBearingERC20KernelStorageLib._getYieldBearingERC20KernelStorage().stOwnedYieldBearingAssets);
    }

    /// @inheritdoc RoycoKernel
    function _stMaxDepositGlobally(address) internal pure override(RoycoKernel) returns (TRANCHE_UNIT) {
        // No limit to how many yield bearing assets can be deposited into this kernel
        return MAX_TRANCHE_UNITS;
    }

    /// @inheritdoc RoycoKernel
    function _stMaxWithdrawableGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // The max yield bearing assets that can be withdrawn is the number of assets owned by ST
        return YieldBearingERC20KernelStorageLib._getYieldBearingERC20KernelStorage().stOwnedYieldBearingAssets;
    }

    /// @inheritdoc RoycoKernel
    function _stPreviewWithdraw(TRANCHE_UNIT _stAssets) internal pure override(RoycoKernel) returns (TRANCHE_UNIT withdrawnSTAssets) {
        // No conversion between the assets being withdrawn and what will be withdrawn: the kernel simply transfers them out
        return _stAssets;
    }

    /// @inheritdoc RoycoKernel
    function _stDepositAssets(TRANCHE_UNIT _stAssets) internal override(RoycoKernel) returns (NAV_UNIT stDepositNAV) {
        // No fees or slippage involved in depositing
        stDepositNAV = stConvertTrancheUnitsToNAVUnits(_stAssets);
        // The tranche vault has already transfered the assets to the kernel, so simply credit those assets to the senior tranche
        YieldBearingERC20KernelState storage $ = YieldBearingERC20KernelStorageLib._getYieldBearingERC20KernelStorage();
        $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets + _stAssets;
    }

    /// @inheritdoc RoycoKernel
    function _stWithdrawAssets(TRANCHE_UNIT _stAssets, address _receiver) internal override(RoycoKernel) {
        // Debit the yield bearing assets being withdrawn from the senior tranche
        YieldBearingERC20KernelState storage $ = YieldBearingERC20KernelStorageLib._getYieldBearingERC20KernelStorage();
        $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets - _stAssets;

        // Transfer the yield bearing assets being withdrawn to the receiver
        IERC20(ST_ASSET).safeTransfer(_receiver, toUint256(_stAssets));
    }
}
