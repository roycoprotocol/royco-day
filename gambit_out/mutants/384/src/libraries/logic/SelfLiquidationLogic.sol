// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { WAD, ZERO_NAV_UNITS } from "../Constants.sol";
import { AssetClaims, SyncedAccountingState } from "../Types.sol";
import { Math, NAV_UNIT, RoycoUnitsMath } from "../Units.sol";
import { TrancheClaimsLogic } from "./TrancheClaimsLogic.sol";

/**
 * @title SelfLiquidationLogic
 * @author Waymont
 * @notice The senior-tranche self-liquidation bonus computation for a Royco market
 */
library SelfLiquidationLogic {
    using RoycoUnitsMath for NAV_UNIT;

    /**
     * @notice Computes and applies the self-liquidation bonus for ST redemptions when the liquidation coverage utilization threshold is breached, sourced from JT asset claims
     * @dev The bonus incentivizes ST to self-liquidate by redeeming to delever the market
     * @dev After exiting the market, the bonus affords ST LPs the ability to:
     *      1. Absorb discounts/losses on secondary markets when liquidating the withdrawn exposure
     *      2. Absorb any duration risk associated with liquidating the withdrawn exposure
     * @dev The bonus is computed on the NAV being redeemed by the senior tranche
     * @dev The bonus is capped to ensure coverage utilization does not increase, preventing bank run dynamics where one LP's bonus eats into coverage for remaining LPs
     * @param _state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @param _stUserClaims The claims of the redeeming ST user
     * @return stUserClaimsWithBonus The claims of the redeeming ST user after applying the self-liquidation bonus
     * @return stSelfLiquidationBonusNAV Bonus sourced from JT's claims on ST and JT assets
     */
    function applySeniorTrancheSelfLiquidationBonus(
        IRoycoDayKernel.RoycoDayKernelState storage $,
        SyncedAccountingState memory _state,
        AssetClaims memory _stUserClaims
    )
        external
        view
        returns (AssetClaims memory stUserClaimsWithBonus, NAV_UNIT stSelfLiquidationBonusNAV)
    {
        // If the liquidation coverage utilization threshold has not been breached, there is no ST self-liquidation bonus remitted
        if (_state.coverageUtilizationWAD < _state.coverageLiquidationUtilizationWAD) return (_stUserClaims, ZERO_NAV_UNITS);

        // Compute the desired ST bonus based on the configured ST self-liquidation bonus rate
        NAV_UNIT desiredBonusNAV = _stUserClaims.nav.mulDiv($.stSelfLiquidationBonusWAD, WAD, Math.Rounding.Floor);

        // Decompose the NAV claims for the Junior Tranche to get the NAV claims for sourcing the bonus
        (,, NAV_UNIT jtClaimOnSTRawNAV,) = TrancheClaimsLogic._computeSTandJTClaimsOnRawNAVs(_state);

        // Compute the maximum bonus that doesn't increase coverage utilization, preventing bank run dynamics
        NAV_UNIT maxCoverageUtilizationNeutralBonusNAV = _computeMaxCoverageUtilizationNeutralBonus(_state, _stUserClaims, jtClaimOnSTRawNAV);

        // Clamp the actual bonus by the remaining JT controlled NAV and the maximum coverage-utilization-neutral (leverage retaining or delevering) NAV
        stSelfLiquidationBonusNAV = RoycoUnitsMath.min(RoycoUnitsMath.min(desiredBonusNAV, _state.jtEffectiveNAV), maxCoverageUtilizationNeutralBonusNAV);

        // Preemptively return if there is no remaining bonus capital to remit
        if (stSelfLiquidationBonusNAV == ZERO_NAV_UNITS) return (_stUserClaims, ZERO_NAV_UNITS);

        // Compute the bonus NAV sourced from JT's claims on each tranche's NAV: prioritize ST assets over JT assets for sourcing
        // stSelfLiquidationBonusNAV <= (jtClaimOnSTRawNAV + jtClaimOnSelfRawNAV) since it was bounded by JT effective NAV already
        NAV_UNIT bonusFromJTClaimOnSTRawNAV = RoycoUnitsMath.min(stSelfLiquidationBonusNAV, jtClaimOnSTRawNAV);
        NAV_UNIT bonusFromJTClaimOnSelfRawNAV = (stSelfLiquidationBonusNAV - bonusFromJTClaimOnSTRawNAV);

        // Apply the derived bonus to the user's asset claims
        stUserClaimsWithBonus.stAssets = _stUserClaims.stAssets + IRoycoDayKernel(address(this)).stConvertNAVUnitsToTrancheUnits(bonusFromJTClaimOnSTRawNAV);
        stUserClaimsWithBonus.jtAssets = _stUserClaims.jtAssets + IRoycoDayKernel(address(this)).jtConvertNAVUnitsToTrancheUnits(bonusFromJTClaimOnSelfRawNAV);
        stUserClaimsWithBonus.nav = _stUserClaims.nav + stSelfLiquidationBonusNAV;
    }

    /**
     * @notice Computes the maximum self-liquidation bonus that doesn't increase coverage utilization (market's leverage)
     * @dev Prevents bank run dynamics by ensuring one LP's bonus doesn't reduce coverage for remaining LPs
     * @dev Derivation:
     *      Post-redemption coverage utilization must not exceed original coverage utilization:
     *      U = Current coverage utilization = ((ST_RAW_NAV + (JT_COINVESTED ? JT_RAW_NAV : 0)) * MIN_COVERAGE) / JT_EFFECTIVE_NAV
     *      U' = Post-redemption coverage utilization (including bonus)
     *      Post-redemption coverage utilization:
     *      U' = (((ST_RAW_NAV - ST_REDEMPTION_ST_RAW_NAV - BONUS_ST_RAW_NAV) + (JT_COINVESTED ? (JT_RAW_NAV - ST_REDEMPTION_JT_RAW_NAV - BONUS_JT_RAW_NAV) : 0)) * MIN_COVERAGE) / (JT_EFFECTIVE_NAV - BONUS_ST_RAW_NAV - BONUS_JT_RAW_NAV)
     *
     *      NOTE: INVARIANT: U' <= U
     *      Resulting invariant after simplification:
     *      COVERED_EXPOSURE = ST_RAW_NAV + (JT_COINVESTED ? JT_RAW_NAV : 0)
     *      BONUS_ST_RAW_NAV * (COVERED_EXPOSURE - JT_EFFECTIVE_NAV) + BONUS_JT_RAW_NAV * (COVERED_EXPOSURE - (JT_COINVESTED ? JT_EFFECTIVE_NAV : 0)) <= JT_EFFECTIVE_NAV * (ST_REDEMPTION_ST_RAW_NAV + (JT_COINVESTED ? ST_REDEMPTION_JT_RAW_NAV : 0))
     *
     *      Since when the junior tranche is not co-invested BONUS_ST_RAW_NAV is cheaper per unit, use the ST_RAW_NAV to source the bonus first:
     *      First Priority (BONUS_JT_RAW_NAV = 0):
     *          BONUS_MAX = (ST_REDEMPTION_ST_RAW_NAV + (JT_COINVESTED ? ST_REDEMPTION_JT_RAW_NAV : 0)) * JT_EFFECTIVE_NAV / (COVERED_EXPOSURE - JT_EFFECTIVE_NAV)
     *
     *      Second Priority (BONUS_ST_RAW_NAV = JT_CLAIM_ON_ST_RAW_NAV, maxed out):
     *          BONUS_MAX = (ST_REDEMPTION_ST_RAW_NAV + (JT_COINVESTED ? ST_REDEMPTION_JT_RAW_NAV : 0) + (JT_COINVESTED ? 0 : JT_CLAIM_ON_ST_RAW_NAV)) * JT_EFFECTIVE_NAV / (COVERED_EXPOSURE - (JT_COINVESTED ? JT_EFFECTIVE_NAV : 0))
     *
     * @param _state The synced accounting state
     * @param _stUserClaims The ST user's base claims before bonus
     * @param _jtClaimOnSTRawNAV JT's cross-tranche claim on ST assets
     * @return maxCoverageUtilizationNeutralBonusNAV The maximum bonus NAV that maintains coverage utilization neutrality
     */
    function _computeMaxCoverageUtilizationNeutralBonus(
        SyncedAccountingState memory _state,
        AssetClaims memory _stUserClaims,
        NAV_UNIT _jtClaimOnSTRawNAV
    )
        internal
        view
        returns (NAV_UNIT maxCoverageUtilizationNeutralBonusNAV)
    {
        // Preemptively return if there is no remaining capital to source a bonus from
        NAV_UNIT jtEffectiveNAV = _state.jtEffectiveNAV;
        if (jtEffectiveNAV == ZERO_NAV_UNITS) return ZERO_NAV_UNITS;

        // Compute the total covered exposure of the market, rounding up to be conservative
        /// BinaryOpMutation(`+` |==> `**`) of: `NAV_UNIT totalCoveredExposure = _state.stRawNAV + (_state.jtCoinvested ? _state.jtRawNAV : ZERO_NAV_UNITS);`
        NAV_UNIT totalCoveredExposure = _state.stRawNAV**(_state.jtCoinvested ? _state.jtRawNAV : ZERO_NAV_UNITS);

        // Compute the ST LP's NAV claim on real exposure (including the junior leg only when the junior tranche is co-invested)
        NAV_UNIT stUserWeightedClaimNAV = IRoycoDayKernel(address(this)).stConvertTrancheUnitsToNAVUnits(_stUserClaims.stAssets)
            + (_state.jtCoinvested ? IRoycoDayKernel(address(this)).jtConvertTrancheUnitsToNAVUnits(_stUserClaims.jtAssets) : ZERO_NAV_UNITS);
        // If the weighted claim is zero, there is no bonus to apply
        if (stUserWeightedClaimNAV == ZERO_NAV_UNITS) return ZERO_NAV_UNITS;

        // Case 1: Bonus sourced entirely from JT's claim on ST assets
        // maxBonus = stUserWeightedClaimNAV * jtEffectiveNAV / (totalCoveredExposure - jtEffectiveNAV)
        NAV_UNIT stAssetSourcedMaxBonusNAV = stUserWeightedClaimNAV.mulDiv(jtEffectiveNAV, (totalCoveredExposure - jtEffectiveNAV), Math.Rounding.Floor);
        if (stAssetSourcedMaxBonusNAV <= _jtClaimOnSTRawNAV) return stAssetSourcedMaxBonusNAV;

        // Case 2: Bonus sourced from both JT's claim on ST assets and JT's claim on JT assets
        // maxBonus = (stUserWeightedClaimNAV + (jtCoinvested ? 0 : jtClaimOnSTRawNAV)) * jtEffectiveNAV / (totalCoveredExposure - (jtCoinvested ? jtEffectiveNAV : 0))
        NAV_UNIT weightedClaimWithSTSourceAdjustmentNAV = stUserWeightedClaimNAV + (_state.jtCoinvested ? ZERO_NAV_UNITS : _jtClaimOnSTRawNAV);
        return weightedClaimWithSTSourceAdjustmentNAV.mulDiv(
            jtEffectiveNAV, (totalCoveredExposure - (_state.jtCoinvested ? jtEffectiveNAV : ZERO_NAV_UNITS)), Math.Rounding.Floor
        );
    }
}
