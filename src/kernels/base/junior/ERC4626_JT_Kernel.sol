// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IERC20, SafeERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionModel, IRoycoKernel } from "../../../interfaces/kernel/IRoycoKernel.sol";
import { SyncedAccountingState } from "../../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toTrancheUnits, toUint256 } from "../../../libraries/Units.sol";
import { ERC4626KernelState, ERC4626KernelStorageLib } from "../../../libraries/kernels/ERC4626KernelStorageLib.sol";
import { RoycoKernel } from "../RoycoKernel.sol";

/**
 * @title ERC4626_JT_Kernel
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Junior tranche kernel for ERC4626 vault deposits
 * @dev NOTE: This kernel does not support ERC4626 vaults with slippage on deposit/withdrawal that isn't reflected in the preview functions
 * @dev Manages junior tranche deposits and withdrawals via an ERC4626 compliant vault
 *      Deposited assets are converted to vault shares
 *      Handles illiquidity gracefully by transferring vault shares when withdrawals fail
 */
abstract contract ERC4626_JT_Kernel is RoycoKernel {
    using SafeERC20 for IERC20;
    using UnitsMathLib for TRANCHE_UNIT;

    /// @notice Thrown when the JT base asset is different the the ERC4626 vault's base asset
    error JUNIOR_TRANCHE_AND_VAULT_ASSET_MISMATCH();

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant JT_DEPOSIT_EXECUTION_MODEL = ExecutionModel.SYNC;

    /// @notice Immutable addresses for the underlying JT ERC4626 vault
    address internal immutable JT_VAULT;

    /// @notice Constructs the ERC4626 junior tranche kernel
    /// @param _jtVault The address of the ERC4626 compliant vault the junior tranche will deploy into
    constructor(address _jtVault) {
        // Ensure that the JT base asset is identical to the ERC4626 vault's base asset
        require(IERC4626(_jtVault).asset() == JT_ASSET, JUNIOR_TRANCHE_AND_VAULT_ASSET_MISMATCH());

        // Set the immutable address for the JT ERC4626 vault
        JT_VAULT = _jtVault;
    }

    /// @notice Initializes a kernel where the junior tranche is deployed into an ERC4626 vault
    function __ERC4626_JT_Kernel_init_unchained() internal onlyInitializing {
        // Extend a one time max approval to the ERC4626 vault for the JT's base asset
        IERC20(JT_ASSET).forceApprove(JT_VAULT, type(uint256).max);
    }

    /// @inheritdoc IRoycoKernel
    function jtPreviewDeposit(TRANCHE_UNIT _jtAssets)
        external
        view
        override
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated)
    {
        stateBeforeDeposit = _previewSyncTrancheAccounting();
        valueAllocated = _jtPreviewDepositAllocatedNAV(_jtAssets);
    }

    /// @inheritdoc RoycoKernel
    function _getJuniorTrancheRawNAV() internal view override(RoycoKernel) returns (NAV_UNIT) {
        ERC4626KernelState storage $ = ERC4626KernelStorageLib._getERC4626KernelStorage();
        // Must use convert to assets for the tranche owned shares in order to be exclusive of any fixed fees on withdrawal
        // Cannot use max withdraw since it will treat illiquidity as a NAV loss
        TRANCHE_UNIT jtOwnedAssets = toTrancheUnits(IERC4626(JT_VAULT).convertToAssets($.jtOwnedShares));
        return jtConvertTrancheUnitsToNAVUnits(jtOwnedAssets);
    }

    /// @inheritdoc RoycoKernel
    function _jtMaxDepositGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // Max deposit takes global withdrawal limits into account
        return toTrancheUnits(IERC4626(JT_VAULT).maxDeposit(address(this)));
    }

    /// @inheritdoc RoycoKernel
    function _jtMaxWithdrawableGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // If the underlying vault is illiquid, we transfer the owned shares to the receiver
        // Therefore, the max withdrawable assets is equivalent to the number of shares owned by the kernel
        ERC4626KernelState storage $ = ERC4626KernelStorageLib._getERC4626KernelStorage();
        return toTrancheUnits(IERC4626(JT_VAULT).convertToAssets($.jtOwnedShares));
    }

    /// @inheritdoc RoycoKernel
    function _jtPreviewWithdraw(TRANCHE_UNIT _jtAssets) internal view override(RoycoKernel) returns (TRANCHE_UNIT withdrawnJTAssets) {
        // Convert the ST assets to underlying shares
        uint256 jtVaultShares = IERC4626(JT_VAULT).convertToShares(toUint256(_jtAssets));
        // Preview the amount of ST assets that would be redeemed for the given amount of underlying shares
        withdrawnJTAssets = toTrancheUnits(IERC4626(JT_VAULT).previewRedeem(jtVaultShares));
    }

    /// @inheritdoc RoycoKernel
    function _jtDepositAssets(TRANCHE_UNIT _jtAssets) internal override(RoycoKernel) returns (NAV_UNIT jtDepositNAV) {
        // Account for any fees or slippage involved in depositing
        jtDepositNAV = _jtPreviewDepositAllocatedNAV(_jtAssets);

        // Deposit the assets into the underlying investment vault and add to the number of ST controlled shares for this vault
        ERC4626KernelState storage $ = ERC4626KernelStorageLib._getERC4626KernelStorage();
        $.jtOwnedShares += IERC4626(JT_VAULT).deposit(toUint256(_jtAssets), address(this));
    }

    /// @inheritdoc RoycoKernel
    function _jtWithdrawAssets(TRANCHE_UNIT _jtAssets, address _receiver) internal override(RoycoKernel) {
        ERC4626KernelState storage $ = ERC4626KernelStorageLib._getERC4626KernelStorage();
        // Convert assets to shares, representing the user's fair share of vault shares excluding fees/slippage
        uint256 sharesToRedeem = IERC4626(JT_VAULT).convertToShares(toUint256(_jtAssets));
        // Check if the vault has sufficient liquidity to redeem the shares
        uint256 maxRedeemableShares = IERC4626(JT_VAULT).maxRedeem(address(this));
        // If the vault has sufficient liquidity to redeem the shares, do so
        if (maxRedeemableShares >= sharesToRedeem) {
            // Redeem shares: user receives fee/slippage adjusted assets from the vault
            $.jtOwnedShares -= sharesToRedeem;
            IERC4626(JT_VAULT).redeem(sharesToRedeem, _receiver, address(this));
        } else {
            // If the vault has insufficient liquidity, transfer the shares directly to the receiver
            $.jtOwnedShares -= sharesToRedeem;
            IERC20(address(JT_VAULT)).safeTransfer(_receiver, sharesToRedeem);
        }
    }

    /**
     * @notice Helper function to preview the deposit of assets into the underlying investment vault and convert the allocated assets to NAV units
     * @param _jtAssets The amount of assets to deposit, denominated in the junior tranche's tranche units
     * @return jtDepositNAV The value of the assets deposited, denominated in the kernel's NAV units before the deposit is made
     */
    function _jtPreviewDepositAllocatedNAV(TRANCHE_UNIT _jtAssets) internal view returns (NAV_UNIT) {
        // Simulate the deposit of the assets into the underlying investment vault
        uint256 jtVaultSharesMinted = IERC4626(JT_VAULT).previewDeposit(toUint256(_jtAssets));

        // Convert the underlying vault shares to tranche units. This value may differ from _jtAssets if a fee or slippage is incurred to the deposit.
        TRANCHE_UNIT jtAssetsAllocated = toTrancheUnits(IERC4626(JT_VAULT).convertToAssets(jtVaultSharesMinted));

        // Convert the assets allocated to NAV units and preview a sync to get the current NAV to mint shares at for the junior tranche
        return jtConvertTrancheUnitsToNAVUnits(jtAssetsAllocated);
    }
}
