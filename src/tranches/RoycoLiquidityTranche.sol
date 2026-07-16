// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRoycoDayKernel } from "../interfaces/IRoycoDayKernel.sol";
import { IRoycoLiquidityTranche } from "../interfaces/IRoycoLiquidityTranche.sol";
import { IRoycoVaultTranche } from "../interfaces/IRoycoVaultTranche.sol";
import { ZERO_NAV_UNITS } from "../libraries/Constants.sol";
import { AssetClaims, TrancheType } from "../libraries/Types.sol";
import { Math, NAV_UNIT, RoycoUnitsMath, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../libraries/Units.sol";
import { ValuationLogic } from "../libraries/logic/ValuationLogic.sol";
import { RoycoVaultTranche } from "./base/RoycoVaultTranche.sol";

/**
 * @title RoycoLiquidityTranche
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Liquidity tranche implementation for Royco markets
 * @dev In addition to the standard LT asset deposit/redeem flows, it exposes multi-asset entrypoints that let an LP enter/exit with ST and quote assets directly (ST assets are involved in minting/redeeming ST shares)
 */
contract RoycoLiquidityTranche is RoycoVaultTranche, IRoycoLiquidityTranche {
    using SafeERC20 for IERC20;
    using RoycoUnitsMath for uint256;

    /**
     * @notice Constructs the Royco liquidity tranche vault
     * @param _asset The underlying asset for the tranche
     * @param _kernel The kernel that handles the core market logic and accounting synchronization
     */
    constructor(address _asset, address _kernel) RoycoVaultTranche(_asset, _kernel) { }

    /// @notice Initializes the Royco liquidity tranche
    /// @param _ltParams Deployment parameters including name, symbol, and initial authority for the liquidity tranche
    function initialize(RoycoTrancheInitParams calldata _ltParams) external initializer {
        __RoycoTranche_init(_ltParams);
    }

    /// @inheritdoc RoycoVaultTranche
    function TRANCHE_TYPE() public pure virtual override(RoycoVaultTranche, IRoycoVaultTranche) returns (TrancheType) {
        return TrancheType.LIQUIDITY;
    }

    // =============================
    // Multi-Asset Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoLiquidityTranche
    function depositMultiAsset(
        uint256 _stAssets,
        uint256 _quoteAssets,
        uint256 _minLTAssetsOut,
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

        // Pull the constituent assets to the kernel (it executes them for the senior mint and the liquidity add)
        address kernel = KERNEL;
        if (_stAssets != 0) IERC20(IRoycoDayKernel(kernel).ST_ASSET()).safeTransferFrom(msg.sender, kernel, _stAssets);
        if (_quoteAssets != 0) IERC20(IRoycoDayKernel(kernel).QUOTE_ASSET()).safeTransferFrom(msg.sender, kernel, _quoteAssets);

        // Orchestrate the multi-asset deposit in the kernel, bounding the liquidity add's slippage by the caller's minimum LT assets out
        (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, TRANCHE_UNIT ltAssetsOut) =
            IRoycoDayKernel(kernel).ltDepositMultiAsset(toTrancheUnits(_stAssets), _quoteAssets, toTrancheUnits(_minLTAssetsOut));

        // navToMintSharesAt can be zero when the tranche is freshly deployed
        require(valueAllocated != ZERO_NAV_UNITS, INVALID_VALUE_ALLOCATED());

        // Mint the LT shares to the receiver at the pre-deposit LT effective NAV per share
        shares = ValuationLogic._convertToShares(valueAllocated, navToMintSharesAt, totalSupply(), Math.Rounding.Floor);
        require(shares != 0, MUST_MINT_NON_ZERO_SHARES());
        _mint(_receiver, shares);

        emit MultiAssetDeposit(msg.sender, _receiver, _stAssets, _quoteAssets, toUint256(ltAssetsOut), shares);
    }

    /// @inheritdoc IRoycoLiquidityTranche
    function redeemMultiAsset(
        uint256 _shares,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _receiver,
        address _owner
    )
        external
        virtual
        override(IRoycoLiquidityTranche)
        whenNotPaused
        restricted
        returns (AssetClaims memory stClaims, uint256 quoteAssets)
    {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));
        require(_shares != 0, MUST_REQUEST_NON_ZERO_SHARES());

        // Spend allowance if msg.sender is not the owner
        if (msg.sender != _owner) {
            _spendAllowance(_owner, msg.sender, _shares);
        }

        // Orchestrate the multi-asset redemption in the kernel, bounding the removal's slippage by the caller's minimum senior shares and quote out, it transfers the assets directly to the receiver
        (stClaims, quoteAssets) = IRoycoDayKernel(KERNEL).ltRedeemMultiAsset(_shares, _minSTSharesOut, _minQuoteAssetsOut, _receiver);

        // Burn shares after the kernel processes the redemption (kernel depends on pre-burn total supply)
        _burn(_owner, _shares);

        emit MultiAssetRedeem(msg.sender, _receiver, _owner, _shares, stClaims, quoteAssets);
    }

    // =============================
    // Multi-Asset Preview Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoLiquidityTranche
    function previewDepositMultiAsset(uint256 _stAssets, uint256 _quoteAssets) external virtual override(IRoycoLiquidityTranche) returns (uint256 shares) {
        // Simulate the kernel's multi-asset deposit for the value allocated, the pre-deposit LT effective NAV per share, and the LT supply the pre-op sync will have minted
        (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt,, uint256 ltTotalSupplyAfterMints) =
            IRoycoDayKernel(KERNEL).ltPreviewDepositMultiAsset(toTrancheUnits(_stAssets), _quoteAssets);
        // Mint LT shares at the pre-deposit LT effective NAV per share against that post-sync supply, identical to depositMultiAsset's share math
        shares = ValuationLogic._convertToShares(valueAllocated, navToMintSharesAt, ltTotalSupplyAfterMints, Math.Rounding.Floor);
    }

    /// @inheritdoc IRoycoLiquidityTranche
    function previewRedeemMultiAsset(uint256 _shares)
        external
        virtual
        override(IRoycoLiquidityTranche)
        returns (AssetClaims memory stClaims, uint256 quoteAssets)
    {
        // Simulate the kernel's multi-asset redemption for the ST claims and quote assets the receiver would get, identical to redeemMultiAsset's outputs
        (stClaims, quoteAssets) = IRoycoDayKernel(KERNEL).ltPreviewRedeemMultiAsset(_shares);
    }

    // =============================
    // Multi-Asset Max Redeem Function
    // =============================

    /// @inheritdoc IRoycoLiquidityTranche
    function maxRedeemMultiAsset(address _owner) external virtual override(IRoycoLiquidityTranche) returns (uint256 shares) {
        uint256 sharesOwned = balanceOf(_owner);

        // The liquidity tranche has claims only on its own RAW NAV
        (NAV_UNIT claimOnLTNAV, NAV_UNIT ltMaxWithdrawableNAV, uint256 totalTrancheSharesAfterMintingFees) =
            IRoycoDayKernel(KERNEL).ltMaxWithdrawableMultiAsset(_owner);

        // We do not allow redemptions if the tranche has no claims on the assets
        if (claimOnLTNAV == ZERO_NAV_UNITS) return 0;

        shares = Math.min(sharesOwned, totalTrancheSharesAfterMintingFees.mulDiv(ltMaxWithdrawableNAV, claimOnLTNAV, Math.Rounding.Floor));
    }
}
