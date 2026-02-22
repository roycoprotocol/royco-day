// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC20Upgradeable, IERC20, IERC20Metadata } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import { ERC20PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import { ERC20PermitUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { SafeERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoBase } from "../../base/RoycoBase.sol";
import { IRoycoKernel } from "../../interfaces/kernel/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/tranche/IRoycoVaultTranche.sol";
import { WAD_DECIMALS, ZERO_NAV_UNITS } from "../../libraries/Constants.sol";
import { RoycoTrancheStorageLib } from "../../libraries/RoycoTrancheStorageLib.sol";
import { AssetClaims, SyncedAccountingState, TrancheDeploymentParams, TrancheType } from "../../libraries/Types.sol";
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
        RoycoTrancheStorageLib.__RoycoTranche_init(_kernelAddress, _asset, _marketId);
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
        uint256 sharesOwned = balanceOf(_owner);
        // Get the notional claims and the max withdrawable assets for the tranche
        (NAV_UNIT claimOnStNAV, NAV_UNIT claimOnJtNAV, NAV_UNIT stMaxWithdrawableNAV, NAV_UNIT jtMaxWithdrawableNAV, uint256 totalSharesAfterMintingFees) =
            (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(kernel()).stMaxWithdrawable(_owner) : IRoycoKernel(kernel()).jtMaxWithdrawable(_owner));

        // Calculate the maximum amount of shares that can be redeemed based on the senior and junior constraints
        // If the notional claim of the tranche on the ST or JT assets is zero, ignore the constraints since the tranche has no claims on the assets
        uint256 sharesWithdrawableBasedOnSeniorConstraints =
            claimOnStNAV == ZERO_NAV_UNITS ? sharesOwned : totalSharesAfterMintingFees.mulDiv(stMaxWithdrawableNAV, claimOnStNAV, Math.Rounding.Floor);
        uint256 sharesWithdrawableBasedOnJuniorConstraints =
            claimOnJtNAV == ZERO_NAV_UNITS ? sharesOwned : totalSharesAfterMintingFees.mulDiv(jtMaxWithdrawableNAV, claimOnJtNAV, Math.Rounding.Floor);
        shares = Math.min(sharesOwned, Math.min(sharesWithdrawableBasedOnSeniorConstraints, sharesWithdrawableBasedOnJuniorConstraints));
    }

    /// @inheritdoc IRoycoVaultTranche
    function previewDeposit(TRANCHE_UNIT _assets) external view virtual override(IRoycoVaultTranche) returns (uint256 shares) {
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
    function previewRedeem(uint256 _shares) external view virtual override(IRoycoVaultTranche) returns (AssetClaims memory claims) {
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

    /// @inheritdoc IRoycoVaultTranche
    function deposit(TRANCHE_UNIT _assets, address _receiver) public virtual override whenNotPaused restricted returns (uint256 shares) {
        require(_assets != toTrancheUnits(0), MUST_DEPOSIT_NON_ZERO_ASSETS());

        // Transfer the assets to the kernel
        IRoycoKernel kernel_ = IRoycoKernel(kernel());
        IERC20(asset()).safeTransferFrom(msg.sender, address(kernel_), toUint256(_assets));

        // Deposit the assets into the underlying investment opportunity and get the fraction of total assets allocated
        (NAV_UNIT valueAllocated, NAV_UNIT effectiveNAVToMintAt) =
            (TRANCHE_TYPE() == TrancheType.SENIOR ? kernel_.stDeposit(_assets, msg.sender, _receiver) : kernel_.jtDeposit(_assets, msg.sender, _receiver));

        // effectiveNAVToMint at can be zero initially when the tranche is deployed
        require(valueAllocated != ZERO_NAV_UNITS, INVALID_VALUE_ALLOCATED());

        // valueAllocated represents the value of the assets deposited in the asset that the tranche's NAV is denominated in
        // shares are minted to the user at the effective NAV of the tranche
        // effectiveNAVToMintAt is the effective NAV of the tranche before the deposit is made, ie. the NAV at which the shares will be minted
        shares = _convertToShares(valueAllocated, totalSupply(), effectiveNAVToMintAt, Math.Rounding.Floor);

        // Mint the shares to the receiver
        _mint(_receiver, shares);

        emit Deposit(msg.sender, _receiver, _assets, shares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function redeem(uint256 _shares, address _receiver, address _owner) public virtual override whenNotPaused restricted returns (AssetClaims memory claims) {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));
        require(_shares != 0, MUST_REQUEST_NON_ZERO_SHARES());

        // Spend allowance if caller is not the owner
        if (msg.sender != _owner) {
            _spendAllowance(_owner, msg.sender, _shares);
        }

        // Process the withdrawal from the underlying investment opportunity
        // It is expected that the kernel transfers the assets directly to the receiver
        claims =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IRoycoKernel(kernel()).stRedeem(_shares, msg.sender, _owner, _receiver)
                : IRoycoKernel(kernel()).jtRedeem(_shares, msg.sender, _owner, _receiver));

        // Burn shares after kernel processes redemption (kernel depends on pre-burn total supply)
        _burn(_owner, _shares);

        emit Redeem(msg.sender, _receiver, claims, _shares);
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
        // The Kernel always uses WAD precision for NAV units
        // Shares are minted using NAV values, instead of asset values, so they have identical precision to NAV units (WAD precision)
        return uint8(WAD_DECIMALS);
    }

    /// @inheritdoc IRoycoVaultTranche
    function asset() public view virtual override(IRoycoVaultTranche) returns (address) {
        return RoycoTrancheStorageLib._getRoycoTrancheStorage().asset;
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

    /// @dev Returns the specified share quantity added to the tranche's virtual shares
    function _withVirtualShares(uint256 _shares) internal pure returns (uint256) {
        return _shares + 1;
    }

    /// @dev Returns the specified share quantity subtracted from the tranche's virtual shares
    function _withoutVirtualShares(uint256 _shares) internal pure returns (uint256) {
        return _shares - 1;
    }

    /// @dev Returns the specified NAV added to the tranche's virtual NAV (1)
    function _withVirtualAssets(NAV_UNIT _assets) internal pure returns (NAV_UNIT) {
        // NAV units are always in WAD precision, therefore 1 wei of NAV_UNITs are the virtual assets corresponding to 1 wei of tranche shares (WAD precision)
        return _assets + toNAVUnits(uint256(1));
    }

    /// @inheritdoc ERC20PausableUpgradeable
    function _update(address _from, address _to, uint256 _value) internal override(ERC20PausableUpgradeable, ERC20Upgradeable) whenNotPaused {
        super._update(_from, _to, _value);
    }

    /// @dev Returns the type of the tranche (Senior or Junior)
    function TRANCHE_TYPE() public pure virtual returns (TrancheType);
}
