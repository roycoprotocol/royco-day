// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { FixedPointMathLib } from "../../lib/solady/src/utils/FixedPointMathLib.sol";

/**
 * @title RoycoTestMath
 * @notice Independent expected-value library for the Royco Day test suite. Every formula is re-derived
 *         from the written product and accounting rules, NOT imported from the production code, so unit
 *         and fuzz assertions can compare production output against a genuinely independent second
 *         derivation.
 * @dev Conventions (binding across the suite):
 *      - All amounts are plain uint256. NAVs are WAD-normalized NAV units, share supplies are share wei,
 *        percentages and utilizations are WAD fractions (1e18 == 100%).
 *      - Every function is pure and stateless. Rounding direction and who keeps the dust are stated per
 *        function.
 *      - Forbidden imports: anything under src/libraries/logic/ or src/accountant/. Allowed: OZ Math
 *        (mulDiv and Rounding) and solady FixedPointMathLib.expWad for the adaptive yield model.
 */
library RoycoTestMath {
    /// @notice Raised when a sync input set violates the two-term conservation identity after the sync.
    error CONSERVATION_VIOLATED();

    /// @notice Raised when the computed premiums exceed the senior gain, mirroring the production guard.
    error PREMIUMS_EXCEED_SENIOR_YIELD();

    /// @notice Raised when a FIXED_TERM resolution carries a nonzero fee or premium, an unrepresentable state under same-sign attribution.
    error FIXED_TERM_FEES_NONZERO();

    /// @notice WAD fixed-point unit, 1e18 == 100%.
    uint256 internal constant WAD = 1e18;

    /// @notice Independent restatement of the protocol's max mint dilution (Constants.sol
    ///         MAX_MINT_DILUTION_WAD = WAD − 1e6): a single mint owns at most (1 − 1e-12) of the
    ///         post-mint supply, leaving incumbents a 1e-12 residual. Deliberately NOT imported from
    ///         src so a silent production change diverges from this mirror and fails every cross-assert loudly.
    uint256 internal constant MAX_MINT_DILUTION = 1e18 - 1e6;

    /// @notice Virtual shares / virtual value, this library's independent restatement of the src constants
    ///         (VIRTUAL_SHARES / VIRTUAL_VALUE in Constants.sol). Every conversion prices against
    ///         (supply + VIRTUAL_SHARES) over (totalValue + VIRTUAL_VALUE); if the src values change without this
    ///         mirror, every cross-assert fails loudly.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_VALUE = 1;

    /// @notice One below solady expWad's overflow threshold, the clamp on the adaptive yield model's linear adaptation.
    int256 internal constant MAX_LINEAR_ADAPTATION_WAD = 135_305_999_368_893_231_589 - 1;

    /// @notice Mirror of the production market-state enum with identical ordinals (PERPETUAL = 0, FIXED_TERM = 1).
    enum MarketState {
        PERPETUAL,
        FIXED_TERM
    }

    /**
     * @title SyncInputs
     * @notice Complete input set for one single-collateral-NAV tranche accounting sync, mirroring the inputs src's
     *         AccountingSyncLogic.syncTrancheAccounting consumes.
     * @custom:field collateralNAVLast - Collateral NAV at the last committed checkpoint (the coinvested pool, equal to stEffectiveNAVLast + jtEffectiveNAVLast under conservation)
     * @custom:field stEffectiveNAVLast - Senior effective NAV at the last committed checkpoint (ST's claim on the collateral NAV)
     * @custom:field jtEffectiveNAVLast - Junior effective NAV at the last committed checkpoint (JT's residual claim on the collateral NAV)
     * @custom:field jtImpermanentLossLast - JT impermanent loss carried from the last checkpoint
     * @custom:field marketStateLast - Market state committed at the last checkpoint
     * @custom:field fixedTermEndTimestampLast - Fixed-term end timestamp committed at the last checkpoint (0 if none)
     * @custom:field collateralNAVDelta - Signed collateral-NAV delta since the last checkpoint (the single attribution input)
     * @custom:field ltRawNAVNew - Fresh LT raw NAV mark, committed outside the collateral sync, pass-through only
     * @custom:field jtTwYieldShareAccrual - Time-weighted JT yield-share accrual Σ shareWAD·Δt over the premium window
     * @custom:field ltTwYieldShareAccrual - Time-weighted LT yield-share accrual Σ shareWAD·Δt over the premium window
     * @custom:field elapsedSincePremiumPayment - Seconds since the last premium payment (0 selects the instantaneous branch)
     * @custom:field jtInstYieldShareWAD - Raw JT previewYieldShare output consumed only by the instantaneous branch
     * @custom:field ltInstYieldShareWAD - Raw LT previewYieldShare output consumed only by the instantaneous branch
     * @custom:field maxJTYieldShareWAD - Cap applied to the instantaneous JT share, ignored on the time-weighted path
     * @custom:field maxLTYieldShareWAD - Cap applied to the instantaneous LT share, ignored on the time-weighted path
     * @custom:field stProtocolFeeWAD - Protocol fee fraction applied to the residual ST gain
     * @custom:field jtProtocolFeeWAD - Protocol fee fraction applied to the residual JT gain above the dust tolerance
     * @custom:field jtYieldShareProtocolFeeWAD - Protocol fee fraction applied to the JT risk premium (a distinct rate)
     * @custom:field ltYieldShareProtocolFeeWAD - Protocol fee fraction applied to the LT liquidity premium
     * @custom:field nowTimestamp - Block timestamp of the sync (state-machine predicate input)
     * @custom:field fixedTermDuration - Configured fixed-term duration (0 forces PERPETUAL)
     * @custom:field minCoverageWAD - Minimum coverage fraction (input for the post-sync coverage utilization)
     * @custom:field coverageLiquidationUtilizationWAD - Liquidation threshold on coverage utilization
     * @custom:field dustTolerance - The single collateral NAV dust tolerance used by the fee gates and the state machine
     * @custom:field minLiquidityWAD - Minimum liquidity fraction (input for the mirror-side liquidity utilization)
     */
    struct SyncInputs {
        uint256 collateralNAVLast;
        uint256 stEffectiveNAVLast;
        uint256 jtEffectiveNAVLast;
        uint256 jtImpermanentLossLast;
        MarketState marketStateLast;
        uint256 fixedTermEndTimestampLast;
        int256 collateralNAVDelta;
        uint256 ltRawNAVNew;
        uint256 jtTwYieldShareAccrual;
        uint256 ltTwYieldShareAccrual;
        uint256 elapsedSincePremiumPayment;
        uint256 jtInstYieldShareWAD;
        uint256 ltInstYieldShareWAD;
        uint256 maxJTYieldShareWAD;
        uint256 maxLTYieldShareWAD;
        uint256 stProtocolFeeWAD;
        uint256 jtProtocolFeeWAD;
        uint256 jtYieldShareProtocolFeeWAD;
        uint256 ltYieldShareProtocolFeeWAD;
        uint256 nowTimestamp;
        uint256 fixedTermDuration;
        uint256 minCoverageWAD;
        uint256 coverageLiquidationUtilizationWAD;
        uint256 dustTolerance;
        uint256 minLiquidityWAD;
    }

    /**
     * @title SyncOutputs
     * @notice Complete expected post-sync state, mirroring the production checkpoint field-for-field.
     * @custom:field collateralNAV - Post-sync collateral NAV (last collateral NAV plus the applied delta)
     * @custom:field ltRawNAV - Post-sync LT raw NAV (committed pass-through of ltRawNAVNew)
     * @custom:field stEffectiveNAV - Post-sync senior effective NAV
     * @custom:field jtEffectiveNAV - Post-sync junior effective NAV
     * @custom:field jtImpermanentLoss - Post-sync JT impermanent loss
     * @custom:field jtRiskPremium - JT risk premium paid out of ST gain on this sync (folded into jtEffectiveNAV, mirror-only observable)
     * @custom:field ltLiquidityPremium - LT liquidity premium paid out of ST gain on this sync
     * @custom:field stProtocolFee - Protocol fee taken on ST gain on this sync
     * @custom:field jtProtocolFee - Protocol fee taken on JT gain and the JT risk premium on this sync
     * @custom:field ltProtocolFee - Protocol fee taken on the LT liquidity premium on this sync
     * @custom:field coverageUtilizationWAD - Coverage utilization at the post-sync marks
     * @custom:field liquidityUtilizationWAD - Liquidity utilization at the post-sync marks (post-commit view)
     * @custom:field marketState - Post-sync market state per the state-machine predicate
     * @custom:field fixedTermEndTimestamp - Post-sync fixed-term end timestamp (0 outside FIXED_TERM)
     * @custom:field premiumsPaid - Whether the premium dust gate cleared, driving the accumulator reset
     * @custom:field ilErased - The JT IL erased by this sync's PERPETUAL commit (every PERPETUAL commit clears the ledger), the exact reset-event arg
     */
    struct SyncOutputs {
        uint256 collateralNAV;
        uint256 ltRawNAV;
        uint256 stEffectiveNAV;
        uint256 jtEffectiveNAV;
        uint256 jtImpermanentLoss;
        uint256 jtRiskPremium;
        uint256 ltLiquidityPremium;
        uint256 stProtocolFee;
        uint256 jtProtocolFee;
        uint256 ltProtocolFee;
        uint256 coverageUtilizationWAD;
        uint256 liquidityUtilizationWAD;
        MarketState marketState;
        uint256 fixedTermEndTimestamp;
        bool premiumsPaid;
        uint256 ilErased;
    }

    /**
     * @title Claims
     * @notice Plain-uint256 mirror of the production four-field asset-claims struct.
     * @custom:field collateralAssets - Claim on the coinvested collateral assets in tranche units (the single ST and JT asset leg)
     * @custom:field ltAssets - Claim on liquidity tranche assets in LT tranche units
     * @custom:field stShares - Claim on senior tranche shares (the LT's idle liquidity premium senior shares, src ltOwnedSeniorTrancheShares)
     * @custom:field nav - Net asset value of the claims in NAV units
     */
    struct Claims {
        uint256 collateralAssets;
        uint256 ltAssets;
        uint256 stShares;
        uint256 nav;
    }

    /**
     * @title SeniorTrancheSelfLiquidationBonusInputs
     * @notice Input set for the self-liquidation bonus mirror.
     * @custom:field stEffectiveNAV - Senior effective NAV at the synced marks (the U-neutral scaling denominator, equal to collateralNAV minus jtEffectiveNAV under conservation)
     * @custom:field jtEffectiveNAV - Junior effective NAV at the synced marks (the bonus source cap and U-neutral numerator)
     * @custom:field coverageUtilizationWAD - Coverage utilization at the synced marks
     * @custom:field coverageLiquidationUtilizationWAD - Liquidation threshold gating the bonus (strict-less means inactive)
     * @custom:field bonusWAD - Configured self-liquidation bonus fraction of the redeemed NAV
     * @custom:field userClaimNAV - The redeeming ST user's total claim NAV (the desired-bonus base and the U-neutral scaling weight)
     */
    struct SeniorTrancheSelfLiquidationBonusInputs {
        uint256 stEffectiveNAV;
        uint256 jtEffectiveNAV;
        uint256 coverageUtilizationWAD;
        uint256 coverageLiquidationUtilizationWAD;
        uint256 bonusWAD;
        uint256 userClaimNAV;
    }

    /**
     * @title AdaptiveCurveYieldShareInputs
     * @notice Input set for the adaptive-curve yield model mirror (the AdaptiveCurveYDM_V2 shape).
     * @custom:field utilizationWAD - Driving utilization, capped at WAD before evaluation
     * @custom:field targetUtilizationWAD - Utilization at the kink, precondition 0 < targetU <= WAD
     * @custom:field startYieldShareAtTargetWAD - Yield share at target from the last committed adaptation
     * @custom:field elapsedSeconds - Seconds since the last adaptation (0 on the first-ever call)
     * @custom:field discountToTargetAtZeroUtilWAD - Fixed discount below the target share at 0% utilization (FD_T)
     * @custom:field premiumToTargetAtFullUtilWAD - Fixed premium above the target share at 100% utilization (FP_T)
     * @custom:field adaptationSpeedAtBoundaryWAD - Adaptation speed per second at the region boundary, scaled by the normalized delta
     * @custom:field minYieldShareAtTargetWAD - Lower clamp on the adapted share at target (1bp in production)
     * @custom:field maxYieldShareAtTargetWAD - Upper clamp on the adapted share at target (WAD in production)
     * @custom:field perpetual - Whether the market is PERPETUAL, the only state in which the curve adapts
     */
    struct AdaptiveCurveYieldShareInputs {
        uint256 utilizationWAD;
        uint256 targetUtilizationWAD;
        uint256 startYieldShareAtTargetWAD;
        uint256 elapsedSeconds;
        uint256 discountToTargetAtZeroUtilWAD;
        uint256 premiumToTargetAtFullUtilWAD;
        uint256 adaptationSpeedAtBoundaryWAD;
        uint256 minYieldShareAtTargetWAD;
        uint256 maxYieldShareAtTargetWAD;
        bool perpetual;
    }

    /**
     * @title AdaptiveCurveYieldShareOutputs
     * @notice Output of the adaptive-curve yield model mirror.
     * @custom:field yieldShareWAD - Curve output at the trapezoid-averaged share at target, clamped to [0, WAD]
     * @custom:field endYieldShareAtTargetWAD - Adapted share at target after expWad and the [min, max] clamp
     */
    struct AdaptiveCurveYieldShareOutputs {
        uint256 yieldShareWAD;
        uint256 endYieldShareAtTargetWAD;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SINGLE-FORMULA MIRRORS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice PnL attribution: attributed = ⌊|delta| · claim / lastCollateralNAV⌋ with the sign of delta re-applied.
     * @dev Mirrors the proportional split inlined in src RoycoDayAccountant's STEP_APPLY_PNL_ATTRIBUTION.
     *      Rounding: Floor on the magnitude (a negative delta attributes toward zero, never away from it).
     *      Favors: the complementary tranche (JT is the residual and absorbs the flooring drift of the split).
     *      Edge: returns 0 if delta == 0, claim == 0, or lastCollateralNAV == 0. The empty-checkpoint seniority
     *      tie-break (a zero lastCollateralNAV routes the whole delta to ST) lives at the sync call site, not here.
     *      Precondition: claim <= lastCollateralNAV (ST's claim is stEffectiveNAV, never exceeding the pool under conservation).
     * @param delta The signed collateral-NAV delta being attributed
     * @param claim The attributee's effective NAV claim on the last committed collateral NAV
     * @param lastCollateralNAV The last committed collateral NAV the claim is measured against
     * @return attributed The signed portion of delta attributed to the claim
     */
    function attributeDeltaToClaimOnCollateralNAV(int256 delta, uint256 claim, uint256 lastCollateralNAV) internal pure returns (int256 attributed) {
        if (delta == 0 || claim == 0 || lastCollateralNAV == 0) return 0;
        uint256 magnitude;
        unchecked {
            magnitude = delta < 0 ? uint256(0) - uint256(delta) : uint256(delta);
        }
        uint256 attributedMagnitude = Math.mulDiv(magnitude, claim, lastCollateralNAV);
        attributed = delta < 0 ? -int256(attributedMagnitude) : int256(attributedMagnitude);
    }

    /**
     * @notice Coverage utilization: ⌈collateralNAV · minCoverageWAD / jtEffectiveNAV⌉.
     * @dev Mirrors src UtilizationLogic._computeCoverageUtilization.
     *      Edges (zero edges take precedence): 0 if minCoverageWAD == 0 or collateralNAV == 0, then uint256 max if
     *      jtEffectiveNAV == 0 against a positive requirement.
     *      Rounding: Ceil. Favors: senior (utilization reads high, gating deposits earlier).
     * @param collateralNAV The coinvested collateral NAV backing the senior and junior tranches
     * @param minCoverageWAD The minimum coverage fraction in WAD
     * @param jtEffectiveNAV The junior effective NAV
     * @return utilizationWAD The coverage utilization in WAD
     */
    function computeCoverageUtilization(uint256 collateralNAV, uint256 minCoverageWAD, uint256 jtEffectiveNAV) internal pure returns (uint256 utilizationWAD) {
        if (minCoverageWAD == 0 || collateralNAV == 0) return 0;
        if (jtEffectiveNAV == 0) return type(uint256).max;
        utilizationWAD = Math.mulDiv(collateralNAV, minCoverageWAD, jtEffectiveNAV, Math.Rounding.Ceil);
    }

    /**
     * @notice Liquidity utilization: ⌈stEffectiveNAV · minLiquidityWAD / ltRawNAV⌉.
     * @dev Mirrors src UtilizationLogic._computeLiquidityUtilization.
     *      Edges (zero edges take precedence): 0 if stEffectiveNAV == 0 or minLiquidityWAD == 0, then uint256 max if
     *      ltRawNAV == 0 against a positive requirement.
     *      Rounding: Ceil. Favors: senior (utilization reads high, gating LT redemptions earlier).
     * @param stEffectiveNAV The senior effective NAV
     * @param minLiquidityWAD The minimum liquidity fraction in WAD
     * @param ltRawNAV The LT raw NAV (BPT only, idle liquidity premium senior shares excluded)
     * @return utilizationWAD The liquidity utilization in WAD
     */
    function computeLiquidityUtilization(uint256 stEffectiveNAV, uint256 minLiquidityWAD, uint256 ltRawNAV) internal pure returns (uint256 utilizationWAD) {
        if (stEffectiveNAV == 0 || minLiquidityWAD == 0) return 0;
        if (ltRawNAV == 0) return type(uint256).max;
        utilizationWAD = Math.mulDiv(stEffectiveNAV, minLiquidityWAD, ltRawNAV, Math.Rounding.Ceil);
    }

    /**
     * @notice Shares minted for a value contribution: min(⌊(supply + VIRTUAL_SHARES) · value / (totalValue + VIRTUAL_ASSETS)⌋, dilution cap).
     * @dev Mirrors src ValuationLogic._convertToShares.
     *      Edges: a genuinely fresh tranche (supply == 0 AND totalValue == 0) mints value 1:1 (no clamp — a
     *      bootstrap mint dilutes nobody); the empty-with-backing state (supply == 0, totalValue > 0) falls
     *      through to the priced branch so pre-existing backing is not captured; totalValue == 0 with a live
     *      supply pins the denominator to the 1-wei VIRTUAL_ASSETS.
     *      The mint-dilution clamp: a single mint may own at most MAX_MINT_DILUTION / WAD of the
     *      post-mint EFFECTIVE supply (MAX_MINT_DILUTION is this library's own restatement of the protocol
     *      constant — if Constants.sol changes without this mirror, every cross-assert fails loudly). The
     *      shares therefore never exceed cap = ⌊(supply + VIRTUAL_SHARES) · MAX_MINT_DILUTION / (WAD − MAX_MINT_DILUTION)⌋.
     *      The bind test runs BEFORE the fair-shares division in its overflow-free form
     *      (⌈value·(WAD − MAX_MINT_DILUTION) / MAX_MINT_DILUTION⌉ > denominator,
     *      integer-equivalent to fair > cap), mirroring production's ordering exactly — including the panic
     *      surface: the cap mulDiv overflows uint256 once supply ≥ ⌈2^256·(WAD − MAX_MINT_DILUTION) / MAX_MINT_DILUTION⌉,
     *      exactly when production's does (load-bearing for the invariant handler's revert prediction).
     *      Rounding: Floor on both branches (the cap floor favors existing holders).
     * @param value The value being contributed
     * @param totalValue The pre-contribution total value backing the supply
     * @param supply The pre-contribution share supply
     * @return shares The shares minted for the contribution
     */
    function convertToShares(uint256 value, uint256 totalValue, uint256 supply) internal pure returns (uint256 shares) {
        // A genuinely fresh tranche (no shares, no backing) mints 1:1; the dangerous empty-with-backing state
        // (supply 0, totalValue > 0) falls through to the priced branch so pre-existing backing is not captured
        if (supply == 0 && totalValue == 0) return value;
        // Virtual shares / virtual value: the effective supply is never zero and the denominator always carries
        // VIRTUAL_VALUE. The bind predicate's effective supply cancels, so its form is unchanged
        uint256 effectiveSupply = supply + VIRTUAL_SHARES;
        uint256 denominator = totalValue + VIRTUAL_VALUE;
        if (Math.mulDiv(value, WAD - MAX_MINT_DILUTION, MAX_MINT_DILUTION, Math.Rounding.Ceil) > denominator) {
            return Math.mulDiv(effectiveSupply, MAX_MINT_DILUTION, WAD - MAX_MINT_DILUTION);
        }
        shares = Math.mulDiv(effectiveSupply, value, denominator);
    }

    /**
     * @notice Value redeemed for shares: ⌊(totalValue + VIRTUAL_ASSETS) · shares / (supply + VIRTUAL_SHARES)⌋.
     * @dev Mirrors src ValuationLogic._convertToValue.
     *      Edge: only a genuinely fresh tranche (supply == 0 AND totalValue == 0) returns 0; with backing but no
     *      supply the priced branch runs against the VIRTUAL_SHARES-only denominator.
     *      Rounding: Floor. Favors: remaining holders.
     * @param shares The shares being valued
     * @param totalValue The total value backing the supply
     * @param supply The share supply
     * @return value The value of the shares
     */
    function convertToValue(uint256 shares, uint256 totalValue, uint256 supply) internal pure returns (uint256 value) {
        // A fresh tranche (no shares, no backing) has nothing to claim; matches the convertToShares fresh branch
        if (supply == 0 && totalValue == 0) return 0;
        // Inverse of convertToShares under the same virtual shares / virtual value
        value = Math.mulDiv(totalValue + VIRTUAL_VALUE, shares, supply + VIRTUAL_SHARES);
    }

    /**
     * @notice The ST fee and liquidity premium share mints, both computed at the pre-sync supply
     *         over the retained denominator stEffectiveNAV − premium − fee.
     * @dev Mirrors src FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint.
     *      Each mint is a convertToShares computation over the retained NAV, so the share-conversion edges
     *      apply per leg (a genuinely fresh state — pre-sync supply 0 AND retained NAV 0 — mints 1:1, and a
     *      retained NAV of 0 with a live supply pins the denominator to the 1-wei VIRTUAL_ASSETS) — including
     *      the mint-dilution clamp, which applies PER MINT at the shared pre-sync supply: in the degenerate
     *      zero-retained state both legs clamp to the same cap, so the pair may own up to 2·cap/(preSupply + 2·cap)
     *      of the post-mint supply (the residual guarantee is per mint, not per sync).
     *      Rounding: Floor on both mints. Favors: pre-existing ST shares.
     *      Precondition: premium + fee <= stEffectiveNAV (guaranteed upstream by the tranche accounting sync).
     * @dev This zero-ltFee overload forwards to the five-argument form: with no LT protocol fee the premium leg
     *      mints the full premium and the fee leg mints only the ST protocol fee.
     * @param stEffectiveNAV The post-sync senior effective NAV
     * @param premium The LT liquidity premium to mint as ST shares
     * @param fee The ST protocol fee to mint as ST shares
     * @param preSupply The pre-sync ST share supply
     * @return premiumShares The ST shares minted for the liquidity premium
     * @return feeShares The ST shares minted for the protocol fee
     * @return supplyAfter The ST share supply after both mints
     */
    function computeSTFeeAndLiquidityPremiumSharesToMint(
        uint256 stEffectiveNAV,
        uint256 premium,
        uint256 fee,
        uint256 preSupply
    )
        internal
        pure
        returns (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter)
    {
        return computeSTFeeAndLiquidityPremiumSharesToMint(stEffectiveNAV, premium, fee, 0, preSupply);
    }

    /**
     * @notice The senior share mint split with an LT protocol fee carved out of the liquidity premium.
     * @dev Mirrors src FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint. The LT protocol
     *      fee moves from the premium carve-out into the fee carve-out: the premium leg mints (premium − ltFee) so
     *      the LT holds the premium net of the fee, and the fee leg mints (fee + ltFee) so the protocol receives the
     *      ST protocol fee plus the carved LT fee as senior shares. The retained denominator subtracts the gross
     *      premium and the ST fee (the LT fee is already inside the premium), so it is unchanged by the carve-out.
     *      Precondition: ltFee <= premium and premium + fee <= stEffectiveNAV (both guaranteed upstream).
     * @param stEffectiveNAV The post-sync senior effective NAV
     * @param premium The gross LT liquidity premium
     * @param fee The ST protocol fee to mint as ST shares
     * @param ltFee The LT protocol fee carved out of the premium and remitted as ST shares to the protocol
     * @param preSupply The pre-sync ST share supply
     * @return premiumShares The ST shares minted for the premium net of the LT fee
     * @return feeShares The ST shares minted for the ST fee plus the carved LT fee
     * @return supplyAfter The ST share supply after both mints
     */
    function computeSTFeeAndLiquidityPremiumSharesToMint(
        uint256 stEffectiveNAV,
        uint256 premium,
        uint256 fee,
        uint256 ltFee,
        uint256 preSupply
    )
        internal
        pure
        returns (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter)
    {
        uint256 retained = stEffectiveNAV - premium - fee;
        premiumShares = convertToShares(premium - ltFee, retained, preSupply);
        feeShares = convertToShares(fee + ltFee, retained, preSupply);
        supplyAfter = preSupply + premiumShares + feeShares;
    }

    /**
     * @notice Claim scaling: every one of the four claim fields scales as ⌊claim · shares / (totalShares + VIRTUAL_SHARES)⌋.
     * @dev Mirrors src TrancheClaimsLogic._scaleAssetClaims.
     *      Virtual shares: the redeemer's slice is priced against the effective supply (totalShares + VIRTUAL_SHARES),
     *      so a sole holder can never redeem the whole tranche 1:1 — the virtual-share sliver stays behind, closing the
     *      donation/premium extraction vector on the redemption side.
     *      Rounding: Floor on all four fields. Favors: remaining LPs.
     *      Precondition: totalShares > 0 (production scales a redeemer's slice of a live tranche supply).
     * @param total The total claims being sliced
     * @param shares The redeemer's shares
     * @param totalShares The tranche's total share supply
     * @return scaled The redeemer's pro-rata claims
     */
    function scaleClaims(Claims memory total, uint256 shares, uint256 totalShares) internal pure returns (Claims memory scaled) {
        uint256 effectiveTotalShares = totalShares + VIRTUAL_SHARES;
        scaled.collateralAssets = Math.mulDiv(total.collateralAssets, shares, effectiveTotalShares);
        scaled.ltAssets = Math.mulDiv(total.ltAssets, shares, effectiveTotalShares);
        scaled.stShares = Math.mulDiv(total.stShares, shares, effectiveTotalShares);
        scaled.nav = Math.mulDiv(total.nav, shares, effectiveTotalShares);
    }

    /**
     * @notice LT effective NAV: ltRawNAV + ⌊idleShares · (stEffectiveNAV + VIRTUAL_ASSETS) / (stSupply + VIRTUAL_SHARES)⌋,
     *         the BPT depth plus the claimable idle liquidity premium senior shares valued at the senior share price.
     * @dev Mirrors src ValuationLogic._getLiquidityTrancheEffectiveNAV.
     *      The idle-share leg is a convertToValue valuation, so stSupply == 0 values it at 0.
     *      Rounding: Floor on the idle-share leg. Favors: pool leg.
     * @param ltRawNAV The LT raw NAV (BPT only)
     * @param idleShares The not-yet-reinvested liquidity premium senior shares held for the LT (src ltOwnedSeniorTrancheShares)
     * @param stEffectiveNAV The senior effective NAV
     * @param stSupply The senior share supply
     * @return effNav The LT effective NAV
     */
    function getLiquidityTrancheEffectiveNAV(
        uint256 ltRawNAV,
        uint256 idleShares,
        uint256 stEffectiveNAV,
        uint256 stSupply
    )
        internal
        pure
        returns (uint256 effNav)
    {
        // Mirror src's short-circuit: with no idle shares OR no senior supply the effective NAV is just the pool leg.
        // The guard is load-bearing under the virtual-shares offset — convertToValue(idle, stEff, 0) no longer returns
        // 0 once stEff > 0 (the fresh exemption requires totalValue == 0 too), so the raw call would overvalue the leg.
        if (idleShares == 0 || stSupply == 0) return ltRawNAV;
        effNav = ltRawNAV + convertToValue(idleShares, stEffectiveNAV, stSupply);
    }

    /**
     * @notice Static yield model: a piecewise-linear 3-point yield curve through (0, y0), (targetU, yTarget) and
     *         (WAD, yFull), evaluated as ⌊slope · u / WAD⌋ + intercept per segment.
     * @dev Mirrors src StaticCurveYDM._yieldShare (the curve behind previewYieldShare and yieldShare).
     *      The driving utilization is capped at WAD before evaluation and the result is capped at WAD after.
     *      Each segment slope is itself a floored WAD division of the segment rise over its run, mirroring a
     *      stored-slope implementation, so interpolated points carry a double-floor artifact by design.
     *      At u == targetU the exact point value yTarget is returned with no interpolation, which also covers
     *      the degenerate runs (targetU == 0 evaluates the upper segment, targetU == WAD the lower).
     *      Rounding: Floor at the slope and at the evaluation. Favors: the paying tranche (ST).
     *      Preconditions: y0 <= yTarget <= yFull (non-decreasing curve) and targetU <= WAD.
     * @param u The driving utilization in WAD, capped at WAD
     * @param y0 The yield share at zero utilization in WAD
     * @param yTarget The yield share at the target utilization in WAD
     * @param yFull The yield share at full (WAD) utilization in WAD
     * @param targetU The target utilization in WAD
     * @return yWAD The yield share in WAD, capped at WAD
     */
    function staticCurveYieldShare(uint256 u, uint256 y0, uint256 yTarget, uint256 yFull, uint256 targetU) internal pure returns (uint256 yWAD) {
        if (u > WAD) u = WAD;
        if (u == targetU) {
            yWAD = yTarget;
        } else if (u < targetU) {
            uint256 slope = ((yTarget - y0) * WAD) / targetU;
            yWAD = y0 + (slope * u) / WAD;
        } else {
            uint256 slope = ((yFull - yTarget) * WAD) / (WAD - targetU);
            yWAD = yTarget + (slope * (u - targetU)) / WAD;
        }
        if (yWAD > WAD) yWAD = WAD;
    }

    /*//////////////////////////////////////////////////////////////////////////
                        COMPOSED MIRRORS AND INVERSIONS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The full single-collateral-NAV sync mirror, composing attribution, coverage, premiums, fees, and the state machine.
     * @dev Mirrors src AccountingSyncLogic.syncTrancheAccounting (previewed by _previewSyncTrancheAccounting).
     *      Pipeline: single-delta attribution to ST with JT as the residual, the JT leg with its dust-gated fee,
     *      the ST loss leg with coverage (no JT-fee recompute), the ST gain leg with IL recovery first and the
     *      premium block (instantaneous branch when elapsedSincePremiumPayment == 0), the byte-exact conservation
     *      check, and the state machine: every PERPETUAL commit erases the IL and clears the term, FIXED_TERM
     *      stickiness keeps the original end, and a FIXED_TERM resolution provably carries no fees (checked).
     *      Coinvestment invariant: one collateral asset at one rate, so the attributed ST and JT deltas always
     *      share the sign of collateralNAVDelta (mixed-sign tranche PnL is unrepresentable).
     *      Mirror-side extras vs the raw production return: out.ltRawNAV echoes in.ltRawNAVNew and
     *      out.liquidityUtilizationWAD is the post-commit view (production returns (0, 0) placeholders).
     *      Preconditions: collateralNAVLast == stEffectiveNAVLast + jtEffectiveNAVLast, the delta does not underflow collateralNAVLast,
     *      and elapsedSincePremiumPayment · WAD fits uint256.
     * @param in_ The complete sync input set
     * @return out The complete expected post-sync state
     */
    function syncTrancheAccounting(SyncInputs memory in_) internal pure returns (SyncOutputs memory out) {
        // Fresh collateral NAV from the signed delta; LT raw NAV is a committed pass-through
        out.collateralNAV = _applyDelta(in_.collateralNAVLast, in_.collateralNAVDelta);
        out.ltRawNAV = in_.ltRawNAVNew;

        // Attribution: the collateral delta is split to ST pro-rata to its effective NAV claim (Floor on the magnitude),
        // and JT takes the residual so it absorbs all rounding drift on both signs
        // Seniority tie-break for an empty checkpoint: value marked from a zero collateral NAV has no live claims to split, so it accrues to the senior tranche first
        int256 deltaSTEff = in_.collateralNAVLast == 0
            ? in_.collateralNAVDelta
            : attributeDeltaToClaimOnCollateralNAV(in_.collateralNAVDelta, in_.stEffectiveNAVLast, in_.collateralNAVLast);
        int256 deltaJTEff = in_.collateralNAVDelta - deltaSTEff;

        uint256 stEffectiveNAV = in_.stEffectiveNAVLast;
        uint256 jtEffectiveNAV = in_.jtEffectiveNAVLast;
        uint256 il = in_.jtImpermanentLossLast;

        // JT leg first: losses are unfee'd and book IL, gains recover IL first and only the residual takes the dust-gated jtProtocolFeeWAD fee (Floor)
        // IL is JT's drawdown from its high-water mark: JT losses and coverage deepen it, JT gains and ST recoveries repay it
        if (deltaJTEff < 0) {
            uint256 jtLoss = uint256(-deltaJTEff);
            jtEffectiveNAV -= jtLoss;
            il += jtLoss;
        } else if (deltaJTEff > 0) {
            uint256 jtGain = uint256(deltaJTEff);
            uint256 jtRecovery = Math.min(jtGain, il);
            il -= jtRecovery;
            jtEffectiveNAV += jtRecovery;
            jtGain -= jtRecovery;
            if (jtGain > in_.dustTolerance) out.jtProtocolFee = Math.mulDiv(jtGain, in_.jtProtocolFeeWAD, WAD);
            jtEffectiveNAV += jtGain;
        }

        if (deltaSTEff < 0) {
            // ST loss: coverage from the post-JT-leg jtEffectiveNAV, residual loss to ST
            uint256 stLoss = uint256(-deltaSTEff);
            uint256 coverageApplied = Math.min(stLoss, jtEffectiveNAV);
            jtEffectiveNAV -= coverageApplied;
            il += coverageApplied;
            stLoss -= coverageApplied;
            if (stLoss != 0) stEffectiveNAV -= stLoss;
        } else if (deltaSTEff > 0) {
            // ST gain: IL recovery FIRST, exact and never fee'd
            uint256 stGain = uint256(deltaSTEff);
            uint256 recovered = Math.min(stGain, il);
            il -= recovered;
            jtEffectiveNAV += recovered;
            stGain -= recovered;

            if (stGain != 0) {
                // Premium block: the dust gate drives fees and the accumulator reset, not the premiums
                out.premiumsPaid = stGain > in_.dustTolerance;
                uint256 elapsed = in_.elapsedSincePremiumPayment;
                uint256 twJT = in_.jtTwYieldShareAccrual;
                uint256 twLT = in_.ltTwYieldShareAccrual;
                if (elapsed == 0) {
                    // Same-block instantaneous branch: 1-second window with the capped preview shares
                    elapsed = 1;
                    twJT = Math.min(in_.jtInstYieldShareWAD, in_.maxJTYieldShareWAD);
                    twLT = Math.min(in_.ltInstYieldShareWAD, in_.maxLTYieldShareWAD);
                }
                out.jtRiskPremium = Math.mulDiv(stGain, twJT, elapsed * WAD);
                out.ltLiquidityPremium = Math.mulDiv(stGain, twLT, elapsed * WAD);
                require(out.jtRiskPremium + out.ltLiquidityPremium <= stGain, PREMIUMS_EXCEED_SENIOR_YIELD());
                if (out.jtRiskPremium != 0) {
                    if (out.premiumsPaid) out.jtProtocolFee += Math.mulDiv(out.jtRiskPremium, in_.jtYieldShareProtocolFeeWAD, WAD);
                    jtEffectiveNAV += out.jtRiskPremium;
                    stGain -= out.jtRiskPremium;
                }
                if (out.ltLiquidityPremium != 0) {
                    if (out.premiumsPaid) out.ltProtocolFee = Math.mulDiv(out.ltLiquidityPremium, in_.ltYieldShareProtocolFeeWAD, WAD);
                    stGain -= out.ltLiquidityPremium;
                }
                if (out.premiumsPaid) out.stProtocolFee = Math.mulDiv(stGain, in_.stProtocolFeeWAD, WAD);
                // The LT premium stays a senior claim, so it is re-added after sizing plain ST's retention
                stEffectiveNAV += stGain + out.ltLiquidityPremium;
            }
        }

        // Collateral conservation at wei precision: the pool always equals the sum of the tranche effective NAVs
        require(out.collateralNAV == stEffectiveNAV + jtEffectiveNAV, CONSERVATION_VIOLATED());

        // State machine on the fresh collateral NAV and the settled post-sync jtEffectiveNAV. The market resolves
        // PERPETUAL when there is no drawdown, the market is permanently perpetual, the term elapsed, the junior
        // buffer is wiped (partial or total, extinguishing its dead restoration claim), or the drawdown is dust
        // from a perpetual state (dust noise never locks the market)
        out.coverageUtilizationWAD = computeCoverageUtilization(out.collateralNAV, in_.minCoverageWAD, jtEffectiveNAV);
        bool perpetual = il == 0 || in_.fixedTermDuration == 0
            || (in_.marketStateLast == MarketState.FIXED_TERM && in_.fixedTermEndTimestampLast <= in_.nowTimestamp)
            || out.coverageUtilizationWAD >= in_.coverageLiquidationUtilizationWAD || jtEffectiveNAV == 0
            || (il <= in_.dustTolerance && in_.marketStateLast == MarketState.PERPETUAL);
        if (perpetual) {
            // A perpetual commit always erases the IL and clears the term, so a perpetual market never carries a drawdown
            out.ilErased = il;
            il = 0;
            out.marketState = MarketState.PERPETUAL;
        } else {
            // A locked market stays locked until full recovery, term expiry, or a forced transition, keeping the
            // original end so boundary noise cannot re-stamp and extend the term
            out.marketState = MarketState.FIXED_TERM;
            out.fixedTermEndTimestamp =
                in_.marketStateLast == MarketState.PERPETUAL ? uint256(uint32(in_.nowTimestamp + in_.fixedTermDuration)) : in_.fixedTermEndTimestampLast;
            // The fee/premium theorem, checked rather than assumed: same-sign attribution means any nonzero fee
            // requires a gain residual that fully recovered the IL, which resolves PERPETUAL instead. A violation
            // here means the waterfall above (or production, via a diverging cross-assert) broke the theorem
            require(out.ltLiquidityPremium == 0 && out.stProtocolFee == 0 && out.jtProtocolFee == 0 && out.ltProtocolFee == 0, FIXED_TERM_FEES_NONZERO());
        }

        out.stEffectiveNAV = stEffectiveNAV;
        out.jtEffectiveNAV = jtEffectiveNAV;
        out.jtImpermanentLoss = il;
        out.liquidityUtilizationWAD = computeLiquidityUtilization(stEffectiveNAV, in_.minLiquidityWAD, in_.ltRawNAVNew);
    }

    /**
     * @notice Max ST deposit: min of the coverage-leg and liquidity-leg inversions, each minus dust slack.
     * @dev Mirrors src RoycoDayAccountant.maxSTDeposit.
     *      Coverage leg: ⌊jtEffectiveNAV · WAD / minCoverageWAD⌋ − (collateralNAV + dustTolerance), saturating. Liquidity leg:
     *      ⌊ltRawNAV · WAD / minLiquidityWAD⌋ − (stEffectiveNAV + dustTolerance), saturating. A zero requirement disables its leg
     *      (uint256 max). Rounding: Floor on both inversions. Favors: protocol (the max reads low).
     * @param collateralNAV The collateral NAV at the synced marks
     * @param stEffectiveNAV The senior effective NAV at the synced marks
     * @param jtEffectiveNAV The junior effective NAV at the synced marks
     * @param ltRawNAV The LT raw NAV at the synced marks
     * @param minCoverageWAD The minimum coverage fraction in WAD
     * @param minLiquidityWAD The minimum liquidity fraction in WAD
     * @param dustTolerance The single collateral NAV dust tolerance
     * @return maxDeposit The maximum ST deposit NAV
     */
    function maxSTDeposit(
        uint256 collateralNAV,
        uint256 stEffectiveNAV,
        uint256 jtEffectiveNAV,
        uint256 ltRawNAV,
        uint256 minCoverageWAD,
        uint256 minLiquidityWAD,
        uint256 dustTolerance
    )
        internal
        pure
        returns (uint256 maxDeposit)
    {
        uint256 maxGivenCoverage = type(uint256).max;
        if (minCoverageWAD != 0) {
            uint256 totalCoveredValue = Math.mulDiv(jtEffectiveNAV, WAD, minCoverageWAD);
            maxGivenCoverage = _sat(totalCoveredValue, collateralNAV + dustTolerance);
        }
        uint256 maxGivenLiquidity = type(uint256).max;
        if (minLiquidityWAD != 0) {
            uint256 maxSTEffectiveNAV = Math.mulDiv(ltRawNAV, WAD, minLiquidityWAD);
            maxGivenLiquidity = _sat(maxSTEffectiveNAV, stEffectiveNAV + dustTolerance);
        }
        maxDeposit = Math.min(maxGivenCoverage, maxGivenLiquidity);
    }

    /**
     * @notice Max JT withdrawal: the coverage-surplus inversion, stretched by the coverage retention factor (1 − minCoverageWAD).
     * @dev Mirrors src RoycoDayAccountant.maxJTWithdrawal.
     *      requiredJT = ⌈(collateralNAV + dustTolerance) · minCoverageWAD / WAD⌉ folds the dust tolerance into the coverage requirement,
     *      surplus = sat(jtEffectiveNAV − requiredJT). Since JT is coinvested, each withdrawn NAV unit relaxes the requirement by
     *      minCoverageWAD, so the withdrawable NAV is ⌊surplus · WAD / (WAD − minCoverageWAD)⌋.
     *      Rounding: Ceil on the requirement, Floor on the inversion. Favors: protocol. Precondition: minCoverageWAD < WAD.
     * @param collateralNAV The collateral NAV at the synced marks
     * @param jtEffectiveNAV The junior effective NAV at the synced marks
     * @param minCoverageWAD The minimum coverage fraction in WAD
     * @param dustTolerance The single collateral NAV dust tolerance
     * @return jtWithdrawable The JT-withdrawable NAV
     */
    function maxJTWithdrawal(
        uint256 collateralNAV,
        uint256 jtEffectiveNAV,
        uint256 minCoverageWAD,
        uint256 dustTolerance
    )
        internal
        pure
        returns (uint256 jtWithdrawable)
    {
        uint256 requiredJTValue = Math.mulDiv(collateralNAV + dustTolerance, minCoverageWAD, WAD, Math.Rounding.Ceil);
        uint256 surplus = _sat(jtEffectiveNAV, requiredJTValue);
        jtWithdrawable = Math.mulDiv(surplus, WAD, WAD - minCoverageWAD, Math.Rounding.Floor);
    }

    /**
     * @notice Max LT withdrawal: ltRawNAV − (⌈(stEffectiveNAV + dustTolerance) · minLiquidityWAD / WAD⌉), saturating.
     * @dev Mirrors src RoycoDayAccountant.maxLTWithdrawal.
     *      Bypass (full ltRawNAV): minLiquidityWAD == 0. The liquidity requirement is enforced at all coverage levels,
     *      including once the liquidation coverage threshold is breached, so no coverage input feeds the bound.
     *      Rounding: Ceil on the dust-padded required depth (the dust tolerance folds into the senior NAV before
     *      scaling, mirroring the accountant). Favors: senior (the max reads low).
     * @param ltRawNAV The LT raw NAV at the synced marks
     * @param stEffectiveNAV The senior effective NAV at the synced marks
     * @param minLiquidityWAD The minimum liquidity fraction in WAD
     * @param dustTolerance The single collateral NAV dust tolerance
     * @return ltWithdrawable The maximum LT withdrawal NAV
     */
    function maxLTWithdrawal(
        uint256 ltRawNAV,
        uint256 stEffectiveNAV,
        uint256 minLiquidityWAD,
        uint256 dustTolerance
    )
        internal
        pure
        returns (uint256 ltWithdrawable)
    {
        if (minLiquidityWAD == 0) return ltRawNAV;
        uint256 requiredLTValue = Math.mulDiv(stEffectiveNAV + dustTolerance, minLiquidityWAD, WAD, Math.Rounding.Ceil);
        ltWithdrawable = _sat(ltRawNAV, requiredLTValue);
    }

    /**
     * @notice Self-liquidation bonus: min(⌊userClaimNAV · bonusWAD / WAD⌋, jtEffectiveNAV, U-neutral max), active
     *         only once coverage utilization is at or above the liquidation threshold.
     * @dev Mirrors src SelfLiquidationLogic.applySeniorTrancheSelfLiquidationBonus (the bonus NAV computation).
     *      The bonus source does not change the U-neutral bound, so the max is ⌊weighted · jtEffectiveNAV / (exposure − jtEffectiveNAV)⌋.
     *      Early-outs: below the threshold, jtEffectiveNAV == 0, or weighted == 0 return 0.
     *      Rounding: Floor throughout. Favors: JT.
     *      Precondition: exposure > jtEffectiveNAV whenever the bonus is active (the documented positivity lemma).
     * @param in_ The bonus input set
     * @return bonusNAV The self-liquidation bonus in NAV units
     */
    function seniorTrancheSelfLiquidationBonus(SeniorTrancheSelfLiquidationBonusInputs memory in_) internal pure returns (uint256 bonusNAV) {
        if (in_.coverageUtilizationWAD < in_.coverageLiquidationUtilizationWAD) return 0;
        uint256 desiredBonusNAV = Math.mulDiv(in_.userClaimNAV, in_.bonusWAD, WAD);
        uint256 maxNeutralBonusNAV = _maxCoverageUtilizationNeutralBonus(in_);
        bonusNAV = Math.min(Math.min(desiredBonusNAV, in_.jtEffectiveNAV), maxNeutralBonusNAV);
    }

    /**
     * @dev Mirrors src SelfLiquidationLogic.applySeniorTrancheSelfLiquidationBonus (the reported bonus NAV).
     *      The sized bonus is granted entirely in the coinvested collateral asset: it floors into collateral tranche
     *      units at the collateral NAV-per-unit rate and re-values once, so the report is the value of the assets
     *      actually granted (a single value -> assets -> value round trip, replacing the old two-leg split).
     *      Rounding: Floor on both conversion directions. Favors: the market (never overstates).
     * @param in_ The bonus input set
     * @param collateralNAVPerUnitWAD The collateral leg's NAV per tranche unit in WAD
     * @return reportedBonusNAV The asset-quantized self-liquidation bonus in NAV units
     */
    function seniorTrancheSelfLiquidationBonusReported(
        SeniorTrancheSelfLiquidationBonusInputs memory in_,
        uint256 collateralNAVPerUnitWAD
    )
        internal
        pure
        returns (uint256 reportedBonusNAV)
    {
        uint256 bonusNAV = seniorTrancheSelfLiquidationBonus(in_);
        if (bonusNAV == 0) return 0;
        uint256 bonusAssets = Math.mulDiv(bonusNAV, WAD, collateralNAVPerUnitWAD);
        reportedBonusNAV = Math.mulDiv(bonusAssets, collateralNAVPerUnitWAD, WAD);
    }

    /**
     * @notice Adaptive yield model, the AdaptiveCurveYDM_V2 mirror: expWad adaptation of the share at target,
     *         trapezoid averaging (y0 + y1 + 2·ymid) / 4, and the fixed-spread curve output.
     * @dev Mirrors src AdaptiveCurveYDM_V2.yieldShare / previewYieldShare.
     *      Utilization is capped at WAD. The normalized delta is a truncating signed division over the
     *      region's max delta. Adaptation runs only when perpetual: linear = speed · elapsed with
     *      speed = (boundarySpeed · normDelta) / WAD, each adapted point is
     *      clamp(⌊start · expWad(min(linear, MAX_LINEAR_ADAPTATION_WAD)) / WAD⌋, [min, max]), and the midpoint
     *      uses linear / 2 (halved before its own clamp). The curve output adds (normDelta · spread) / WAD to
     *      the averaged share at target, spread = FD_T below target and FP_T at or above, then clamps to
     *      [0, WAD]. Rounding: truncation on the signed divisions, Floor on the expWad product.
     *      Precondition: 0 < targetUtilizationWAD <= WAD.
     * @param in_ The adaptive YDM input set
     * @return out The curve output and the adapted share at target
     */
    function adaptiveCurveYieldShare(AdaptiveCurveYieldShareInputs memory in_) internal pure returns (AdaptiveCurveYieldShareOutputs memory out) {
        uint256 u = in_.utilizationWAD > WAD ? WAD : in_.utilizationWAD;
        uint256 maxDeltaInRegion = u > in_.targetUtilizationWAD ? WAD - in_.targetUtilizationWAD : in_.targetUtilizationWAD;
        int256 normalizedDeltaWAD = ((int256(u) - int256(in_.targetUtilizationWAD)) * int256(WAD)) / int256(maxDeltaInRegion);

        uint256 avgYieldShareAtTargetWAD;
        if (in_.perpetual) {
            int256 speedWAD = (int256(in_.adaptationSpeedAtBoundaryWAD) * normalizedDeltaWAD) / int256(WAD);
            int256 linearAdaptationWAD = speedWAD * int256(in_.elapsedSeconds);
            out.endYieldShareAtTargetWAD = _adaptYieldShareAtTarget(in_, linearAdaptationWAD);
            uint256 midYieldShareAtTargetWAD = _adaptYieldShareAtTarget(in_, linearAdaptationWAD / 2);
            avgYieldShareAtTargetWAD = (in_.startYieldShareAtTargetWAD + out.endYieldShareAtTargetWAD + (2 * midYieldShareAtTargetWAD)) / 4;
        } else {
            out.endYieldShareAtTargetWAD = avgYieldShareAtTargetWAD = in_.startYieldShareAtTargetWAD;
        }

        uint256 maxAdjustment = normalizedDeltaWAD < 0 ? in_.discountToTargetAtZeroUtilWAD : in_.premiumToTargetAtFullUtilWAD;
        int256 adjustment = (normalizedDeltaWAD * int256(maxAdjustment)) / int256(WAD);
        int256 signedYieldShareWAD = int256(avgYieldShareAtTargetWAD) + adjustment;
        if (signedYieldShareWAD <= 0) out.yieldShareWAD = 0;
        else if (signedYieldShareWAD >= int256(WAD)) out.yieldShareWAD = WAD;
        else out.yieldShareWAD = uint256(signedYieldShareWAD);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                PRIVATE HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Saturating subtraction, max(a − b, 0).
    function _sat(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    /// @dev Applies a signed delta to a base, reverting on underflow (precondition of the sync inputs).
    function _applyDelta(uint256 base, int256 delta) private pure returns (uint256) {
        return delta < 0 ? base - uint256(-delta) : base + uint256(delta);
    }

    /**
     * @dev The U-neutral max bonus, mirroring src SelfLiquidationLogic._computeMaxCoverageUtilizationNeutralBonus:
     *      under conservation the exposure minus jtEffectiveNAV is exactly stEffectiveNAV, so the bound is
     *      ⌊userClaimNAV · jtEffectiveNAV / stEffectiveNAV⌋, with the userClaimNAV == 0 early-out. Floor on the
     *      division. The liquidation-branch caller guarantees stEffectiveNAV > 0.
     */
    function _maxCoverageUtilizationNeutralBonus(SeniorTrancheSelfLiquidationBonusInputs memory in_) private pure returns (uint256) {
        if (in_.userClaimNAV == 0) return 0;
        return Math.mulDiv(in_.userClaimNAV, in_.jtEffectiveNAV, in_.stEffectiveNAV);
    }

    /**
     * @dev One adapted point of the adaptive curve: clamp the linear adaptation at MAX_LINEAR_ADAPTATION_WAD, apply
     *      expWad multiplicatively (Floor), then clamp the result to [min, max].
     */
    function _adaptYieldShareAtTarget(
        AdaptiveCurveYieldShareInputs memory in_,
        int256 linearAdaptationWAD
    )
        private
        pure
        returns (uint256 yieldShareAtTargetWAD)
    {
        if (linearAdaptationWAD > MAX_LINEAR_ADAPTATION_WAD) linearAdaptationWAD = MAX_LINEAR_ADAPTATION_WAD;
        yieldShareAtTargetWAD = Math.mulDiv(in_.startYieldShareAtTargetWAD, uint256(FixedPointMathLib.expWad(linearAdaptationWAD)), WAD);
        if (yieldShareAtTargetWAD < in_.minYieldShareAtTargetWAD) return in_.minYieldShareAtTargetWAD;
        if (yieldShareAtTargetWAD > in_.maxYieldShareAtTargetWAD) return in_.maxYieldShareAtTargetWAD;
    }
}
