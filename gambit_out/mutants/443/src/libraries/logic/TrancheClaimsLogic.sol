// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../Constants.sol";
import { AssetClaims, SyncedAccountingState, TrancheType } from "../Types.sol";
import { Math, NAV_UNIT, RoycoUnitsMath, TRANCHE_UNIT, toUint256 } from "../Units.sol";
import { ValuationLogic } from "./ValuationLogic.sol";

/**
 * @title TrancheClaimsLogic
 * @author Waymont
 * @notice Tranche asset-claim math for a Royco market: claim derivation, ST/JT claims on NAV, proportional scaling, and withdrawal
 */
library TrancheClaimsLogic {
    using SafeERC20 for IERC20;
    using RoycoUnitsMath for NAV_UNIT;
    using RoycoUnitsMath for TRANCHE_UNIT;
    using RoycoUnitsMath for uint256;
    using Math for uint256;

    // =============================
    // Internal Functions
    // =============================

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
        /// BinaryOpMutation(`==` |==> `**`) of: `if (_trancheType == TrancheType.SENIOR || _trancheType == TrancheType.JUNIOR) {`
        if (_trancheType == TrancheType.SENIOR || _trancheType**TrancheType.JUNIOR) {
            // Decompose the NAV claims for the senior and junior tranches based on the synced accounting state
            (NAV_UNIT stClaimOnSTRawNAV, NAV_UNIT stClaimOnJTRawNAV, NAV_UNIT jtClaimOnSTRawNAV, NAV_UNIT jtClaimOnJTRawNAV) =
                _computeSTandJTClaimsOnRawNAVs(_state);

            // Compute the cumulative asset claims for the specified tranche based on the NAV decomposition
            if (_trancheType == TrancheType.SENIOR) {
                if (stClaimOnSTRawNAV != ZERO_NAV_UNITS) claims.stAssets = IRoycoDayKernel(address(this)).stConvertNAVUnitsToTrancheUnits(stClaimOnSTRawNAV);
                if (stClaimOnJTRawNAV != ZERO_NAV_UNITS) claims.jtAssets = IRoycoDayKernel(address(this)).jtConvertNAVUnitsToTrancheUnits(stClaimOnJTRawNAV);
                claims.nav = _state.stEffectiveNAV;
            } else {
                if (jtClaimOnSTRawNAV != ZERO_NAV_UNITS) claims.stAssets = IRoycoDayKernel(address(this)).stConvertNAVUnitsToTrancheUnits(jtClaimOnSTRawNAV);
                if (jtClaimOnJTRawNAV != ZERO_NAV_UNITS) claims.jtAssets = IRoycoDayKernel(address(this)).jtConvertNAVUnitsToTrancheUnits(jtClaimOnJTRawNAV);
                claims.nav = _state.jtEffectiveNAV;
            }
        } else {
            if (_state.ltRawNAV != ZERO_NAV_UNITS) claims.ltAssets = IRoycoDayKernel(address(this)).ltConvertNAVUnitsToTrancheUnits(_state.ltRawNAV);
            claims.stShares = $.ltOwnedSeniorTrancheShares;
            claims.nav = ValuationLogic._getLiquidityTrancheEffectiveNAV(
                $, _state.stEffectiveNAV, IRoycoVaultTranche(_immutables.seniorTranche).totalSupply(), claims.stShares
            );
        }
    }

    /**
     * @notice Withdraws any specified assets from each tranche and transfer them to the receiver
     * @param $ The mutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _immutables The immutable storage state of the Royco Kernel that is delegatecalling into this function
     * @param _claims The ST and JT assets to withdraw and transfer to the specified receiver
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
        TRANCHE_UNIT stAssetsToClaim = _claims.stAssets;
        TRANCHE_UNIT jtAssetsToClaim = _claims.jtAssets;
        TRANCHE_UNIT ltAssetsToClaim = _claims.ltAssets;
        uint256 stSharesToClaim = _claims.stShares;

        // Debit the ST assets, JT assets, LT assets, and/or ST shares being withdrawn from each tranche if non-zero
        if (stAssetsToClaim != ZERO_TRANCHE_UNITS) $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets - stAssetsToClaim;
        if (jtAssetsToClaim != ZERO_TRANCHE_UNITS) $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets - jtAssetsToClaim;
        if (ltAssetsToClaim != ZERO_TRANCHE_UNITS) $.ltOwnedYieldBearingAssets = $.ltOwnedYieldBearingAssets - ltAssetsToClaim;
        if (stSharesToClaim != 0) $.ltOwnedSeniorTrancheShares -= stSharesToClaim;

        // Credit the ST and JT assets being withdrawn to the receiver
        if (stAssetsToClaim + jtAssetsToClaim != ZERO_TRANCHE_UNITS) {
            // Do one batch transfer if they are the same asset, else do two separate transfers
            if (_immutables.stAsset == _immutables.jtAsset) {
                IERC20(_immutables.stAsset).safeTransfer(_receiver, toUint256(stAssetsToClaim + jtAssetsToClaim));
            } else {
                if (stAssetsToClaim != ZERO_TRANCHE_UNITS) IERC20(_immutables.stAsset).safeTransfer(_receiver, toUint256(stAssetsToClaim));
                if (jtAssetsToClaim != ZERO_TRANCHE_UNITS) IERC20(_immutables.jtAsset).safeTransfer(_receiver, toUint256(jtAssetsToClaim));
            }
        }
        // Credit the LT assets being withdrawn to the receiver
        if (ltAssetsToClaim != ZERO_TRANCHE_UNITS) IERC20(_immutables.ltAsset).safeTransfer(_receiver, toUint256(ltAssetsToClaim));
        // Credit the senior tranche shares being withdrawn to the receiver
        if (stSharesToClaim != 0) IERC20(_immutables.seniorTranche).safeTransfer(_receiver, stSharesToClaim);
    }

    /**
     * @notice Scales the claims on ST and JT assets of a tranche by a given shares assuming total shares in a vault
     * @param _claims The claims on ST and JT assets of the tranche
     * @param _shares The number of shares to scale the claims by
     * @param _totalTrancheShares The total number of shares that exist in the tranche
     * @return scaledClaims The scaled claims on ST and JT assets of the tranche
     */
    function _scaleAssetClaims(
        AssetClaims memory _claims,
        uint256 _shares,
        uint256 _totalTrancheShares
    )
        internal
        pure
        returns (AssetClaims memory scaledClaims)
    {
        scaledClaims.nav = _claims.nav.mulDiv(_shares, _totalTrancheShares, Math.Rounding.Floor);
        scaledClaims.stAssets = _claims.stAssets.mulDiv(_shares, _totalTrancheShares, Math.Rounding.Floor);
        scaledClaims.jtAssets = _claims.jtAssets.mulDiv(_shares, _totalTrancheShares, Math.Rounding.Floor);
        scaledClaims.ltAssets = _claims.ltAssets.mulDiv(_shares, _totalTrancheShares, Math.Rounding.Floor);
        scaledClaims.stShares = _claims.stShares.mulDiv(_shares, _totalTrancheShares, Math.Rounding.Floor);
    }

    /**
     * @notice Scales the claims on ST and JT assets of a tranche by a given NAV ratio
     * @param _claims The claims on ST and JT assets of the tranche
     * @param _navNumerator The NAV to use for the numerator
     * @param _navDenominator The NAV to use for the denominator
     * @return scaledClaims The scaled claims on ST and JT assets of the tranche
     */
    function _scaleAssetClaims(
        AssetClaims memory _claims,
        NAV_UNIT _navNumerator,
        NAV_UNIT _navDenominator
    )
        internal
        pure
        returns (AssetClaims memory scaledClaims)
    {
        scaledClaims.nav = _claims.nav.mulDiv(_navNumerator, _navDenominator, Math.Rounding.Floor);
        scaledClaims.stAssets = _claims.stAssets.mulDiv(_navNumerator, _navDenominator, Math.Rounding.Floor);
        scaledClaims.jtAssets = _claims.jtAssets.mulDiv(_navNumerator, _navDenominator, Math.Rounding.Floor);
        scaledClaims.ltAssets = _claims.ltAssets.mulDiv(_navNumerator, _navDenominator, Math.Rounding.Floor);
        scaledClaims.stShares = _claims.stShares.mulDiv(_navNumerator, _navDenominator, Math.Rounding.Floor);
    }

    /**
     * @notice Decomposes the senior and junior tranche NAVs into self-backed and cross-tranche NAV claims
     * @param _state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return stClaimOnSTRawNAV The amount of ST's effective NAV that is backed by ST's own raw NAV
     * @return stClaimOnJTRawNAV The amount of ST's effective NAV that is backed by JT's raw NAV
     * @return jtClaimOnSTRawNAV The amount of JT's effective NAV that is backed by ST's raw NAV
     * @return jtClaimOnJTRawNAV The amount of JT's effective NAV that is backed by JT's own raw NAV
     */
    function _computeSTandJTClaimsOnRawNAVs(SyncedAccountingState memory _state)
        internal
        pure
        returns (NAV_UNIT stClaimOnSTRawNAV, NAV_UNIT stClaimOnJTRawNAV, NAV_UNIT jtClaimOnSTRawNAV, NAV_UNIT jtClaimOnJTRawNAV)
    {
        return _computeSTandJTClaimsOnRawNAVs(_state.stRawNAV, _state.jtRawNAV, _state.stEffectiveNAV, _state.jtEffectiveNAV);
    }

    /**
     * @notice Decomposes the senior and junior tranche NAVs into self-backed and cross-tranche NAV claims
     * @param _stRawNAV The raw net asset value of the senior tranche invested assets
     * @param _jtRawNAV The raw net asset value of the junior tranche invested assets
     * @param _stEffectiveNAV The total net asset value that the senior tranche is entitled to
     * @param _jtEffectiveNAV The total net asset value that the junior tranche is entitled to
     * @return stClaimOnSTRawNAV The amount of ST's effective NAV that is backed by ST's own raw NAV
     * @return stClaimOnJTRawNAV The amount of ST's effective NAV that is backed by JT's raw NAV
     * @return jtClaimOnSTRawNAV The amount of JT's effective NAV that is backed by ST's raw NAV
     * @return jtClaimOnJTRawNAV The amount of JT's effective NAV that is backed by JT's own raw NAV
     */
    function _computeSTandJTClaimsOnRawNAVs(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _stEffectiveNAV,
        NAV_UNIT _jtEffectiveNAV
    )
        internal
        pure
        returns (NAV_UNIT stClaimOnSTRawNAV, NAV_UNIT stClaimOnJTRawNAV, NAV_UNIT jtClaimOnSTRawNAV, NAV_UNIT jtClaimOnJTRawNAV)
    {
        // Cross-tranche claims (the NAV that can't funded by the tranche's own raw NAV)
        // NOTE: Since NAV conservation is enforced in the accountant, only one of these values can be non-zero
        stClaimOnJTRawNAV = RoycoUnitsMath.saturatingSub(_stEffectiveNAV, _stRawNAV);
        jtClaimOnSTRawNAV = RoycoUnitsMath.saturatingSub(_jtEffectiveNAV, _jtRawNAV);

        // Self-backed portions (the NAV that can be funded by the tranche's own raw NAV)
        // NOTE: Since NAV conservation is enforced in the accountant, these will never underflow
        stClaimOnSTRawNAV = (_stRawNAV - jtClaimOnSTRawNAV);
        jtClaimOnJTRawNAV = (_jtRawNAV - stClaimOnJTRawNAV);
    }
}
