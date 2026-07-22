// SPDX-License-Identifier: LicenseRef-PolyForm-Perimeter-1.0.1
pragma solidity ^0.8.28;

import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { WAD, ZERO_NAV_UNITS } from "../Constants.sol";
import { AssetClaims, SyncedAccountingState } from "../Types.sol";
import { Math, NAV_UNIT, RoycoUnitsMath, TRANCHE_UNIT } from "../Units.sol";
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
        // Compute the maximum bonus that doesn't increase coverage utilization, preventing bank run dynamics
        NAV_UNIT maxCoverageUtilizationNeutralBonusNAV = _computeMaxCoverageUtilizationNeutralBonus(_state, _stUserClaims);
        // Clamp the actual bonus by the maximum coverage-utilization-neutral bonus NAV (leverage retaining or delevering) and the remaining JT effective NAV and
        stSelfLiquidationBonusNAV = RoycoUnitsMath.min(RoycoUnitsMath.min(desiredBonusNAV, maxCoverageUtilizationNeutralBonusNAV), _state.jtEffectiveNAV);
        // Preemptively return if there is no remaining bonus capital to remit
        if (stSelfLiquidationBonusNAV == ZERO_NAV_UNITS) return (_stUserClaims, ZERO_NAV_UNITS);

        // Decompose the NAV claims for the Junior Tranche to get the NAV claims for sourcing the bonus
        (,, NAV_UNIT jtClaimOnSTRawNAV,) = TrancheClaimsLogic._computeSTandJTClaimsOnRawNAVs(_state);
        // Compute the bonus NAV sourced from JT's claims on each tranche's NAV: prioritize ST assets over JT assets for sourcing
        // stSelfLiquidationBonusNAV <= (jtClaimOnSTRawNAV + jtClaimOnJTRawNAV) since it was bounded by JT effective NAV already
        NAV_UNIT bonusFromJTClaimOnSTRawNAV = RoycoUnitsMath.min(stSelfLiquidationBonusNAV, jtClaimOnSTRawNAV);
        NAV_UNIT bonusFromJTClaimOnJTRawNAV = (stSelfLiquidationBonusNAV - bonusFromJTClaimOnSTRawNAV);

        // Apply the derived bonus to the user's asset claims
        TRANCHE_UNIT stBonusAssets = IRoycoDayKernel(address(this)).stConvertNAVUnitsToTrancheUnits(bonusFromJTClaimOnSTRawNAV);
        TRANCHE_UNIT jtBonusAssets = IRoycoDayKernel(address(this)).jtConvertNAVUnitsToTrancheUnits(bonusFromJTClaimOnJTRawNAV);
        // Report the bonus at the value of the assets actually granted
        stSelfLiquidationBonusNAV = IRoycoDayKernel(address(this)).stConvertTrancheUnitsToNAVUnits(stBonusAssets)
            + IRoycoDayKernel(address(this)).jtConvertTrancheUnitsToNAVUnits(jtBonusAssets);
        stUserClaimsWithBonus.stAssets = _stUserClaims.stAssets + stBonusAssets;
        stUserClaimsWithBonus.jtAssets = _stUserClaims.jtAssets + jtBonusAssets;
        stUserClaimsWithBonus.nav = _stUserClaims.nav + stSelfLiquidationBonusNAV;
    }

    /**
     * @notice Computes the maximum self-liquidation bonus that doesn't increase coverage utilization (market's leverage)
     * @dev Prevents bank run dynamics by ensuring one LP's bonus doesn't reduce coverage for remaining LPs
     * @dev Derivation:
     *      Post-redemption coverage utilization must not exceed original coverage utilization:
     *      COVERED_EXPOSURE = (ST_RAW_NAV + JT_RAW_NAV)
     *      U = Current coverage utilization = (COVERED_EXPOSURE * MIN_COVERAGE) / JT_EFFECTIVE_NAV
     *      U' = Post-redemption coverage utilization (including bonus)
     *      Post-redemption coverage utilization:
     *      U' = ((COVERED_EXPOSURE - ST_REDEMPTION_NAV - BONUS_NAV) * MIN_COVERAGE) / (JT_EFFECTIVE_NAV - BONUS_NAV)
     *
     *      NOTE: INVARIANT: U' == U
     *      Result after simplification:
     *      BONUS_MAX = (ST_REDEMPTION_NAV * JT_EFFECTIVE_NAV) / (COVERED_EXPOSURE - JT_EFFECTIVE_NAV)
     *                = (ST_REDEMPTION_NAV * JT_EFFECTIVE_NAV) / ST_EFFECTIVE_NAV
     *
     * @param _state The synced accounting state
     * @param _stUserClaims The ST user's base claims before bonus
     * @return maxCoverageUtilizationNeutralBonusNAV The maximum bonus NAV that maintains coverage utilization neutrality
     */
    function _computeMaxCoverageUtilizationNeutralBonus(
        SyncedAccountingState memory _state,
        AssetClaims memory _stUserClaims
    )
        internal
        pure
        returns (NAV_UNIT maxCoverageUtilizationNeutralBonusNAV)
    {
        // If the ST claim on NAV is zero, there is no bonus to apply
        if (_stUserClaims.nav == ZERO_NAV_UNITS) return ZERO_NAV_UNITS;
        // Compute the coverage-utilization-neutral bonus, rounding down to be conservative
        return _stUserClaims.nav.mulDiv(_state.jtEffectiveNAV, _state.stEffectiveNAV, Math.Rounding.Floor);
    }
}
