/*
 * Capacity Math of RoycoDayAccountant
 * ==================================================================================================
 * Component under verification: the three advisory, view-only capacity functions
 *   - maxSTDeposit(SyncedAccountingState)      -> largest senior deposit consistent with the
 *                                                 coverage AND liquidity requirements
 *   - maxJTWithdrawal(SyncedAccountingState)   -> largest junior exit consistent with coverage
 *   - maxLPTWithdrawal(SyncedAccountingState)  -> largest venue-depth exit consistent with liquidity
 *
 * All three take a caller-supplied, in-memory SyncedAccountingState packet and read exactly one
 * storage field of the accountant: $.dustTolerance.
 *
 * NOTATION USED THROUGHOUT (all NAV quantities in raw NAV units, all ratios in WAD)
 *   C = state.collateralNAV     S = state.stEffectiveNAV    J = state.jtEffectiveNAV
 *   P = state.lptRawNAV         c = state.minCoverageWAD    l = state.minLiquidityWAD
 *   D = $.dustTolerance         W = WAD = 1e18
 *
 * THE AUTHORITATIVE GATES (src/libraries/logic/AccountingSyncLogic.sol :: postOpSyncTrancheAccounting)
 *   ST_DEPOSIT | JT_REDEMPTION : coverageUtilizationWAD  <= WAD
 *   ST_DEPOSIT | LPT_REDEMPTION: liquidityUtilizationWAD <= WAD
 *   JT_DEPOSIT                 : coverageUtilizationWAD  <  coverageLiquidationUtilizationWAD
 * with the utilizations computed by UtilizationLogic (exercised verbatim through the harness
 * wrappers coverageUtilizationRaw / liquidityUtilizationRaw, so the spec compares the advisory
 * figures against the *real* gate math rather than a re-implementation of it).
 *
 * HARNESS
 * NAV_UNIT is a Solidity user-defined value type; CVL cannot perform arithmetic on UDVTs
 * (cvl doc-ref 8bc8fa62f2da549faa395d375151762ad34c434b8ad818), so every capacity view is reached
 * through a plain-uint256 wrapper on RoycoDayAccountantHarness which forwards to the real,
 * unmodified function body. The harness also exposes two verification-only, unauthenticated storage
 * writers (harnessSetDustTolerance / harnessSetCapacityIrrelevantState) so that the admin-settable
 * configuration can be quantified over inside a single rule. Those writers are NOT part of the
 * deployed surface; no rule below relies on them modelling the real access control.
 *
 * IMPORTED SUMMARIES - what is replaced by a model, and why that is faithful for these properties
 *  - summaries/RoycoDayAccountant_base_summaries.spec pulls in EIP712, FixedPointMathLib, OZ_Math,
 *    OZ_SafeERC20, OZ_ShortStrings and OZ_Strings. Of these only OZ_Math touches the capacity math:
 *    it summarizes Math.mulDiv (both overloads), Math.average and Math.sqrt. The mulDiv summary
 *    (certora/specs/summaries/Math.spec) is a BIT-EXACT mathint transcription of OpenZeppelin's
 *    512-bit mulDiv: x*y/d for Math.Rounding.Floor, (x*y + d - 1)/d for Ceil, reverting exactly
 *    when the denominator is zero or the result exceeds 2^256 - 1. It is an exact model, not an
 *    abstraction, so the rounding direction that every property below is about is the
 *    implementation's own rounding, not the model's. Math.average / Math.sqrt are likewise exact
 *    and lie on no capacity code path. Math.saturatingSub, RoycoUnitsMath.min and the NAV_UNIT
 *    wrappers are NOT summarized: that code runs for real.
 *  - summaries/custom_summaries.spec summarizes only the four out-of-protocol actors the accountant
 *    reaches transitively (Chainlink feeds, the Chainalysis sanctions list, Idle's virtualPrice,
 *    Makina's accounting clock and convertToAssets) with ghost-backed, view-only expression
 *    summaries. None of them is reachable from the three capacity views, which call into no contract
 *    other than the accountant itself.
 *
 * STANDING ASSUMPTIONS (each stated at its use site as well)
 *  A1. Configuration invariants on the *packet's* ratio fields: c < WAD and l < WAD. On the storage
 *      side these are enforced by initialize() and by the setters and are proved as invariants in
 *      certora/invariants.spec (minCoverage < WAD, minLiquidity < WAD). The packet is in memory and
 *      is NOT validated by the views (property 13 demonstrates exactly that), so the storage-side
 *      invariant does not by itself discharge the packet-side assumption: what discharges it is the
 *      call-site fact that the kernel only ever passes packets produced by a real (pre)sync, which
 *      copies the stored ratios verbatim. That is a KERNEL-SIDE OBLIGATION, recorded here as such,
 *      to be verified by a kernel/entry-point spec. c == WAD would make the (WAD - c) divisor of
 *      maxJTWithdrawal zero (property 11).
 *  A2. Realistic magnitudes: every NAV quantity and the dust tolerance are <= 1e36 raw NAV units
 *      (= 1e18 whole units of account at WAD precision). This bounds every intermediate product so
 *      that no 512-bit mulDiv can overflow; it is the "realistic bounds" clause of property 11.
 *  A3. NAV conservation C == S + J, where required. On the storage side this is the invariant the
 *      accountant enforces on every post-op sync (NAV_CONSERVATION_VIOLATION) and is proved as the
 *      nav_conservation invariant in certora/invariants.spec. As with A1, for the *packet* it is a
 *      kernel-side obligation ("only sync-produced packets are ever passed"), recorded as such.
 *      Rules that deliberately drop it (property 13) say so explicitly.
 */

import "summaries/RoycoDayAccountant_base_summaries.spec";
import "summaries/custom_summaries.spec";

using RoycoDayAccountantHarness as harness;

// ==================================================================================================
// Constants and pure math helpers (mathint mirrors of the exact closed forms)
// ==================================================================================================

/// @notice WAD, the fixed-point scale of every ratio in the accountant
definition WAD() returns mathint = 1000000000000000000;

/// @notice MAX_NAV_UNITS: the "unbounded capacity" sentinel returned by maxSTDeposit
definition MAX_NAV_UNITS_() returns mathint = max_uint256;

/// @notice Upper bound on realistic NAV magnitudes (assumption A2): 1e18 whole units of account
definition NAV_BOUND() returns mathint = 1000000000000000000000000000000000000;

/// @notice Floor division, defended against a zero divisor (the zero-divisor branch is never used)
function floorDivM(mathint a, mathint b) returns mathint {
    return (b == 0) ? 0 : (a / b);
}

/// @notice Ceiling division, defended against a zero divisor (the zero-divisor branch is never used)
function ceilDivM(mathint a, mathint b) returns mathint {
    return (b == 0) ? 0 : ((a + b - 1) / b);
}

/// @notice max(a - b, 0), mirroring Math.saturatingSub
function satSubM(mathint a, mathint b) returns mathint {
    return (a > b) ? (a - b) : 0;
}

/// @notice min(a, b)
function minM(mathint a, mathint b) returns mathint {
    return (a < b) ? a : b;
}

/**
 * @notice The exact coverage leg of maxSTDeposit: the largest x with (C + x) * c <= J * W, padded by D
 * @dev c == 0 switches the coverage requirement off, so the leg is the MAX_NAV_UNITS sentinel
 */
function covLegExact(mathint C, mathint J, mathint c, mathint D) returns mathint {
    return (c == 0) ? MAX_NAV_UNITS_() : satSubM(floorDivM(J * WAD(), c), C + D);
}

/**
 * @notice The exact liquidity leg of maxSTDeposit: the largest x with (S + x) * l <= P * W, padded by D
 * @dev l == 0 switches the liquidity requirement off, so the leg is the MAX_NAV_UNITS sentinel
 */
function liqLegExact(mathint P, mathint S, mathint l, mathint D) returns mathint {
    return (l == 0) ? MAX_NAV_UNITS_() : satSubM(floorDivM(P * WAD(), l), S + D);
}

/// @notice The exact closed form of maxJTWithdrawal: floor(satSub(J, ceil((C+D)*c/W)) * W / (W - c))
function maxJTWithdrawalExact(mathint C, mathint J, mathint c, mathint D) returns mathint {
    return floorDivM(satSubM(J, ceilDivM((C + D) * c, WAD())) * WAD(), WAD() - c);
}

/// @notice The exact closed form of maxLPTWithdrawal: l == 0 ? P : satSub(P, ceil((S+D)*l/W))
function maxLPTWithdrawalExact(mathint P, mathint S, mathint l, mathint D) returns mathint {
    return (l == 0) ? P : satSubM(P, ceilDivM((S + D) * l, WAD()));
}

// ==================================================================================================
// State-packet construction and standing assumptions
// ==================================================================================================

/**
 * @notice Builds a caller-supplied capacity packet pinning ONLY the six requirement-relevant fields
 * @dev Every other field (marketState, jtImpermanentLoss, the premiums and fees, the two cached
 *      utilizations, coverageLiquidationUtilizationWAD, fixedTermEndTimestamp) is left completely
 *      unconstrained, so every rule below is automatically quantified over them. Two separate calls
 *      produce two independently non-deterministic packets that agree on the six pinned fields,
 *      which is exactly what property 17 needs.
 */
function capacityState(uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l)
    returns RoycoDayAccountantHarness.RawSyncedAccountingState
{
    RoycoDayAccountantHarness.RawSyncedAccountingState st;
    require st.collateralNAV == C;
    require st.lptRawNAV == P;
    require st.stEffectiveNAV == S;
    require st.jtEffectiveNAV == J;
    require st.minCoverageWAD == c;
    require st.minLiquidityWAD == l;
    return st;
}

/// @notice Assumption A2: realistic NAV magnitudes, which preclude any 512-bit mulDiv overflow
function requireRealisticMagnitudes(uint256 C, uint256 P, uint256 S, uint256 J, uint256 D) {
    require C <= NAV_BOUND();
    require P <= NAV_BOUND();
    require S <= NAV_BOUND();
    require J <= NAV_BOUND();
    require D <= NAV_BOUND();
    return;
}

/// @notice Assumption A1: the accountant's own configuration invariants on the requirement ratios
function requireValidRatios(uint256 c, uint256 l) {
    require c < WAD();
    require l < WAD();
    return;
}

// ==================================================================================================
// Property 1: max_st_deposit_coverage_safe
// ==================================================================================================

/**
 * @notice A senior deposit of exactly maxSTDeposit settles with coverage utilization <= WAD
 * @dev (C + m + D) * c <= J * W, i.e. the reported capacity can be consumed in full and the dust
 *      pad is still in hand afterwards
 */
rule max_st_deposit_coverage_safe(env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);
    require c != 0;

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 m = harness.maxSTDepositRaw(e, st);

    // The degenerate answers (zero capacity, unbounded sentinel) are covered by properties 6 and 7
    require m != 0;
    require m != MAX_NAV_UNITS_();

    assert (C + m + D) * c <= J * WAD(),
        "an ST deposit of exactly maxSTDeposit must leave the coverage requirement satisfied with the dust pad intact";
}

// ==================================================================================================
// Property 2: max_st_deposit_liquidity_safe
// ==================================================================================================

/**
 * @notice A senior deposit of exactly maxSTDeposit settles with liquidity utilization <= WAD
 * @dev (S + m + D) * l <= P * W: maxSTDeposit is bounded by the liquidity headroom too, never only
 *      by the coverage leg
 */
rule max_st_deposit_liquidity_safe(env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);
    require l != 0;

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 m = harness.maxSTDepositRaw(e, st);

    require m != 0;
    require m != MAX_NAV_UNITS_();

    assert (S + m + D) * l <= P * WAD(),
        "an ST deposit of exactly maxSTDeposit must leave the liquidity requirement satisfied with the dust pad intact";
}

// ==================================================================================================
// Property 3: max_jt_withdrawal_coverage_safe
// ==================================================================================================

/**
 * @notice A junior exit of exactly maxJTWithdrawal leaves the coverage requirement satisfied
 * @dev Withdrawing y lowers both J and C by y: (J - y) * W >= (C + D - y) * c
 */
rule max_jt_withdrawal_coverage_safe(env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 y = harness.maxJTWithdrawalRaw(e, st);

    require y != 0;

    assert (J - y) * WAD() >= (C + D - y) * c,
        "a JT withdrawal of exactly maxJTWithdrawal must leave the coverage requirement satisfied with the dust pad intact";
}

// ==================================================================================================
// Property 4 (and the safe half of property 13): max_jt_withdrawal_bounded_by_junior_claim
// ==================================================================================================

/**
 * @notice For any NAV-conserving packet the junior exit size never exceeds the junior claim
 * @dev The closed form divides by (W - c), which amplifies the surplus; conservation (assumption A3)
 *      is what keeps the amplified figure below J and below C
 */
rule max_jt_withdrawal_bounded_by_junior_claim(env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);
    // Assumption A3: NAV conservation, enforced by postOpSyncTrancheAccounting and proved as the
    // nav_conservation invariant in certora/invariants.spec; a kernel-side obligation for the packet
    require C == S + J;

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 y = harness.maxJTWithdrawalRaw(e, st);

    assert y <= J, "maxJTWithdrawal must never exceed the junior tranche's own effective NAV";
    assert y <= C, "maxJTWithdrawal must never exceed the collateral backing the tranches";
}

// ==================================================================================================
// Property 5: max_lpt_withdrawal_liquidity_safe
// ==================================================================================================

/**
 * @notice maxLPTWithdrawal never exceeds the venue depth and leaves the senior liquidity floor intact
 */
rule max_lpt_withdrawal_liquidity_safe(env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 z = harness.maxLPTWithdrawalRaw(e, st);

    assert z <= P, "maxLPTWithdrawal can never exceed the venue depth it is withdrawn from";
    assert (l != 0 && z != 0) => ((P - z) * WAD() >= (S + D) * l),
        "removing exactly maxLPTWithdrawal of depth must leave the senior liquidity floor satisfied with the dust pad intact";
}

// ==================================================================================================
// Property 6: zero_requirement_capacity_degeneracy
// ==================================================================================================

/**
 * @notice Switching the coverage requirement off makes the coverage leg vanish exactly
 * @dev c == 0 => the coverage leg is the MAX_NAV_UNITS sentinel, so maxSTDeposit collapses onto the
 *      liquidity leg alone, and maxJTWithdrawal equals the entire junior claim
 */
rule zero_min_coverage_capacity_degeneracy(env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 l, uint256 D) {
    requireRealisticMagnitudes(C, P, S, J, D);
    require l < WAD();

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, 0, l);
    uint256 m = harness.maxSTDepositRaw(e, st);
    uint256 y = harness.maxJTWithdrawalRaw(e, st);

    assert m == liqLegExact(P, S, l, D),
        "with minCoverageWAD == 0 the coverage leg must be unbounded, leaving only the liquidity leg";
    assert y == J,
        "with minCoverageWAD == 0 the junior tranche must be able to withdraw its entire claim";
}

/**
 * @notice Switching the liquidity requirement off makes the liquidity leg vanish exactly
 * @dev l == 0 => the liquidity leg is the MAX_NAV_UNITS sentinel and maxLPTWithdrawal is the whole
 *      venue depth with no dust deduction (the 'zero-min-liquidity market reduces to a plain
 *      senior/junior market' reduction)
 */
rule zero_min_liquidity_capacity_degeneracy(env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 D) {
    requireRealisticMagnitudes(C, P, S, J, D);
    require c < WAD();

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, 0);
    uint256 m = harness.maxSTDepositRaw(e, st);
    uint256 z = harness.maxLPTWithdrawalRaw(e, st);

    assert m == covLegExact(C, J, c, D),
        "with minLiquidityWAD == 0 the liquidity leg must be unbounded, leaving only the coverage leg";
    assert z == P,
        "with minLiquidityWAD == 0 the entire venue depth must be withdrawable, with no dust deduction";
}

// ==================================================================================================
// Property 7: capacity_saturates_to_zero_when_violated
// ==================================================================================================

/**
 * @notice An already-violated coverage requirement saturates the coverage-bounded capacities to zero
 * @dev The utilization is computed by the real UtilizationLogic used by the kernel's gate
 */
rule coverage_violation_saturates_capacity_to_zero(env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);

    uint256 u = harness.coverageUtilizationRaw(e, C, c, J);
    require u > WAD();

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 m = harness.maxSTDepositRaw(e, st);
    uint256 y = harness.maxJTWithdrawalRaw(e, st);

    assert m == 0, "a market already past its coverage requirement must report zero ST deposit capacity";
    assert y == 0, "a market already past its coverage requirement must report zero JT withdrawal capacity";
}

/**
 * @notice An already-violated liquidity requirement saturates the liquidity-bounded capacities to zero
 */
rule liquidity_violation_saturates_capacity_to_zero(env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);

    uint256 u = harness.liquidityUtilizationRaw(e, S, l, P);
    require u > WAD();

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 m = harness.maxSTDepositRaw(e, st);
    uint256 z = harness.maxLPTWithdrawalRaw(e, st);

    assert m == 0, "a market already past its liquidity requirement must report zero ST deposit capacity";
    assert z == 0, "a market already past its liquidity requirement must report zero LPT withdrawal capacity";
}

// ==================================================================================================
// Property 8: no_spurious_zero_capacity
// ==================================================================================================

/// @notice Strict slack beyond the dust pad on both legs must produce strictly positive ST capacity
rule no_spurious_zero_max_st_deposit(env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);
    // floor(J*W/c) > C + D  and  floor(P*W/l) > S + D  (the sentinel encodes 'requirement switched off')
    require covLegExact(C, J, c, D) > 0;
    require liqLegExact(P, S, l, D) > 0;

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 m = harness.maxSTDepositRaw(e, st);

    assert m > 0, "a healthy market with strict slack on both legs must report positive ST deposit capacity";
}

/// @notice Venue depth strictly above the padded senior liquidity floor must produce positive LPT capacity
rule no_spurious_zero_max_lpt_withdrawal(env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);
    require (l != 0 && P > ceilDivM((S + D) * l, WAD())) || (l == 0 && P > 0);

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 z = harness.maxLPTWithdrawalRaw(e, st);

    assert z > 0, "venue depth strictly above the padded senior liquidity floor must be partially withdrawable";
}

/// @notice A junior buffer strictly above the padded coverage requirement must produce positive JT capacity
rule no_spurious_zero_max_jt_withdrawal(env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);
    require J > ceilDivM((C + D) * c, WAD());

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 y = harness.maxJTWithdrawalRaw(e, st);

    assert y > 0, "a junior buffer strictly above the padded coverage requirement must be partially withdrawable";
}

// ==================================================================================================
// Property 9: capacity_monotonicity
// ==================================================================================================

/**
 * @notice maxSTDeposit never grows as the market becomes riskier
 * @dev nondecreasing in J and P, nonincreasing in C, S and in the dust tolerance
 */
rule max_st_deposit_monotonicity(
    env e,
    uint256 C1, uint256 C2, uint256 P1, uint256 P2, uint256 S1, uint256 S2, uint256 J1, uint256 J2,
    uint256 c, uint256 l, uint256 D1, uint256 D2
) {
    requireRealisticMagnitudes(C1, P1, S1, J1, D1);
    requireRealisticMagnitudes(C2, P2, S2, J2, D2);
    requireValidRatios(c, l);

    // State 1 is the riskier / more padded configuration
    require J1 <= J2;
    require P1 <= P2;
    require C1 >= C2;
    require S1 >= S2;
    require D1 >= D2;

    RoycoDayAccountantHarness.RawSyncedAccountingState st1 = capacityState(C1, P1, S1, J1, c, l);
    RoycoDayAccountantHarness.RawSyncedAccountingState st2 = capacityState(C2, P2, S2, J2, c, l);

    harness.harnessSetDustTolerance(e, D1);
    uint256 m1 = harness.maxSTDepositRaw(e, st1);
    harness.harnessSetDustTolerance(e, D2);
    uint256 m2 = harness.maxSTDepositRaw(e, st2);

    assert m1 <= m2, "a loss (falling J or P), a larger senior book, or a wider dust pad must never widen maxSTDeposit";
}

/// @notice maxJTWithdrawal is nondecreasing in J and nonincreasing in C and in the dust tolerance
rule max_jt_withdrawal_monotonicity(
    env e,
    uint256 C1, uint256 C2, uint256 P, uint256 S, uint256 J1, uint256 J2,
    uint256 c, uint256 l, uint256 D1, uint256 D2
) {
    requireRealisticMagnitudes(C1, P, S, J1, D1);
    requireRealisticMagnitudes(C2, P, S, J2, D2);
    requireValidRatios(c, l);

    require J1 <= J2;
    require C1 >= C2;
    require D1 >= D2;

    RoycoDayAccountantHarness.RawSyncedAccountingState st1 = capacityState(C1, P, S, J1, c, l);
    RoycoDayAccountantHarness.RawSyncedAccountingState st2 = capacityState(C2, P, S, J2, c, l);

    harness.harnessSetDustTolerance(e, D1);
    uint256 y1 = harness.maxJTWithdrawalRaw(e, st1);
    harness.harnessSetDustTolerance(e, D2);
    uint256 y2 = harness.maxJTWithdrawalRaw(e, st2);

    assert y1 <= y2, "a smaller junior buffer, more collateral, or a wider dust pad must never widen maxJTWithdrawal";
}

/// @notice maxLPTWithdrawal is nondecreasing in P and nonincreasing in S and in the dust tolerance
rule max_lpt_withdrawal_monotonicity(
    env e,
    uint256 C, uint256 P1, uint256 P2, uint256 S1, uint256 S2, uint256 J,
    uint256 c, uint256 l, uint256 D1, uint256 D2
) {
    requireRealisticMagnitudes(C, P1, S1, J, D1);
    requireRealisticMagnitudes(C, P2, S2, J, D2);
    requireValidRatios(c, l);

    require P1 <= P2;
    require S1 >= S2;
    require D1 >= D2;

    RoycoDayAccountantHarness.RawSyncedAccountingState st1 = capacityState(C, P1, S1, J, c, l);
    RoycoDayAccountantHarness.RawSyncedAccountingState st2 = capacityState(C, P2, S2, J, c, l);

    harness.harnessSetDustTolerance(e, D1);
    uint256 z1 = harness.maxLPTWithdrawalRaw(e, st1);
    harness.harnessSetDustTolerance(e, D2);
    uint256 z2 = harness.maxLPTWithdrawalRaw(e, st2);

    assert z1 <= z2, "less venue depth, a larger senior book, or a wider dust pad must never widen maxLPTWithdrawal";
}

// ==================================================================================================
// Property 10: capacity_is_function_of_supplied_state_and_dust_only
// ==================================================================================================

/**
 * @notice The three capacity views write no state at all
 * @dev NOTE: the harness wrappers are `view`, so the absence of writes is compiler-enforced for any
 *      implementation that compiles. This rule is a regression guard, not an independent finding.
 */
rule capacity_views_write_no_storage(env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l) {
    requireValidRatios(c, l);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);

    storage before = lastStorage;
    harness.maxSTDepositRaw(e, st);
    harness.maxJTWithdrawalRaw(e, st);
    harness.maxLPTWithdrawalRaw(e, st);

    assert lastStorage == before, "the capacity views must not write any state";
}

/**
 * @notice The capacity views read no accountant storage other than the dust tolerance
 * @dev Every other stored field, including the stale lastCollateralNAV / lastSTEffectiveNAV /
 *      lastJTEffectiveNAV / lastLPTRawNAV checkpoints AND the stored coverage/liquidity parameters,
 *      is rewritten to arbitrary values between the two evaluations; the outputs must not move.
 * @dev The residual stored fields that harnessSetCapacityIrrelevantState does not perturb (the four
 *      protocol-fee ratios, fixedTermDurationSeconds, the two accrual timestamps, the two YDM
 *      addresses, the two max-yield-share caps, the two time-weighted accruals, the kernel address
 *      and fixedTermCommenceableAtTimestamp) are covered instead by the property-15 exact closed
 *      forms below, which pin all three outputs to functions of the packet and D alone.
 */
rule capacity_ignores_accountant_storage(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D,
    uint256 a1, uint256 a2, uint256 a3, uint256 a4, uint256 a5,
    uint256 a6, uint256 a7, uint256 a8, uint256 a9, uint256 a10
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);

    uint256 m1 = harness.maxSTDepositRaw(e, st);
    uint256 y1 = harness.maxJTWithdrawalRaw(e, st);
    uint256 z1 = harness.maxLPTWithdrawalRaw(e, st);

    // Arbitrarily rewrite every stored field except the dust tolerance
    harness.harnessSetCapacityIrrelevantState(e, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10);

    uint256 m2 = harness.maxSTDepositRaw(e, st);
    uint256 y2 = harness.maxJTWithdrawalRaw(e, st);
    uint256 z2 = harness.maxLPTWithdrawalRaw(e, st);

    assert m1 == m2, "maxSTDeposit must depend only on the supplied packet and the dust tolerance";
    assert y1 == y2, "maxJTWithdrawal must depend only on the supplied packet and the dust tolerance";
    assert z1 == z2, "maxLPTWithdrawal must depend only on the supplied packet and the dust tolerance";
}

// ==================================================================================================
// Property 11: capacity_views_total_for_valid_configs
// ==================================================================================================

/**
 * @notice All three capacity views terminate without reverting for every valid configuration
 * @dev In particular the (WAD - minCoverageWAD) divisor of maxJTWithdrawal is never zero, because
 *      the configuration invariant minCoverageWAD < WAD (assumption A1) holds on every governance path
 */
rule capacity_views_never_revert(env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);
    require e.msg.value == 0;

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);

    harness.maxSTDepositRaw@withrevert(e, st);
    assert !lastReverted, "maxSTDeposit must be total for valid configurations";

    harness.maxJTWithdrawalRaw@withrevert(e, st);
    assert !lastReverted, "maxJTWithdrawal must be total for valid configurations: (WAD - minCoverageWAD) is never zero";

    harness.maxLPTWithdrawalRaw@withrevert(e, st);
    assert !lastReverted, "maxLPTWithdrawal must be total for valid configurations";
}

// ==================================================================================================
// Property 12: advisory_capacity_vs_enforced_gate_mismatch
// --------------------------------------------------------------------------------------------------
// The advisory figure is derived from a PRE-op preview packet while the authoritative requirement
// check runs on the POST-op state. The accountant-side obligation is therefore: the dust pad must
// dominate the drift between the two. This section settles that question in three parts, and the
// answer is NOT a plain "the pad covers any drift up to D".
//
// (12.i) THE DRIFT BUDGET THE PAD ACTUALLY BUYS - proved, exactly.
//   Writing cDrift / sDrift for upward drift in collateral / senior effective NAV and jDrift /
//   pDrift for downward drift in junior effective NAV / the venue mark, the pad covers exactly
//        jDrift * W + cDrift * c <= D * c        (coverage side)
//        pDrift * W + sDrift * l <= D * l        (liquidity side)
//   and no more. The three `..._within_drift_budget` rules below prove that every operation sized at
//   exactly the reported maximum is admitted by the REAL post-op gate under any drift inside that
//   budget. The budget is the honest reading of the pad: because the pad is subtracted in NAV units
//   on the collateral / senior side of a requirement that is scaled by c (resp. l), a pad of D NAV
//   units buys only D*c/W NAV units of junior-side slack and D*l/W of venue-side slack.
//
// (12.ii) THE COLLATERAL-DUST CHANNEL IS FULLY COVERED - proved.
//   The accountant's own NatSpec for dustTolerance says it is "the worst case dust tolerance for
//   collateralNAV from underlying NAV quoting/rounding, effective NAV deltas are pro-rata
//   attributions of the collateral NAV delta so it bounds their dust too"
//   (src/interfaces/IRoycoDayAccountant.sol:89). Modelled faithfully - a signed collateral drift
//   bounded by D, with the junior tranche receiving at least, and the senior tranche at most, its
//   pro-rata share of that delta - the post-op gate is satisfied for BOTH signs of the drift, and
//   the proof does not even need the magnitude bound: it is the pro-rata structure that saves it.
//   That is rule gate_admits_max_st_deposit_under_prorata_collateral_dust.
//
// (12.iii) THE SENIOR-SHARE-MINT AND VENUE-MARK CHANNELS ARE **NOT** COVERED - counterexampled.
//   The two drift channels property 12 explicitly names, however, are not pro-rata attributions of a
//   collateral delta: a fee / liquidity-premium senior share mint moves NAV from junior to senior
//   with collateralNAV unchanged (deltaC = 0, deltaS = +f, deltaJ = -f), and a freshly committed
//   venue mark moves lptRawNAV on its own. For those, a dust-sized (f <= D, pDrift <= D) move is NOT
//   dominated by the pad, exactly because of the c/W and l/W scaling above: surviving deltaJ = -f
//   needs f*W <= D*c, i.e. f <= D*c/W < D. The two `dust_pad_dominates_...` rules below encode the
//   naive claim "any dust-sized drift in the junior effective NAV / the venue mark is covered" and
//   are EXPECTED TO FAIL; the failures are the property-12 finding, and they are what the drift
//   budget in (12.i) quantifies. Consequences and remediation are recorded at each failing rule.
// ==================================================================================================

/// @notice An ST deposit sized at exactly maxSTDeposit passes both real post-op gates inside the budget
rule gate_admits_max_st_deposit_within_drift_budget(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D,
    uint256 cDrift, uint256 sDrift, uint256 jDrift, uint256 pDrift
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 m = harness.maxSTDepositRaw(e, st);

    require m != 0;
    require m != MAX_NAV_UNITS_();
    // Assumption A2 extended to the settled state
    require C + m <= NAV_BOUND();
    require S + m <= NAV_BOUND();

    // Every drift component is itself dust-bounded, and the two legs' budgets hold (12.i)
    require cDrift <= D;
    require sDrift <= D;
    require jDrift <= J;
    require pDrift <= P;
    require jDrift * WAD() + cDrift * c <= D * c;
    require pDrift * WAD() + sDrift * l <= D * l;

    uint256 postC = assert_uint256(C + m + cDrift);
    uint256 postS = assert_uint256(S + m + sDrift);
    uint256 postJ = assert_uint256(J - jDrift);
    uint256 postP = assert_uint256(P - pDrift);

    uint256 uCov = harness.coverageUtilizationRaw(e, postC, c, postJ);
    uint256 uLiq = harness.liquidityUtilizationRaw(e, postS, l, postP);

    assert uCov <= WAD(), "the post-op coverage gate must admit an ST deposit sized at exactly maxSTDeposit";
    assert uLiq <= WAD(), "the post-op liquidity gate must admit an ST deposit sized at exactly maxSTDeposit";
}

/// @notice A JT redemption sized at exactly maxJTWithdrawal passes the real post-op gate inside the budget
rule gate_admits_max_jt_withdrawal_within_drift_budget(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D,
    uint256 cDrift, uint256 jDrift
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);
    require C == S + J; // assumption A3

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 y = harness.maxJTWithdrawalRaw(e, st);

    require y != 0;
    require cDrift <= D;
    require y + jDrift <= J;
    require jDrift * WAD() + cDrift * c <= D * c;

    uint256 postC = assert_uint256(C - y + cDrift);
    uint256 postJ = assert_uint256(J - y - jDrift);

    uint256 uCov = harness.coverageUtilizationRaw(e, postC, c, postJ);

    assert uCov <= WAD(), "the post-op coverage gate must admit a JT redemption sized at exactly maxJTWithdrawal";
}

/// @notice An LPT redemption sized at exactly maxLPTWithdrawal passes the real post-op gate inside the budget
rule gate_admits_max_lpt_withdrawal_within_drift_budget(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D,
    uint256 sDrift, uint256 pDrift
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 z = harness.maxLPTWithdrawalRaw(e, st);

    require z != 0;
    require sDrift <= D;
    require z + pDrift <= P;
    require pDrift * WAD() + sDrift * l <= D * l;

    uint256 postP = assert_uint256(P - z - pDrift);
    uint256 postS = assert_uint256(S + sDrift);

    uint256 uLiq = harness.liquidityUtilizationRaw(e, postS, l, postP);

    assert uLiq <= WAD(), "the post-op liquidity gate must admit an LPT redemption sized at exactly maxLPTWithdrawal";
}

/**
 * @notice The collateral-NAV dust channel is fully covered, for both signs of the drift
 * @dev Model (12.ii), stated exactly as the accountant's dustTolerance NatSpec describes it:
 *      `cd` is the signed collateral-NAV drift, bounded by the pad in both directions (cUp, cDown are
 *      both bounded by D, so cd ranges over the whole interval from -D to D); `jd` and `sd` are the
 *      signed junior / senior effective-NAV deltas, and the pro-rata attribution is encoded
 *      division-free as `jd * A >= cd * J` (the junior tranche receives at least its pro-rata share of
 *      a gain and absorbs at most its pro-rata share of a loss) and `sd * A <= cd * S` (the mirror
 *      statement for senior), where A is the previewed post-op collateral NAV. Each inequality covers
 *      both signs of `cd` at once.
 */
rule gate_admits_max_st_deposit_under_prorata_collateral_dust(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D,
    uint256 cUp, uint256 cDown, uint256 jUp, uint256 jDown, uint256 sUp, uint256 sDown
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);
    require C == S + J; // assumption A3

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 m = harness.maxSTDepositRaw(e, st);

    require m != 0;
    require m != MAX_NAV_UNITS_();
    require C + m <= NAV_BOUND();
    require S + m <= NAV_BOUND();

    // The knob bounds the collateral-NAV dust in both directions
    require cUp <= D;
    require cDown <= D;

    mathint A = C + m;              // the previewed post-op collateral NAV
    mathint cd = cUp - cDown;       // signed collateral-NAV drift
    mathint jd = jUp - jDown;       // signed junior effective-NAV drift
    mathint sd = sUp - sDown;       // signed senior effective-NAV drift

    // Pro-rata attribution of the collateral delta to the two tranches
    require jd * A >= cd * J;
    require sd * A <= cd * S;
    // NAVs remain nonnegative and inside the modelled magnitude bound (assumption A2)
    require A + cd >= 0;
    require A + cd <= NAV_BOUND();
    require J + jd >= 0;
    require J + jd <= NAV_BOUND();
    require S + m + sd >= 0;
    require S + m + sd <= NAV_BOUND();

    uint256 uCov = harness.coverageUtilizationRaw(e, assert_uint256(A + cd), c, assert_uint256(J + jd));
    uint256 uLiq = harness.liquidityUtilizationRaw(e, assert_uint256(S + m + sd), l, P);

    assert uCov <= WAD(),
        "a pro-rata collateral-NAV dust drift must never make an ST deposit sized at maxSTDeposit trip the coverage gate";
    assert uLiq <= WAD(),
        "a pro-rata collateral-NAV dust drift must never make an ST deposit sized at maxSTDeposit trip the liquidity gate";
}

/**
 * @notice EXPECTED TO FAIL - a dust-sized senior share mint is NOT dominated by the dust pad
 * @dev The naive claim behind the padding: "an ST deposit sized at exactly maxSTDeposit still passes
 *      the post-op coverage gate after any dust-sized (f <= dustTolerance) reattribution of NAV from
 *      junior to senior". The sync's protocol-fee and liquidity-premium senior share mints are exactly
 *      such a reattribution (collateralNAV unchanged, stEffectiveNAV up by f, jtEffectiveNAV down by f),
 *      and property 12 names them explicitly as running between the previewed state the capacity was
 *      computed from and the post-op state the gate is evaluated on.
 * @dev Why it must fail: property 1 gives only (C + m + D) * c <= J * W, so surviving J -> J - f needs
 *      f * W <= D * c, i.e. f <= D * c / W. Since c < W the pad is worth strictly less than D NAV units
 *      of junior-side slack, and f = D breaks the gate for every c < W. The Prover's actual witness:
 *      C = 423, S = 304, J = 119, P = 3, c = 1 (one wei-WAD), l = 0, D = 0x67374ed82cf7bf1f0 (about 1.19e20).
 *      With l == 0 the liquidity leg is the sentinel, so the coverage leg alone gives
 *      m = satSub(floor(119 * 1e18 / 1), C + D) = 3177; a mint of f = 119 (legitimately <= D and <= J)
 *      drives post-op jtEffectiveNAV to EXACTLY ZERO, where _computeCoverageUtilization takes its
 *      jtEffectiveNAV == 0 branch and returns type(uint256).max - so the gate rejection is maximal
 *      rather than marginal. CONSEQUENCE: an ST deposit
 *      sized at the reported maximum can revert on the post-op coverage gate, breaking keeper and
 *      entry-point maximal fills. REMEDIATION (source change, out of this spec's scope): either scale
 *      the pad by the requirement ratio when it is subtracted on the collateral/senior side (deduct
 *      ceil(D * W / c) rather than D from the coverage leg), or have the kernel size operations from the
 *      post-mint previewed state so that this drift channel is zero by construction.
 */
rule dust_pad_dominates_dust_sized_senior_share_mint(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D, uint256 f
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);
    require C == S + J; // assumption A3
    require c != 0;

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 m = harness.maxSTDepositRaw(e, st);

    require m != 0;
    require m != MAX_NAV_UNITS_();
    require C + m <= NAV_BOUND();

    // The sync's fee / liquidity-premium senior share mint moves f NAV units from junior to senior
    require f <= D;
    require f <= J;

    uint256 uCov = harness.coverageUtilizationRaw(e, assert_uint256(C + m), c, assert_uint256(J - f));

    assert uCov <= WAD(),
        "a dust-sized senior share mint must not make an ST deposit sized at exactly maxSTDeposit trip the coverage gate";
}

/**
 * @notice EXPECTED TO FAIL - a dust-sized downward venue-mark move is NOT dominated by the dust pad
 * @dev The mirror of the rule above on the liquidity leg: property 5 gives only
 *      (P - z) * W >= (S + D) * l, so surviving P -> P - pDrift needs pDrift * W <= D * l, i.e.
 *      pDrift <= D * l / W < D. A dust-sized (pDrift <= D) difference between the mark the packet
 *      carried and the mark in force when the kernel's post-op liquidity gate runs therefore makes an
 *      LPT redemption sized at exactly maxLPTWithdrawal revert. The Prover's actual witness:
 *      S = 15, P = 14, l = 0x905438e6000ffff (about 0.65e18), D = pDrift = 5. Then
 *      requiredLPTValue = ceil((S + D) * l / W) = ceil(20 * 0.65e18 / 1e18) = 13, so z = satSub(14, 13) = 1;
 *      the gate is evaluated at postP = P - z - pDrift = 8 and reports
 *      liquidityUtilization = ceil(15 * 0.65e18 / 8) = about 1.22e18 > WAD. Note the pad of 5 buys only
 *      about D * l / W = 3 NAV units of venue-side slack, so the failure bites at EVERY l < WAD, not
 *      merely at contrived dust-scale NAVs.
 *      REMEDIATION: as above - scale the pad by l when it is applied on the senior side, or commit the
 *      venue mark before the figure is published (which is also the property-18 call-site obligation).
 */
rule dust_pad_dominates_dust_sized_venue_mark_drift(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D, uint256 pDrift
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);
    require l != 0;

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 z = harness.maxLPTWithdrawalRaw(e, st);

    require z != 0;
    require pDrift <= D;
    require z + pDrift <= P;

    uint256 uLiq = harness.liquidityUtilizationRaw(e, S, l, assert_uint256(P - z - pDrift));

    assert uLiq <= WAD(),
        "a dust-sized downward venue-mark move must not make an LPT redemption sized at exactly maxLPTWithdrawal trip the liquidity gate";
}

// ==================================================================================================
// Property 13: unvalidated_caller_supplied_capacity_state
// --------------------------------------------------------------------------------------------------
// The three views are permissionless and validate nothing about the in-memory packet. For a
// NAV-conserving packet (every packet a real sync produces) the junior figure is bounded by the
// junior claim: rule max_jt_withdrawal_bounded_by_junior_claim above. The rule below drops the
// conservation hypothesis, i.e. it models an integrator (or a fabricated call) supplying a packet
// with jtEffectiveNAV > collateralNAV. It is EXPECTED TO FAIL, and the Prover's actual witness is
//   C = 0, S = 4, J = 25, P = 5, c = 0, l = 3, D = 0
//   =>  requiredJTValue = ceil((C+D)*c/W) = 0, surplus = satSub(J, 0) = 25,
//       y = floor(25 * W / (W - 0)) = 25  >  C = 0
// i.e. with minCoverageWAD == 0 the required-coverage term vanishes entirely and the whole junior
// claim is reported as withdrawable against an empty collateral pool - note this witness needs no
// amplification at all, only the missing conservation check. The amplification path
// y = surplus * W / (W - c) makes the overstatement unbounded rather than merely equal to J for
// non-conserving inputs (e.g. C = 0, J = 100, c = 0.5e18, D = 0 gives y = 200). A direct reader of
// the accountant can therefore be handed an overstated, unfulfillable capacity, and a downstream
// NAV-to-share conversion of that figure can exceed the tranche's total supply.
// The finding is informational for the protocol itself (the kernel only ever passes sync-produced,
// conserving packets, and conservation is enforced by postOpSyncTrancheAccounting and proved as the
// nav_conservation invariant) but is a genuine hazard for third-party integrators and is surfaced
// here rather than assumed away. Remediation options for the protocol authors: either validate
// collateralNAV == stEffectiveNAV + jtEffectiveNAV at the head of each capacity view and revert
// otherwise, or document the three views as kernel-internal advisory helpers that integrators must
// not call with self-constructed packets.
// ==================================================================================================

rule max_jt_withdrawal_bounded_for_unvalidated_caller_state(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);
    // Deliberately NO NAV-conservation hypothesis: an arbitrary caller-supplied packet

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 y = harness.maxJTWithdrawalRaw(e, st);

    assert y <= J && y <= C,
        "maxJTWithdrawal must never exceed the junior claim, even for an unvalidated caller-supplied packet";
}

// ==================================================================================================
// Property 14: dust_tolerance_knob_extremes
// --------------------------------------------------------------------------------------------------
// The knob is admin-settable with no upper bound (setDustTolerance validates nothing) and can be set
// to zero. Four rules bound its entire effect:
//  (a) dust_pad_acts_exactly_as_extra_collateral_and_senior_nav - EXACT: a pad of D is
//      indistinguishable from D extra NAV units of collateral (coverage leg, maxJTWithdrawal) and D
//      extra units of senior effective NAV (liquidity leg, maxLPTWithdrawal), for ALL THREE views.
//      Combined with the property-9 monotonicity rules this pins the knob's effect completely: it can
//      only ever shrink the figures, and only by as much as that much extra collateral / senior book
//      would - the pad is never amplified, in particular never by the (W - c) divisor.
//  (b) dust_tolerance_under_reports_by_at_most_the_pad - the resulting shrinkage, quantified.
//  (c) healthy_market_reports_positive_capacity_for_any_dust_tolerance - EXPECTED TO FAIL: since the
//      knob is unbounded, (a) is also the hazard: a large enough pad zeroes the reported capacity on
//      a perfectly healthy market.
//  (d) zero_dust_tolerance_capacity_still_gate_safe - the zero-pad extreme is still gate-safe when the
//      settled state matches the previewed one; what a zero pad removes is precisely the drift budget
//      of property 12 (12.i), which with D == 0 admits only zero drift.
// ==================================================================================================

/**
 * @notice The dust pad acts exactly as D extra units of collateral / senior effective NAV
 * @dev Exact for all three views: D enters maxSTDeposit only as (C + D) on the coverage leg and
 *      (S + D) on the liquidity leg, maxJTWithdrawal only as (C + D), and maxLPTWithdrawal only as
 *      (S + D). It is therefore never amplified by the (W - c) divisor or by anything else.
 */
rule dust_pad_acts_exactly_as_extra_collateral_and_senior_nav(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);
    require C + D <= NAV_BOUND();
    require S + D <= NAV_BOUND();

    RoycoDayAccountantHarness.RawSyncedAccountingState stD = capacityState(C, P, S, J, c, l);
    RoycoDayAccountantHarness.RawSyncedAccountingState st0 =
        capacityState(assert_uint256(C + D), P, assert_uint256(S + D), J, c, l);

    harness.harnessSetDustTolerance(e, D);
    uint256 mD = harness.maxSTDepositRaw(e, stD);
    uint256 yD = harness.maxJTWithdrawalRaw(e, stD);
    uint256 zD = harness.maxLPTWithdrawalRaw(e, stD);

    harness.harnessSetDustTolerance(e, 0);
    uint256 m0 = harness.maxSTDepositRaw(e, st0);
    uint256 y0 = harness.maxJTWithdrawalRaw(e, st0);
    uint256 z0 = harness.maxLPTWithdrawalRaw(e, st0);

    assert mD == m0, "the dust pad must cost maxSTDeposit exactly what D extra collateral and senior NAV would";
    assert yD == y0, "the dust pad must cost maxJTWithdrawal exactly what D extra collateral would, never amplified";
    assert zD == z0, "the dust pad must cost maxLPTWithdrawal exactly what D extra senior NAV would";
}

/// @notice A wider dust pad under-reports by at most the pad itself (scaled by the ratio it enters through)
rule dust_tolerance_under_reports_by_at_most_the_pad(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);

    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);

    harness.harnessSetDustTolerance(e, 0);
    uint256 m0 = harness.maxSTDepositRaw(e, st);
    uint256 z0 = harness.maxLPTWithdrawalRaw(e, st);

    harness.harnessSetDustTolerance(e, D);
    uint256 mD = harness.maxSTDepositRaw(e, st);
    uint256 zD = harness.maxLPTWithdrawalRaw(e, st);

    assert mD >= m0 - D,
        "the dust pad may cost maxSTDeposit at most the pad itself";
    assert zD >= z0 - ceilDivM(D * l, WAD()),
        "the dust pad may cost maxLPTWithdrawal at most the pad scaled by the liquidity ratio";
}

/**
 * @notice EXPECTED TO FAIL - an unbounded dust pad freezes a healthy market's reported capacity
 * @dev setDustTolerance (src/accountant/RoycoDayAccountant.sol) validates nothing: any uint256 is
 *      accepted, under a role separate from the coverage/liquidity parameter setters. The rule states
 *      the property an operator would rely on - "a market with strict coverage and liquidity slack
 *      reports strictly positive senior deposit capacity, whatever the pad is set to" - and it is
 *      false: for D at or above the slack the reported figure saturates to zero, freezing every flow
 *      that sizes itself off it. The Prover's actual witness is the tightest possible boundary case:
 *      C = 3, S = 4, J = 1, P = 6, D = 2, c = 0x2501e734690aaac (about 0.1667e18),
 *      l = 0xbe52ee321c36db7 (about 0.857e18). Coverage slack is floor(J*W/c) - C = 5 - 3 = 2 and
 *      liquidity slack is floor(P*W/l) - S = 6 - 4 = 2, both strict; the pad is exactly 2, so BOTH
 *      legs saturate: satSub(5, 3 + 2) = 0 and satSub(6, 4 + 2) = 0, hence maxSTDeposit == 0. Nothing
 *      about the witness is scale-specific: the pad is an absolute NAV figure with no cap and no
 *      proportionality to collateralNAV, so an arbitrarily large healthy market can be frozen the
 *      same way, and a bare zero does not distinguish "saturated by the pad" from "at the boundary",
 *      freezing every flow
 *      that sizes itself off the view (kernel inkindMaxDeposit, entry-point ST fills, keepers), on a
 *      market that is in fact perfectly healthy. REMEDIATION: cap dustTolerance at initialization or
 *      in the setter as a small absolute figure or a small fraction of collateralNAV, and/or expose
 *      the capacity views' saturation as a distinguishable signal rather than a bare zero.
 */
rule healthy_market_reports_positive_capacity_for_any_dust_tolerance(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);
    require c != 0;
    require l != 0;
    // Strict coverage and liquidity slack, measured WITHOUT the pad: the market is healthy
    require floorDivM(J * WAD(), c) > C;
    require floorDivM(P * WAD(), l) > S;

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 m = harness.maxSTDepositRaw(e, st);

    assert m > 0,
        "a market with strict coverage and liquidity slack must report positive ST deposit capacity for every admin-settable dust tolerance";
}

/// @notice With a zero dust pad the reported maxima are still admitted by the real post-op gates
rule zero_dust_tolerance_capacity_still_gate_safe(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l
) {
    requireRealisticMagnitudes(C, P, S, J, 0);
    requireValidRatios(c, l);
    require C == S + J; // assumption A3

    harness.harnessSetDustTolerance(e, 0);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);

    uint256 m = harness.maxSTDepositRaw(e, st);
    uint256 y = harness.maxJTWithdrawalRaw(e, st);
    uint256 z = harness.maxLPTWithdrawalRaw(e, st);

    require m != MAX_NAV_UNITS_();

    uint256 uCovDep = harness.coverageUtilizationRaw(e, assert_uint256(C + m), c, J);
    uint256 uLiqDep = harness.liquidityUtilizationRaw(e, assert_uint256(S + m), l, P);
    uint256 uCovRed = harness.coverageUtilizationRaw(e, assert_uint256(C - y), c, assert_uint256(J - y));
    uint256 uLiqRed = harness.liquidityUtilizationRaw(e, S, l, assert_uint256(P - z));

    assert m != 0 => (uCovDep <= WAD() && uLiqDep <= WAD()),
        "with a zero dust pad an ST deposit sized at maxSTDeposit must still pass both gates";
    assert y != 0 => uCovRed <= WAD(),
        "with a zero dust pad a JT redemption sized at maxJTWithdrawal must still pass the coverage gate";
    assert z != 0 => uLiqRed <= WAD(),
        "with a zero dust pad an LPT redemption sized at maxLPTWithdrawal must still pass the liquidity gate";
}

// ==================================================================================================
// Property 15: capacity_tightness_bounded_by_dust_pad
// ==================================================================================================

/**
 * @notice maxSTDeposit equals the exact minimum of the two padded closed forms, never less
 * @dev Clauses (a) and (b): the coverage leg is exactly saturatingSub(floor(J*W/c) - C, D) and the
 *      liquidity leg exactly saturatingSub(floor(P*W/l) - S, D); a systematically conservative figure
 *      (a mis-inverted closed form, a wrong rounding side, or the wrong WAD divisor) is ruled out
 */
rule max_st_deposit_is_exactly_the_tighter_padded_leg(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 m = harness.maxSTDepositRaw(e, st);

    assert m == minM(covLegExact(C, J, c, D), liqLegExact(P, S, l, D)),
        "maxSTDeposit must be exactly the tighter of the two padded closed forms";
}

/// @notice maxLPTWithdrawal is exactly the padded closed form, and under-reports by at most the padded ceiling
rule max_lpt_withdrawal_is_exactly_the_padded_closed_form(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 z = harness.maxLPTWithdrawalRaw(e, st);

    assert z == maxLPTWithdrawalExact(P, S, l, D),
        "maxLPTWithdrawal must be exactly the padded closed form";
    assert z >= (P - ceilDivM(S * l, WAD())) - ceilDivM(D * l, WAD()),
        "clause (c): the under-report of maxLPTWithdrawal is bounded by the padded ceiling term";
}

/**
 * @notice maxJTWithdrawal is exactly its padded closed form, and within one amplified rounding unit
 *         plus the dust term of the exact requirement boundary
 * @dev First assertion (clause (d), exact form): y == floor(satSub(J, ceil((C+D)*c/W)) * W / (W - c)).
 *      This is the sharpest possible tightness statement - it also completes property 10 for this view,
 *      since it pins the output to a function of the packet and D alone.
 * @dev Second assertion (clause (d), boundary form): y * (W - c) >= J*W - C*c - D*c - 2*W, i.e. the
 *      under-report relative to the exact boundary (J*W - C*c)/(W - c) is at most (D*c/W + 2) * W/(W - c)
 *      NAV units. An unboundedly or systematically conservative junior figure is ruled out.
 */
rule max_jt_withdrawal_tightness(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, P, S, J, c, l);
    uint256 y = harness.maxJTWithdrawalRaw(e, st);

    assert y == maxJTWithdrawalExact(C, J, c, D),
        "maxJTWithdrawal must be exactly its padded closed form";
    assert y * (WAD() - c) >= J * WAD() - C * c - D * c - 2 * WAD(),
        "maxJTWithdrawal must stay within one amplified rounding unit plus the dust term of the exact boundary";
}

// ==================================================================================================
// Property 16: capacity_monotone_in_requirement_ratios
// ==================================================================================================

/// @notice Tightening either requirement ratio never widens maxSTDeposit
rule max_st_deposit_monotone_in_requirement_ratios(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c1, uint256 c2, uint256 l1, uint256 l2, uint256 D
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c2, l2);
    require c1 <= c2;
    require l1 <= l2;

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st1 = capacityState(C, P, S, J, c1, l1);
    RoycoDayAccountantHarness.RawSyncedAccountingState st2 = capacityState(C, P, S, J, c2, l2);

    uint256 m1 = harness.maxSTDepositRaw(e, st1);
    uint256 m2 = harness.maxSTDepositRaw(e, st2);

    assert m1 >= m2, "raising the coverage or liquidity requirement must never widen maxSTDeposit";
}

/// @notice Tightening the liquidity requirement never widens maxLPTWithdrawal
rule max_lpt_withdrawal_monotone_in_min_liquidity(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l1, uint256 l2, uint256 D
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l2);
    require l1 <= l2;

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st1 = capacityState(C, P, S, J, c, l1);
    RoycoDayAccountantHarness.RawSyncedAccountingState st2 = capacityState(C, P, S, J, c, l2);

    uint256 z1 = harness.maxLPTWithdrawalRaw(e, st1);
    uint256 z2 = harness.maxLPTWithdrawalRaw(e, st2);

    assert z1 >= z2, "raising the liquidity requirement must never widen maxLPTWithdrawal";
}

/**
 * @notice Tightening the coverage requirement never widens the advertised junior exit size, up to a
 *         PROVED (not assumed) rounding slack
 * @dev This is the primary, HYPOTHESIS-FREE junior clause of property 16: it holds for every
 *      conservation-respecting state, including the S == 0 / D == 0 corner where exact monotonicity
 *      genuinely fails. c appears both in the required-coverage numerator (raising it shrinks the
 *      surplus) and in the (W - c) divisor (raising it amplifies whatever surplus remains). Exactly:
 *      the real-valued figure yStar(c) = (J*W - C*c) / (W - c) has derivative
 *      W*(J - C - D)/(W - c)^2 <= 0 under conservation (J <= C), so the continuous figure is
 *      nonincreasing, and the integer figure sits within one ceiling unit amplified by W/(W - c) of
 *      it. Hence y(c1) > yStar(c1) - W/(W-c1) - 1 >= yStar(c2) - W/(W-c2) - 1 >= y(c2) - W/(W-c2) - 1.
 */
rule max_jt_withdrawal_monotone_in_min_coverage_up_to_rounding(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c1, uint256 c2, uint256 l, uint256 D
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c2, l);
    require C == S + J; // assumption A3
    require c1 <= c2;

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st1 = capacityState(C, P, S, J, c1, l);
    RoycoDayAccountantHarness.RawSyncedAccountingState st2 = capacityState(C, P, S, J, c2, l);

    uint256 y1 = harness.maxJTWithdrawalRaw(e, st1);
    uint256 y2 = harness.maxJTWithdrawalRaw(e, st2);

    assert y1 >= y2 - ceilDivM(WAD(), WAD() - c2) - 1,
        "raising the coverage requirement may widen the advertised junior exit size by at most one amplified rounding unit";
}

/**
 * @notice The sharp form of the junior clause: exact monotonicity, under a stated sufficient condition
 * @dev SUPPLEMENTARY to the hypothesis-free rule above, which is the property-16 claim proper. Here the
 *      exact decrease is required to dominate the ceiling's one-unit rounding error amplified by
 *      W/(W - c2), i.e. (S + D) * (c2 - c1) >= W - c2. A senior book of at least one whole NAV unit
 *      (S >= 1e18) is sufficient for any c1 < c2. At dust-scale senior NAV the exact claim is genuinely
 *      false, which is why it is not the primary statement: C = J = 4, S = 0, D = 0 gives y = 2 at
 *      c = 0.6e18 and y = 4 at c = 0.75e18 - a rounding artefact of a market holding four wei of NAV,
 *      bounded by the rule above.
 */
rule max_jt_withdrawal_monotone_in_min_coverage(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c1, uint256 c2, uint256 l, uint256 D
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c2, l);
    require C == S + J; // assumption A3
    require c1 <= c2;
    require (c1 == c2) || ((S + D) * (c2 - c1) >= WAD() - c2);

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st1 = capacityState(C, P, S, J, c1, l);
    RoycoDayAccountantHarness.RawSyncedAccountingState st2 = capacityState(C, P, S, J, c2, l);

    uint256 y1 = harness.maxJTWithdrawalRaw(e, st1);
    uint256 y2 = harness.maxJTWithdrawalRaw(e, st2);

    assert y1 >= y2, "raising the coverage requirement must never widen the advertised junior exit size";
}

// ==================================================================================================
// Property 17: capacity_independent_of_market_state_and_liquidation_fields
// ==================================================================================================

/**
 * @notice The three capacities depend on no market-state, utilization or liquidation field
 * @dev The two packets agree on the six requirement-relevant fields and are otherwise completely
 *      unconstrained: marketState (PERPETUAL vs FIXED_TERM), coverageUtilizationWAD,
 *      liquidityUtilizationWAD, coverageLiquidationUtilizationWAD, fixedTermEndTimestamp,
 *      jtImpermanentLoss, the liquidity premium and all three protocol-fee fields may all differ.
 *      No state-conditional shortcut branch may unlock venue depth or relax a coverage bound.
 */
rule capacity_ignores_market_and_utilization_fields(
    env e, uint256 C, uint256 P, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D
) {
    requireRealisticMagnitudes(C, P, S, J, D);
    requireValidRatios(c, l);

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st1 = capacityState(C, P, S, J, c, l);
    RoycoDayAccountantHarness.RawSyncedAccountingState st2 = capacityState(C, P, S, J, c, l);

    uint256 m1 = harness.maxSTDepositRaw(e, st1);
    uint256 y1 = harness.maxJTWithdrawalRaw(e, st1);
    uint256 z1 = harness.maxLPTWithdrawalRaw(e, st1);

    uint256 m2 = harness.maxSTDepositRaw(e, st2);
    uint256 y2 = harness.maxJTWithdrawalRaw(e, st2);
    uint256 z2 = harness.maxLPTWithdrawalRaw(e, st2);

    assert m1 == m2, "maxSTDeposit must ignore the market state, utilizations and liquidation threshold";
    assert y1 == y2, "maxJTWithdrawal must ignore the market state, utilizations and liquidation threshold";
    assert z1 == z2, "maxLPTWithdrawal must ignore the market state, utilizations and liquidation threshold";
}

// ==================================================================================================
// Property 18: preop_placeholder_lpt_raw_nav_reaching_capacity_views
// --------------------------------------------------------------------------------------------------
// preOpSyncTrancheAccounting returns lptRawNAV == 0 as a documented placeholder (the venue mark is
// committed separately). The views cannot distinguish a placeholder from a genuinely empty venue, so
// the question is which direction of staleness is dangerous. The rules below settle it: a supplied
// mark that is at most the mark in force at gate-evaluation time - the placeholder 0 being the
// extreme case - can only under-report; the figures it produces remain admissible by the REAL gate
// evaluated at the true mark. The complementary direction (a supplied mark ABOVE the gate-time mark)
// is genuinely unsafe and cannot be enforced from inside a permissionless view: it is a call-site
// obligation on the kernel/consumer. That obligation has been CHECKED against the current call sites
// rather than merely recorded: DepositLogic.inkindMaxDeposit, RedemptionLogic.inkindMaxRedeemable (both
// the JUNIOR and the LIQUIDITY_PROVIDER branch) and RedemptionLogic.lptMaxRedeemableMultiAsset all
// obtain their packet from AccountingSyncLogic.previewPreOpSyncTrancheAccounting, which overwrites the
// accountant's lptRawNAV == 0 placeholder with a live venue mark before any capacity view is invoked
// (Code Document-Ref 91c28bc36f7749d1). So the placeholder never reaches a capacity view through a
// protocol call path, and the only residual channel is movement of the mark between the preview and
// the gate - whose dust-scale instance is exactly the
// expected-to-fail rule dust_pad_dominates_dust_sized_venue_mark_drift under property 12. The third
// rule characterises the freeze the placeholder causes, so the consequence is proved rather than
// asserted.
// ==================================================================================================

/// @notice A stale-low or placeholder venue mark still yields a gate-admissible ST deposit size
rule stale_low_lpt_mark_st_deposit_still_gate_safe(
    env e, uint256 C, uint256 Pview, uint256 Pgate, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D, uint256 drift
) {
    requireRealisticMagnitudes(C, Pview, S, J, D);
    require Pgate <= NAV_BOUND();
    requireValidRatios(c, l);
    require Pview <= Pgate; // the supplied mark is stale-low (Pview == 0 is the documented placeholder)
    require drift <= D;

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, Pview, S, J, c, l);
    uint256 m = harness.maxSTDepositRaw(e, st);

    require m != 0;
    require m != MAX_NAV_UNITS_();
    require S + m <= NAV_BOUND();

    uint256 uLiq = harness.liquidityUtilizationRaw(e, assert_uint256(S + m + drift), l, Pgate);

    assert uLiq <= WAD(),
        "an ST deposit sized off a stale-low venue mark must still be admitted by the gate at the true mark";
}

/// @notice A stale-low or placeholder venue mark still yields a gate-admissible LPT withdrawal size
rule stale_low_lpt_mark_lpt_withdrawal_still_gate_safe(
    env e, uint256 C, uint256 Pview, uint256 Pgate, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D, uint256 drift
) {
    requireRealisticMagnitudes(C, Pview, S, J, D);
    require Pgate <= NAV_BOUND();
    requireValidRatios(c, l);
    require Pview <= Pgate;
    require drift <= D;

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, Pview, S, J, c, l);
    uint256 z = harness.maxLPTWithdrawalRaw(e, st);

    require z != 0;

    uint256 uLiq = harness.liquidityUtilizationRaw(e, assert_uint256(S + drift), l, assert_uint256(Pgate - z));

    assert uLiq <= WAD(),
        "an LPT redemption sized off a stale-low venue mark must still be admitted by the gate at the true mark";
}

/// @notice The placeholder mark zeroes both liquidity-bounded capacities exactly (the documented freeze)
rule placeholder_lpt_mark_zeroes_liquidity_bounded_capacity(
    env e, uint256 C, uint256 S, uint256 J, uint256 c, uint256 l, uint256 D
) {
    requireRealisticMagnitudes(C, 0, S, J, D);
    requireValidRatios(c, l);
    require l != 0;

    harness.harnessSetDustTolerance(e, D);
    RoycoDayAccountantHarness.RawSyncedAccountingState st = capacityState(C, 0, S, J, c, l);

    uint256 m = harness.maxSTDepositRaw(e, st);
    uint256 z = harness.maxLPTWithdrawalRaw(e, st);

    assert m == 0, "a placeholder (zero) venue mark reports zero ST deposit capacity for any nonzero liquidity requirement";
    assert z == 0, "a placeholder (zero) venue mark reports zero LPT withdrawal capacity";
}

// ==================================================================================================
// Property 19: no_advisory_bound_for_jt_deposit_liquidation_gate
// --------------------------------------------------------------------------------------------------
// The capacity surface exposes maxSTDeposit / maxJTWithdrawal / maxLPTWithdrawal and nothing for the
// JT_DEPOSIT gate, which requires the post-op coverage utilization to settle STRICTLY BELOW the
// liquidation threshold ('restore health in one shot'). Junior deposits are therefore effectively
// advertised as unconditional. The first rule encodes exactly that advertisement and is EXPECTED TO
// FAIL: once coverage utilization has breached the threshold, a junior deposit strictly smaller than
// the full recapitalization size is rejected by the gate, so an advertised-but-unconsumable capacity
// exists precisely during recovery. The second rule is the constructive half: the post-op utilization
// is monotonically nonincreasing in the junior deposit size for NAV-conserving states, so the gate is
// a single threshold in deposit size and the missing advisory figure (the minimum fillable junior
// deposit) is well defined and computable from the very state packet these views already receive.
// The Prover's witness for the failing rule: a NAV-conserving state with c = 15 (fifteen wei-WAD),
// J = 8, theta ~ 1.106e18 and coverage utilization u ~ 1.077e19 > theta; a junior deposit of x = 11
// improves the post-op utilization to ~4.53e18 - a genuine partial recapitalization - yet it is
// still above theta, so the JT_DEPOSIT gate reverts. RECOMMENDATION FOR THE PROTOCOL AUTHORS (not
// implemented here, since it is a source change to a component this spec only observes): add a
// fourth advisory view - a minJTDeposit / maxJTDepositShortfall figure derived from
// coverageLiquidationUtilizationWAD and padded by dustTolerance in the same senior-protective
// direction as the other three - and surface it from the kernel's inkindMaxDeposit for the junior
// tranche.
// ==================================================================================================

rule jt_deposit_of_any_size_admitted_when_coverage_breached(
    env e, uint256 C, uint256 S, uint256 J, uint256 c, uint256 theta, uint256 x
) {
    requireRealisticMagnitudes(C, 0, S, J, 0);
    require c < WAD();
    require theta > WAD(); // configuration invariant: the liquidation threshold sits above WAD
    require C == S + J;    // assumption A3
    require x != 0;
    require x <= NAV_BOUND();

    uint256 u = harness.coverageUtilizationRaw(e, C, c, J);
    require u >= theta; // coverage utilization has breached the liquidation threshold

    uint256 uPost = harness.coverageUtilizationRaw(e, assert_uint256(C + x), c, assert_uint256(J + x));

    assert uPost < theta,
        "a junior deposit of any positive size must be admitted by the JT_DEPOSIT gate for the capacity surface's silence to be sound";
}

/**
 * @notice The JT_DEPOSIT gate is a single monotone threshold in the junior deposit size
 * @dev EXCLUDED DEGENERATE BRANCH (stated, not hidden): _computeCoverageUtilization clamps an empty
 *      market (collateralNAV == 0) and a switched-off requirement (minCoverageWAD == 0) to utilization
 *      0, which is the minimum possible value, so a positive junior deposit into such a market moves
 *      the reported utilization UP off that floor (witness: C = S = J = 0, c = 8341, x1 = 0, x2 = 1
 *      gives u1 = 0 and u2 = 8341). That is a definitional artefact of the clamp, not a failure of
 *      the recovery direction, and it cannot arise in the scenario this property is about: a market
 *      that has breached the liquidation threshold theta > WAD necessarily has collateralNAV != 0 and
 *      minCoverageWAD != 0, since otherwise branch one pins its utilization to 0. On the remaining
 *      domain U(x) = ceil((C+x)*c/(J+x)) with C >= J is genuinely nonincreasing, and the
 *      J == 0 => type(uint256).max branch is the maximal value, so moving off it can only help.
 */
rule jt_deposit_monotonically_restores_coverage(
    env e, uint256 C, uint256 S, uint256 J, uint256 c, uint256 x1, uint256 x2
) {
    requireRealisticMagnitudes(C, 0, S, J, 0);
    require c < WAD();
    require C == S + J; // assumption A3
    require C != 0;     // the market is not empty (implied by a breached liquidation threshold)
    require c != 0;     // the coverage requirement is switched on (implied by a breached threshold)
    require x1 <= x2;
    require x2 <= NAV_BOUND();

    uint256 u1 = harness.coverageUtilizationRaw(e, assert_uint256(C + x1), c, assert_uint256(J + x1));
    uint256 u2 = harness.coverageUtilizationRaw(e, assert_uint256(C + x2), c, assert_uint256(J + x2));

    assert u2 <= u1,
        "a larger junior deposit must never leave the post-op coverage utilization higher: the fillable size is a single threshold";
}
