// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { IRoycoLiquidityTranche } from "../interfaces/IRoycoLiquidityTranche.sol";
import { IRoycoVaultTranche } from "../interfaces/IRoycoVaultTranche.sol";
import { ZERO_NAV_UNITS } from "../libraries/Constants.sol";
import { AssetClaims, SyncedAccountingState, TrancheType } from "../libraries/Types.sol";
import { NAV_UNIT } from "../libraries/Units.sol";
import { RoycoVaultTranche } from "./base/RoycoVaultTranche.sol";

/**
 * @title RoycoLiquidityTranche
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Liquidity tranche (LT) share token for Royco Day markets. The LT's base asset is a market-making LP token
 *         (the senior share paired against a quote stablecoin) and the tranche earns a liquidity premium out of ST yield.
 * @dev Inherits from RoycoVaultTranche and specifies LIQUIDITY as the tranche type. In addition to the standard
 *      LP-token deposit/redeem, it exposes multi-asset entrypoints that let an LP enter/exit with the LP token's
 *      constituent assets (ST underlying + quote) directly.
 */
contract RoycoLiquidityTranche is RoycoVaultTranche, IRoycoLiquidityTranche {
    using SafeERC20 for IERC20;

    constructor(address _asset, address _kernel) RoycoVaultTranche(_asset, _kernel) { }

    /**
     * @notice Initializes the Royco liquidity tranche.
     * @param _ltParams Deployment parameters including name, symbol, and initial authority for the liquidity tranche.
     */
    function initialize(RoycoTrancheInitParams calldata _ltParams) external initializer {
        __RoycoTranche_init(_ltParams);
    }

    /// @inheritdoc RoycoVaultTranche
    function TRANCHE_TYPE() public pure virtual override(RoycoVaultTranche, IRoycoVaultTranche) returns (TrancheType) {
        return TrancheType.LIQUIDITY;
    }

    /// @inheritdoc IRoycoVaultTranche
    function burn(uint256 _shares) public override(RoycoVaultTranche, IRoycoVaultTranche) {
        super.burn(_shares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function burnFrom(address _account, uint256 _shares) public override(RoycoVaultTranche, IRoycoVaultTranche) {
        super.burnFrom(_account, _shares);
    }

    // =============================
    // Multi-Asset Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoLiquidityTranche
    function depositMultiAsset(
        uint256 _stUnderlying,
        uint256 _quoteAmount,
        uint256 _minStSharesMinted,
        address _receiver
    )
        external
        virtual
        override(IRoycoLiquidityTranche)
        whenNotPaused
        restricted
        returns (uint256 shares)
    {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));

        // Pull the constituent assets to the kernel (it custodies them for the senior mint and the liquidity add)
        address kernel = KERNEL;
        if (_stUnderlying != 0) IERC20(IRoycoDayKernel(kernel).ST_ASSET()).safeTransferFrom(msg.sender, kernel, _stUnderlying);
        if (_quoteAmount != 0) IERC20(IRoycoDayKernel(kernel).QUOTE_ASSET()).safeTransferFrom(msg.sender, kernel, _quoteAmount);

        // Orchestrate the multi-asset deposit in the kernel
        (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, uint256 trancheAssetsMinted) =
            IRoycoDayKernel(kernel).ltDepositMultiAsset(_stUnderlying, _quoteAmount, _minStSharesMinted);

        // navToMintSharesAt can be zero when the tranche is freshly deployed
        require(valueAllocated != ZERO_NAV_UNITS, INVALID_VALUE_ALLOCATED());

        // Mint the LT shares to the receiver at the pre-deposit LT raw NAV per share
        shares = _convertToShares(valueAllocated, totalSupply(), navToMintSharesAt, Math.Rounding.Floor);
        require(shares != 0, MUST_MINT_NON_ZERO_SHARES());
        _mint(_receiver, shares);

        emit MultiAssetDeposit(msg.sender, _receiver, _stUnderlying, _quoteAmount, trancheAssetsMinted, shares);
    }

    /// @inheritdoc IRoycoLiquidityTranche
    function redeemMultiAsset(
        uint256 _shares,
        uint256 _minQuoteOut,
        address _receiver,
        address _owner
    )
        external
        virtual
        override(IRoycoLiquidityTranche)
        whenNotPaused
        restricted
        returns (AssetClaims memory stClaims, uint256 quoteOut)
    {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));
        require(_shares != 0, MUST_REQUEST_NON_ZERO_SHARES());

        // Spend allowance if msg.sender is not the owner
        if (msg.sender != _owner) {
            _spendAllowance(_owner, msg.sender, _shares);
        }

        // Orchestrate the multi-asset redemption in the kernel; it transfers the assets directly to the receiver
        (stClaims, quoteOut) = IRoycoDayKernel(KERNEL).ltRedeemMultiAsset(_shares, _minQuoteOut, _receiver);

        // Burn shares after the kernel processes the redemption (kernel depends on pre-burn total supply)
        _burn(_owner, _shares);

        emit MultiAssetRedeem(msg.sender, _receiver, _owner, _shares, stClaims, quoteOut);
    }

    // =============================
    // Multi-Asset Preview Functions
    // =============================

    /// @inheritdoc IRoycoLiquidityTranche
    function previewDepositMultiAsset(
        uint256 _stUnderlying,
        uint256 _quoteAmount
    )
        external
        virtual
        override(IRoycoLiquidityTranche)
        returns (uint256 shares, uint256 trancheAssetsMinted)
    {
        NAV_UNIT valueAllocated;
        NAV_UNIT navToMintSharesAt;
        (valueAllocated, navToMintSharesAt, trancheAssetsMinted) = IRoycoDayKernel(KERNEL).previewLtDepositMultiAsset(_stUnderlying, _quoteAmount);

        // Mirror previewDeposit: account for the LT protocol fee shares that would be minted on the pre-op sync
        (SyncedAccountingState memory state,,) = IRoycoDayKernel(KERNEL).previewSyncTrancheAccounting(TrancheType.LIQUIDITY);
        (uint256 feeSharesMinted,) = previewMintProtocolFeeShares(state.ltProtocolFee, state.ltRawNAV);

        shares = _convertToShares(valueAllocated, feeSharesMinted + totalSupply(), navToMintSharesAt, Math.Rounding.Floor);
    }

    /// @inheritdoc IRoycoLiquidityTranche
    function previewRedeemMultiAsset(uint256 _shares)
        external
        virtual
        override(IRoycoLiquidityTranche)
        returns (AssetClaims memory stClaims, uint256 quoteOut)
    {
        (stClaims, quoteOut) = IRoycoDayKernel(KERNEL).previewLtRedeemMultiAsset(_shares);
    }
}
