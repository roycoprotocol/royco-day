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
import { DispatchLogic } from "../libraries/logic/DispatchLogic.sol";
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
    using DispatchLogic for address;

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
        restricted
        returns (uint256 shares, uint256 ltAssetsOut)
    {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));

        // Pull the constituent assets to the kernel (it executes them for the senior mint and the liquidity add)
        address kernel = KERNEL;
        if (_stAssets != 0) IERC20(IRoycoDayKernel(kernel).ST_ASSET()).safeTransferFrom(msg.sender, kernel, _stAssets);
        if (_quoteAssets != 0) IERC20(IRoycoDayKernel(kernel).QUOTE_ASSET()).safeTransferFrom(msg.sender, kernel, _quoteAssets);

        // Deposit the constituent assets into the Royco market and price the shares to mint
        TRANCHE_UNIT ltAssetsMinted;
        (shares, ltAssetsMinted) = _depositMultiAsset(false, _stAssets, _quoteAssets, _minLTAssetsOut);
        ltAssetsOut = toUint256(ltAssetsMinted);

        // Mint the shares to the receiver
        _mint(_receiver, shares);

        emit MultiAssetDeposit(msg.sender, _receiver, _stAssets, _quoteAssets, ltAssetsOut, shares);
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
        restricted
        returns (AssetClaims memory stClaims, uint256 quoteAssets)
    {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));
        require(_shares != 0, MUST_REQUEST_NON_ZERO_SHARES());

        // Spend allowance if msg.sender is not the owner
        if (msg.sender != _owner) {
            _spendAllowance(_owner, msg.sender, _shares);
        }

        (stClaims, quoteAssets) = _redeemMultiAsset(false, _shares, _minSTSharesOut, _minQuoteAssetsOut, _receiver);

        // Burn shares after the kernel processes the redemption (kernel depends on pre-burn total supply)
        _burn(_owner, _shares);

        emit MultiAssetRedeem(msg.sender, _receiver, _owner, _shares, stClaims, quoteAssets);
    }

    // =============================
    // Multi-Asset Preview Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoLiquidityTranche
    /// @dev Routes the deposit through the execute-and-revert pattern so the quote is produced by the actual kernel multi-asset deposit path under its real semantics
    function previewDepositMultiAsset(
        uint256 _stAssets,
        uint256 _quoteAssets
    )
        external
        virtual
        override(IRoycoLiquidityTranche)
        returns (uint256 shares, uint256 ltAssetsOut)
    {
        TRANCHE_UNIT ltAssetsMinted;
        (shares, ltAssetsMinted) = _depositMultiAsset(true, _stAssets, _quoteAssets, 0);
        ltAssetsOut = toUint256(ltAssetsMinted);
    }

    /// @inheritdoc IRoycoLiquidityTranche
    /// @dev Routes the redemption through the execute-and-revert pattern so the quote is produced by the actual kernel multi-asset redemption path under its real semantics
    function previewRedeemMultiAsset(uint256 _shares)
        external
        virtual
        override(IRoycoLiquidityTranche)
        returns (AssetClaims memory stClaims, uint256 quoteAssets)
    {
        // The kernel stands in as receiver so the quote stays receiver-agnostic, its screening gates preview and execution alike
        (stClaims, quoteAssets) = _redeemMultiAsset(true, _shares, 0, 0, KERNEL);
    }

    // =============================
    // Multi-Asset Max Redeem Function
    // =============================

    /// @inheritdoc IRoycoLiquidityTranche
    function maxRedeemMultiAsset(address _owner) external virtual override(IRoycoLiquidityTranche) returns (uint256 shares) {
        // The liquidity tranche has claims only on its own RAW NAV, bounded here by the multi-asset liquidity requirement
        (NAV_UNIT claimOnLTNAV, NAV_UNIT ltMaxWithdrawableNAV, uint256 totalTrancheSharesAfterMintingFees) =
            IRoycoDayKernel(KERNEL).ltMaxWithdrawableMultiAsset(_owner);

        // We do not allow redemptions if the tranche has no claim on the assets
        if (claimOnLTNAV == ZERO_NAV_UNITS) return 0;

        shares = Math.min(balanceOf(_owner), totalTrancheSharesAfterMintingFees.mulDiv(ltMaxWithdrawableNAV, claimOnLTNAV, Math.Rounding.Floor));
    }

    // =============================
    // Internal Utility Function
    // =============================

    /**
     * @dev Deposits the constituent assets into the Royco market through the kernel's multi-asset deposit entrypoint and prices the shares to mint
     * @dev Shares are priced at the pre-deposit LT effective NAV per share (the sync mints no LT shares, so the pre-mint supply is current)
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _stAssets The amount of ST underlying to deposit, in the ST asset's native units
     * @param _quoteAssets The amount of quote asset to add as the second venue leg
     * @param _minLTAssetsOut The minimum LT tranche assets the liquidity add must mint
     * @return shares The number of shares to mint for the deposit
     * @return ltAssetsOut The LT tranche assets minted by the add
     */
    function _depositMultiAsset(
        bool _isPreview,
        uint256 _stAssets,
        uint256 _quoteAssets,
        uint256 _minLTAssetsOut
    )
        internal
        virtual
        returns (uint256 shares, TRANCHE_UNIT ltAssetsOut)
    {
        // Orchestrate the multi-asset deposit in the kernel, bounding the liquidity add's slippage by the caller's minimum LT assets out
        NAV_UNIT depositNAV;
        NAV_UNIT effectiveNAV;
        (depositNAV, effectiveNAV, ltAssetsOut) = abi.decode(
            KERNEL._dispatchAndUnwrap(
                _isPreview,
                abi.encodeCall(IRoycoDayKernel.ltDepositMultiAsset, (_isPreview, toTrancheUnits(_stAssets), _quoteAssets, toTrancheUnits(_minLTAssetsOut)))
            ),
            (NAV_UNIT, NAV_UNIT, TRANCHE_UNIT)
        );

        // effectiveNAV can be zero when the tranche is freshly deployed
        require(depositNAV != ZERO_NAV_UNITS, INVALID_DEPOSIT_NAV());

        // Price the LT shares at the pre-deposit LT effective NAV per share
        shares = ValuationLogic._convertToShares(depositNAV, effectiveNAV, totalSupply(), Math.Rounding.Floor);
        require(shares != 0, MUST_MINT_NON_ZERO_SHARES());
    }

    /**
     * @dev Redeems the shares through the kernel's multi-asset redemption entrypoint, the kernel transfers the constituents directly to the receiver
     * @param _isPreview Whether this is a preview of the operation which must not mutate state
     * @param _shares The number of LT shares to redeem
     * @param _minSTSharesOut The minimum senior tranche shares the proportional removal must yield (slippage bound)
     * @param _minQuoteAssetsOut The minimum quote to receive (slippage bound)
     * @param _receiver The address that receives the ST underlying and quote
     * @return stClaims The ST redemption asset claims transferred to the receiver
     * @return quoteAssets The quote transferred to the receiver
     */
    function _redeemMultiAsset(
        bool _isPreview,
        uint256 _shares,
        uint256 _minSTSharesOut,
        uint256 _minQuoteAssetsOut,
        address _receiver
    )
        internal
        virtual
        returns (AssetClaims memory stClaims, uint256 quoteAssets)
    {
        // Orchestrate the multi-asset redemption in the kernel, bounding the removal's slippage by the caller's minimum senior shares and quote out
        return abi.decode(
            KERNEL._dispatchAndUnwrap(
                _isPreview, abi.encodeCall(IRoycoDayKernel.ltRedeemMultiAsset, (_isPreview, _shares, _minSTSharesOut, _minQuoteAssetsOut, _receiver))
            ),
            (AssetClaims, uint256)
        );
    }
}
