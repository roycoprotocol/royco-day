// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { ERC20Upgradeable, IERC20, IERC20Metadata } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import { ERC20BurnableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { ERC20PermitUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { SafeERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoBase } from "../../base/RoycoBase.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { WAD_DECIMALS } from "../../libraries/Constants.sol";
import { AssetClaims, DispatchMode, SyncedAccountingState, TrancheType } from "../../libraries/Types.sol";
import { NAV_UNIT, RoycoUnitsMath, TRANCHE_UNIT, toUint256 } from "../../libraries/Units.sol";
import { AssetLedgerLogic } from "../../libraries/logic/AssetLedgerLogic.sol";
import { DispatchLogic } from "../../libraries/logic/DispatchLogic.sol";
import { ValuationLogic } from "../../libraries/logic/ValuationLogic.sol";

/**
 * @title RoycoVaultTranche
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base contract implementing core vault functionality for Royco tranches (ST, JT, and LPT)
 * @dev Tranches interact with the kernel to execute all operations based on the current holistic state of the Royco market
 */
abstract contract RoycoVaultTranche is IRoycoVaultTranche, RoycoBase, ERC20BurnableUpgradeable, ERC20PermitUpgradeable {
    using Math for uint256;
    using RoycoUnitsMath for uint256;
    using SafeERC20 for IERC20;
    using DispatchLogic for address;

    /// @dev Storage slot for RoycoVaultTrancheState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoVaultTrancheState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _ROYCO_VAULT_TRANCHE_STORAGE_SLOT = 0xb29e56aa3db56637b513fb077b36928988b241f28eccd4f6a5bd34624bbe3900;

    /// @dev Permissions the function to only be callable by the kernel, the single source of truth for sync-driven share mints
    modifier onlyKernel() {
        require(msg.sender == _getRoycoVaultTrancheStorage().kernel, ONLY_KERNEL());
        _;
    }

    /**
     * @notice Initializes the Royco tranche
     * @dev This function initializes parent contracts and the tranche-specific state
     * @param _params Deployment parameters including name, symbol, initial authority, kernel, and asset
     */
    function __RoycoTranche_init(RoycoTrancheInitParams calldata _params) internal onlyInitializing {
        // Ensure that the asset and kernel are not null
        require(_params.asset != address(0) && _params.kernel != address(0), NULL_ADDRESS());

        // Set the tranche's market wiring
        RoycoVaultTrancheState storage $ = _getRoycoVaultTrancheStorage();
        $.kernel = _params.kernel;
        $.asset = _params.asset;

        // Initialize all the parent contracts
        __RoycoBase_init(_params.initialAuthority);
        __ERC20_init_unchained(_params.name, _params.symbol);
        __ERC20Burnable_init();
        __ERC20Permit_init(_params.name);
    }

    // =============================
    // Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoVaultTranche
    function deposit(TRANCHE_UNIT _assets, address _receiver) public virtual override(IRoycoVaultTranche) restricted returns (uint256 shares) {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));

        // Transfer the assets to the kernel
        RoycoVaultTrancheState storage $ = _getRoycoVaultTrancheStorage();
        IERC20($.asset).safeTransferFrom(msg.sender, $.kernel, toUint256(_assets));

        // Deposit the assets into the Royco market, the kernel prices the shares and mints them to the receiver
        shares = _deposit(DispatchMode.EXECUTE, _assets, _receiver);

        emit Deposit(msg.sender, _receiver, _assets, shares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner
    )
        public
        virtual
        override(IRoycoVaultTranche)
        restricted
        returns (AssetClaims memory claims)
    {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));

        // Spend allowance if msg.sender is not the owner
        if (msg.sender != _owner) _spendAllowance(_owner, msg.sender, _shares);

        // Process the withdrawal from the Royco market, the kernel burns the owner's shares after scaling their claims
        // It is expected that the kernel transfers the assets directly to the receiver
        claims = _redeem(DispatchMode.EXECUTE, _shares, _receiver, _owner);

        emit Redeem(msg.sender, _receiver, claims, _shares);
    }

    // =============================
    // Tranche Max Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoVaultTranche
    function maxDeposit(address _receiver) external view virtual override(IRoycoVaultTranche) returns (TRANCHE_UNIT assets) {
        return IRoycoDayKernel(kernel()).inkindMaxDeposit(_receiver);
    }

    /// @inheritdoc IRoycoVaultTranche
    function maxRedeem(address _owner) public view virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        // The maximum redeemable shares are the minimum of the owner's share balance and the globally redeemable shares the kernel prices
        return Math.min(balanceOf(_owner), IRoycoDayKernel(kernel()).inkindMaxRedeemable(_owner));
    }

    // =============================
    // Tranche Preview and Conversion Functions
    // =============================

    /// @inheritdoc IRoycoVaultTranche
    /// @dev Routes the deposit through the execute-and-revert pattern so the quote is produced by the actual kernel deposit path under its real semantics
    function previewDeposit(TRANCHE_UNIT _assets) external virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        return _deposit(DispatchMode.SIMULATE, _assets, kernel());
    }

    /// @inheritdoc IRoycoVaultTranche
    /// @dev Routes the redemption through the execute-and-revert pattern so the quote is produced by the actual kernel redemption path under its real semantics
    function previewRedeem(uint256 _shares) external virtual override(IRoycoVaultTranche) returns (AssetClaims memory claims) {
        return _redeem(DispatchMode.SIMULATE, _shares, kernel(), address(0));
    }

    /// @inheritdoc IRoycoVaultTranche
    function convertToAssets(uint256 _shares) public view virtual override(IRoycoVaultTranche) returns (AssetClaims memory claims) {
        // Get the post-sync tranche state: applying NAV reconciliation
        (SyncedAccountingState memory state, AssetClaims memory trancheClaims, uint256 trancheTotalShares) =
            IRoycoDayKernel(kernel()).previewSyncTrancheAccountingFor(TRANCHE_TYPE());
        if (TRANCHE_TYPE() == TrancheType.LIQUIDITY_PROVIDER) {
            // We exclude any idle (not reinvested) ST shares from the LPT claims in order to ensure that its share price does not drop due to slippage incurred on reinvestment
            trancheClaims.stShares = 0;
            trancheClaims.nav = state.lptRawNAV;
        }
        return AssetLedgerLogic._scaleAssetClaims(trancheClaims, _shares, trancheTotalShares, true);
    }

    /// @inheritdoc IRoycoVaultTranche
    function convertToShares(TRANCHE_UNIT _assets) public view virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        address kernel_ = kernel();

        // Value the assets specified in NAV units
        NAV_UNIT value = (TRANCHE_TYPE() == TrancheType.LIQUIDITY_PROVIDER)
            ? IRoycoDayKernel(kernel_).convertLPTAssetsToValue(_assets)
            : IRoycoDayKernel(kernel_).convertCollateralAssetsToValue(_assets);

        // Get the post-sync tranche state
        (SyncedAccountingState memory state, AssetClaims memory trancheClaims, uint256 trancheTotalShares) =
            IRoycoDayKernel(kernel_).previewSyncTrancheAccountingFor(TRANCHE_TYPE());

        // We exclude any idle (not reinvested) ST shares from the LPT NAV basis in order to ensure that its NAV per share does not drop due to slippage incurred on reinvestment
        NAV_UNIT navBasis = ((TRANCHE_TYPE() == TrancheType.LIQUIDITY_PROVIDER) ? state.lptRawNAV : trancheClaims.nav);
        shares = ValuationLogic._convertToShares(value, navBasis, trancheTotalShares, Math.Rounding.Floor);
    }

    // =============================
    // General Tranche View Functions
    // =============================

    /// @inheritdoc IRoycoVaultTranche
    function totalAssets() external view virtual override(IRoycoVaultTranche) returns (AssetClaims memory claims) {
        (, claims,) = IRoycoDayKernel(kernel()).previewSyncTrancheAccountingFor(TRANCHE_TYPE());
    }

    /// @inheritdoc IRoycoVaultTranche
    function asset() external view virtual override(IRoycoVaultTranche) returns (address) {
        return _getRoycoVaultTrancheStorage().asset;
    }

    /// @inheritdoc IRoycoVaultTranche
    function kernel() public view virtual override(IRoycoVaultTranche) returns (address) {
        return _getRoycoVaultTrancheStorage().kernel;
    }

    /**
     * @inheritdoc IERC20Metadata
     * @dev The kernel always uses WAD precision for NAV units
     * @dev Shares are minted using NAV_UNIT values instead of TRANCHE_UNIT values, so they have identical precision to NAV_UNIT values (WAD precision)
     */
    function decimals() public view virtual override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        return uint8(WAD_DECIMALS);
    }

    /// @dev Returns the type of the tranche (Senior, Junior, or Liquidity)
    function TRANCHE_TYPE() public pure virtual returns (TrancheType);

    // =============================
    // Kernel Mint and Burn Entrypoints
    // =============================

    /// @inheritdoc IRoycoVaultTranche
    function mintProtocolFeeShares(
        address _protocolFeeRecipient,
        uint256 _protocolFeeShares
    )
        external
        virtual
        override(IRoycoVaultTranche)
        onlyKernel
        returns (uint256 totalTrancheShares)
    {
        // Mint the precomputed protocol fee shares to the recipient (the kernel prices them jointly with the liquidity premium)
        if (_protocolFeeShares != 0) _mint(_protocolFeeRecipient, _protocolFeeShares);

        totalTrancheShares = totalSupply();
        emit ProtocolFeeSharesMinted(_protocolFeeRecipient, _protocolFeeShares, totalTrancheShares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function kernelMint(address _to, uint256 _shares) external virtual override(IRoycoVaultTranche) onlyKernel {
        require(_to != address(0), ERC20InvalidReceiver(address(0)));
        _mint(_to, _shares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function kernelBurn(address _from, uint256 _shares) external virtual override(IRoycoVaultTranche) onlyKernel {
        _burn(_from, _shares);
    }

    // =============================
    // Public Burn Functions
    // =============================

    /// @inheritdoc ERC20BurnableUpgradeable
    function burn(uint256 _shares) public virtual override(ERC20BurnableUpgradeable) restricted {
        super.burn(_shares);
    }

    /// @inheritdoc ERC20BurnableUpgradeable
    function burnFrom(address _account, uint256 _shares) public virtual override(ERC20BurnableUpgradeable) restricted {
        super.burnFrom(_account, _shares);
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @dev Deposits the assets into the Royco market through the kernel's in-kind deposit entrypoint
     * @dev The kernel resolves the deposited tranche from this calling tranche, prices the shares at its pre-deposit effective NAV against the post-sync supply, and mints them to the receiver
     * @dev Forwards msg.sender as the caller for an execution, a simulation carries the null synthetic caller so previews never vary by caller
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _assets The amount of assets to deposit, denominated in the tranche's base asset units
     * @param _receiver The address that receives the minted shares
     * @return shares The number of shares minted for the deposit
     */
    function _deposit(DispatchMode _mode, TRANCHE_UNIT _assets, address _receiver) internal virtual returns (uint256 shares) {
        // Deposit the assets into the Royco market through the kernel's in-kind deposit entrypoint, which prices and mints the shares
        // The kernel rejects a deposit that prices to zero shares
        return abi.decode(
            kernel()._dispatchAndUnwrap(_mode, abi.encodeCall(IRoycoDayKernel.inkindDeposit, (_mode, _assets, _resolveCaller(_mode), _receiver))), (uint256)
        );
    }

    /**
     * @dev Redeems the shares from the Royco market through the kernel's in-kind redemption entrypoint
     * @dev The kernel resolves the redeemed tranche from this calling tranche, transfers the redeemed assets directly to the receiver, and burns the owner's shares after scaling their claims
     * @dev Forwards msg.sender as the caller for an execution, a simulation carries the null synthetic caller so previews never vary by caller
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _shares The number of shares to redeem
     * @param _receiver The address that receives the redeemed assets
     * @param _owner The address whose shares are burned for the redemption
     * @return claims The distribution of assets transferred to the receiver on redemption
     */
    function _redeem(DispatchMode _mode, uint256 _shares, address _receiver, address _owner) internal virtual returns (AssetClaims memory claims) {
        // Redeem the shares through the kernel's in-kind redemption entrypoint, the kernel transfers the redeemed assets directly to the receiver
        // The kernel rejects a zero-share redemption
        return abi.decode(
            kernel()._dispatchAndUnwrap(_mode, abi.encodeCall(IRoycoDayKernel.inkindRedeem, (_mode, _shares, _resolveCaller(_mode), _owner, _receiver))),
            (AssetClaims)
        );
    }

    /// @dev Resolves the caller forwarded to the kernel: an execution forwards msg.sender and a simulation carries the null address so previews never vary by caller
    /// @param _mode The dispatch mode used to resolve the caller
    function _resolveCaller(DispatchMode _mode) internal view returns (address) {
        return (_mode == DispatchMode.SIMULATE) ? address(0) : msg.sender;
    }

    /**
     * @inheritdoc ERC20Upgradeable
     * @dev Routes every balance update through the kernel's screening hook, which enforces the market's blacklist and
     *      reverts when the kernel is paused: transfers, mints, and burns are all gated by the kernel
     */
    function _update(address _from, address _to, uint256 _value) internal override(ERC20Upgradeable) {
        // Call the kernel's pre-balance update hook to assert that the balance update is valid
        IRoycoDayKernel(kernel()).preTrancheBalanceUpdateHook(msg.sender, _from, _to, _value);

        // Call the parent contract's update function to update the balance
        ERC20Upgradeable._update(_from, _to, _value);
    }

    /**
     * @notice Returns a storage pointer to the RoycoVaultTrancheState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the tranche's state
     */
    function _getRoycoVaultTrancheStorage() internal pure returns (RoycoVaultTrancheState storage $) {
        assembly ("memory-safe") {
            $.slot := _ROYCO_VAULT_TRANCHE_STORAGE_SLOT
        }
    }
}
