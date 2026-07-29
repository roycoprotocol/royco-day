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
import { WAD_DECIMALS, ZERO_NAV_UNITS } from "../../libraries/Constants.sol";
import { AssetClaims, SyncedAccountingState, TrancheType } from "../../libraries/Types.sol";
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

    /// @dev The address of the yield bearing asset of the tranche
    address internal immutable ASSET;

    /// @inheritdoc IRoycoVaultTranche
    address public immutable override(IRoycoVaultTranche) KERNEL;

    /// @dev Permissions the function to only be callable by the kernel, the single source of truth for sync-driven share mints
    modifier onlyKernel() {
        require(msg.sender == KERNEL, ONLY_KERNEL());
        _;
    }

    /**
     * @notice Constructs the Royco vault tranche
     * @param _asset The underlying asset for the tranche
     * @param _kernel The kernel that handles the core market logic and accounting synchronization
     */
    constructor(address _asset, address _kernel) {
        // Ensure that the asset and kernel are not null
        require(_asset != address(0) && _kernel != address(0), NULL_ADDRESS());

        // Set the immutable state
        ASSET = _asset;
        KERNEL = _kernel;
    }

    /**
     * @notice Initializes the Royco tranche
     * @dev This function initializes parent contracts and the tranche-specific state
     * @param _params Deployment parameters including name, symbol, and initial authority
     */
    function __RoycoTranche_init(RoycoTrancheInitParams calldata _params) internal onlyInitializing {
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
        IERC20(ASSET).safeTransferFrom(msg.sender, KERNEL, toUint256(_assets));

        // Deposit the assets into the Royco market, the kernel prices the shares and mints them to the receiver
        shares = _deposit(false, _assets, _receiver);

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
        claims = _redeem(false, _shares, _receiver, _owner);

        emit Redeem(msg.sender, _receiver, claims, _shares);
    }

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

    // =============================
    // Kernel Mint and Burn Entrypoints
    // =============================

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
    // Tranche Preview and Conversion Functions
    // =============================

    /// @inheritdoc IRoycoVaultTranche
    /// @dev Routes the deposit through the execute-and-revert pattern so the quote is produced by the actual kernel deposit path under its real semantics
    function previewDeposit(TRANCHE_UNIT _assets) external virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        return _deposit(true, _assets, KERNEL);
    }

    /// @inheritdoc IRoycoVaultTranche
    /// @dev Routes the redemption through the execute-and-revert pattern so the quote is produced by the actual kernel redemption path under its real semantics
    function previewRedeem(uint256 _shares) external virtual override(IRoycoVaultTranche) returns (AssetClaims memory claims) {
        return _redeem(true, _shares, KERNEL, KERNEL);
    }

    /// @inheritdoc IRoycoVaultTranche
    function convertToAssets(uint256 _shares) public view virtual override(IRoycoVaultTranche) returns (AssetClaims memory claims) {
        // Get the post-sync tranche state: applying NAV reconciliation
        (SyncedAccountingState memory state, AssetClaims memory trancheClaims, uint256 trancheTotalShares) =
            IRoycoDayKernel(KERNEL).previewSyncTrancheAccountingFor(TRANCHE_TYPE());
        if (TRANCHE_TYPE() == TrancheType.LIQUIDITY_PROVIDER) {
            // We exclude any idle (not reinvested) ST shares from the LPT claims in order to ensure that its share price does not drop due to slippage incurred on reinvestment
            trancheClaims.stShares = 0;
            trancheClaims.nav = state.lptRawNAV;
        }
        return AssetLedgerLogic._scaleAssetClaims(trancheClaims, _shares, trancheTotalShares, true);
    }

    /// @inheritdoc IRoycoVaultTranche
    function convertToShares(TRANCHE_UNIT _assets) public view virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        // Value the assets specified in NAV units
        NAV_UNIT value = (TRANCHE_TYPE() == TrancheType.LIQUIDITY_PROVIDER)
            ? IRoycoDayKernel(KERNEL).convertLPTAssetsToValue(_assets)
            : IRoycoDayKernel(KERNEL).convertCollateralAssetsToValue(_assets);

        // Get the post-sync tranche state
        (SyncedAccountingState memory state, AssetClaims memory trancheClaims, uint256 trancheTotalShares) =
            IRoycoDayKernel(KERNEL).previewSyncTrancheAccountingFor(TRANCHE_TYPE());

        // We exclude any idle (not reinvested) ST shares from the LPT NAV basis in order to ensure that its NAV per share does not drop due to slippage incurred on reinvestment
        NAV_UNIT navBasis = ((TRANCHE_TYPE() == TrancheType.LIQUIDITY_PROVIDER) ? state.lptRawNAV : trancheClaims.nav);
        shares = ValuationLogic._convertToShares(value, navBasis, trancheTotalShares, Math.Rounding.Floor);
    }

    // =============================
    // Tranche Max Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoVaultTranche
    function maxDeposit(address _receiver) external view virtual override(IRoycoVaultTranche) returns (TRANCHE_UNIT assets) {
        if (TRANCHE_TYPE() == TrancheType.SENIOR) assets = IRoycoDayKernel(KERNEL).stMaxDeposit(_receiver);
        else if (TRANCHE_TYPE() == TrancheType.JUNIOR) assets = IRoycoDayKernel(KERNEL).jtMaxDeposit(_receiver);
        else assets = IRoycoDayKernel(KERNEL).lptMaxDeposit(_receiver);
    }

    /// @inheritdoc IRoycoVaultTranche
    function maxRedeem(address _owner) public view virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        // Query the tranche's total claim on the market's NAV and its global maximum withdrawable NAV
        NAV_UNIT claimNAV;
        NAV_UNIT maxWithdrawableNAV;
        uint256 totalTrancheShares;
        if (TRANCHE_TYPE() == TrancheType.SENIOR) (claimNAV, maxWithdrawableNAV, totalTrancheShares) = IRoycoDayKernel(KERNEL).stMaxWithdrawable(_owner);
        else if (TRANCHE_TYPE() == TrancheType.JUNIOR) (claimNAV, maxWithdrawableNAV, totalTrancheShares) = IRoycoDayKernel(KERNEL).jtMaxWithdrawable(_owner);
        else (claimNAV, maxWithdrawableNAV, totalTrancheShares) = IRoycoDayKernel(KERNEL).lptMaxWithdrawable(_owner);

        // We do not allow redemptions if the tranche has no claim on the assets
        if (claimNAV == ZERO_NAV_UNITS) return 0;

        // The maximum redeemable shares are the minimum of the owner's share balance and the globally redeemable
        // shares, priced through the same virtual shares primitive as deposits and _scaleAssetClaims
        shares = Math.min(balanceOf(_owner), ValuationLogic._convertToShares(maxWithdrawableNAV, claimNAV, totalTrancheShares, Math.Rounding.Floor));
    }

    // =============================
    // General Tranche View Functions
    // =============================

    /// @inheritdoc IRoycoVaultTranche
    function totalAssets() external view virtual override(IRoycoVaultTranche) returns (AssetClaims memory claims) {
        (, claims,) = IRoycoDayKernel(KERNEL).previewSyncTrancheAccountingFor(TRANCHE_TYPE());
    }

    /// @inheritdoc IRoycoVaultTranche
    function asset() external view virtual override(IRoycoVaultTranche) returns (address) {
        return ASSET;
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
    // Internal Utility Functions
    // =============================

    /**
     * @dev Deposits the assets into the Royco market through this tranche's kernel deposit entrypoint
     * @dev The kernel prices the shares at the tranche's pre-deposit effective NAV against the post-sync supply and mints them to the receiver
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _assets The amount of assets to deposit, denominated in the tranche's base asset units
     * @param _receiver The address that receives the minted shares
     * @return shares The number of shares minted for the deposit
     */
    function _deposit(bool _isPreview, TRANCHE_UNIT _assets, address _receiver) internal virtual returns (uint256 shares) {
        // Deposit the assets into the Royco market through the tranche's kernel entrypoint, which prices and mints the shares
        bytes memory callData;
        if (TRANCHE_TYPE() == TrancheType.SENIOR) callData = abi.encodeCall(IRoycoDayKernel.stDeposit, (_isPreview, _assets, _receiver));
        else if (TRANCHE_TYPE() == TrancheType.JUNIOR) callData = abi.encodeCall(IRoycoDayKernel.jtDeposit, (_isPreview, _assets, _receiver));
        else callData = abi.encodeCall(IRoycoDayKernel.lptDeposit, (_isPreview, _assets, _receiver));
        shares = abi.decode(KERNEL._dispatchAndUnwrap(_isPreview, callData), (uint256));
        require(shares != 0, MUST_MINT_NON_ZERO_SHARES());
    }

    /**
     * @dev Redeems the shares from the Royco market through this tranche's kernel redemption entrypoint
     * @dev The kernel transfers the redeemed assets directly to the receiver and burns the owner's shares after scaling their claims
     * @dev Forwards msg.sender as the caller the kernel screens with the owner and receiver against the market's blacklist
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _shares The number of shares to redeem
     * @param _receiver The address that receives the redeemed assets
     * @param _owner The address whose shares are burned for the redemption
     * @return claims The distribution of assets transferred to the receiver on redemption
     */
    function _redeem(bool _isPreview, uint256 _shares, address _receiver, address _owner) internal virtual returns (AssetClaims memory claims) {
        require(_shares != 0, MUST_REDEEM_NON_ZERO_SHARES());

        // Redeem the shares through the tranche's kernel entrypoint, the kernel transfers the redeemed assets directly to the receiver
        bytes memory callData;
        if (TRANCHE_TYPE() == TrancheType.SENIOR) callData = abi.encodeCall(IRoycoDayKernel.stRedeem, (_isPreview, _shares, msg.sender, _owner, _receiver));
        else if (TRANCHE_TYPE() == TrancheType.JUNIOR) callData = abi.encodeCall(IRoycoDayKernel.jtRedeem, (_isPreview, _shares, msg.sender, _owner, _receiver));
        else callData = abi.encodeCall(IRoycoDayKernel.lptRedeem, (_isPreview, _shares, msg.sender, _owner, _receiver));
        return abi.decode(KERNEL._dispatchAndUnwrap(_isPreview, callData), (AssetClaims));
    }

    /**
     * @inheritdoc ERC20Upgradeable
     * @dev Routes every balance update through the kernel's screening hook, which enforces the market's blacklist and
     *      whitelist policy and reverts when the kernel is paused: transfers, mints, and burns are all gated by the kernel
     */
    function _update(address _from, address _to, uint256 _value) internal override(ERC20Upgradeable) {
        // Call the kernel's pre-balance update hook to assert that the balance update is valid
        IRoycoDayKernel(KERNEL).preTrancheBalanceUpdateHook(msg.sender, _from, _to, _value);

        // Call the parent contract's update function to update the balance
        ERC20Upgradeable._update(_from, _to, _value);
    }
}
