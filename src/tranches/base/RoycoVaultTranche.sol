// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC20Upgradeable, IERC20, IERC20Metadata } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import { ERC20PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import { ERC20PermitUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { SafeERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoBase } from "../../base/RoycoBase.sol";
import { IAsyncJTDepositKernel } from "../../interfaces/kernel/IAsyncJTDepositKernel.sol";
import { IAsyncSTDepositKernel } from "../../interfaces/kernel/IAsyncSTDepositKernel.sol";
import { IAsyncSTRedemptionKernel } from "../../interfaces/kernel/IAsyncSTRedemptionKernel.sol";
import { ExecutionModel, IRoycoKernel, SharesRedemptionModel } from "../../interfaces/kernel/IRoycoKernel.sol";
import { IRoycoAsyncCancellableVault, IRoycoAsyncVault, IRoycoVaultTranche } from "../../interfaces/tranche/IRoycoVaultTranche.sol";
import { WAD_DECIMALS, ZERO_NAV_UNITS } from "../../libraries/Constants.sol";
import { RoycoTrancheStorageLib } from "../../libraries/RoycoTrancheStorageLib.sol";
import { Action, AssetClaims, SyncedAccountingState, TrancheDeploymentParams, TrancheType } from "../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toNAVUnits, toTrancheUnits, toUint256 } from "../../libraries/Units.sol";
import { UtilsLib } from "../../libraries/UtilsLib.sol";

/**
 * @title RoycoVaultTranche
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base contract implementing core vault functionality for Royco tranches (ST and JT)
 * @dev Tranches interact with the kernel for asset operations and the accountant for NAV synchronizations
 */
abstract contract RoycoVaultTranche is IRoycoVaultTranche, RoycoBase, ERC20PausableUpgradeable, ERC20PermitUpgradeable {
    using Math for uint256;
    using UnitsMathLib for uint256;
    using SafeERC20 for IERC20;

    /**
     * @notice Modifier to ensure the specified action uses a synchronous execution model
     * @param _action The action to check (DEPOSIT or REDEEM)
     * @dev Reverts if the execution model for the action is asynchronous
     */
    /// forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier executionIsSync(Action _action) {
        require(_isSync(_action), DISABLED());
        _;
    }

    /**
     * @notice Modifier to ensure the specified action uses an asynchronous execution model
     * @param _action The action to check (DEPOSIT or REDEEM)
     * @dev Reverts if the execution model for the action is synchronous
     */
    /// forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier executionIsAsync(Action _action) {
        require(!_isSync(_action), DISABLED());
        _;
    }

    /**
     * @notice Modifier to ensure caller is either the specified account or an approved operator
     * @dev Reverts if caller is neither the specified account nor an approved operator
     * @param _account The address that the caller should match or have operator approval for
     */
    /// forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier onlyCallerOrOperator(address _account) {
        require(_isCallerOrOperator(_account), ONLY_CALLER_OR_OPERATOR());
        _;
    }

    /**
     * @notice Initializes the Royco tranche
     * @dev This function initializes parent contracts and the tranche-specific state
     * @param _trancheParams Deployment parameters including name, symbol, kernel, and kernel initialization data
     * @param _asset The underlying asset for the tranche
     * @param _initialAuthority The initial authority for the tranche
     * @param _marketId The identifier of the Royco market this tranche is linked to
     */
    function __RoycoTranche_init(
        TrancheDeploymentParams calldata _trancheParams,
        address _asset,
        address _initialAuthority,
        bytes32 _marketId
    )
        internal
        onlyInitializing
    {
        // Initialize the parent contracts
        __ERC20_init_unchained(_trancheParams.name, _trancheParams.symbol);
        __ERC20Pausable_init();
        __ERC20Permit_init(_trancheParams.name);
        __RoycoBase_init(_initialAuthority);

        // Initialize the Royco Tranche state
        __RoycoTranche_init_unchained(_asset, _trancheParams.kernel, _marketId);
    }

    /**
     * @notice Internal initialization function for Royco tranche-specific state
     * @dev This function sets up the tranche storage and initializes the kernel
     * @param _asset The underlying asset for the tranche
     * @param _kernelAddress The address of the kernel that handles strategy logic
     * @param _marketId The identifier of the Royco market this tranche is linked to
     */
    function __RoycoTranche_init_unchained(address _asset, address _kernelAddress, bytes32 _marketId) internal onlyInitializing {
        RoycoTrancheStorageLib.__RoycoTranche_init(_kernelAddress, _asset, _marketId, TRANCHE_TYPE());
    }

    /// @inheritdoc IRoycoVaultTranche
    function kernel() public view virtual override(IRoycoVaultTranche) returns (address) {
        return RoycoTrancheStorageLib._getRoycoTrancheStorage().kernel;
    }

    /// @inheritdoc IRoycoVaultTranche
    function marketId() external view virtual override(IRoycoVaultTranche) returns (bytes32) {
        return RoycoTrancheStorageLib._getRoycoTrancheStorage().marketId;
    }

    /// @inheritdoc IRoycoVaultTranche
    function totalAssets() external view virtual override(IRoycoVaultTranche) returns (AssetClaims memory claims) {
        (, claims,) = IRoycoKernel(kernel()).previewSyncTrancheAccounting(TRANCHE_TYPE());
    }

    /// @inheritdoc IRoycoVaultTranche
    function getRawNAV() external view virtual override(IRoycoVaultTranche) returns (NAV_UNIT nav) {
        (SyncedAccountingState memory state,,) = IRoycoKernel(kernel()).previewSyncTrancheAccounting(TRANCHE_TYPE());
        nav = TRANCHE_TYPE() == TrancheType.SENIOR ? state.stRawNAV : state.jtRawNAV;
    }

    /// @inheritdoc IRoycoVaultTranche
    function maxDeposit(address _receiver) external view virtual override(IRoycoVaultTranche) returns (TRANCHE_UNIT assets) {
        assets = (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(kernel()).stMaxDeposit(_receiver) : IRoycoKernel(kernel()).jtMaxDeposit(_receiver));
    }

    /// @inheritdoc IRoycoVaultTranche
    function maxRedeem(address _owner) public view virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        shares = _maxRedeem(_owner, balanceOf(_owner));
    }

    /// @inheritdoc IRoycoVaultTranche
    function previewDeposit(TRANCHE_UNIT _assets) external view virtual override(IRoycoVaultTranche) executionIsSync(Action.DEPOSIT) returns (uint256 shares) {
        // Get the state of the tranche before the deposit and the value allocated to the tranche
        (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated) =
            (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(kernel()).stPreviewDeposit(_assets) : IRoycoKernel(kernel()).jtPreviewDeposit(_assets));

        // Preview the total tranche shares after minting any protocol fee shares post-sync
        NAV_UNIT feeAccrued = TRANCHE_TYPE() == TrancheType.SENIOR ? stateBeforeDeposit.stProtocolFeeAccrued : stateBeforeDeposit.jtProtocolFeeAccrued;
        NAV_UNIT effectiveNAV = TRANCHE_TYPE() == TrancheType.SENIOR ? stateBeforeDeposit.stEffectiveNAV : stateBeforeDeposit.jtEffectiveNAV;
        (uint256 feeSharesMinted,) = previewMintProtocolFeeShares(feeAccrued, effectiveNAV);

        // Calculate the shares to be minted to the receiver, considering the protocol fee shares
        shares = _convertToShares(valueAllocated, feeSharesMinted + totalSupply(), effectiveNAV, Math.Rounding.Floor);
    }

    /// @inheritdoc IRoycoVaultTranche
    function previewRedeem(uint256 _shares)
        external
        view
        virtual
        override(IRoycoVaultTranche)
        executionIsSync(Action.REDEEM)
        returns (AssetClaims memory claims)
    {
        claims = (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(kernel()).stPreviewRedeem(_shares) : IRoycoKernel(kernel()).jtPreviewRedeem(_shares));
    }

    /// @inheritdoc IRoycoVaultTranche
    function convertToAssets(uint256 _shares) public view virtual override(IRoycoVaultTranche) returns (AssetClaims memory claims) {
        // Get the post-sync tranche state: applying NAV reconciliation.
        (AssetClaims memory trancheClaims, uint256 trancheTotalShares) = _previewPostSyncTrancheState();
        return UtilsLib.scaleAssetClaims(trancheClaims, _shares, trancheTotalShares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function convertToShares(TRANCHE_UNIT _assets) public view virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        // Get the post-sync tranche state: applying NAV reconciliation.
        NAV_UNIT navAssets =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IRoycoKernel(kernel()).stConvertTrancheUnitsToNAVUnits(_assets)
                : IRoycoKernel(kernel()).jtConvertTrancheUnitsToNAVUnits(_assets));
        (AssetClaims memory trancheClaims, uint256 trancheTotalShares) = _previewPostSyncTrancheState();
        // trancheTotalShares includes virtual shares, while _convertToShares expects the total supply without virtual shares
        // Subtract the virtual shares from the total supply to get the total supply without virtual shares
        shares = _convertToShares(navAssets, _withoutVirtualShares(trancheTotalShares), trancheClaims.nav, Math.Rounding.Floor);
    }

    /// @inheritdoc IRoycoAsyncVault
    function deposit(TRANCHE_UNIT _assets, address _receiver, address _controller) external virtual override returns (uint256 shares, bytes memory metadata) {
        (shares, metadata) = deposit(_assets, _receiver, _controller, 0);
    }

    /// @inheritdoc IRoycoAsyncVault
    /// @dev For sync deposits (ERC-4626), `_controller` is not used for authorization - assets are transferred from msg.sender.
    ///      For async deposits (ERC-7540), `_controller` is the request controller and caller must be controller or operator.
    function deposit(
        TRANCHE_UNIT _assets,
        address _receiver,
        address _controller,
        uint256 _depositRequestId
    )
        public
        virtual
        override
        whenNotPaused
        restricted
        returns (uint256 shares, bytes memory metadata)
    {
        require(_assets != toTrancheUnits(0), MUST_DEPOSIT_NON_ZERO_ASSETS());

        IRoycoKernel kernel_ = IRoycoKernel(kernel());

        // If the deposit is synchronous, transfer the assets from the caller to the kernel
        if (_isSync(Action.DEPOSIT)) {
            IERC20(asset()).safeTransferFrom(msg.sender, address(kernel_), toUint256(_assets));
        } else {
            // If the deposit is asynchronous, the assets were transferred in during requestDeposit
            // Ensure that the caller is the controller or an approved operator
            require(_isCallerOrOperator(_controller), ONLY_CALLER_OR_OPERATOR());
        }

        // Deposit the assets into the underlying investment opportunity and get the fraction of total assets allocated
        (NAV_UNIT valueAllocated, NAV_UNIT effectiveNAVToMintAt, bytes memory _metadata) = (TRANCHE_TYPE() == TrancheType.SENIOR
                ? kernel_.stDeposit(_assets, _controller, _receiver, _depositRequestId)
                : kernel_.jtDeposit(_assets, _controller, _receiver, _depositRequestId));
        metadata = _metadata;

        // effectiveNAVToMint at can be zero initially when the tranche is deployed
        require(valueAllocated != ZERO_NAV_UNITS, INVALID_VALUE_ALLOCATED());

        // valueAllocated represents the value of the assets deposited in the asset that the tranche's NAV is denominated in
        // shares are minted to the user at the effective NAV of the tranche
        // effectiveNAVToMintAt is the effective NAV of the tranche before the deposit is made, ie. the NAV at which the shares will be minted
        shares = _convertToShares(valueAllocated, totalSupply(), effectiveNAVToMintAt, Math.Rounding.Floor);

        // Mint the shares to the receiver
        _mint(_receiver, shares);

        emit Deposit(msg.sender, _receiver, _assets, shares, _depositRequestId, metadata);
    }

    /// @inheritdoc IRoycoAsyncVault
    function redeem(
        uint256 _shares,
        address _receiver,
        address _controller
    )
        external
        virtual
        override
        returns (AssetClaims memory claims, bytes memory metadata)
    {
        (claims, metadata) = redeem(_shares, _receiver, _controller, 0);
    }

    /// @inheritdoc IRoycoAsyncVault
    /// @dev For sync redeems (ERC-4626), `_controller` acts as the owner - shares are burned from it and allowance is checked.
    ///      For async redeems (ERC-7540), `_controller` is the request controller and caller must be controller or operator.
    function redeem(
        uint256 _shares,
        address _receiver,
        address _controller,
        uint256 _redemptionRequestId
    )
        public
        virtual
        override
        whenNotPaused
        restricted
        returns (AssetClaims memory claims, bytes memory metadata)
    {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));
        require(_shares != 0, MUST_REQUEST_NON_ZERO_SHARES());

        // Process the withdrawal from the underlying investment opportunity
        // It is expected that the kernel transfers the assets directly to the receiver
        (claims, metadata) =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IRoycoKernel(kernel()).stRedeem(_shares, _controller, _receiver, _redemptionRequestId)
                : IRoycoKernel(kernel()).jtRedeem(_shares, _controller, _receiver, _redemptionRequestId));

        // Account for the redemption
        // Shares must be burned after the kernel processes the redemption since the kernel has a causal dependency on the pre-burn and post-sync total share supply
        // If redemptions are synchronous, burn the shares from the owner
        if (_isSync(Action.REDEEM)) {
            // Spend the caller's share allowance if the caller isn't the owner
            if (msg.sender != _controller) _spendAllowance(_controller, msg.sender, _shares);
            // Burn the shares being redeemed from the owner
            _burn(_controller, _shares);
        } else {
            // If redemptions are asynchronous, require the caller to be the owner or an approved operator
            require(_isCallerOrOperator(_controller), ONLY_CALLER_OR_OPERATOR());
            // If the vault is expected to burn shares on executing redeem, burn the locked shares
            if (_requestRedeemSharesBehavior() == SharesRedemptionModel.BURN_ON_CLAIM_REDEEM) _burn(address(this), _shares);
        }

        emit Redeem(msg.sender, _receiver, claims, _shares, _redemptionRequestId, metadata);
    }

    // =============================
    // ERC7540 Asynchronous flow functions
    // =============================

    /// @inheritdoc IRoycoAsyncVault
    function isOperator(address _controller, address _operator) external view virtual override(IRoycoAsyncVault) returns (bool) {
        return RoycoTrancheStorageLib._getRoycoTrancheStorage().isOperator[_controller][_operator];
    }

    /// @inheritdoc IRoycoAsyncVault
    function setOperator(address _operator, bool _approved) external virtual override(IRoycoAsyncVault) whenNotPaused returns (bool) {
        // Cannot set the null address as an operator
        require(_operator != address(0), NULL_ADDRESS());
        // At least one flow needs to be async to set an operator
        require(!_isSync(Action.DEPOSIT) || !_isSync(Action.REDEEM), DEPOSIT_OR_REDEEM_MUST_BE_ASYNC());

        // Set the operator's approval status for the caller
        RoycoTrancheStorageLib._getRoycoTrancheStorage().isOperator[msg.sender][_operator] = _approved;
        emit OperatorSet(msg.sender, _operator, _approved);

        // Must return true as per ERC7540
        return true;
    }

    /// @inheritdoc IRoycoAsyncVault
    /// @dev Will revert if this tranche does not employ an asynchronous deposit flow
    function requestDeposit(
        TRANCHE_UNIT _assets,
        address _controller,
        address _owner
    )
        external
        virtual
        override(IRoycoAsyncVault)
        whenNotPaused
        restricted
        executionIsAsync(Action.DEPOSIT)
        onlyCallerOrOperator(_owner)
        returns (uint256 requestId, bytes memory metadata)
    {
        address kernel_ = kernel();

        // Transfer the assets from the owner to the kernel
        IERC20(asset()).safeTransferFrom(_owner, kernel_, toUint256(_assets));

        // Queue the deposit request and get the request ID from the kernel
        (requestId, metadata) =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(kernel_).stRequestDeposit(msg.sender, _assets, _controller)
                : IAsyncJTDepositKernel(kernel_).jtRequestDeposit(msg.sender, _assets, _controller));

        emit DepositRequest(_controller, _owner, requestId, msg.sender, _assets, metadata);
    }

    /// @inheritdoc IRoycoAsyncVault
    /// @dev Will revert if this tranche does not employ an asynchronous deposit flow
    function pendingDepositRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncVault)
        executionIsAsync(Action.DEPOSIT)
        returns (TRANCHE_UNIT pendingAssets)
    {
        pendingAssets =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(kernel()).stPendingDepositRequest(_requestId, _controller)
                : IAsyncJTDepositKernel(kernel()).jtPendingDepositRequest(_requestId, _controller));
    }

    /// @inheritdoc IRoycoAsyncVault
    /// @dev Will revert if this tranche does not employ an asynchronous deposit flow
    function claimableDepositRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncVault)
        executionIsAsync(Action.DEPOSIT)
        returns (TRANCHE_UNIT claimableAssets)
    {
        claimableAssets =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(kernel()).stClaimableDepositRequest(_requestId, _controller)
                : IAsyncJTDepositKernel(kernel()).jtClaimableDepositRequest(_requestId, _controller));
    }

    /// @inheritdoc IRoycoAsyncVault
    /// @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
    function requestRedeem(
        uint256 _shares,
        address _controller,
        address _owner
    )
        external
        virtual
        override(IRoycoAsyncVault)
        whenNotPaused
        restricted
        executionIsAsync(Action.REDEEM)
        returns (uint256 requestId, bytes memory metadata)
    {
        // Must be requesting to redeem a non-zero number of shares
        require(_shares != 0, MUST_REQUEST_NON_ZERO_SHARES());

        // Spend the caller's share allowance if the caller isn't the owner or an approved operator
        if (!_isCallerOrOperator(_owner)) {
            _spendAllowance(_owner, msg.sender, _shares);
        }

        // Queue the redemption request and get the request ID from the kernel
        (requestId, metadata) =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTRedemptionKernel(kernel()).stRequestRedeem(msg.sender, _shares, _controller)
                : IRoycoKernel(kernel()).jtRequestRedeem(msg.sender, _shares, _controller));

        // Handle the shares being redeemed from the owner using the tranche's redemption behavior
        if (_requestRedeemSharesBehavior() == SharesRedemptionModel.BURN_ON_CLAIM_REDEEM) {
            // Transfer and lock the requested shares being redeemed from the owner to the tranche
            _transfer(_owner, address(this), _shares);
        } else {
            // Burn the shares being redeemed from the owner immediately after the request is made
            _burn(_owner, _shares);
        }

        emit RedeemRequest(_controller, _owner, requestId, msg.sender, _shares, metadata);
    }

    /// @inheritdoc IRoycoAsyncVault
    /// @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
    function pendingRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncVault)
        executionIsAsync(Action.REDEEM)
        returns (uint256 pendingShares)
    {
        // Get the number of shares pending from the request
        uint256 pendingSharesFromRequest =
            (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTRedemptionKernel(kernel()).stPendingRedeemRequest(_requestId, _controller)
                : IRoycoKernel(kernel()).jtPendingRedeemRequest(_requestId, _controller));

        // If the request is claimable from underlying, some shares may still be locked due to the coverage condition
        uint256 claimableSharesFromRequest =
            (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTRedemptionKernel(kernel()).stClaimableRedeemRequest(_requestId, _controller)
                : IRoycoKernel(kernel()).jtClaimableRedeemRequest(_requestId, _controller));
        uint256 lockedClaimableSharesDueToCoverageCondition = claimableSharesFromRequest - _maxRedeem(_controller, claimableSharesFromRequest);

        pendingShares = pendingSharesFromRequest + lockedClaimableSharesDueToCoverageCondition;
    }

    /// @inheritdoc IRoycoAsyncVault
    /// @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
    function claimableRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncVault)
        executionIsAsync(Action.REDEEM)
        returns (uint256 claimableShares)
    {
        claimableShares =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTRedemptionKernel(kernel()).stClaimableRedeemRequest(_requestId, _controller)
                : IRoycoKernel(kernel()).jtClaimableRedeemRequest(_requestId, _controller));

        claimableShares = _maxRedeem(_controller, claimableShares);
    }

    // ===========================================
    // Royco Tranche Vault Cancellation Functions
    // ===========================================

    /// @inheritdoc IRoycoAsyncCancellableVault
    /// @dev Will revert if this tranche does not employ an asynchronous deposit flow
    function cancelDepositRequest(
        uint256 _requestId,
        address _controller
    )
        external
        virtual
        override(IRoycoAsyncCancellableVault)
        whenNotPaused
        restricted
        executionIsAsync(Action.DEPOSIT)
        onlyCallerOrOperator(_controller)
    {
        if (TRANCHE_TYPE() == TrancheType.SENIOR) {
            IAsyncSTDepositKernel(kernel()).stCancelDepositRequest(msg.sender, _requestId, _controller);
        } else {
            IAsyncJTDepositKernel(kernel()).jtCancelDepositRequest(msg.sender, _requestId, _controller);
        }

        emit CancelDepositRequest(_controller, _requestId, msg.sender);
    }

    /// @inheritdoc IRoycoAsyncCancellableVault
    /// @dev Will revert if this tranche does not employ an asynchronous deposit flow
    function pendingCancelDepositRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncCancellableVault)
        executionIsAsync(Action.DEPOSIT)
        returns (bool isPending)
    {
        return (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(kernel()).stPendingCancelDepositRequest(_requestId, _controller)
                : IAsyncJTDepositKernel(kernel()).jtPendingCancelDepositRequest(_requestId, _controller));
    }

    /// @inheritdoc IRoycoAsyncCancellableVault
    /// @dev Will revert if this tranche does not employ an asynchronous deposit flow
    function claimableCancelDepositRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncCancellableVault)
        executionIsAsync(Action.DEPOSIT)
        returns (TRANCHE_UNIT assets)
    {
        assets =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(kernel()).stClaimableCancelDepositRequest(_requestId, _controller)
                : IAsyncJTDepositKernel(kernel()).jtClaimableCancelDepositRequest(_requestId, _controller));
    }

    /// @inheritdoc IRoycoAsyncCancellableVault
    /// @dev Will revert if this tranche does not employ an asynchronous deposit flow
    function claimCancelDepositRequest(
        uint256 _requestId,
        address _receiver,
        address _controller
    )
        external
        virtual
        override(IRoycoAsyncCancellableVault)
        whenNotPaused
        restricted
        executionIsAsync(Action.DEPOSIT)
        onlyCallerOrOperator(_controller)
    {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));
        // Expect the kernel to transfer the assets to the receiver directly after the cancellation is processed
        TRANCHE_UNIT claimedAssets =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(kernel()).stClaimCancelDepositRequest(_requestId, _receiver, _controller)
                : IAsyncJTDepositKernel(kernel()).jtClaimCancelDepositRequest(_requestId, _receiver, _controller));
        emit CancelDepositClaim(_controller, _receiver, _requestId, msg.sender, claimedAssets);
    }

    /// @inheritdoc IRoycoAsyncCancellableVault
    /// @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
    function cancelRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        external
        virtual
        override(IRoycoAsyncCancellableVault)
        whenNotPaused
        restricted
        executionIsAsync(Action.REDEEM)
        onlyCallerOrOperator(_controller)
    {
        // Request the kernel to cancel a previously made redeem request on behalf of the user
        if (TRANCHE_TYPE() == TrancheType.SENIOR) {
            IAsyncSTRedemptionKernel(kernel()).stCancelRedeemRequest(_requestId, _controller);
        } else {
            IRoycoKernel(kernel()).jtCancelRedeemRequest(_requestId, _controller);
        }

        emit CancelRedeemRequest(_controller, _requestId, msg.sender);
    }

    /// @inheritdoc IRoycoAsyncCancellableVault
    /// @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
    function pendingCancelRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncCancellableVault)
        executionIsAsync(Action.REDEEM)
        returns (bool isPending)
    {
        isPending =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTRedemptionKernel(kernel()).stPendingCancelRedeemRequest(_requestId, _controller)
                : IRoycoKernel(kernel()).jtPendingCancelRedeemRequest(_requestId, _controller));
    }

    /// @inheritdoc IRoycoAsyncCancellableVault
    /// @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
    function claimableCancelRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncCancellableVault)
        executionIsAsync(Action.REDEEM)
        returns (uint256 shares)
    {
        shares =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTRedemptionKernel(kernel()).stClaimableCancelRedeemRequest(_requestId, _controller)
                : IRoycoKernel(kernel()).jtClaimableCancelRedeemRequest(_requestId, _controller));
    }

    /// @inheritdoc IRoycoAsyncCancellableVault
    /// @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
    function claimCancelRedeemRequest(
        uint256 _requestId,
        address _receiver,
        address _controller
    )
        external
        virtual
        override(IRoycoAsyncCancellableVault)
        whenNotPaused
        restricted
        executionIsAsync(Action.REDEEM)
        onlyCallerOrOperator(_controller)
    {
        // Get the number of shares in a canceled state for this request ID
        uint256 shares =
            (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTRedemptionKernel(kernel()).stClaimCancelRedeemRequest(_requestId, _controller)
                : IRoycoKernel(kernel()).jtClaimCancelRedeemRequest(_requestId, _controller));

        // Ensure a non-zero amount can be claimed
        require(shares != 0, MUST_CLAIM_NON_ZERO_SHARES());

        // Return the shares to the receiver based on the tranche's redeem shares behavior
        if (_requestRedeemSharesBehavior() == SharesRedemptionModel.BURN_ON_REQUEST_REDEEM) {
            // Mint the burnt shares to the receiver
            _mint(_receiver, shares);
        } else {
            // Transfer the previously locked shares (on request) to the receiver
            _transfer(address(this), _receiver, shares);
        }

        emit CancelRedeemClaim(_controller, _receiver, _requestId, msg.sender, shares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function previewMintProtocolFeeShares(
        NAV_UNIT _protocolFeeAssets,
        NAV_UNIT _trancheTotalAssets
    )
        public
        view
        virtual
        override(IRoycoVaultTranche)
        returns (uint256 protocolFeeSharesMinted, uint256 totalTrancheShares)
    {
        // Compute the shares to be minted to the protocol fee recipient to satisfy the ratio of total assets that the fee represents
        // Subtract fee assets from total tranche assets because fees are included in total tranche assets
        // Round in favor of the tranche
        uint256 totalShares = totalSupply();
        protocolFeeSharesMinted = _convertToShares(_protocolFeeAssets, totalShares, (_trancheTotalAssets - _protocolFeeAssets), Math.Rounding.Floor);

        // The total tranche shares include the protocol fee shares and virtual shares
        totalTrancheShares = _withVirtualShares(totalShares + protocolFeeSharesMinted);
    }

    /// @inheritdoc IRoycoVaultTranche
    function mintProtocolFeeShares(
        NAV_UNIT _protocolFeeAssets,
        NAV_UNIT _trancheTotalAssets,
        address _protocolFeeRecipient
    )
        external
        virtual
        override(IRoycoVaultTranche)
        returns (uint256 protocolFeeSharesMinted, uint256 totalTrancheShares)
    {
        // Only the kernel can mint protocol fee shares based on sync
        require(msg.sender == kernel(), ONLY_KERNEL());

        // Mint any protocol fee shares accrued to the specified recipient
        (protocolFeeSharesMinted, totalTrancheShares) = previewMintProtocolFeeShares(_protocolFeeAssets, _trancheTotalAssets);
        if (protocolFeeSharesMinted != 0) _mint(_protocolFeeRecipient, protocolFeeSharesMinted);

        emit ProtocolFeeSharesMinted(_protocolFeeRecipient, protocolFeeSharesMinted, totalTrancheShares);
    }

    /// @inheritdoc IERC20Metadata
    function decimals() public view virtual override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        // The Kernel always uses WAD precision for the NAV units
        // Since virtual assets and shares are set to 1, the shares are minted in the same precision as the NAV units (WAD precision)
        return uint8(WAD_DECIMALS);
    }

    /// @inheritdoc IRoycoVaultTranche
    function asset() public view virtual override(IRoycoVaultTranche) returns (address) {
        return RoycoTrancheStorageLib._getRoycoTrancheStorage().asset;
    }

    /**
     * @dev Returns the maximum amount of shares that can be redeemed from the tranche
     * @dev We query the kernel for (a) N_s and N_j - the notional claim of the tranche on the ST and JT assets respectively in NAV units, and
     *                              (b) L_s and L_j - the amount that can be withdrawn from the senior and junior tranches globally in NAV units, respectively
     *      When shares are redeemed, assets from the senior and junior tranches are withdrawn proportionally to the notional claims of the tranche on the respective assets.
     *      But, the global max withdrawable assets for each tranche are also considered. These are inclusive of any coverage requirements, as well as liquidity constraints.
     *      If T respresents the total shares in the tranche, s the total shares owned by the owner, then the maximum amount of shares that can be redeemed s' is subject to:
     *      (a) s' * N_s / T  <= min(s * N_s / T, L_s) => s' <= min(s, T * L_s / N_s)
     *      (b) s' * N_j / T  <= min(s * N_j / T, L_j) => s' <= min(s, T * L_j / N_j)
     *      Therefore, the maximum amount of shares that can be redeemed is:
     *      s' = min(s, T * L_s / N_s, T * L_j / N_j)
     */
    function _maxRedeem(address _owner, uint256 _sharesOwned) internal view returns (uint256 shares) {
        // Get the notional claims and the max withdrawable assets for the tranche
        (NAV_UNIT claimOnStNAV, NAV_UNIT claimOnJtNAV, NAV_UNIT stMaxWithdrawableNAV, NAV_UNIT jtMaxWithdrawableNAV, uint256 totalSharesAfterMintingFees) =
            (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(kernel()).stMaxWithdrawable(_owner) : IRoycoKernel(kernel()).jtMaxWithdrawable(_owner));

        // Calculate the maximum amount of shares that can be redeemed based on the senior and junior constraints
        // If the notional claim of the tranche on the ST or JT assets is zero, ignore the constraints since the tranche has no claims on the assets
        uint256 sharesWithdrawableBasedOnSeniorConstraints =
            claimOnStNAV == ZERO_NAV_UNITS ? _sharesOwned : totalSharesAfterMintingFees.mulDiv(stMaxWithdrawableNAV, claimOnStNAV, Math.Rounding.Floor);
        uint256 sharesWithdrawableBasedOnJuniorConstraints =
            claimOnJtNAV == ZERO_NAV_UNITS ? _sharesOwned : totalSharesAfterMintingFees.mulDiv(jtMaxWithdrawableNAV, claimOnJtNAV, Math.Rounding.Floor);
        shares = Math.min(_sharesOwned, Math.min(sharesWithdrawableBasedOnSeniorConstraints, sharesWithdrawableBasedOnJuniorConstraints));
    }

    /**
     * @notice Returns the total tranche assets and shares after previewing a NAV synchronization in the kernel
     * @return trancheClaims The breakdown of total tranche's total controlled assets
     * @return trancheTotalShares The total supply of tranche shares (including marginally minted fee shares)
     */
    function _previewPostSyncTrancheState() internal view returns (AssetClaims memory trancheClaims, uint256 trancheTotalShares) {
        // Get the post-sync state of the kernel for the tranche
        IRoycoKernel kernel_ = IRoycoKernel(kernel());
        SyncedAccountingState memory state;
        (state, trancheClaims, trancheTotalShares) = kernel_.previewSyncTrancheAccounting(TRANCHE_TYPE());
    }

    /**
     * @dev Returns the amount of shares that have a claim on the specified amount of tranche controlled assets
     * @param _assets The amount of assets to convert in NAV units
     * @param _totalSupply The total supply of tranche shares (including marginally minted fee shares)
     * @param _totalAssets The total tranche controlled assets in NAV units
     * @param _rounding The rounding mode to use
     * @return shares The number of shares that have a claim on the specified amount of tranche controlled assets
     */
    function _convertToShares(NAV_UNIT _assets, uint256 _totalSupply, NAV_UNIT _totalAssets, Math.Rounding _rounding) internal view returns (uint256 shares) {
        return _withVirtualShares(_totalSupply).mulDiv(_assets, _withVirtualAssets(_totalAssets), _rounding);
    }

    /**
     * @notice Checks if the caller is either the specified address or an approved operator
     * @param _account The address of the user to check
     * @return A boolean indicating whether the user is the caller or an approved operator for the user
     */
    function _isCallerOrOperator(address _account) internal view returns (bool) {
        return (msg.sender == _account || RoycoTrancheStorageLib._getRoycoTrancheStorage().isOperator[_account][msg.sender]);
    }

    /// @dev Returns if the specified action employs a synchronous execution model
    function _isSync(Action _action) internal view returns (bool) {
        return (_action == Action.DEPOSIT
                    ? RoycoTrancheStorageLib._getRoycoTrancheStorage().DEPOSIT_EXECUTION_MODEL
                    : RoycoTrancheStorageLib._getRoycoTrancheStorage().WITHDRAW_EXECUTION_MODEL) == ExecutionModel.SYNC;
    }

    /// @dev Returns whether or not shares should be burned upon requesting a redeem or executing the redeem
    function _requestRedeemSharesBehavior() internal view virtual returns (SharesRedemptionModel) {
        return (TRANCHE_TYPE() == TrancheType.SENIOR
                ? RoycoTrancheStorageLib._getRoycoTrancheStorage().REQUEST_REDEEM_SHARES_ST_BEHAVIOR
                : RoycoTrancheStorageLib._getRoycoTrancheStorage().REQUEST_REDEEM_SHARES_JT_BEHAVIOR);
    }

    /// @dev Returns the specified share quantity added to the tranche's virtual shares
    function _withVirtualShares(uint256 _shares) internal view returns (uint256) {
        // NAV units are always in WAD precision, therefore virtual shares are 10 ^ (WAD_DECIMALS - 18) = 1
        return _shares + 1;
    }

    /// @dev Returns the specified share quantity subtracted from the tranche's virtual shares
    function _withoutVirtualShares(uint256 _shares) internal view returns (uint256) {
        // NAV units are always in WAD precision, therefore virtual shares are 10 ^ (WAD_DECIMALS - 18) = 1
        return _shares - 1;
    }

    /// @dev Returns the specified NAV added to the tranche's virtual NAV (1)
    function _withVirtualAssets(NAV_UNIT _assets) internal pure returns (NAV_UNIT) {
        return _assets + toNAVUnits(uint256(1));
    }

    /// @inheritdoc ERC20PausableUpgradeable
    function _update(address _from, address _to, uint256 _value) internal override(ERC20PausableUpgradeable, ERC20Upgradeable) whenNotPaused {
        super._update(_from, _to, _value);
    }

    /// @dev Returns the type of the tranche (Senior or Junior)
    function TRANCHE_TYPE() public pure virtual returns (TrancheType);
}
