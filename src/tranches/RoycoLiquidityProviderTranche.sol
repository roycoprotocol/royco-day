// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { IRoycoLiquidityProviderTranche } from "../interfaces/IRoycoLiquidityProviderTranche.sol";
import { IRoycoVaultTranche } from "../interfaces/IRoycoVaultTranche.sol";
import { AssetClaims, DispatchMode, TrancheType } from "../libraries/Types.sol";
import { Math, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../libraries/Units.sol";
import { DispatchLogic } from "../libraries/logic/DispatchLogic.sol";
import { RoycoVaultTranche } from "./base/RoycoVaultTranche.sol";

/**
 * @title RoycoLiquidityProviderTranche
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Liquidity provider tranche implementation for Royco markets
 * @dev In addition to the standard LPT asset deposit/redeem flows, it exposes multi-asset entrypoints that let an LP enter/exit with collateral and quote assets directly (the collateral leg mints/redeems senior shares)
 */
contract RoycoLiquidityProviderTranche is RoycoVaultTranche, IRoycoLiquidityProviderTranche {
    using SafeERC20 for IERC20;
    using DispatchLogic for address;

    /**
     * @notice Constructs the Royco liquidity provider tranche vault
     * @param _asset The underlying asset for the tranche
     * @param _kernel The kernel that handles the core market logic and accounting synchronization
     */
    constructor(address _asset, address _kernel) RoycoVaultTranche(_asset, _kernel) { }

    /// @notice Initializes the Royco liquidity provider tranche
    /// @param _lptParams Deployment parameters including name, symbol, and initial authority for the liquidity provider tranche
    function initialize(RoycoTrancheInitParams calldata _lptParams) external initializer {
        __RoycoTranche_init(_lptParams);
    }

    /// @inheritdoc RoycoVaultTranche
    function TRANCHE_TYPE() public pure virtual override(RoycoVaultTranche, IRoycoVaultTranche) returns (TrancheType) {
        return TrancheType.LIQUIDITY_PROVIDER;
    }

    // =============================
    // Multi-Asset Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoLiquidityProviderTranche
    function depositMultiAsset(
        uint256 _collateralAssets,
        uint256 _quoteAssets,
        uint256 _minLPTAssetsOut,
        address _receiver
    )
        external
        virtual
        override(IRoycoLiquidityProviderTranche)
        restricted
        returns (uint256 shares, uint256 lptAssetsOut)
    {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));

        // Pull the constituent assets to the kernel (it executes them for the senior mint and the liquidity add)
        address kernel = KERNEL;
        if (_collateralAssets != 0) IERC20(IRoycoDayKernel(kernel).COLLATERAL_ASSET()).safeTransferFrom(msg.sender, kernel, _collateralAssets);
        if (_quoteAssets != 0) IERC20(IRoycoDayKernel(kernel).QUOTE_ASSET()).safeTransferFrom(msg.sender, kernel, _quoteAssets);

        // Deposit the constituent assets into the Royco market, the kernel prices the shares and mints them to the receiver
        TRANCHE_UNIT lptAssetsMinted;
        (shares, lptAssetsMinted) = _depositMultiAsset(DispatchMode.EXECUTE, _collateralAssets, _quoteAssets, _minLPTAssetsOut, _receiver);
        lptAssetsOut = toUint256(lptAssetsMinted);

        emit MultiAssetDeposit(msg.sender, _receiver, _collateralAssets, _quoteAssets, lptAssetsOut, shares);
    }

    /// @inheritdoc IRoycoLiquidityProviderTranche
    function redeemMultiAsset(
        uint256 _shares,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _receiver,
        address _owner
    )
        external
        virtual
        override(IRoycoLiquidityProviderTranche)
        restricted
        returns (AssetClaims memory stClaims, uint256 quoteAssets)
    {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));

        // Spend allowance if msg.sender is not the owner
        if (msg.sender != _owner) _spendAllowance(_owner, msg.sender, _shares);

        // Redeem the shares through the tranche's kernel entrypoint, the kernel burns the owner's shares after scaling their claims
        (stClaims, quoteAssets) = _redeemMultiAsset(DispatchMode.EXECUTE, _shares, _minSTSharesOut, _minQuoteAssetsOut, _receiver, _owner);

        emit MultiAssetRedeem(msg.sender, _receiver, _owner, _shares, stClaims, quoteAssets);
    }

    // =============================
    // Multi-Asset Preview Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoLiquidityProviderTranche
    /// @dev Routes the deposit through the execute-and-revert pattern so the quote is produced by the actual kernel multi-asset deposit path under its real semantics
    function previewDepositMultiAsset(
        uint256 _collateralAssets,
        uint256 _quoteAssets
    )
        external
        virtual
        override(IRoycoLiquidityProviderTranche)
        returns (uint256 shares, uint256 lptAssetsOut)
    {
        TRANCHE_UNIT lptAssetsMinted;
        (shares, lptAssetsMinted) = _depositMultiAsset(DispatchMode.SIMULATE, _collateralAssets, _quoteAssets, 0, KERNEL);
        lptAssetsOut = toUint256(lptAssetsMinted);
    }

    /// @inheritdoc IRoycoLiquidityProviderTranche
    /// @dev Routes the redemption through the execute-and-revert pattern so the quote is produced by the actual kernel multi-asset redemption path under its real semantics
    function previewRedeemMultiAsset(uint256 _shares)
        external
        virtual
        override(IRoycoLiquidityProviderTranche)
        returns (AssetClaims memory stClaims, uint256 quoteAssets)
    {
        (stClaims, quoteAssets) = _redeemMultiAsset(DispatchMode.SIMULATE, _shares, 0, 0, KERNEL, address(0));
    }

    // =============================
    // Multi-Asset Max Redeem Function
    // =============================

    /// @inheritdoc IRoycoLiquidityProviderTranche
    function maxRedeemMultiAsset(address _owner) external virtual override(IRoycoLiquidityProviderTranche) returns (uint256 shares) {
        // The maximum redeemable shares are the minimum of the owner's share balance and the globally redeemable shares the kernel prices
        return Math.min(balanceOf(_owner), IRoycoDayKernel(KERNEL).lptMaxRedeemableMultiAsset(_owner));
    }

    // =============================
    // Internal Utility Function
    // =============================

    /**
     * @dev Deposits the constituent assets into the Royco market through the kernel's multi-asset deposit entrypoint
     * @dev The kernel prices the shares at the pre-deposit LPT effective NAV against the venue's settled post-add state and mints them to the receiver
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _collateralAssets The amount of collateral to deposit, in the collateral asset's native units
     * @param _quoteAssets The amount of quote asset to add as the second venue leg
     * @param _minLPTAssetsOut The minimum LPT tranche assets the liquidity add must mint
     * @param _receiver The address that receives the minted shares
     * @return shares The number of shares minted for the deposit
     * @return lptAssetsOut The LPT tranche assets minted by the add
     */
    function _depositMultiAsset(
        DispatchMode _mode,
        uint256 _collateralAssets,
        uint256 _quoteAssets,
        uint256 _minLPTAssetsOut,
        address _receiver
    )
        internal
        virtual
        returns (uint256 shares, TRANCHE_UNIT lptAssetsOut)
    {
        // Orchestrate the multi-asset deposit in the kernel, bounding the liquidity add's slippage by the caller's minimum LPT assets out
        return abi.decode(
            KERNEL._dispatchAndUnwrap(
                _mode,
                abi.encodeCall(
                    IRoycoDayKernel.lptDepositMultiAsset,
                    (_mode, toTrancheUnits(_collateralAssets), _quoteAssets, toTrancheUnits(_minLPTAssetsOut), _resolveCaller(_mode), _receiver)
                )
            ),
            (uint256, TRANCHE_UNIT)
        );
    }

    /**
     * @dev Redeems the shares through the kernel's multi-asset redemption entrypoint, the kernel transfers the constituents directly to the receiver
     *      and burns the owner's shares after scaling their claims
     * @dev Forwards msg.sender as the caller for an execution, a simulation carries the null synthetic caller so previews never vary by caller
     * @param _mode The dispatch mode: SIMULATE computes the operation and unwinds every mutation by reverting with its result, EXECUTE settles it
     * @param _shares The number of LPT shares to redeem
     * @param _minSTSharesOut The minimum senior tranche shares the proportional removal must yield (slippage bound)
     * @param _minQuoteAssetsOut The minimum quote to receive (slippage bound)
     * @param _receiver The address that receives the collateral and quote
     * @param _owner The address whose LPT shares are burned for the redemption
     * @return stClaims The ST redemption asset claims transferred to the receiver
     * @return quoteAssets The quote transferred to the receiver
     */
    function _redeemMultiAsset(
        DispatchMode _mode,
        uint256 _shares,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _receiver,
        address _owner
    )
        internal
        virtual
        returns (AssetClaims memory stClaims, uint256 quoteAssets)
    {
        // Orchestrate the multi-asset redemption in the kernel, bounding the removal's slippage by the caller's minimum senior shares and quote out
        // The kernel rejects a zero-share redemption at its LPT redemption leg
        return abi.decode(
            KERNEL._dispatchAndUnwrap(
                _mode,
                abi.encodeCall(
                    IRoycoDayKernel.lptRedeemMultiAsset, (_mode, _shares, _minSTSharesOut, _minQuoteAssetsOut, _resolveCaller(_mode), _owner, _receiver)
                )
            ),
            (AssetClaims, uint256)
        );
    }
}
