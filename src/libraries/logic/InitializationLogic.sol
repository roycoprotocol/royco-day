// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IRoycoAuth } from "../../interfaces/IRoycoAuth.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { WAD } from "../Constants.sol";

/// @title InitializationLogic
/// @author Waymont
library InitializationLogic {
    /**
     * @notice Validates and persists the market's wiring and configuration into the kernel's state
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _params The standard initialization parameters for the Royco kernel
     */
    function initializeKernel(IRoycoDayKernel.RoycoDayKernelState storage $, IRoycoDayKernel.RoycoDayKernelInitParams memory _params) external {
        // Ensure that the tranche, asset, and accountant addresses are not null
        // The senior and junior tranches are coinvested structurally: both deposit the same collateral asset
        require(
            _params.seniorTranche != address(0) && _params.juniorTranche != address(0) && _params.liquidityProviderTranche != address(0)
                && _params.collateralAsset != address(0) && _params.lptAsset != address(0) && _params.quoteAsset != address(0)
                && _params.accountant != address(0),
            IRoycoAuth.NULL_ADDRESS()
        );
        // Ensure that the protocol fee recipient is not null (the initial authority is validated by the base initializer)
        require(_params.protocolFeeRecipient != address(0), IRoycoAuth.NULL_ADDRESS());
        // Ensure that the ST self-liquidiation bonus is less than 100% of its value
        require(_params.stSelfLiquidationBonusWAD < WAD, IRoycoDayKernel.INVALID_SELF_LIQUIDATION_BONUS());

        // Set the market's wiring: the tranche set, its assets, and the accountant
        $.seniorTranche = _params.seniorTranche;
        $.juniorTranche = _params.juniorTranche;
        $.liquidityProviderTranche = _params.liquidityProviderTranche;
        $.collateralAsset = _params.collateralAsset;
        // Ensure that the collateral asset's decimals are less than or equal to 18
        uint256 collateralAssetDecimals = IERC20Metadata(_params.collateralAsset).decimals();
        require(collateralAssetDecimals <= 18, IRoycoDayKernel.INVALID_COLLATERAL_ASSET_DECIMALS());
        $.oneWholeCollateralAsset = uint64(10 ** collateralAssetDecimals);
        $.lptAsset = _params.lptAsset;
        // Ensure that the LPT asset's decimals are less than or equal to 18
        uint256 lptAssetDecimals = IERC20Metadata(_params.lptAsset).decimals();
        require(lptAssetDecimals <= 18, IRoycoDayKernel.INVALID_LPT_ASSET_DECIMALS());
        $.oneWholeLPTAsset = uint64(10 ** lptAssetDecimals);
        $.quoteAsset = _params.quoteAsset;
        $.accountant = _params.accountant;

        // Ensure that the tranches and their corresponding assets in the kernel match: coinvestment is structural, both the senior and junior tranches deposit the one collateral asset
        require(
            IRoycoVaultTranche(_params.seniorTranche).asset() == _params.collateralAsset
                && IRoycoVaultTranche(_params.juniorTranche).asset() == _params.collateralAsset
                && IRoycoVaultTranche(_params.liquidityProviderTranche).asset() == _params.lptAsset,
            IRoycoDayKernel.TRANCHE_AND_KERNEL_ASSETS_MISMATCH()
        );

        // Set the market's configuration
        $.protocolFeeRecipient = _params.protocolFeeRecipient;
        $.stSelfLiquidationBonusWAD = _params.stSelfLiquidationBonusWAD;
        $.roycoBlacklist = _params.roycoBlacklist;
        emit IRoycoDayKernel.ProtocolFeeRecipientUpdated(_params.protocolFeeRecipient);
        emit IRoycoDayKernel.SeniorTrancheSelfLiquidationBonusUpdated(_params.stSelfLiquidationBonusWAD);
        emit IRoycoDayKernel.RoycoBlacklistUpdated(_params.roycoBlacklist);
    }
}
