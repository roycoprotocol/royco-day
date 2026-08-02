// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { VIRTUAL_SHARES, VIRTUAL_VALUE, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../Constants.sol";
import { AssetClaims, SyncedAccountingState, TrancheType } from "../Types.sol";
import { Math, NAV_UNIT, RoycoUnitsMath, TRANCHE_UNIT, toUint256 } from "../Units.sol";
import { ValuationLogic } from "./ValuationLogic.sol";

/**
 * @title AssetLedgerLogic
 * @author Waymont
 * @notice Tranche asset-ledger accounting for a Royco market: claim derivation, proportional scaling, ledger credits and debits, and remittance
 */
library AssetLedgerLogic {
    using SafeERC20 for IERC20;
    using RoycoUnitsMath for NAV_UNIT;
    using RoycoUnitsMath for TRANCHE_UNIT;
    using RoycoUnitsMath for uint256;
    using Math for uint256;

    /**
     * @notice Resolves the specified tranche's contract address from the kernel's state
     * @param $ The storage state of the Royco Kernel that is delegatecalling into this function
     * @param _trancheType An enumerator indicating which tranche's address to resolve
     * @return The specified tranche's contract address
     */
    function _getTrancheAddress(IRoycoDayKernel.RoycoDayKernelState storage $, TrancheType _trancheType) internal view returns (address) {
        if (_trancheType == TrancheType.SENIOR) return $.seniorTranche;
        else if (_trancheType == TrancheType.JUNIOR) return $.juniorTranche;
        else return $.liquidityProviderTranche;
    }

    /**
     * @notice Derives the cumulative asset claims that the specified tranche is entitled to
     * @param $ The storage state of the Royco Kernel that is delegatecalling into this function
     * @param _trancheType An enumerator indicating which tranche to return cumulative claims for
     * @param _state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     * @return claims The cumulative asset claims that the specified tranche is entitled to
     */
    function _deriveTrancheAssetClaims(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        TrancheType _trancheType,
        SyncedAccountingState memory _state
    )
        internal
        view
        returns (AssetClaims memory claims)
    {
        if (_trancheType == TrancheType.LIQUIDITY_PROVIDER) {
            if (_state.lptRawNAV != ZERO_NAV_UNITS) claims.lptAssets = IRoycoDayKernel(address(this)).convertValueToLPTAssets(_state.lptRawNAV);
            claims.stShares = $.lptOwnedSeniorTrancheShares;
            claims.nav = ValuationLogic._getLiquidityProviderTrancheEffectiveNAV(
                $, _state.stEffectiveNAV, IRoycoVaultTranche($.seniorTranche).totalSupply(), claims.stShares
            );
        } else {
            // A tranche's claim is its effective NAV, granted in the coinvested collateral asset
            claims.nav = (_trancheType == TrancheType.SENIOR ? _state.stEffectiveNAV : _state.jtEffectiveNAV);
            if (claims.nav != ZERO_NAV_UNITS) claims.collateralAssets = IRoycoDayKernel(address(this)).convertValueToCollateralAssets(claims.nav);
        }
    }

    /**
     * @notice Credits deposited assets to the specified tranche's ledger
     * @param $ The storage state of the Royco Kernel that is delegatecalling into this function
     * @param _trancheType An enumerator indicating which tranche's ledger to credit
     * @param _assets The amount of assets to credit, denominated in the tranche's tranche units
     */
    function _creditAssets(IRoycoDayKernel.RoycoDayKernelState storage $, TrancheType _trancheType, TRANCHE_UNIT _assets) internal {
        // The senior and junior tranches share the coinvested collateral ledger, the liquidity provider tranche holds the LPT asset ledger
        if (_trancheType == TrancheType.LIQUIDITY_PROVIDER) $.totalLPTAssets = $.totalLPTAssets + _assets;
        else $.totalCollateralAssets = $.totalCollateralAssets + _assets;
    }

    /**
     * @notice Debits the specified asset claims from the kernel's tranche ledgers
     * @param $ The storage state of the Royco Kernel that is delegatecalling into this function
     * @param _claims The collateral assets, LPT assets, and ST shares to debit from the ledgers
     */
    function _debitAssets(IRoycoDayKernel.RoycoDayKernelState storage $, AssetClaims memory _claims) internal {
        // Debit the collateral assets, LPT assets, and/or ST shares being withdrawn if non-zero
        if (_claims.collateralAssets != ZERO_TRANCHE_UNITS) $.totalCollateralAssets = $.totalCollateralAssets - _claims.collateralAssets;
        if (_claims.lptAssets != ZERO_TRANCHE_UNITS) $.totalLPTAssets = $.totalLPTAssets - _claims.lptAssets;
        if (_claims.stShares != 0) $.lptOwnedSeniorTrancheShares -= _claims.stShares;
    }

    /**
     * @notice Remits the specified asset claims to the receiver via direct transfers
     * @dev Holds no accounting effects, callers debit the claims from their ledgers first so the transfers can run last (CEI)
     * @param $ The storage state of the Royco Kernel that is delegatecalling into this function
     * @param _claims The collateral assets, LPT assets, and ST shares to transfer to the specified receiver
     * @param _receiver The receiver of the asset claims
     */
    function _remitClaims(IRoycoDayKernel.RoycoDayKernelState storage $, AssetClaims memory _claims, address _receiver) internal {
        // Preemptively return if this is a self-remittance
        if (_receiver == address(this)) return;
        // Transfer the collateral assets being remitted to the receiver
        if (_claims.collateralAssets != ZERO_TRANCHE_UNITS) IERC20($.collateralAsset).safeTransfer(_receiver, toUint256(_claims.collateralAssets));
        // Transfer the LPT assets being remitted to the receiver
        if (_claims.lptAssets != ZERO_TRANCHE_UNITS) IERC20($.lptAsset).safeTransfer(_receiver, toUint256(_claims.lptAssets));
        // Transfer the senior tranche shares being remitted to the receiver
        if (_claims.stShares != 0) IERC20($.seniorTranche).safeTransfer(_receiver, _claims.stShares);
    }

    /**
     * @notice Remits the specified asset claims to the receiver via direct transfers, resolving the claim assets from the kernel's immutable-state carrier
     * @dev The periphery variant of `_remitClaims`: a contract outside the kernel holds no kernel storage pointer, so it remits from the carrier `getImmutableState` returns
     * @param _immutables The kernel's immutable-state carrier resolving the claim assets
     * @param _claims The collateral assets, LPT assets, and ST shares to transfer to the specified receiver
     * @param _receiver The receiver of the asset claims
     */
    function _remitClaims(IRoycoDayKernel.RoycoDayKernelImmutableState memory _immutables, AssetClaims memory _claims, address _receiver) internal {
        // Preemptively return if this is a self-remittance
        if (_receiver == address(this)) return;
        // Transfer the collateral assets being remitted to the receiver
        if (_claims.collateralAssets != ZERO_TRANCHE_UNITS) IERC20(_immutables.collateralAsset).safeTransfer(_receiver, toUint256(_claims.collateralAssets));
        // Transfer the LPT assets being remitted to the receiver
        if (_claims.lptAssets != ZERO_TRANCHE_UNITS) IERC20(_immutables.lptAsset).safeTransfer(_receiver, toUint256(_claims.lptAssets));
        // Transfer the senior tranche shares being remitted to the receiver
        if (_claims.stShares != 0) IERC20(_immutables.seniorTranche).safeTransfer(_receiver, _claims.stShares);
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
        NAV_UNIT effectiveTrancheValue = _claims.nav + (_includeVirtualShares ? VIRTUAL_VALUE : ZERO_NAV_UNITS);

        scaledClaims.collateralAssets = _claims.collateralAssets.mulDiv(_shares, effectiveTrancheShares, Math.Rounding.Floor);
        scaledClaims.lptAssets = _claims.lptAssets.mulDiv(_shares, effectiveTrancheShares, Math.Rounding.Floor);
        scaledClaims.stShares = _claims.stShares.mulDiv(_shares, effectiveTrancheShares, Math.Rounding.Floor);
        scaledClaims.nav = effectiveTrancheValue.mulDiv(_shares, effectiveTrancheShares, Math.Rounding.Floor);
    }
}
