// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { FixedPointMathLib } from "../../../lib/solady/src/utils/FixedPointMathLib.sol";

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
    /// @notice Raised when a waterfall input set violates the two-term conservation identity after the sync.
    error CONSERVATION_VIOLATED();

    /// @notice Raised when the computed premiums exceed the senior gain, mirroring the production guard.
    error PREMIUMS_EXCEED_SENIOR_YIELD();

    /// @notice WAD fixed-point unit, 1e18 == 100%.
    uint256 internal constant WAD = 1e18;

    /// @notice Independent restatement of the protocol's mint-dilution residual (Constants.sol
    ///         MINT_DILUTION_RESIDUAL_WAD = 1e6, a 1e-12 residual): a single mint owns at most
    ///         (1 − 1e-12) of the post-mint supply. Deliberately NOT imported from src so a silent
    ///         production change diverges from this mirror and fails every cross-assert loudly.
    uint256 internal constant MINT_DILUTION_RESIDUAL = 1e6;

    /// @notice One below solady expWad's overflow threshold, the clamp on the adaptive yield model's linear adaptation.
    int256 internal constant MAX_LINEAR_ADAPTATION_WAD = 135_305_999_368_893_231_589 - 1;

    /// @notice Mirror of the production market-state enum with identical ordinals (PERPETUAL = 0, FIXED_TERM = 1).
    enum MarketState {
        PERPETUAL,
        FIXED_TERM
    }

    /**
     * @title WaterfallIn
     * @notice Complete input set for one sync of the two-term loss waterfall.
     * @custom:field stRawLast - Senior raw NAV at the last committed checkpoint
     * @custom:field jtRawLast - Junior raw NAV at the last committed checkpoint
     * @custom:field stEffLast - Senior effective NAV at the last committed checkpoint
     * @custom:field jtEffLast - Junior effective NAV at the last committed checkpoint
     * @custom:field jtCoverageILLast - JT coverage impermanent loss carried from the last checkpoint
     * @custom:field marketStateLast - Market state committed at the last checkpoint
     * @custom:field fixedTermEndLast - Fixed-term end timestamp committed at the last checkpoint (0 if none)
     * @custom:field stRawDelta - Signed senior raw-NAV delta since the last checkpoint (the attribution input)
     * @custom:field jtRawDelta - Signed junior raw-NAV delta since the last checkpoint
     * @custom:field ltRawNew - Fresh LT raw NAV mark, committed outside the two-term waterfall, pass-through only
     * @custom:field jtTwYieldShareAccrual - Time-weighted JT yield-share accrual Σ shareWAD·Δt over the premium window
     * @custom:field ltTwYieldShareAccrual - Time-weighted LT yield-share accrual Σ shareWAD·Δt over the premium window
     * @custom:field elapsedSincePremiumPayment - Seconds since the last premium payment (0 selects the instantaneous branch)
     * @custom:field jtInstYieldShareWAD - Raw JT previewYieldShare output consumed only by the instantaneous branch
     * @custom:field ltInstYieldShareWAD - Raw LT previewYieldShare output consumed only by the instantaneous branch
     * @custom:field maxJTYieldShareWAD - Cap applied to the instantaneous JT share, ignored on the time-weighted path
     * @custom:field maxLTYieldShareWAD - Cap applied to the instantaneous LT share, ignored on the time-weighted path
     * @custom:field stProtocolFeeWAD - Protocol fee fraction applied to the residual ST gain
     * @custom:field jtProtocolFeeWAD - Protocol fee fraction applied to JT net gain, recomputed after coverage
     * @custom:field jtYieldShareProtocolFeeWAD - Protocol fee fraction applied to the JT risk premium (a distinct rate)
     * @custom:field ltYieldShareProtocolFeeWAD - Protocol fee fraction applied to the LT liquidity premium
     * @custom:field nowTimestamp - Block timestamp of the sync (state-machine predicate input)
     * @custom:field fixedTermDuration - Configured fixed-term duration (0 forces PERPETUAL)
     * @custom:field minCoverageWAD - Minimum coverage fraction (input for the post-sync coverage utilization)
     * @custom:field jtCoinvested - Whether JT raw NAV counts toward coverage exposure (the exposure beta)
     * @custom:field coverageLiquidationUtilizationWAD - Liquidation threshold on coverage utilization
     * @custom:field effectiveDust - Dust tolerance used by the fee gates and the state machine
     * @custom:field minLiquidityWAD - Minimum liquidity fraction (input for the mirror-side liquidity utilization)
     */
    struct WaterfallIn {
        uint256 stRawLast;
        uint256 jtRawLast;
        uint256 stEffLast;
        uint256 jtEffLast;
        uint256 jtCoverageILLast;
        MarketState marketStateLast;
        uint256 fixedTermEndLast;
        int256 stRawDelta;
        int256 jtRawDelta;
        uint256 ltRawNew;
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
        bool jtCoinvested;
        uint256 coverageLiquidationUtilizationWAD;
        uint256 effectiveDust;
        uint256 minLiquidityWAD;
    }

    /**
     * @title WaterfallOut
     * @notice Complete expected post-sync state, mirroring the production checkpoint field-for-field.
     * @custom:field stRaw - Post-sync senior raw NAV (last raw plus the applied delta)
     * @custom:field jtRaw - Post-sync junior raw NAV
     * @custom:field ltRaw - Post-sync LT raw NAV (committed pass-through of ltRawNew)
     * @custom:field stEff - Post-sync senior effective NAV
     * @custom:field jtEff - Post-sync junior effective NAV
     * @custom:field jtCoverageIL - Post-sync JT coverage impermanent loss
     * @custom:field jtRiskPremium - JT risk premium paid out of ST gain on this sync (folded into jtEff, mirror-only observable)
     * @custom:field ltLiquidityPremium - LT liquidity premium carved out of ST gain on this sync
     * @custom:field stProtocolFee - Protocol fee taken on ST gain on this sync
     * @custom:field jtProtocolFee - Protocol fee taken on JT gain and the JT risk premium on this sync
     * @custom:field ltProtocolFee - Protocol fee taken on the LT liquidity premium on this sync
     * @custom:field coverageUtilizationWAD - Coverage utilization at the post-sync marks
     * @custom:field liquidityUtilizationWAD - Liquidity utilization at the post-sync marks (post-commit view)
     * @custom:field marketState - Post-sync market state per the state-machine predicate
     * @custom:field fixedTermEnd - Post-sync fixed-term end timestamp (0 outside FIXED_TERM)
     * @custom:field premiumsPaid - Whether the premium dust gate cleared, driving the accumulator reset
     * @custom:field ilErased - The JT coverage IL erased by a forced-PERPETUAL commit, the exact reset-event arg
     */
    struct WaterfallOut {
        uint256 stRaw;
        uint256 jtRaw;
        uint256 ltRaw;
        uint256 stEff;
        uint256 jtEff;
        uint256 jtCoverageIL;
        uint256 jtRiskPremium;
        uint256 ltLiquidityPremium;
        uint256 stProtocolFee;
        uint256 jtProtocolFee;
        uint256 ltProtocolFee;
        uint256 coverageUtilizationWAD;
        uint256 liquidityUtilizationWAD;
        MarketState marketState;
        uint256 fixedTermEnd;
        bool premiumsPaid;
        uint256 ilErased;
    }

    /**
     * @title Claims
     * @notice Plain-uint256 mirror of the production five-field asset-claims struct.
     * @custom:field stAssets - Claim on senior tranche assets in ST tranche units
     * @custom:field jtAssets - Claim on junior tranche assets in JT tranche units
     * @custom:field ltAssets - Claim on liquidity tranche assets in LT tranche units
     * @custom:field stShares - Claim on senior tranche shares (the LT idle-premium leg)
     * @custom:field nav - Net asset value of the claims in NAV units
     */
    struct Claims {
        uint256 stAssets;
        uint256 jtAssets;
        uint256 ltAssets;
        uint256 stShares;
        uint256 nav;
    }

    /**
     * @title SelfLiqBonusIn
     * @notice Input set for the self-liquidation bonus mirror.
     * @custom:field stRaw - Senior raw NAV at the synced marks
     * @custom:field jtRaw - Junior raw NAV at the synced marks
     * @custom:field jtEff - Junior effective NAV at the synced marks (the bonus source cap)
     * @custom:field jtCoinvested - Whether JT raw NAV counts toward covered exposure
     * @custom:field coverageUtilizationWAD - Coverage utilization at the synced marks
     * @custom:field coverageLiquidationUtilizationWAD - Liquidation threshold gating the bonus (strict-less means inactive)
     * @custom:field bonusWAD - Configured self-liquidation bonus fraction of the redeemed NAV
     * @custom:field userClaimNAV - The redeeming ST user's total claim NAV (the desired-bonus base)
     * @custom:field stUserWeightedClaimNAV - The user's claim on real exposure, ST leg plus JT leg only when co-invested
     */
    struct SelfLiqBonusIn {
        uint256 stRaw;
        uint256 jtRaw;
        uint256 jtEff;
        bool jtCoinvested;
        uint256 coverageUtilizationWAD;
        uint256 coverageLiquidationUtilizationWAD;
        uint256 bonusWAD;
        uint256 userClaimNAV;
        uint256 stUserWeightedClaimNAV;
    }

    /**
     * @title AdaptiveYdmIn
     * @notice Input set for the adaptive-curve yield model mirror (the AdaptiveCurveYDM_V2 shape).
     * @custom:field utilizationWAD - Driving utilization, capped at WAD before evaluation
     * @custom:field targetUtilizationWAD - Utilization at the kink, precondition 0 < targetU <= WAD
     * @custom:field startYieldShareAtTargetWAD - Yield share at target from the last committed adaptation
     * @custom:field elapsedSeconds - Seconds since the last adaptation (0 on the first-ever call)
     * @custom:field discountToTargetAtZeroUtilWAD - Fixed discount below the target share at 0% utilization (FD_T)
     * @custom:field premiumToTargetAtFullUtilWAD - Fixed premium above the target share at 100% utilization (FP_T)
     * @custom:field maxAdaptationSpeedWAD - Max adaptation speed per second, scaled by the normalized delta
     * @custom:field minYieldShareAtTargetWAD - Lower clamp on the adapted share at target (1bp in production)
     * @custom:field maxYieldShareAtTargetWAD - Upper clamp on the adapted share at target (WAD in production)
     * @custom:field perpetual - Whether the market is PERPETUAL, the only state in which the curve adapts
     */
    struct AdaptiveYdmIn {
        uint256 utilizationWAD;
        uint256 targetUtilizationWAD;
        uint256 startYieldShareAtTargetWAD;
        uint256 elapsedSeconds;
        uint256 discountToTargetAtZeroUtilWAD;
        uint256 premiumToTargetAtFullUtilWAD;
        uint256 maxAdaptationSpeedWAD;
        uint256 minYieldShareAtTargetWAD;
        uint256 maxYieldShareAtTargetWAD;
        bool perpetual;
    }

    /**
     * @title AdaptiveYdmOut
     * @notice Output of the adaptive-curve yield model mirror.
     * @custom:field yieldShareWAD - Curve output at the trapezoid-averaged share at target, clamped to [0, WAD]
     * @custom:field endYieldShareAtTargetWAD - Adapted share at target after expWad and the [min, max] clamp
     */
    struct AdaptiveYdmOut {
        uint256 yieldShareWAD;
        uint256 endYieldShareAtTargetWAD;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SINGLE-FORMULA MIRRORS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice PnL attribution: attributed = ⌊|deltaRaw| · claim / lastRaw⌋ with the sign of deltaRaw re-applied.
     * @dev Rounding: Floor on the magnitude (a negative delta attributes toward zero, never away from it).
     *      Favors: the complementary tranche (JT absorbs the flooring residual of the split).
     *      Preconditions: claim <= lastRaw, and lastRaw > 0 whenever deltaRaw != 0 and claim != 0.
     * @param deltaRaw The signed raw-NAV delta being attributed
     * @param claim The attributee's claim on the last committed raw NAV
     * @param lastRaw The last committed raw NAV the claim is measured against
     * @return attributed The signed portion of deltaRaw attributed to the claim
     */
    function attribute(int256 deltaRaw, uint256 claim, uint256 lastRaw) internal pure returns (int256 attributed) {
        if (deltaRaw == 0 || claim == 0) return 0;
        uint256 magnitude;
        unchecked {
            magnitude = deltaRaw < 0 ? uint256(0) - uint256(deltaRaw) : uint256(deltaRaw);
        }
        uint256 attributedMagnitude = Math.mulDiv(magnitude, claim, lastRaw);
        attributed = deltaRaw < 0 ? -int256(attributedMagnitude) : int256(attributedMagnitude);
    }

    /**
     * @notice Coverage utilization: ⌈(stRaw + beta·jtRaw) · minCovWAD / jtEff⌉ where beta is 1 if JT is
     *         co-invested and 0 otherwise.
     * @dev Edges (zero edges take precedence): 0 if minCovWAD == 0 or the exposure is 0, then uint256 max if
     *      jtEff == 0 against a positive requirement.
     *      Rounding: Ceil. Favors: senior (utilization reads high, gating deposits earlier).
     * @param stRaw The senior raw NAV (total, no exclusion)
     * @param jtRaw The junior raw NAV
     * @param jtCoinvested Whether JT raw NAV counts toward covered exposure
     * @param minCovWAD The minimum coverage fraction in WAD
     * @param jtEff The junior effective NAV
     * @return utilizationWAD The coverage utilization in WAD
     */
    function covUtil(uint256 stRaw, uint256 jtRaw, bool jtCoinvested, uint256 minCovWAD, uint256 jtEff) internal pure returns (uint256 utilizationWAD) {
        uint256 exposure = jtCoinvested ? stRaw + jtRaw : stRaw;
        if (minCovWAD == 0 || exposure == 0) return 0;
        if (jtEff == 0) return type(uint256).max;
        utilizationWAD = Math.mulDiv(exposure, minCovWAD, jtEff, Math.Rounding.Ceil);
    }

    /**
     * @notice Liquidity utilization: ⌈stEff · minLiqWAD / ltRaw⌉.
     * @dev Edges (zero edges take precedence): 0 if stEff == 0 or minLiqWAD == 0, then uint256 max if
     *      ltRaw == 0 against a positive requirement.
     *      Rounding: Ceil. Favors: senior (utilization reads high, gating LT redemptions earlier).
     * @param stEff The senior effective NAV
     * @param minLiqWAD The minimum liquidity fraction in WAD
     * @param ltRaw The LT raw NAV (BPT only, idle premium excluded)
     * @return utilizationWAD The liquidity utilization in WAD
     */
    function liqUtil(uint256 stEff, uint256 minLiqWAD, uint256 ltRaw) internal pure returns (uint256 utilizationWAD) {
        if (stEff == 0 || minLiqWAD == 0) return 0;
        if (ltRaw == 0) return type(uint256).max;
        utilizationWAD = Math.mulDiv(stEff, minLiqWAD, ltRaw, Math.Rounding.Ceil);
    }

    /**
     * @notice F9 — shares minted for a value contribution: min(⌊supply · value / totalValue⌋, dilution cap).
     * @dev Edges: supply == 0 mints value 1:1 (totalValue ignored, no clamp — a bootstrap mint dilutes nobody),
     *      and totalValue == 0 with a live supply pins the denominator to 1 wei.
     *      The mint-dilution clamp (amendment to F9): a single mint may own at most (1 − ε/WAD) of the
     *      post-mint supply, ε = MINT_DILUTION_RESIDUAL (this library's own restatement of the protocol
     *      constant — if Constants.sol changes without this mirror, every cross-assert fails loudly). The
     *      shares therefore never exceed cap = ⌊supply · (WAD − ε) / ε⌋. The bind test runs BEFORE the
     *      fair-shares division in its overflow-free form (⌈value·ε/(WAD − ε)⌉ > denominator,
     *      integer-equivalent to fair > cap), mirroring production's ordering exactly — including the panic
     *      surface: the cap mulDiv overflows uint256 once supply ≥ ⌈2^256·ε/(WAD − ε)⌉, exactly when
     *      production's does (load-bearing for the invariant handler's revert prediction).
     *      Rounding: Floor on both branches (the cap floor favors existing holders).
     * @param value The value being contributed
     * @param totalValue The pre-contribution total value backing the supply
     * @param supply The pre-contribution share supply
     * @return shares The shares minted for the contribution
     */
    function sharesFor(uint256 value, uint256 totalValue, uint256 supply) internal pure returns (uint256 shares) {
        if (supply == 0) return value;
        uint256 denominator = totalValue == 0 ? 1 : totalValue;
        if (Math.mulDiv(value, MINT_DILUTION_RESIDUAL, WAD - MINT_DILUTION_RESIDUAL, Math.Rounding.Ceil) > denominator) {
            return Math.mulDiv(supply, WAD - MINT_DILUTION_RESIDUAL, MINT_DILUTION_RESIDUAL);
        }
        shares = Math.mulDiv(supply, value, denominator);
    }

    /**
     * @notice Value redeemed for shares: ⌊totalValue · shares / supply⌋.
     * @dev Edge: supply == 0 returns 0. Rounding: Floor. Favors: remaining holders.
     * @param shares The shares being valued
     * @param totalValue The total value backing the supply
     * @param supply The share supply
     * @return value The value of the shares
     */
    function valueFor(uint256 shares, uint256 totalValue, uint256 supply) internal pure returns (uint256 value) {
        if (supply == 0) return 0;
        value = Math.mulDiv(totalValue, shares, supply);
    }

    /**
     * @notice The ST fee / liquidity-premium carve-out share mints, both computed at the pre-sync supply
     *         over the retained denominator stEff − premium − fee.
     * @dev Each mint is an F9 share computation over the retained NAV, so the F9 edges apply per leg
     *      (pre-sync supply 0 mints 1:1, retained NAV 0 pins the denominator to 1 wei) — including the
     *      mint-dilution clamp, which applies PER MINT at the shared pre-sync supply: in the degenerate
     *      zero-retained state both legs clamp to the same cap, so the pair may own up to 2·cap/(preSupply + 2·cap)
     *      of the post-mint supply (the residual guarantee is per mint, not per sync).
     *      Rounding: Floor on both mints. Favors: pre-existing ST shares.
     *      Precondition: premium + fee <= stEff (guaranteed upstream by the waterfall).
     * @param stEff The post-waterfall senior effective NAV
     * @param premium The LT liquidity premium to mint as ST shares
     * @param fee The ST protocol fee to mint as ST shares
     * @param preSupply The pre-sync ST share supply
     * @return premiumShares The ST shares minted for the liquidity premium
     * @return feeShares The ST shares minted for the protocol fee
     * @return supplyAfter The ST share supply after both mints
     */
    function carveOut(
        uint256 stEff,
        uint256 premium,
        uint256 fee,
        uint256 preSupply
    )
        internal
        pure
        returns (uint256 premiumShares, uint256 feeShares, uint256 supplyAfter)
    {
        uint256 retained = stEff - premium - fee;
        premiumShares = sharesFor(premium, retained, preSupply);
        feeShares = sharesFor(fee, retained, preSupply);
        supplyAfter = preSupply + premiumShares + feeShares;
    }

    /**
     * @notice Claim scaling: every one of the five claim fields scales as ⌊claim · shares / totalShares⌋.
     * @dev Rounding: Floor on all five fields. Favors: remaining LPs.
     *      Precondition: totalShares > 0 (production scales a redeemer's slice of a live tranche supply).
     * @param total The total claims being sliced
     * @param shares The redeemer's shares
     * @param totalShares The tranche's total share supply
     * @return scaled The redeemer's pro-rata claims
     */
    function scaleClaims(Claims memory total, uint256 shares, uint256 totalShares) internal pure returns (Claims memory scaled) {
        scaled.stAssets = Math.mulDiv(total.stAssets, shares, totalShares);
        scaled.jtAssets = Math.mulDiv(total.jtAssets, shares, totalShares);
        scaled.ltAssets = Math.mulDiv(total.ltAssets, shares, totalShares);
        scaled.stShares = Math.mulDiv(total.stShares, shares, totalShares);
        scaled.nav = Math.mulDiv(total.nav, shares, totalShares);
    }

    /**
     * @notice LT effective NAV: ltRaw + ⌊idleShares · stEff / stSupply⌋, the BPT depth plus the claimable
     *         idle-premium leg valued at the senior share price.
     * @dev The idle leg is a valueFor valuation, so stSupply == 0 values it at 0.
     *      Rounding: Floor on the idle leg. Favors: pool leg.
     * @param ltRaw The LT raw NAV (BPT only)
     * @param idleShares The staged, not-yet-deployed premium ST shares held for the LT
     * @param stEff The senior effective NAV
     * @param stSupply The senior share supply
     * @return effNav The LT effective NAV
     */
    function ltEffNav(uint256 ltRaw, uint256 idleShares, uint256 stEff, uint256 stSupply) internal pure returns (uint256 effNav) {
        effNav = ltRaw + valueFor(idleShares, stEff, stSupply);
    }

    /**
     * @notice Static yield model: a piecewise-linear 3-point yield curve through (0, y0), (targetU, yTarget) and
     *         (WAD, yFull), evaluated as ⌊slope · u / WAD⌋ + intercept per segment.
     * @dev The driving utilization is capped at WAD before evaluation and the result is capped at WAD after.
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
    function staticYdm(uint256 u, uint256 y0, uint256 yTarget, uint256 yFull, uint256 targetU) internal pure returns (uint256 yWAD) {
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
     * @notice The full two-term sync mirror, composing attribution, coverage, premiums, fees, and the state machine.
     * @dev Pipeline: claims decomposition, attribution (with the zero-lastSTRaw special case), the JT leg with
     *      its dust-gated fee, the ST loss leg with coverage and the JT-fee recompute, the ST gain leg with IL
     *      recovery first and the premium block (instantaneous branch when elapsedSincePremiumPayment == 0),
     *      the byte-exact conservation check, and the state machine including dust-IL FIXED_TERM
     *      stickiness and the FIXED_TERM fee zeroing.
     *      Mirror-side extras vs the raw production return: out.ltRaw echoes in.ltRawNew and
     *      out.liquidityUtilizationWAD is the post-commit view (production returns (0, 0) placeholders).
     *      Preconditions: stRawLast + jtRawLast == stEffLast + jtEffLast, deltas do not underflow their raws,
     *      and elapsedSincePremiumPayment · WAD fits uint256.
     * @param in_ The complete waterfall input set
     * @return out The complete expected post-sync state
     */
    function waterfall(WaterfallIn memory in_) internal pure returns (WaterfallOut memory out) {
        // Claims decomposition from the last committed checkpoint (at most one cross-claim is nonzero)
        uint256 stClaimOnJTRaw = _sat(in_.stEffLast, in_.stRawLast);
        uint256 jtClaimOnSTRaw = _sat(in_.jtEffLast, in_.jtRawLast);
        uint256 stClaimOnSTRaw = in_.stRawLast - jtClaimOnSTRaw;

        // Fresh raws from the signed deltas
        out.stRaw = _applyDelta(in_.stRawLast, in_.stRawDelta);
        out.jtRaw = _applyDelta(in_.jtRawLast, in_.jtRawDelta);
        out.ltRaw = in_.ltRawNew;

        // Attribution: floors on the magnitude, JT absorbs all rounding drift on both signs
        int256 deltaSTClaimOnSTRaw;
        if (in_.stRawLast == 0) {
            // Zero-lastSTRaw special case: route the whole senior delta to ST iff ST has effective value
            deltaSTClaimOnSTRaw = in_.stEffLast > 0 ? in_.stRawDelta : int256(0);
        } else {
            deltaSTClaimOnSTRaw = attribute(in_.stRawDelta, stClaimOnSTRaw, in_.stRawLast);
        }
        int256 deltaSTEff = deltaSTClaimOnSTRaw + attribute(in_.jtRawDelta, stClaimOnJTRaw, in_.jtRawLast);
        int256 deltaJTEff = (in_.stRawDelta + in_.jtRawDelta) - deltaSTEff;

        uint256 stEff = in_.stEffLast;
        uint256 jtEff = in_.jtEffLast;
        uint256 il = in_.jtCoverageILLast;
        uint256 jtNetGain;

        // JT leg first: losses are unfee'd, gains take the dust-gated jtProtocolFeeWAD fee (Floor)
        if (deltaJTEff < 0) {
            jtEff -= uint256(-deltaJTEff);
        } else if (deltaJTEff > 0) {
            jtNetGain = uint256(deltaJTEff);
            if (jtNetGain > in_.effectiveDust) out.jtProtocolFee = Math.mulDiv(jtNetGain, in_.jtProtocolFeeWAD, WAD);
            jtEff += jtNetGain;
        }

        if (deltaSTEff < 0) {
            // ST loss: coverage from the post-JT-leg jtEff, then the JT-fee recompute, residual loss to ST
            uint256 stLoss = uint256(-deltaSTEff);
            uint256 coverageApplied = Math.min(stLoss, jtEff);
            if (coverageApplied != 0 && out.jtProtocolFee != 0) {
                jtNetGain = _sat(jtNetGain, coverageApplied);
                out.jtProtocolFee = jtNetGain > in_.effectiveDust ? Math.mulDiv(jtNetGain, in_.jtProtocolFeeWAD, WAD) : 0;
            }
            jtEff -= coverageApplied;
            il += coverageApplied;
            stLoss -= coverageApplied;
            if (stLoss != 0) stEff -= stLoss;
        } else if (deltaSTEff > 0) {
            // ST gain: IL recovery FIRST, exact and never fee'd
            uint256 stGain = uint256(deltaSTEff);
            uint256 recovered = Math.min(stGain, il);
            il -= recovered;
            jtEff += recovered;
            stGain -= recovered;

            if (stGain != 0) {
                // Premium block: the dust gate drives fees and the accumulator reset, not the premiums
                out.premiumsPaid = stGain > in_.effectiveDust;
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
                    jtEff += out.jtRiskPremium;
                    stGain -= out.jtRiskPremium;
                }
                if (out.ltLiquidityPremium != 0) {
                    if (out.premiumsPaid) out.ltProtocolFee = Math.mulDiv(out.ltLiquidityPremium, in_.ltYieldShareProtocolFeeWAD, WAD);
                    stGain -= out.ltLiquidityPremium;
                }
                if (out.premiumsPaid) out.stProtocolFee = Math.mulDiv(stGain, in_.stProtocolFeeWAD, WAD);
                // The LT premium stays a senior claim, so it is re-added after sizing plain ST's retention
                stEff += stGain + out.ltLiquidityPremium;
            }
        }

        // Two-term conservation at wei precision
        require(out.stRaw + out.jtRaw == stEff + jtEff, CONSERVATION_VIOLATED());

        // State machine on the fresh raws and the post-waterfall jtEff
        out.coverageUtilizationWAD = covUtil(out.stRaw, out.jtRaw, in_.jtCoinvested, in_.minCoverageWAD, jtEff);
        bool forcedPerpetual = in_.fixedTermDuration == 0 || (in_.marketStateLast == MarketState.FIXED_TERM && in_.fixedTermEndLast <= in_.nowTimestamp)
            || out.coverageUtilizationWAD >= in_.coverageLiquidationUtilizationWAD || (jtEff == 0 && stEff > 0);
        if (forcedPerpetual) {
            // Forced PERPETUAL erases the IL and clears the term
            out.ilErased = il;
            il = 0;
            out.marketState = MarketState.PERPETUAL;
        } else if (il <= in_.effectiveDust) {
            if (in_.marketStateLast == MarketState.PERPETUAL || il == 0) {
                // Dust IL persists un-erased through a PERPETUAL commit and remains recoverable
                out.marketState = MarketState.PERPETUAL;
            } else {
                // Dust-IL FIXED_TERM stickiness: keep the original end and zero the four fee/premium fields
                out.marketState = MarketState.FIXED_TERM;
                out.fixedTermEnd = in_.fixedTermEndLast;
                (out.ltLiquidityPremium, out.stProtocolFee, out.jtProtocolFee, out.ltProtocolFee) = (0, 0, 0, 0);
            }
        } else {
            // FIXED_TERM commit: zero the four fields, stamp the end only on the PERPETUAL -> FIXED_TERM edge
            out.marketState = MarketState.FIXED_TERM;
            (out.ltLiquidityPremium, out.stProtocolFee, out.jtProtocolFee, out.ltProtocolFee) = (0, 0, 0, 0);
            out.fixedTermEnd = in_.marketStateLast == MarketState.PERPETUAL ? uint256(uint32(in_.nowTimestamp + in_.fixedTermDuration)) : in_.fixedTermEndLast;
        }

        out.stEff = stEff;
        out.jtEff = jtEff;
        out.jtCoverageIL = il;
        out.liquidityUtilizationWAD = liqUtil(stEff, in_.minLiquidityWAD, in_.ltRawNew);
    }

    /**
     * @notice Max ST deposit: min of the coverage-leg and liquidity-leg inversions, each minus dust slack.
     * @dev Coverage leg: ⌊jtEff · WAD / minCovWAD⌋ − ((jtCoinvested ? jtRaw : 0) + jtDust + stRaw + stDust),
     *      saturating. The jtDust term applies regardless of co-investment. Liquidity leg:
     *      ⌊ltRaw · WAD / minLiqWAD⌋ − (stEff + stDust), saturating. A zero requirement disables its leg
     *      (uint256 max). Rounding: Floor on both inversions. Favors: protocol (the max reads low).
     * @param stRaw The senior raw NAV at the synced marks
     * @param jtRaw The junior raw NAV at the synced marks
     * @param stEff The senior effective NAV at the synced marks
     * @param jtEff The junior effective NAV at the synced marks
     * @param ltRaw The LT raw NAV at the synced marks
     * @param jtCoinvested Whether JT raw NAV counts toward covered exposure
     * @param minCovWAD The minimum coverage fraction in WAD
     * @param minLiqWAD The minimum liquidity fraction in WAD
     * @param stDust The ST NAV dust tolerance
     * @param jtDust The JT NAV dust tolerance
     * @return maxDeposit The maximum ST deposit NAV
     */
    function maxSTDeposit(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 jtEff,
        uint256 ltRaw,
        bool jtCoinvested,
        uint256 minCovWAD,
        uint256 minLiqWAD,
        uint256 stDust,
        uint256 jtDust
    )
        internal
        pure
        returns (uint256 maxDeposit)
    {
        uint256 maxGivenCoverage = type(uint256).max;
        if (minCovWAD != 0) {
            uint256 totalCoveredValue = Math.mulDiv(jtEff, WAD, minCovWAD);
            maxGivenCoverage = _sat(totalCoveredValue, (jtCoinvested ? jtRaw : 0) + jtDust + stRaw + stDust);
        }
        uint256 maxGivenLiquidity = type(uint256).max;
        if (minLiqWAD != 0) {
            uint256 maxSTEffectiveNAV = Math.mulDiv(ltRaw, WAD, minLiqWAD);
            maxGivenLiquidity = _sat(maxSTEffectiveNAV, stEff + stDust);
        }
        maxDeposit = Math.min(maxGivenCoverage, maxGivenLiquidity);
    }

    /**
     * @notice Max JT withdrawal: the coverage-surplus inversion with claim-fraction floors, the coverage
     *         retention denominator, and the +2 wei fudge, split into per-tranche withdrawable NAVs.
     * @dev surplus = sat(jtEff − (⌈exposure · minCovWAD / WAD⌉ + stDust + (jtCoinvested ? jtDust : 0) + 2)),
     *      where the +2 wei absorbs the worst-case inner-ceil rounding of the coverage utilization check.
     *      Fractions floor over totalJTClaims, retention = WAD − ⌊minCovWAD · (stFrac + beta·jtFrac) / WAD⌋,
     *      totalClaimable = ⌊surplus · WAD / retention⌋, and each split floors again.
     *      Early-outs return (0, 0) on zero surplus, zero total claims, or zero claimable.
     *      Rounding: mixed as stated. Favors: protocol. Precondition: retention > 0.
     * @param stRaw The senior raw NAV at the synced marks
     * @param jtRaw The junior raw NAV at the synced marks
     * @param stEff The senior effective NAV at the synced marks
     * @param jtEff The junior effective NAV at the synced marks
     * @param jtCoinvested Whether JT raw NAV counts toward covered exposure
     * @param minCovWAD The minimum coverage fraction in WAD
     * @param stDust The ST NAV dust tolerance
     * @param jtDust The JT NAV dust tolerance
     * @return stWithdrawable The JT-withdrawable NAV sourced from the ST raw NAV
     * @return jtWithdrawable The JT-withdrawable NAV sourced from the JT raw NAV
     */
    function maxJTWithdrawal(
        uint256 stRaw,
        uint256 jtRaw,
        uint256 stEff,
        uint256 jtEff,
        bool jtCoinvested,
        uint256 minCovWAD,
        uint256 stDust,
        uint256 jtDust
    )
        internal
        pure
        returns (uint256 stWithdrawable, uint256 jtWithdrawable)
    {
        uint256 jtClaimOnSTRaw = _sat(jtEff, jtRaw);
        uint256 jtClaimOnJTRaw = jtRaw - _sat(stEff, stRaw);

        uint256 exposure = stRaw + (jtCoinvested ? jtRaw : 0);
        uint256 requiredJTValue = Math.mulDiv(exposure, minCovWAD, WAD, Math.Rounding.Ceil);
        uint256 surplus = _sat(jtEff, requiredJTValue + stDust + (jtCoinvested ? jtDust : 0) + 2);
        if (surplus == 0) return (0, 0);

        uint256 totalJTClaims = jtClaimOnSTRaw + jtClaimOnJTRaw;
        if (totalJTClaims == 0) return (0, 0);
        uint256 stFracWAD = Math.mulDiv(jtClaimOnSTRaw, WAD, totalJTClaims);
        uint256 jtFracWAD = Math.mulDiv(jtClaimOnJTRaw, WAD, totalJTClaims);
        uint256 retentionWAD = WAD - Math.mulDiv(minCovWAD, stFracWAD + (jtCoinvested ? jtFracWAD : 0), WAD);
        uint256 totalNAVClaimable = Math.mulDiv(surplus, WAD, retentionWAD);
        if (totalNAVClaimable == 0) return (0, 0);

        stWithdrawable = Math.mulDiv(totalNAVClaimable, stFracWAD, WAD);
        jtWithdrawable = Math.mulDiv(totalNAVClaimable, jtFracWAD, WAD);
    }

    /**
     * @notice Max LT withdrawal: ltRaw − (⌈stEff · minLiqWAD / WAD⌉ + stDust), saturating.
     * @dev Bypasses (full ltRaw): minLiqWAD == 0, or covUtilWAD >= covLiqUtilWAD (liquidation breached, the
     *      comparison is >= so the exact threshold bypasses).
     *      Rounding: Ceil on the required depth. Favors: senior (the max reads low).
     * @param ltRaw The LT raw NAV at the synced marks
     * @param stEff The senior effective NAV at the synced marks
     * @param minLiqWAD The minimum liquidity fraction in WAD
     * @param stDust The ST NAV dust tolerance
     * @param covUtilWAD The coverage utilization at the synced marks
     * @param covLiqUtilWAD The coverage liquidation utilization threshold in WAD
     * @return ltWithdrawable The maximum LT withdrawal NAV
     */
    function maxLTWithdrawal(
        uint256 ltRaw,
        uint256 stEff,
        uint256 minLiqWAD,
        uint256 stDust,
        uint256 covUtilWAD,
        uint256 covLiqUtilWAD
    )
        internal
        pure
        returns (uint256 ltWithdrawable)
    {
        if (minLiqWAD == 0 || covUtilWAD >= covLiqUtilWAD) return ltRaw;
        uint256 requiredLTValue = Math.mulDiv(stEff, minLiqWAD, WAD, Math.Rounding.Ceil);
        ltWithdrawable = _sat(ltRaw, requiredLTValue + stDust);
    }

    /**
     * @notice Self-liquidation bonus: min(⌊userClaimNAV · bonusWAD / WAD⌋, jtEff, U-neutral max), active
     *         only once coverage utilization is at or above the liquidation threshold.
     * @dev The U-neutral max sources ST-claim capital first. Case 1 (entirely from JT's claim on ST):
     *      ⌊weighted · jtEff / (exposure − jtEff)⌋, taken iff it fits within jtClaimOnSTRaw = sat(jtEff − jtRaw).
     *      Case 2 (crossing into JT's self-claim):
     *      ⌊(weighted + (jtCoinvested ? 0 : jtClaimOnSTRaw)) · jtEff / (exposure − (jtCoinvested ? jtEff : 0))⌋.
     *      Early-outs: below the threshold, jtEff == 0, or weighted == 0 return 0.
     *      Rounding: Floor throughout. Favors: JT.
     *      Precondition: exposure > jtEff whenever the bonus is active (the documented positivity lemma).
     * @param in_ The bonus input set
     * @return bonusNAV The self-liquidation bonus in NAV units
     */
    function selfLiqBonus(SelfLiqBonusIn memory in_) internal pure returns (uint256 bonusNAV) {
        if (in_.coverageUtilizationWAD < in_.coverageLiquidationUtilizationWAD) return 0;
        uint256 desiredBonusNAV = Math.mulDiv(in_.userClaimNAV, in_.bonusWAD, WAD);
        uint256 jtClaimOnSTRaw = _sat(in_.jtEff, in_.jtRaw);
        uint256 maxNeutralBonusNAV = _maxCoverageUtilizationNeutralBonus(in_, jtClaimOnSTRaw);
        bonusNAV = Math.min(Math.min(desiredBonusNAV, in_.jtEff), maxNeutralBonusNAV);
    }

    /**
     * @notice Adaptive yield model, the AdaptiveCurveYDM_V2 mirror: expWad adaptation of the share at target,
     *         trapezoid averaging (y0 + y1 + 2·ymid) / 4, and the fixed-spread curve output.
     * @dev Utilization is capped at WAD. The normalized delta is a truncating signed division over the
     *      region's max delta. Adaptation runs only when perpetual: linear = speed · elapsed with
     *      speed = (maxSpeed · normDelta) / WAD, each adapted point is
     *      clamp(⌊start · expWad(min(linear, MAX_LINEAR_ADAPTATION_WAD)) / WAD⌋, [min, max]), and the midpoint
     *      uses linear / 2 (halved before its own clamp). The curve output adds (normDelta · spread) / WAD to
     *      the averaged share at target, spread = FD_T below target and FP_T at or above, then clamps to
     *      [0, WAD]. Rounding: truncation on the signed divisions, Floor on the expWad product.
     *      Precondition: 0 < targetUtilizationWAD <= WAD.
     * @param in_ The adaptive YDM input set
     * @return out The curve output and the adapted share at target
     */
    function adaptiveYdm(AdaptiveYdmIn memory in_) internal pure returns (AdaptiveYdmOut memory out) {
        uint256 u = in_.utilizationWAD > WAD ? WAD : in_.utilizationWAD;
        uint256 maxDeltaInRegion = u > in_.targetUtilizationWAD ? WAD - in_.targetUtilizationWAD : in_.targetUtilizationWAD;
        int256 normalizedDeltaWAD = ((int256(u) - int256(in_.targetUtilizationWAD)) * int256(WAD)) / int256(maxDeltaInRegion);

        uint256 avgYieldShareAtTargetWAD;
        if (in_.perpetual) {
            int256 speedWAD = (int256(in_.maxAdaptationSpeedWAD) * normalizedDeltaWAD) / int256(WAD);
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

    /// @dev Applies a signed delta to a base, reverting on underflow (precondition of the waterfall inputs).
    function _applyDelta(uint256 base, int256 delta) private pure returns (uint256) {
        return delta < 0 ? base - uint256(-delta) : base + uint256(delta);
    }

    /**
     * @dev The U-neutral max bonus, ST-claim sourced first (case 1) then crossing into the JT self-claim
     *      (case 2), with the jtEff == 0 and weighted == 0 early-outs. Floor on both divisions.
     */
    function _maxCoverageUtilizationNeutralBonus(SelfLiqBonusIn memory in_, uint256 jtClaimOnSTRaw) private pure returns (uint256) {
        if (in_.jtEff == 0) return 0;
        if (in_.stUserWeightedClaimNAV == 0) return 0;
        uint256 exposure = in_.stRaw + (in_.jtCoinvested ? in_.jtRaw : 0);
        uint256 stSourcedMax = Math.mulDiv(in_.stUserWeightedClaimNAV, in_.jtEff, exposure - in_.jtEff);
        if (stSourcedMax <= jtClaimOnSTRaw) return stSourcedMax;
        uint256 adjustedWeightedClaim = in_.stUserWeightedClaimNAV + (in_.jtCoinvested ? 0 : jtClaimOnSTRaw);
        return Math.mulDiv(adjustedWeightedClaim, in_.jtEff, exposure - (in_.jtCoinvested ? in_.jtEff : 0));
    }

    /**
     * @dev One adapted point of the adaptive curve: clamp the linear adaptation at MAX_LINEAR_ADAPTATION_WAD, apply
     *      expWad multiplicatively (Floor), then clamp the result to [min, max].
     */
    function _adaptYieldShareAtTarget(AdaptiveYdmIn memory in_, int256 linearAdaptationWAD) private pure returns (uint256 yieldShareAtTargetWAD) {
        if (linearAdaptationWAD > MAX_LINEAR_ADAPTATION_WAD) linearAdaptationWAD = MAX_LINEAR_ADAPTATION_WAD;
        yieldShareAtTargetWAD = Math.mulDiv(in_.startYieldShareAtTargetWAD, uint256(FixedPointMathLib.expWad(linearAdaptationWAD)), WAD);
        if (yieldShareAtTargetWAD < in_.minYieldShareAtTargetWAD) return in_.minYieldShareAtTargetWAD;
        if (yieldShareAtTargetWAD > in_.maxYieldShareAtTargetWAD) return in_.maxYieldShareAtTargetWAD;
    }
}
