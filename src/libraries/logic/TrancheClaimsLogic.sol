// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { VIRTUAL_SHARES, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../Constants.sol";
import { AssetClaims, SyncedAccountingState, TrancheType } from "../Types.sol";
import { Math, NAV_UNIT, RoycoUnitsMath, TRANCHE_UNIT, toUint256 } from "../Units.sol";
import { ValuationLogic } from "./ValuationLogic.sol";

/**
 * @title TrancheClaimsLogic
 * @author Waymont
 * @notice Tranche asset-claim math for a Royco market: claim derivation, proportional scaling, and withdrawal
 */
library TrancheClaimsLogic {
    using SafeERC20 for IERC20;
    using RoycoUnitsMath for NAV_UNIT;
    using RoycoUnitsMath for TRANCHE_UNIT;
    using RoycoUnitsMath for uint256;
    using Math for uint256;

    /**
     * @notice Derives the cumulative asset claims that the specified tranche is entitled to
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _trancheType An enumerator indicating which tranche to return cumulative claims for
     * @param _state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     * @return claims The cumulative asset claims that the specified tranche is entitled to
     */
    function _deriveTrancheAssetClaims(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        TrancheType _trancheType,
        SyncedAccountingState memory _state
    )
        internal
        view
        returns (AssetClaims memory claims)
    {
        if (_trancheType == TrancheType.SENIOR || _trancheType == TrancheType.JUNIOR) {
            // A tranche's claim is its effective NAV, granted in the coinvested collateral asset
            claims.nav = _trancheType == TrancheType.SENIOR ? _state.stEffectiveNAV : _state.jtEffectiveNAV;
            if (claims.nav != ZERO_NAV_UNITS) claims.collateralAssets = IRoycoDayKernel(address(this)).convertValueToCollateralAssets(claims.nav);
        } else {
            if (_state.lptRawNAV != ZERO_NAV_UNITS) claims.lptAssets = IRoycoDayKernel(address(this)).convertValueToLPTAssets(_state.lptRawNAV);
            claims.stShares = $.lptOwnedSeniorTrancheShares;
            claims.nav = ValuationLogic._getLiquidityProviderTrancheEffectiveNAV(
                $, _state.stEffectiveNAV, IRoycoVaultTranche(_immutables.seniorTranche).totalSupply(), claims.stShares
            );
        }
    }

    /**
     * @notice Withdraws any specified assets from each tranche and transfer them to the receiver
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _claims The collateral assets, LPT assets, and ST shares to withdraw and transfer to the specified receiver
     * @param _receiver The receiver of the tranche asset claims
     */
    function _withdrawAssets(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables,
        AssetClaims memory _claims,
        address _receiver
    )
        internal
    {
        // Cache the individual claims
        TRANCHE_UNIT collateralAssetsToClaim = _claims.collateralAssets;
        TRANCHE_UNIT lptAssetsToClaim = _claims.lptAssets;
        uint256 stSharesToClaim = _claims.stShares;

        // Debit the collateral assets, LPT assets, and/or ST shares being withdrawn if non-zero
        if (collateralAssetsToClaim != ZERO_TRANCHE_UNITS) $.totalCollateralAssets = $.totalCollateralAssets - collateralAssetsToClaim;
        if (lptAssetsToClaim != ZERO_TRANCHE_UNITS) $.totalLPTAssets = $.totalLPTAssets - lptAssetsToClaim;
        if (stSharesToClaim != 0) $.lptOwnedSeniorTrancheShares -= stSharesToClaim;

        // No need to execute a transfer if the caller is the receiver
        if (_receiver != address(this)) {
            // Credit the collateral assets being withdrawn to the receiver
            if (collateralAssetsToClaim != ZERO_TRANCHE_UNITS) IERC20(_immutables.collateralAsset).safeTransfer(_receiver, toUint256(collateralAssetsToClaim));
            // Credit the LPT assets being withdrawn to the receiver
            if (lptAssetsToClaim != ZERO_TRANCHE_UNITS) IERC20(_immutables.lptAsset).safeTransfer(_receiver, toUint256(lptAssetsToClaim));
            // Credit the senior tranche shares being withdrawn to the receiver
            if (stSharesToClaim != 0) IERC20(_immutables.seniorTranche).safeTransfer(_receiver, stSharesToClaim);
        }
    }

    /**
     * @notice Scales a tranche's asset claims (collateral assets, LPT assets, ST shares, and NAV) by a given shares assuming total shares in a vault
     * @param _claims The asset claims of the tranche
     * @param _shares The number of shares to scale the claims by
     * @param _totalTrancheShares The total number of shares that exist in the tranche
     * @param _includeVirtualShares Whether to use virtual shares for the scaling
     * @return scaledClaims The scaled asset claims of the tranche
     */
    function _scaleAssetClaims(
        AssetClaims memory _claims,
        uint256 _shares,
        uint256 _totalTrancheShares,
        bool _includeVirtualShares
    )
        internal
        pure
        returns (AssetClaims memory scaledClaims)
    {
        // If the total tranche shares is zero, it has no claims on the assets, so return zero claims
        if (_totalTrancheShares == 0) return scaledClaims;

        // Scale the claims by the redeemer's fraction of the EFFECTIVE supply
        uint256 effectiveTrancheShares = _totalTrancheShares + (_includeVirtualShares ? VIRTUAL_SHARES : 0);
        scaledClaims.nav = _claims.nav.mulDiv(_shares, effectiveTrancheShares, Math.Rounding.Floor);
        scaledClaims.collateralAssets = _claims.collateralAssets.mulDiv(_shares, effectiveTrancheShares, Math.Rounding.Floor);
        scaledClaims.lptAssets = _claims.lptAssets.mulDiv(_shares, effectiveTrancheShares, Math.Rounding.Floor);
        scaledClaims.stShares = _claims.stShares.mulDiv(_shares, effectiveTrancheShares, Math.Rounding.Floor);
    }
}
