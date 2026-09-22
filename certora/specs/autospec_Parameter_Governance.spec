/*
 * =====================================================================================================
 *  RoycoDayAccountant — Parameter Governance
 * =====================================================================================================
 *
 *  Scope: the twelve `restricted` setters of `RoycoDayAccountant`, the `withSyncedAccounting` guard that
 *  brackets ten of them, the two YDM swap paths, and the configuration/clock state they write.
 *
 *  ---------------------------------------------------------------------------------------------------
 *  ENVIRONMENT MODEL (every assumption is stated; see AUTOPROVER.md §5 for the protocol team's briefing)
 *  ---------------------------------------------------------------------------------------------------
 *
 *  (M1) The kernel callback `syncTrancheAccountingFromAccountant()` is summarized by `cvlKernelSync()`:
 *       it returns an *unconstrained* `SyncedAccountingState` whose three configuration fields
 *       (`minCoverageWAD`, `coverageLiquidationUtilizationWAD`, `minLiquidityWAD`) are pinned to the
 *       accountant's storage at the moment of the call — exactly as both real sync entrypoints marshal
 *       them. This is AUTOPROVER.md §5.1 "kernel model 2": the callback's only effect on accountant
 *       storage in reality is to re-enter the accountant's own `preOpSyncTrancheAccounting` +
 *       `commitLiquidityProviderTrancheRawNAV`, so a setter's real execution is
 *       [sync] -> [own field write] -> [sync] where each step is an accountant entrypoint.
 *       Consequences, and how each is handled:
 *         - For the guard-semantics rules (Properties 4, 5, 6, 7) leaving the returned utilizations
 *           unconstrained is an *over-approximation*: the guard's `require`s are proved to hold for
 *           arbitrary sync results, which is strictly stronger than proving them for the reachable ones.
 *         - Properties about what the bracketing syncs *do to storage* (Properties 11, 16, 22) are
 *           therefore stated where that work actually happens: directly on
 *           `preOpSyncTrancheAccounting`, which is the callback's body. Nothing is assumed about it.
 *         - Frame-style claims over setters (Properties 17, 18, 22) are claims about the setter body
 *           only; the accompanying `preOpSyncTrancheAccounting` rules discharge the callback half.
 *       The summary can be made to revert (ghost `gSyncReverts`), which models a paused kernel, a
 *       reverting/stale collateral oracle, or an in-flight operation frame (Properties 8, 13).
 *
 *  (M2) `IYDM.yieldShare` / `IYDM.previewYieldShare` are summarized by a CVL function returning a fresh
 *       unconstrained `uint256`. Assumes: side-effect free (the real functions may advance an adaptive
 *       curve — that state lives in the YDM contract and no property here reads it), and no revert.
 *       Excludes: a YDM that reverts (Property 8 covers the "market sync bricked" scenario through the
 *       kernel-sync leg instead), and any determinism between two reads (not needed here — the
 *       accountant clamps every read with `Math.min(., max*YieldShareWAD)`, and leaving the magnitude
 *       unconstrained is what proves the clamp works).
 *
 *  (M3) The `restricted` modifier resolves through `AuthorityUtils.canCallWithDelay`, whose body is an
 *       assembly `staticcall` the Prover cannot resolve. That internal library function is summarized by
 *       `cvlCanCallWithDelay`, backed by the `gCallerAllowed(caller, target)` ghost, with delay 0.
 *       Assumes: an authority that answers immediately. Excludes the AccessManager's *scheduled
 *       operation* path (`delay > 0`), i.e. a caller who holds no immediate grant but has a scheduled
 *       op is modeled as denied. That direction is the conservative one for Property 3 ("a denied caller
 *       cannot write config") and irrelevant for the rules that grant access.
 *
 *  (M4) One unresolved low-level call remains: `_initializeYDM`'s `_dispatch` of caller-supplied
 *       calldata to the incoming YDM. It keeps the Prover's default `AUTO` (`HAVOC_ECF`) treatment: the
 *       accountant's own storage is preserved, other contracts' storage is havoced. Because that havoc
 *       also havocs regular ghosts, *every* ghost in this file is declared `persistent`. (The other
 *       low-level call, the YDM setters' best-effort sync, is modeled — see (M6).)
 *
 *  (M5) Global assumptions, applied where relevant and named in each rule: `0 < block.timestamp < 2^31`
 *       and `block.timestamp >= lastYieldShareAccrualTimestamp / lastPremiumPaymentTimestamp` (the
 *       accountant stores uint32 timestamps; without this, uint32 truncation falsifies clock properties
 *       — the repo tests that wrap behavior separately), realistic NAV magnitudes (<= 1e45) where NAV
 *       arithmetic is compared, and `msg.sender != 0`.
 *
 *  (M6) `DispatchLogic._tryExecute` — the four-line best-effort primitive whose whole body is
 *       `return _target.call(_callData);` — is modeled in CVL. See the entry's own comment for the full
 *       argument. In one line: the model *is* EVM `CALL` semantics (a failed inner call surfaces as a
 *       `false` flag, never as a revert of the caller), it is not a protocol-specific claim, and it is
 *       forced by a Prover artifact (unconstrained `RETURNDATASIZE` at the raw call, which manufactures
 *       a revert of the *caller*). What it assumes: that this generic library primitive keeps that
 *       one-line body. What it does *not* assume, and what the rules still check: that the accountant's
 *       YDM setters route their pre-swap sync through the *best-effort* primitive rather than through
 *       the bubbling `_execute`/`_dispatch` ones (a different function, unaffected by this entry, so
 *       such a regression still produces a counterexample).
 *
 *  (M7) NAMED ASSUMPTION — kernel packet fidelity on the liquidity leg. The `withSyncedAccounting`
 *       guard reads `liquidityUtilizationWAD` and `lptRawNAV` out of the packet the *kernel* returns.
 *       The accountant emits both as zero placeholders (proved by
 *       `sync_packet_reports_true_liquidity_state`) and the protocol's convention is that the kernel
 *       marks the venue, calls `commitLiquidityProviderTrancheRawNAV`, and patches the packet before
 *       returning it. Under (M1) the kernel is summarized, so *this spec does not verify that the
 *       convention is honoured*; the packet's utilizations are left unconstrained, which is the sound
 *       direction for Properties 4/5/6/7 (they are proved for arbitrary packets) but leaves Property
 *       14's guard-side leg assumed. Discharging it requires a rule on
 *       `RoycoDayBalancerV3Kernel.syncTrancheAccountingFromAccountant` — which is present in the source
 *       tree with a harness — asserting that the packet it hands to the guard carries the freshly
 *       committed mark, taken after the fee/premium share mints. Properties 4, 5, 6 and 14 all rest on
 *       that kernel-side obligation.
 *
 *  ---------------------------------------------------------------------------------------------------
 *  EXPECTED FAILURES
 *  ---------------------------------------------------------------------------------------------------
 *  The eleven attack-vector properties in this batch (9, 10, 11, 12, 13, 14, 15, 19, 20, 21, 23) are
 *  each formalized as the *absence* of the attack. Where the Prover produces a counterexample the
 *  attack is confirmed and the rule is marked "expected to fail" — the counterexample is the finding.
 *  Property 16 is stated in full generality (expected to fail, because the premium NAV movement is not
 *  gated on the accumulator-consuming `premiumsPaid` flag) and again under `dustTolerance == 0`, where
 *  it holds — isolating the unvalidated parameter the violation depends on.
 *
 *  CONFIRMED WITNESSES, recorded so no finding is misread from the single instance the solver happened
 *  to report:
 *    - `dust_tolerance_stays_bounded` — a live market's tolerance raised to ~2^256 by an authorized
 *      caller, both bracketing syncs passing with the utilizations literally unchanged across the write.
 *      `initialize` writes the same field with no validation either (there is no `_validateDustTolerance`).
 *    - `capacity_views_never_revert` — `dustTolerance` near 2^256 against a tiny `collateralNAV`; the
 *      revert is the checked NAV addition reached from `maxSTDeposit` *and* `maxJTWithdrawal`.
 *      `maxLPTWithdrawal` returned normally only because the solver short-circuited on
 *      `minLiquidityWAD == 0`; its own `stEffectiveNAV + dustTolerance` site is equally exposed.
 *    - `sync_cannot_erase_live_junior_recovery_claim` — `dustTolerance == lastJTImpermanentLoss` with
 *      `collateralNAV == lastCollateralNAV` (no PnL at all, so nothing legitimately repaid the claim).
 *      The other six forcing conditions are excluded by the rule's own preconditions.
 *    - `premium_payment_consumes_accrual_window` — a non-zero LPT accumulator built over a real window,
 *      `dustTolerance == stGain` so `premiumsPaid == false`, yet a non-zero `lptLiquidityPremium` is
 *      reported and both accumulators and the premium clock survive the payment. A *second*, independent
 *      defect lives on the `elapsedSinceLastPremiumPayments == 0` path, which substitutes a synthetic
 *      one-second window and stamps nothing; it is not closed by any dust-tolerance bound, which is why
 *      the companion `..._zero_dust` rule is scoped to the dust gate only.
 *    - `liquidation_threshold_cannot_be_lowered` / `liquidation_threshold_raise_is_bounded` — a one-wei
 *      decrease, and a raise past 2e18 from a FIXED_TERM prestate with a maximal duration. Both are the
 *      same one-sided `require(Theta > WAD)`: the guard's Theta clause is vacuous in *both* directions
 *      while the market is healthy.
 *    - `protocol_fees_cannot_reach_full_appropriation` — violated on all four setters, each moving
 *      `1e18 - 1` to exactly `1e18`; all four share the identical non-strict `<=` against the identical
 *      constant, so this is not specific to whichever setter is reported.
 *    - `requirements_cannot_be_zeroed` — both `setMinCoverage(0)` and `setMinLiquidity(0)` witnessed from
 *      a `WAD - 1` prestate. The guard is *self-certifying* here: the utilizations it inspects are
 *      computed from the very parameter being zeroed, so no tuning of the guard predicate can catch it.
 *    - `guarded_setter_executable_when_sync_reverts` — a legal argument from an authorized caller; the
 *      revert originates in the modifier's mandatory pre-op sync, before any field is read.
 *    - `sync_packet_reports_true_liquidity_state` — `state.lptRawNAV == 0` returned while
 *      `$.lastLPTRawNAV` is non-zero, with `liquidityUtilizationWAD == 0` in the same packet (the second
 *      conjunct is unreached only because the first fails first; both are violable). Scope: this proves
 *      the *accountant* emits a placeholder, not that the deployed kernel fails to patch it — see (M7).
 *    - `ydm_swap_target_must_be_a_genuine_ydm` — the market's own kernel installed as the JT YDM, with
 *      empty initialization calldata; `newYDM == currentContract` is equally admissible, so this is not
 *      a kernel-only finding.
 *    - `ydm_swap_always_reinitializes_incoming_ydm` — empty initialization calldata, `_initializeYDM`
 *      opens and closes with no sub-call at all, and the YDM pointer is overwritten regardless.
 *    - `ydm_swap_leaves_no_unaccrued_window` — the best-effort sync reports failure, the flag is
 *      discarded, the YDM pointer moves, and the accrual clock is left behind the current block.
 */

import "summaries/RoycoDayAccountant_base_summaries.spec";
import "summaries/custom_summaries.spec";

// -----------------------------------------------------------------------------
// Methods block
// -----------------------------------------------------------------------------

methods {
    // Reads storage only; touches no msg.*/block.* field. The Prover verifies the envfree claim.
    function RoycoDayAccountant.getState() external returns (IRoycoDayAccountant.RoycoDayAccountantState) envfree;

    // (M1) The market's kernel. Receiver is a storage address the Prover cannot resolve; `ALL` is used
    // so the model is applied at every call site regardless of whether the Prover resolves it.
    function _.syncTrancheAccountingFromAccountant() external
        => cvlKernelSync() expect RoycoDayAccountant.SyncedAccountingState ALL;

    // (M2) Both YDM reads: unconstrained magnitude, no state change, no revert.
    function _.yieldShare(RoycoDayAccountant.MarketState marketState, uint256 utilizationWAD) external
        => cvlYieldShare() expect uint256 ALL;
    function _.previewYieldShare(RoycoDayAccountant.MarketState marketState, uint256 utilizationWAD) external
        => cvlYieldShare() expect uint256 ALL;

    // (M3) The authorization oracle behind every `restricted` setter.
    function AuthorityUtils.canCallWithDelay(address authority, address caller, address target, bytes4 selector)
        internal returns (bool, uint32) => cvlCanCallWithDelay(caller, target);

    // (M6) The best-effort dispatch primitive. Its entire body is `return _target.call(_callData);`.
    //
    // WHY IT IS MODELED. At an unmodeled raw `.call` the Prover leaves `RETURNDATASIZE` unconstrained,
    // and Solidity's `bytes memory` copy of an astronomically long buffer reverts — so the Prover
    // manufactures a revert of `setJuniorTrancheYDM` that the contract does not produce. That was the
    // literal counterexample: revert explanation `tacReturnsize <= 2^64 - 1`, no contract line
    // implicated, which both violated Property 8's rule and made Property 10's rule vacuous (all paths
    // reverting). The targeted remedy for this artifact is the Prover option `optimisticReturnsize`,
    // which is a *configuration* setting; the configuration-editing capability available here exposes
    // only input-file and storage-extension settings, with no way to set that flag, so the artifact is
    // removed in CVL instead.
    //
    // WHAT IS ASSUMED, PRECISELY. The summary encodes EVM `CALL` semantics — a failed inner call
    // surfaces to the caller as a `false` success flag and never as a revert — plus a pinned (empty)
    // result buffer, which the accountant discards unread at both call sites. The assumption is
    // therefore about the *generic* library primitive keeping its one-line body, not about the
    // accountant. It excludes exactly one regression class: `_tryExecute` itself being rewritten to
    // bubble.
    //
    // WHAT IS STILL CHECKED, AND WHY PROPERTY 8 IS NOT ASSUMED BACK TO ITSELF. Property 8's subject is
    // the *setter*: whether it settles through the best-effort primitive or through a bubbling one, and
    // whether it inspects the outcome. This entry names `_tryExecute` only. A setter rewritten to use
    // `_execute` / `_dispatch` (the bubbling primitives, which this spec does not summarize), or one
    // that branched on the flag and reverted, is a different program the summary does not cover, and
    // `ydm_swap_succeeds_despite_reverting_sync` would produce a counterexample for it. Likewise
    // `gSyncReverts` leaves the inner call's *outcome* symbolic, so nothing about the swap's success is
    // hard-wired.
    //
    // REACH. `internal` entries apply at every call site (`ALL`). The only sites reachable in this spec
    // are the accountant's two YDM setters, whose call is always
    // `abi.encodeCall(IRoycoDayKernel.syncTrancheAccountingFromAccountant, ())` — so the modeled inner
    // call is the market sync, and the model shares its `gSyncReverts` / bookkeeping with (M1).
    function DispatchLogic._tryExecute(address _target, bytes memory _callData)
        internal returns (bool, bytes memory) => cvlTryExecuteSync();
}

// -----------------------------------------------------------------------------
// Named constants
// -----------------------------------------------------------------------------

/// src/libraries/Constants.sol: `uint256 constant WAD = 1e18`
definition WAD() returns mathint = 1000000000000000000;

/// src/libraries/Constants.sol: `uint256 constant MAX_PROTOCOL_FEE_WAD = 1e18` (= 100%)
definition MAX_PROTOCOL_FEE_WAD() returns mathint = 1000000000000000000;

/// Upper end of the realistic NAV range (ASM-3 of AUTOPROVER.md §5.2): token amounts times oracle
/// prices cannot approach this, and it keeps the checked NAV additions away from their overflow cliff.
definition SANE_NAV() returns mathint = 1000000000000000000000000000000000000000000000;

/// uint32 timestamp headroom (ASM-1 of AUTOPROVER.md §5.2).
definition MAX_TIMESTAMP() returns mathint = 2147483648;

/// A generous governance ceiling for the liquidation threshold: coverage utilization at 200% means the
/// junior buffer has fallen to half of what the coverage requirement demands. The contract imposes no
/// ceiling at all; Property 23 asks whether *some* ceiling is enforced, and this is the placeholder.
definition MAX_SANE_LIQUIDATION_UTILIZATION_WAD() returns mathint = 2000000000000000000;

// -----------------------------------------------------------------------------
// Instrumentation ghosts (all `persistent`: see (M4))
// -----------------------------------------------------------------------------

/// (M1) Selects the modeled behavior of the market sync: `true` models a sync that reverts
/// (paused kernel, stale/reverting collateral oracle, in-flight operation frame, bricked YDM).
persistent ghost bool gSyncReverts;

/// Number of market syncs performed so far in the rule. A guarded setter performs exactly two (the
/// `withSyncedAccounting` bracket); the YDM setters perform at most one (best-effort); no other
/// accountant entrypoint performs any. `gSyncCalls == 2` therefore *characterizes* "the full guard ran"
/// without naming any selector.
persistent ghost mathint gSyncCalls;

/// The utilizations and the liquidation threshold carried by the packet the guard reads, per sync index.
persistent ghost mapping(mathint => mathint) gSyncCovU;
persistent ghost mapping(mathint => mathint) gSyncLiqU;
persistent ghost mapping(mathint => mathint) gSyncTheta;

/// The accountant's configuration as observed *by* each sync (i.e. at the moment the settling /
/// trailing sync runs). Used by Property 7 to prove the ordering of settlement versus the field write.
persistent ghost mapping(mathint => mathint) gSyncMinCov;
persistent ghost mapping(mathint => mathint) gSyncMinLiq;
persistent ghost mapping(mathint => mathint) gSyncStFee;
persistent ghost mapping(mathint => mathint) gSyncJtFee;
persistent ghost mapping(mathint => mathint) gSyncJtYsFee;
persistent ghost mapping(mathint => mathint) gSyncLptYsFee;
persistent ghost mapping(mathint => mathint) gSyncMaxJT;
persistent ghost mapping(mathint => mathint) gSyncMaxLPT;

/// (M3) The authority's verdict for a caller on a target.
persistent ghost gCallerAllowed(address, address) returns bool;

/// Call observation: counts raw CALLs issued to `gWatchedTarget` (used to detect whether the YDM
/// initialization dispatch actually happened — Property 21).
persistent ghost address gWatchedTarget;
persistent ghost mathint gCallsToWatched;

hook CALL(uint g, address addr, uint value, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint rc {
    if (addr == gWatchedTarget) {
        gCallsToWatched = gCallsToWatched + 1;
    }
}

// -----------------------------------------------------------------------------
// Summary bodies
// -----------------------------------------------------------------------------

/// (M2) An opaque yield-share model: a fresh unconstrained WAD fraction on every read.
function cvlYieldShare() returns uint256 {
    uint256 shareWAD;
    return shareWAD;
}

/// (M3) The authority answers immediately (delay 0), granting or denying per (caller, target).
function cvlCanCallWithDelay(address caller, address target) returns (bool, uint32) {
    return (gCallerAllowed(caller, target), 0);
}

/// (M6) The best-effort market sync of the two YDM setters. `gSyncReverts` selects whether the inner
/// call failed (flag `false`, caller swallows it — nothing was synced) or succeeded (the sync is
/// recorded exactly as on the mandatory path). Both return values are discarded by the caller, so the
/// empty result buffer is immaterial.
function cvlTryExecuteSync() returns (bool, bytes) {
    bytes empty;
    require empty.length == 0;

    if (gSyncReverts) {
        return (false, empty);
    }

    RoycoDayAccountant.SyncedAccountingState ignored = cvlKernelSync();
    return (true, empty);
}

/// (M1) The market sync as the accountant's callers see it.
function cvlKernelSync() returns RoycoDayAccountant.SyncedAccountingState {
    // Structural floor on the instrumentation counter: without it the Prover may start the counter
    // negative, the ghost indices below shift, and any rule whose antecedent is `gSyncCalls == 2`
    // becomes unsatisfiable — i.e. its assertion passes *vacuously*. Every rule that indexes a
    // `gSync*` map additionally pins `gSyncCalls == 0` in its preamble; this is the belt to that brace.
    require gSyncCalls >= 0;

    if (gSyncReverts) {
        // Modeled failure of the market sync. A `revert` inside an expression summary is observed by
        // the calling contract exactly like a real callee revert, so the guard's mandatory sync
        // propagates it while the YDM setters' best-effort `_tryExecute` swallows it.
        revert("modeled market sync failure");
    }

    RoycoDayAccountant.SyncedAccountingState state;
    // Both real sync entrypoints marshal these three straight out of storage, so the packet the guard
    // inspects cannot disagree with the stored configuration. Everything else is left unconstrained.
    require state.minCoverageWAD == getMinCoverageWAD();
    require state.coverageLiquidationUtilizationWAD == getCoverageLiquidationUtilizationWAD();
    require state.minLiquidityWAD == getMinLiquidityWAD();

    gSyncCovU[gSyncCalls] = state.coverageUtilizationWAD;
    gSyncLiqU[gSyncCalls] = state.liquidityUtilizationWAD;
    gSyncTheta[gSyncCalls] = state.coverageLiquidationUtilizationWAD;
    gSyncMinCov[gSyncCalls] = getMinCoverageWAD();
    gSyncMinLiq[gSyncCalls] = getMinLiquidityWAD();
    gSyncStFee[gSyncCalls] = getSTProtocolFeeWAD();
    gSyncJtFee[gSyncCalls] = getJTProtocolFeeWAD();
    gSyncJtYsFee[gSyncCalls] = getJTYieldShareProtocolFeeWAD();
    gSyncLptYsFee[gSyncCalls] = getLPTYieldShareProtocolFeeWAD();
    gSyncMaxJT[gSyncCalls] = getMaxJTYieldShareWAD();
    gSyncMaxLPT[gSyncCalls] = getMaxLPTYieldShareWAD();
    gSyncCalls = gSyncCalls + 1;

    return state;
}

// -----------------------------------------------------------------------------
// State accessors (one revert-free, env-free view call each)
// -----------------------------------------------------------------------------

function getKernel() returns address {
    return currentContract.getState().kernel;
}

function getGraceStamp() returns mathint {
    return currentContract.getState().fixedTermCommenceableAtTimestamp;
}

function getMinCoverageWAD() returns mathint {
    return currentContract.getState().minCoverageWAD;
}

function getMinLiquidityWAD() returns mathint {
    return currentContract.getState().minLiquidityWAD;
}

function getCoverageLiquidationUtilizationWAD() returns mathint {
    return currentContract.getState().coverageLiquidationUtilizationWAD;
}

function getSTProtocolFeeWAD() returns mathint {
    return currentContract.getState().stProtocolFeeWAD;
}

function getJTProtocolFeeWAD() returns mathint {
    return currentContract.getState().jtProtocolFeeWAD;
}

function getJTYieldShareProtocolFeeWAD() returns mathint {
    return currentContract.getState().jtYieldShareProtocolFeeWAD;
}

function getLPTYieldShareProtocolFeeWAD() returns mathint {
    return currentContract.getState().lptYieldShareProtocolFeeWAD;
}

function getMaxJTYieldShareWAD() returns mathint {
    return currentContract.getState().maxJTYieldShareWAD;
}

function getMaxLPTYieldShareWAD() returns mathint {
    return currentContract.getState().maxLPTYieldShareWAD;
}

function getFixedTermDurationSeconds() returns mathint {
    return currentContract.getState().fixedTermDurationSeconds;
}

function getFixedTermEndTimestamp() returns mathint {
    return currentContract.getState().fixedTermEndTimestamp;
}

function getJTYDM() returns address {
    return currentContract.getState().jtYDM;
}

function getLPTYDM() returns address {
    return currentContract.getState().lptYDM;
}

function getDustTolerance() returns mathint {
    return currentContract.getState().dustTolerance;
}

function getTwJT() returns mathint {
    return currentContract.getState().twJTYieldShareAccruedWAD;
}

function getTwLPT() returns mathint {
    return currentContract.getState().twLPTYieldShareAccruedWAD;
}

function getAccrualClock() returns mathint {
    return currentContract.getState().lastYieldShareAccrualTimestamp;
}

function getPremiumClock() returns mathint {
    return currentContract.getState().lastPremiumPaymentTimestamp;
}

function getLastCollateralNAV() returns mathint {
    return currentContract.getState().lastCollateralNAV;
}

function getLastSTEffectiveNAV() returns mathint {
    return currentContract.getState().lastSTEffectiveNAV;
}

function getLastJTEffectiveNAV() returns mathint {
    return currentContract.getState().lastJTEffectiveNAV;
}

function getLastJTImpermanentLoss() returns mathint {
    return currentContract.getState().lastJTImpermanentLoss;
}

function getLastLPTRawNAV() returns mathint {
    return currentContract.getState().lastLPTRawNAV;
}

function isMarketPerpetual() returns bool {
    return currentContract.getState().lastMarketState == RoycoDayAccountant.MarketState.PERPETUAL;
}

/// `$.kernel` is written by exactly one function (`initialize`), which requires the value it writes to
/// be non-zero, so this is the "has been configured" witness (AUTOPROVER.md §4.1).
function initialized() returns bool {
    return getKernel() != 0;
}

/// (M5) uint32 clock hygiene: time moves forward relative to every stored checkpoint and stays inside
/// the uint32 range the accountant casts into.
/// Also imports the three proved structural lemmas, so that every rule reasoning about the accountant's
/// checkpointed state starts from a *reachable* configuration rather than from an arbitrary one: the
/// accrual-clock/accumulator coupling, NAV conservation, and the fixed-term lifecycle coupling. All
/// three are proved invariants, not assumptions. (`fixed_term_lifecycle_coupling`'s own preserved block
/// calls this function; an invariant is always assumed inside its own preserved block, so the citation
/// is a no-op there, and the remaining citations are ordinary mutual citation between proved
/// invariants — §1 of the invariants guide.)
function timestampHygiene(env e) {
    requireInvariant accrual_clock_zero_implies_no_accrual();
    requireInvariant nav_conservation();
    requireInvariant fixed_term_lifecycle_coupling();
    require e.block.timestamp > 0;
    require to_mathint(e.block.timestamp) < MAX_TIMESTAMP();
    require to_mathint(e.block.timestamp) >= getAccrualClock();
    require to_mathint(e.block.timestamp) >= getPremiumClock();
    return;
}

/// The accountant is live: initialized, deployed (so OpenZeppelin's `initializer` is spent), and not
/// being addressed by the zero account.
function liveAccountant(env e) {
    requireInvariant initializer_consumed_once_kernel_is_set();
    require initialized();
    require nativeCodesize[currentContract] > 0;
    require e.msg.sender != 0;
    return;
}

// =============================================================================
// Lemma: a configured kernel implies the initializer has already been consumed
// =============================================================================

/**
 * Ties the accountant's own "am I configured?" witness to OpenZeppelin's `Initializable` version
 * counter, read through the ERC-7201 storage-extension path. Inductive with no assumption: the
 * constructor's `_disableInitializers()` leaves the counter at `type(uint64).max`; `initialize` sets it
 * to 1 while writing a non-zero kernel; no other method writes either quantity.
 *
 * Consumer: every rule that needs "`initialize` cannot run again", i.e. every rule that reasons about
 * an already-configured accountant (Properties 2, 3, 6, 15, 19, 20, 23).
 */
invariant initializer_consumed_once_kernel_is_set()
    initialized() => (currentContract.ext_openzeppelin_storage_Initializable._initialized != 0)
    filtered { f -> f.contract == currentContract }

// =============================================================================
// Property 18 (part 1) — the two structural couplings the property names
// =============================================================================

/**
 * NAV conservation: the checkpointed collateral is exactly the sum of the two tranche claims. Property 18
 * names this as one of the two facts that must still hold "at the end of every setter call".
 *
 * Inductive with no assumption: `preOpSyncTrancheAccounting` and `postOpSyncTrancheAccounting` each
 * `require(_collateralNAV == stEffectiveNAV + jtEffectiveNAV)` and then checkpoint all three fields
 * together; no other method writes any of them (which is itself the content of
 * `setters_never_write_nav_checkpoints`); the constructor/initializer state is all-zero.
 */
invariant nav_conservation()
    getLastCollateralNAV() == getLastSTEffectiveNAV() + getLastJTEffectiveNAV()
    filtered { f -> f.contract == currentContract }

/**
 * The lifecycle coupling Property 18 names: PERPETUAL <=> no outstanding drawdown <=> no running term.
 * A setter that left these three fields disagreeing would hand the kernel's fixed-term gates an
 * internally inconsistent lifecycle state to act on.
 *
 * Inductive: the state machine's perpetual commit zeroes the drawdown ledger *and* the term stamp
 * together; its fixed-term branch is reachable only when `jtImpermanentLoss > dustTolerance >= 0` (hence
 * non-zero) and either stamps `block.timestamp + duration` (non-zero for a non-zero duration inside the
 * uint32 range — (M5)) or preserves the already non-zero stamp; `setFixedTermDuration(0)` writes all
 * three consistently; `postOpSyncTrancheAccounting` and every other method leave all three alone.
 */
invariant fixed_term_lifecycle_coupling()
    (isMarketPerpetual() <=> getLastJTImpermanentLoss() == 0)
        && (isMarketPerpetual() <=> getFixedTermEndTimestamp() == 0)
    filtered { f -> f.contract == currentContract }
    {
        preserved with (env e) {
            timestampHygiene(e);
        }
    }

// =============================================================================
// Lemma: an unstamped accrual clock implies empty accrual accumulators
// =============================================================================

/**
 * `_accruePremiumYieldShares` treats `lastYieldShareAccrualTimestamp == 0` as "never accrued": it stamps
 * both clocks and returns a zero accrual. `initialize` does *not* stamp the clock, so that branch is
 * genuinely reachable — but only from the zero-initialized state, where both accumulators are zero too.
 * Without this lemma the Prover pairs an unstamped clock with a *non-zero* accumulator, an unreachable
 * prestate that manufactures counterexamples in which a "premium" is reported out of a window that never
 * existed.
 *
 * Inductive with no assumption beyond a non-zero block timestamp: the only writes that grow either
 * accumulator (`_accruePremiumYieldShares`, elapsed > 0 branch) stamp the clock to `block.timestamp` in
 * the same breath, and the only other writes zero them (the premium payment in
 * `preOpSyncTrancheAccounting`).
 *
 * Consumers: every rule reasoning about the accrual window (Properties 16 and 22).
 */
invariant accrual_clock_zero_implies_no_accrual()
    getAccrualClock() == 0 => (getTwJT() == 0 && getTwLPT() == 0)
    filtered { f -> f.contract == currentContract }
    {
        preserved with (env e) {
            timestampHygiene(e);
        }
    }

// =============================================================================
// Property 1 — config_bounds_always_valid
// =============================================================================

/**
 * Every configuration field of an initialized accountant satisfies exactly the bounds `initialize`
 * enforces, no matter which setter ran last. Stated as a single inductive invariant over every method
 * of the accountant, so it covers the initializer's base case, all twelve setters, the three kernel-only
 * sync entrypoints and the inherited `pause`/`unpause`/`setAuthority` surface.
 *
 * `filtered` restricts the induction steps to the verified accountant's own methods: the invariant
 * constrains only its storage, the accountant is never a delegatecall target (`DispatchLogic` uses
 * plain `.call`), and every reentrant entry point into it is itself one of the checked steps.
 */
invariant config_bounds_always_valid()
    initialized() => (
        getMinCoverageWAD() < WAD()
            && getMinLiquidityWAD() < WAD()
            && getCoverageLiquidationUtilizationWAD() > WAD()
            && getSTProtocolFeeWAD() <= MAX_PROTOCOL_FEE_WAD()
            && getJTProtocolFeeWAD() <= MAX_PROTOCOL_FEE_WAD()
            && getJTYieldShareProtocolFeeWAD() <= MAX_PROTOCOL_FEE_WAD()
            && getLPTYieldShareProtocolFeeWAD() <= MAX_PROTOCOL_FEE_WAD()
            && (getMaxJTYieldShareWAD() + getMaxLPTYieldShareWAD()) <= WAD()
            && getJTYDM() != 0
            && getLPTYDM() != 0
            && getJTYDM() != getLPTYDM()
    )
    filtered { f -> f.contract == currentContract }

// =============================================================================
// Property 2 — kernel_pointer_and_grace_stamp_immutable_after_init
// =============================================================================

/**
 * Once the accountant is configured, no method can move the `kernel` pointer or the
 * `fixedTermCommenceableAtTimestamp` grace stamp. `initialize` is *not* filtered out: the lemma
 * invariant makes OpenZeppelin's `initializer` modifier revert on an already-configured accountant.
 *
 * The `initialize` selector is filtered out only because that instance is *provably vacuous* — every
 * path through it reverts under the lemma, which the Prover reports as a sanity failure rather than as a
 * pass. The exclusion therefore removes no behavior: the lemma is what discharges that step. The same
 * filter, for the same reason, appears on the other rules below that assume a live accountant.
 */
rule kernel_and_grace_stamp_immutable_after_init(method f, env e, calldataarg args)
    filtered {
        f -> f.contract == currentContract
            && f.selector != sig:initialize(IRoycoDayAccountant.RoycoDayAccountantInitParams).selector
    }
{
    liveAccountant(e);

    address kernelBefore = getKernel();
    mathint graceBefore = getGraceStamp();

    f(e, args);

    assert getKernel() == kernelBefore, "the kernel pointer is written exactly once, by initialize";
    assert getGraceStamp() == graceBefore, "the fixed-term grace stamp is written exactly once, by initialize";
}

// =============================================================================
// Property 3 — config_fields_only_writable_by_authorized_setters
// =============================================================================

/**
 * Sole-writer frame condition: each configuration field changes only under `initialize` or its own
 * dedicated setter. In particular the kernel-only sync entrypoints
 * (`preOpSyncTrancheAccounting`, `commitLiquidityProviderTrancheRawNAV`,
 * `postOpSyncTrancheAccounting`) and every view are covered — their selectors appear in none of the
 * permitted sets, so any config write by them is a counterexample.
 */
rule config_fields_have_dedicated_writers(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract }
{
    mathint stFee0 = getSTProtocolFeeWAD();
    mathint jtFee0 = getJTProtocolFeeWAD();
    mathint jtYsFee0 = getJTYieldShareProtocolFeeWAD();
    mathint lptYsFee0 = getLPTYieldShareProtocolFeeWAD();
    mathint minCov0 = getMinCoverageWAD();
    mathint theta0 = getCoverageLiquidationUtilizationWAD();
    mathint minLiq0 = getMinLiquidityWAD();
    mathint maxJT0 = getMaxJTYieldShareWAD();
    mathint maxLPT0 = getMaxLPTYieldShareWAD();
    mathint duration0 = getFixedTermDurationSeconds();
    mathint dust0 = getDustTolerance();
    address jtYDM0 = getJTYDM();
    address lptYDM0 = getLPTYDM();

    f(e, args);

    bool isInit = f.selector == sig:initialize(IRoycoDayAccountant.RoycoDayAccountantInitParams).selector;

    assert getSTProtocolFeeWAD() != stFee0
        => (isInit || f.selector == sig:setSeniorTrancheProtocolFee(uint64).selector),
        "stProtocolFeeWAD is written only by initialize and setSeniorTrancheProtocolFee";
    assert getJTProtocolFeeWAD() != jtFee0
        => (isInit || f.selector == sig:setJuniorTrancheProtocolFee(uint64).selector),
        "jtProtocolFeeWAD is written only by initialize and setJuniorTrancheProtocolFee";
    assert getJTYieldShareProtocolFeeWAD() != jtYsFee0
        => (isInit || f.selector == sig:setJTYieldShareProtocolFee(uint64).selector),
        "jtYieldShareProtocolFeeWAD is written only by initialize and setJTYieldShareProtocolFee";
    assert getLPTYieldShareProtocolFeeWAD() != lptYsFee0
        => (isInit || f.selector == sig:setLPTYieldShareProtocolFee(uint64).selector),
        "lptYieldShareProtocolFeeWAD is written only by initialize and setLPTYieldShareProtocolFee";
    assert getMinCoverageWAD() != minCov0
        => (isInit || f.selector == sig:setMinCoverage(uint64).selector),
        "minCoverageWAD is written only by initialize and setMinCoverage";
    assert getCoverageLiquidationUtilizationWAD() != theta0
        => (isInit || f.selector == sig:setLiquidationCoverageUtilization(uint256).selector),
        "coverageLiquidationUtilizationWAD is written only by initialize and setLiquidationCoverageUtilization";
    assert getMinLiquidityWAD() != minLiq0
        => (isInit || f.selector == sig:setMinLiquidity(uint64).selector),
        "minLiquidityWAD is written only by initialize and setMinLiquidity";
    assert (getMaxJTYieldShareWAD() != maxJT0 || getMaxLPTYieldShareWAD() != maxLPT0)
        => (isInit || f.selector == sig:setMaxYieldShares(uint64,uint64).selector),
        "the max yield shares are written only by initialize and setMaxYieldShares";
    assert getFixedTermDurationSeconds() != duration0
        => (isInit || f.selector == sig:setFixedTermDuration(uint24).selector),
        "fixedTermDurationSeconds is written only by initialize and setFixedTermDuration";
    assert getDustTolerance() != dust0
        => (isInit || f.selector == sig:setDustTolerance(RoycoDayAccountant.NAV_UNIT).selector),
        "dustTolerance is written only by initialize and setDustTolerance";
    assert getJTYDM() != jtYDM0
        => (isInit || f.selector == sig:setJuniorTrancheYDM(address,bytes).selector),
        "jtYDM is written only by initialize and setJuniorTrancheYDM";
    assert getLPTYDM() != lptYDM0
        => (isInit || f.selector == sig:setLiquidityProviderTrancheYDM(address,bytes).selector),
        "lptYDM is written only by initialize and setLiquidityProviderTrancheYDM";
}

/**
 * A caller the authority denies cannot change any configuration field — via any entrypoint, reverting
 * or not. `initialize` is excluded by the same proved lemma as Property 2 (a configured accountant has
 * spent its initializer), not by a filter.
 */
rule denied_caller_cannot_change_config(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract }
{
    liveAccountant(e);
    require !gCallerAllowed(e.msg.sender, currentContract);

    mathint stFee0 = getSTProtocolFeeWAD();
    mathint jtFee0 = getJTProtocolFeeWAD();
    mathint jtYsFee0 = getJTYieldShareProtocolFeeWAD();
    mathint lptYsFee0 = getLPTYieldShareProtocolFeeWAD();
    mathint minCov0 = getMinCoverageWAD();
    mathint theta0 = getCoverageLiquidationUtilizationWAD();
    mathint minLiq0 = getMinLiquidityWAD();
    mathint maxJT0 = getMaxJTYieldShareWAD();
    mathint maxLPT0 = getMaxLPTYieldShareWAD();
    mathint duration0 = getFixedTermDurationSeconds();
    mathint dust0 = getDustTolerance();
    address jtYDM0 = getJTYDM();
    address lptYDM0 = getLPTYDM();

    f@withrevert(e, args);

    assert getSTProtocolFeeWAD() == stFee0 && getJTProtocolFeeWAD() == jtFee0
        && getJTYieldShareProtocolFeeWAD() == jtYsFee0 && getLPTYieldShareProtocolFeeWAD() == lptYsFee0,
        "an unauthorized caller cannot change any protocol fee";
    assert getMinCoverageWAD() == minCov0 && getCoverageLiquidationUtilizationWAD() == theta0
        && getMinLiquidityWAD() == minLiq0,
        "an unauthorized caller cannot change the coverage or liquidity configuration";
    assert getMaxJTYieldShareWAD() == maxJT0 && getMaxLPTYieldShareWAD() == maxLPT0,
        "an unauthorized caller cannot change the max yield shares";
    assert getFixedTermDurationSeconds() == duration0 && getDustTolerance() == dust0,
        "an unauthorized caller cannot change the fixed-term duration or the dust tolerance";
    assert getJTYDM() == jtYDM0 && getLPTYDM() == lptYDM0,
        "an unauthorized caller cannot swap either YDM";
}

// =============================================================================
// Property 4 — guard_blocks_coverage_and_liquidity_worsening
// =============================================================================

/**
 * Every state transition that ran the full `withSyncedAccounting` bracket (two market syncs) leaves the
 * market no worse off on both requirements, as measured by the synced packets before and after the
 * change: post coverage utilization is at most 100% or no higher than pre, and likewise for liquidity.
 *
 * `gSyncCalls == 2` identifies the guarded transitions without naming a selector, so the rule ranges
 * over every method and would catch a guarded setter that reached its end while skipping either check
 * (e.g. an early return, or a check placed before the body).
 *
 * Because the modeled sync returns *unconstrained* utilizations (M1), this is proved for arbitrary sync
 * results — strictly stronger than proving it for the reachable ones.
 */
rule guard_blocks_coverage_and_liquidity_worsening(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract }
{
    require gSyncCalls == 0;
    require !gSyncReverts;

    f(e, args);

    assert gSyncCalls == 2 => (gSyncCovU[1] <= WAD() || gSyncCovU[1] <= gSyncCovU[0]),
        "a guarded change leaves coverage utilization within 100% or no worse than before";
    assert gSyncCalls == 2 => (gSyncLiqU[1] <= WAD() || gSyncLiqU[1] <= gSyncLiqU[0]),
        "a guarded change leaves liquidity utilization within 100% or no worse than before";
}

// =============================================================================
// Property 5 — no_config_induced_liquidation
// =============================================================================

/**
 * A guarded parameter change can never move the market from a non-liquidation state
 * (coverage utilization < threshold) into a liquidation state (coverage utilization >= threshold) —
 * neither by raising minCoverage (which raises coverage utilization) nor by lowering the threshold.
 *
 * The argument the Prover has to reconstruct: entering liquidation means postCov >= postTheta, and
 * Property 1 gives postTheta > WAD, so postCov > WAD; the guard's coverage clause then forces
 * postCov <= preCov, whence preCov >= postCov >= postTheta. Either the threshold was not lowered
 * (preTheta <= postTheta, so preCov >= preTheta, contradicting the healthy pre-state) or the guard's
 * second clause forces postTheta > postCov, contradicting the breach.
 */
rule no_config_induced_liquidation(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract }
{
    requireInvariant config_bounds_always_valid();
    require initialized();
    require gSyncCalls == 0;
    require !gSyncReverts;

    f(e, args);

    assert gSyncCalls == 2 => !(gSyncCovU[0] < gSyncTheta[0] && gSyncCovU[1] >= gSyncTheta[1]),
        "a configuration change cannot push a non-liquidatable market into liquidation";
}

// =============================================================================
// Property 6 — all_utilization_relevant_params_are_guarded
// =============================================================================

/**
 * No code path writes `minCoverageWAD`, `minLiquidityWAD` or `coverageLiquidationUtilizationWAD`
 * without the complete guard: a full accounting sync before the write, another after it, and the
 * coverage/liquidity/liquidation checks evaluated on the post-change sync. The rule ranges over every
 * method (so an unguarded write anywhere is a counterexample) and additionally pins that the trailing
 * sync observed the *new* values, i.e. the guard judged the market at the new configuration.
 *
 * "initializer-after-init" is covered by exclusion rather than by inclusion: the
 * `initializer_consumed_once_kernel_is_set` lemma proves a second `initialize` on a configured
 * accountant always reverts, which is why that instance is filtered out (it is vacuous, not unchecked).
 */
rule utilization_params_only_change_under_full_guard(method f, env e, calldataarg args)
    filtered {
        f -> f.contract == currentContract
            && f.selector != sig:initialize(IRoycoDayAccountant.RoycoDayAccountantInitParams).selector
    }
{
    liveAccountant(e);
    require gSyncCalls == 0;
    require !gSyncReverts;

    mathint minCov0 = getMinCoverageWAD();
    mathint minLiq0 = getMinLiquidityWAD();
    mathint theta0 = getCoverageLiquidationUtilizationWAD();

    f(e, args);

    bool changed = getMinCoverageWAD() != minCov0
        || getMinLiquidityWAD() != minLiq0
        || getCoverageLiquidationUtilizationWAD() != theta0;

    assert changed => gSyncCalls == 2,
        "a write to minCoverage / minLiquidity / the liquidation threshold is bracketed by two full syncs";
    assert changed => (gSyncCovU[1] <= WAD() || gSyncCovU[1] <= gSyncCovU[0]),
        "the coverage guard is evaluated against the post-change sync";
    assert changed => (gSyncLiqU[1] <= WAD() || gSyncLiqU[1] <= gSyncLiqU[0]),
        "the liquidity guard is evaluated against the post-change sync";
    assert changed => (gSyncMinCov[1] == getMinCoverageWAD()
            && gSyncMinLiq[1] == getMinLiquidityWAD()
            && gSyncTheta[1] == getCoverageLiquidationUtilizationWAD()),
        "the trailing sync ran at the new configuration";
}

// =============================================================================
// Property 7 — no_retroactive_repricing_of_pre_change_yield
// =============================================================================

/**
 * PnL and yield-share accrual that predate a parameter change are settled under the OLD configuration:
 * the settling (first) sync of every guarded setter observes the configuration exactly as it was before
 * the call, and the trailing sync observes the new one. Since that first sync *is* the accountant's
 * `preOpSyncTrancheAccounting` (M1) — which accrues the yield shares, pays any premium and re-checkpoints
 * — this is precisely "the accrual clock is checkpointed at the old parameters, and no already-earned
 * senior yield is re-fee'd or re-premium'd at the new ones".
 */
rule pre_change_accrual_settled_under_old_config(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract }
{
    require gSyncCalls == 0;
    require !gSyncReverts;

    mathint stFee0 = getSTProtocolFeeWAD();
    mathint jtFee0 = getJTProtocolFeeWAD();
    mathint jtYsFee0 = getJTYieldShareProtocolFeeWAD();
    mathint lptYsFee0 = getLPTYieldShareProtocolFeeWAD();
    mathint maxJT0 = getMaxJTYieldShareWAD();
    mathint maxLPT0 = getMaxLPTYieldShareWAD();
    mathint minCov0 = getMinCoverageWAD();
    mathint minLiq0 = getMinLiquidityWAD();

    f(e, args);

    assert gSyncCalls >= 1 => (gSyncStFee[0] == stFee0 && gSyncJtFee[0] == jtFee0
            && gSyncJtYsFee[0] == jtYsFee0 && gSyncLptYsFee[0] == lptYsFee0
            && gSyncMaxJT[0] == maxJT0 && gSyncMaxLPT[0] == maxLPT0
            && gSyncMinCov[0] == minCov0 && gSyncMinLiq[0] == minLiq0),
        "the settling sync runs before the field write, at the old configuration";
    assert gSyncCalls == 2 => (gSyncStFee[1] == getSTProtocolFeeWAD()
            && gSyncJtFee[1] == getJTProtocolFeeWAD()
            && gSyncJtYsFee[1] == getJTYieldShareProtocolFeeWAD()
            && gSyncLptYsFee[1] == getLPTYieldShareProtocolFeeWAD()
            && gSyncMaxJT[1] == getMaxJTYieldShareWAD()
            && gSyncMaxLPT[1] == getMaxLPTYieldShareWAD()
            && gSyncMinCov[1] == getMinCoverageWAD()
            && gSyncMinLiq[1] == getMinLiquidityWAD()),
        "the trailing sync runs after the field write, at the new configuration";
}

// =============================================================================
// Property 8 — ydm_swap_remains_a_recovery_path
// =============================================================================

/**
 * A YDM replacement is executable by an authorized caller even when every market sync fails — the
 * scenario the setter exists to recover from (an outgoing YDM that reverts in `yieldShare` bricks every
 * sync). The pre-swap sync is best-effort (`DispatchLogic._tryExecute`, whose success flag is
 * discarded), so it can never be a precondition for the swap.
 */
rule ydm_swap_succeeds_despite_reverting_sync(env e, address newYDM, bytes initializationData) {
    liveAccountant(e);
    timestampHygiene(e);
    requireInvariant config_bounds_always_valid();
    require getLastCollateralNAV() <= SANE_NAV();
    require getLastSTEffectiveNAV() <= SANE_NAV();
    require getLastJTEffectiveNAV() <= SANE_NAV();
    require getLastLPTRawNAV() <= SANE_NAV();
    require getDustTolerance() <= SANE_NAV();

    require gSyncReverts;
    require gCallerAllowed(e.msg.sender, currentContract);
    require e.msg.value == 0;
    require newYDM != 0;
    require newYDM != getLPTYDM();
    // Deliberate: the empty-data case performs no initialization dispatch, which isolates the
    // best-effort sync leg as the only thing that could block the swap. (That the dispatch is skipped
    // for empty data is itself the subject of Properties 21 and 9.)
    require initializationData.length == 0;

    setJuniorTrancheYDM@withrevert(e, newYDM, initializationData);

    assert !lastReverted, "an authorized YDM swap is not blocked by a reverting market sync";
    assert getJTYDM() == newYDM, "the swap installs the requested YDM";
}

/// The JT YDM swap validates the incoming instance: zero and "identical to the other tranche's YDM"
/// are both rejected.
rule ydm_swap_rejects_zero_or_duplicate_ydm(env e, address newYDM, bytes initializationData) {
    address lptYDM0 = getLPTYDM();

    setJuniorTrancheYDM@withrevert(e, newYDM, initializationData);

    assert (newYDM == 0 || newYDM == lptYDM0) => lastReverted,
        "the JT YDM cannot be set to zero or to the LPT YDM";
}

/// Mirror of the above for the LPT YDM swap.
rule lpt_ydm_swap_rejects_zero_or_duplicate_ydm(env e, address newYDM, bytes initializationData) {
    address jtYDM0 = getJTYDM();

    setLiquidityProviderTrancheYDM@withrevert(e, newYDM, initializationData);

    assert (newYDM == 0 || newYDM == jtYDM0) => lastReverted,
        "the LPT YDM cannot be set to zero or to the JT YDM";
}

/// No partial swap. The "failure leaves the stored YDM unchanged" half of Property 8's clause is a
/// consequence of EVM atomicity, which the Prover models faithfully (contract storage is rolled back on a
/// reverted `@withrevert` call), so asserting it would be a tautology; what carries content is the other
/// half — a *successful* call stores exactly the requested instance and nothing else, in particular the
/// initialization dispatch that runs before the store cannot leave a different value behind.
rule ydm_swap_is_atomic(env e, address newYDM, bytes initializationData) {
    setJuniorTrancheYDM@withrevert(e, newYDM, initializationData);
    bool reverted = lastReverted;

    assert !reverted => getJTYDM() == newYDM, "a successful swap stores exactly the requested YDM";
}

// =============================================================================
// Property 9 — ydm_swap_installs_uninitialized_or_bogus_ydm  [EXPECTED TO FAIL]
// =============================================================================

/**
 * The swap's target must be constrained to a genuine YDM. The initialization dispatch is an
 * arbitrary-calldata call made under the accountant's privileged identity (the kernel trusts
 * `msg.sender == accountant`), so at minimum the incoming address must not be the market's kernel or
 * the accountant itself.
 *
 * Expected result: VIOLATED. The setter validates only "non-zero" and "distinct from the other
 * tranche's YDM", so the kernel's own address (or the accountant's) is accepted as a YDM.
 */
rule ydm_swap_target_must_be_a_genuine_ydm(env e, address newYDM, bytes initializationData) {
    // No authorization / value preconditions are needed: the un-annotated call prunes every reverting
    // path, so the counterexample is by construction an authorized, non-payable, successful swap.
    setJuniorTrancheYDM(e, newYDM, initializationData);

    assert newYDM != getKernel(), "a YDM swap cannot install the market's kernel as a YDM";
    assert newYDM != currentContract, "a YDM swap cannot install the accountant itself as a YDM";
}

// =============================================================================
// Property 10 — ydm_swap_reprices_elapsed_accrual_window  [EXPECTED TO FAIL]
// =============================================================================

/**
 * A correct swap leaves no un-accrued window attributable to the outgoing model: after the swap the
 * yield-share accrual clock must stand at the current block, so the next accrual cannot multiply the
 * incoming model's instantaneous share by a window that elapsed under the outgoing one.
 *
 * Expected result: VIOLATED. The pre-swap sync is best-effort, so when it fails (a reverting outgoing
 * YDM, a paused kernel, a stale oracle) the swap still completes with `lastYieldShareAccrualTimestamp`
 * stale, and the whole elapsed window is later priced by the incoming model.
 */
rule ydm_swap_leaves_no_unaccrued_window(env e, address newYDM, bytes initializationData) {
    liveAccountant(e);
    timestampHygiene(e);
    require gSyncReverts;
    require gCallerAllowed(e.msg.sender, currentContract);
    require e.msg.value == 0;
    // Strengthen the antecedent to a *mid-life* market with a genuinely stale clock, rather than the
    // never-accrued corner (`clock == 0`): the finding is that a real elapsed window, priced under the
    // outgoing model, is carried across the swap.
    require getAccrualClock() != 0;
    require getAccrualClock() < to_mathint(e.block.timestamp);

    setJuniorTrancheYDM(e, newYDM, initializationData);

    assert getAccrualClock() == to_mathint(e.block.timestamp),
        "a YDM swap leaves no accrual window un-priced by the outgoing model";
}

// =============================================================================
// Property 11 — unbounded_dust_tolerance_erases_junior_recovery_claim  [EXPECTED TO FAIL]
// =============================================================================

/**
 * A dust tolerance is a rounding allowance, so it must stay within the market's own scale; an
 * arbitrarily large value turns the state machine's `jtImpermanentLoss <= dustTolerance` condition into
 * "always true" and suppresses every premium and protocol-fee booking through the `stGain > D` gates.
 *
 * Expected result: VIOLATED. `setDustTolerance` accepts any NAV value with no bound whatsoever, and the
 * `withSyncedAccounting` guard inspects only the coverage and liquidity utilizations.
 */
rule dust_tolerance_stays_bounded(method f, env e, calldataarg args)
    filtered {
        f -> f.contract == currentContract
            && f.selector != sig:initialize(IRoycoDayAccountant.RoycoDayAccountantInitParams).selector
    }
{
    // The counterexample must land on a *running* market: without `liveAccountant` the Prover reaches
    // `initialize` from the (unreachable) half-initialized prestate `kernel != 0` with the initializer
    // still unspent, and the finding reads as deployment-time configuration rather than as a governance
    // action. `initialize` is equally unvalidated — it writes `$.dustTolerance = _params.dustTolerance`
    // with no `_validateDustTolerance` analogue at all — but that write belongs to the deployment
    // template's trust model, whereas `setDustTolerance` is reachable at any time by a role holder.
    liveAccountant(e);
    requireInvariant config_bounds_always_valid();
    require getDustTolerance() <= SANE_NAV();

    f(e, args);

    assert getDustTolerance() <= SANE_NAV(),
        "no governance action can raise the dust tolerance beyond the market's realistic NAV scale";
}

/**
 * The junior tranche's recoverable drawdown cannot be erased by the dust tolerance alone: from a
 * fixed-term market whose term has not elapsed, with both tranches live, a positive impermanent loss
 * and no collateral PnL to repay it with, a sync must leave the recovery claim standing.
 *
 * The other six forcing conditions of the state machine (AUTOPROVER.md §4.5) are excluded explicitly so
 * the counterexample can only be the dust-tolerance one: `minCoverageWAD == 0` makes coverage
 * utilization identically zero, hence provably below the (> WAD) liquidation threshold.
 *
 * Expected result: VIOLATED. A dust tolerance at or above the outstanding impermanent loss forces
 * PERPETUAL, and a PERPETUAL commit erases the claim — turning a recoverable drawdown into a realized
 * junior loss that lowering the tolerance again cannot undo.
 */
rule sync_cannot_erase_live_junior_recovery_claim(env e, uint256 collateralNAV) {
    require e.msg.sender == getKernel();
    require e.msg.sender != 0;
    timestampHygiene(e);
    requireInvariant config_bounds_always_valid();
    require initialized();

    // A live fixed-term recovery: non-dust drawdown outstanding, term still running, tranches alive.
    require !isMarketPerpetual();
    require getLastJTImpermanentLoss() != 0;
    require getFixedTermEndTimestamp() > to_mathint(e.block.timestamp);
    require getFixedTermDurationSeconds() != 0;
    require getLastSTEffectiveNAV() != 0;
    require getLastJTEffectiveNAV() != 0;
    require to_mathint(e.block.timestamp) >= getGraceStamp();
    // Coverage utilization is identically zero here, so the liquidation-breach condition cannot fire.
    require getMinCoverageWAD() == 0;
    // No PnL: nothing has appreciated that could legitimately repay the claim.
    require to_mathint(collateralNAV) == getLastCollateralNAV();
    require getLastCollateralNAV() <= SANE_NAV();

    currentContract.preOpSyncTrancheAccounting(e, collateralNAV);

    assert getLastJTImpermanentLoss() != 0,
        "the dust tolerance alone cannot extinguish a live junior recovery claim";
}

// =============================================================================
// Property 12 — unbounded_dust_tolerance_bricks_capacity_math  [EXPECTED TO FAIL]
// =============================================================================

/**
 * The three capacity quotes the kernel and the entry point rely on for gating and for max-deposit /
 * max-withdraw reporting must be total on well-formed synced states: a view that reverts is a denial of
 * service on the whole market.
 *
 * Expected result: VIOLATED. `dustTolerance` is added to `collateralNAV` (maxSTDeposit,
 * maxJTWithdrawal) and to `stEffectiveNAV` (maxSTDeposit, maxLPTWithdrawal) with checked arithmetic, so
 * a sufficiently large admin-set tolerance makes every quote revert — and the recovery setter itself
 * runs two full syncs.
 */
rule capacity_views_never_revert(env e, RoycoDayAccountant.SyncedAccountingState state) {
    require e.msg.value == 0;
    // A well-formed synced state at a valid configuration and realistic magnitudes.
    require to_mathint(state.minCoverageWAD) < WAD();
    require to_mathint(state.minLiquidityWAD) < WAD();
    require to_mathint(state.collateralNAV) <= SANE_NAV();
    require to_mathint(state.stEffectiveNAV) <= SANE_NAV();
    require to_mathint(state.jtEffectiveNAV) <= SANE_NAV();
    require to_mathint(state.lptRawNAV) <= SANE_NAV();

    currentContract.maxSTDeposit@withrevert(e, state);
    bool stDepositReverted = lastReverted;
    currentContract.maxJTWithdrawal@withrevert(e, state);
    bool jtWithdrawalReverted = lastReverted;
    currentContract.maxLPTWithdrawal@withrevert(e, state);
    bool lptWithdrawalReverted = lastReverted;

    assert !stDepositReverted && !jtWithdrawalReverted && !lptWithdrawalReverted,
        "the capacity quotes are total on well-formed synced states";
}

// =============================================================================
// Property 13 — guarded_setters_locked_out_by_pause_or_stale_oracle  [EXPECTED TO FAIL]
// =============================================================================

/**
 * A configuration fix is frequently the intended remediation for a sick market, so an authorized
 * parameter setter must stay executable when the market sync cannot run (paused kernel, oracle that
 * reverts on staleness or a circuit break, in-flight operation frame).
 *
 * Expected result: VIOLATED. `withSyncedAccounting` performs two mandatory (non-best-effort) calls into
 * the kernel's pause-gated, reentrancy-gated sync entrypoint, so a single pauser can freeze all
 * accountant parameter governance while unpausing requires a different role.
 */
rule guarded_setter_executable_when_sync_reverts(env e, uint64 newMinCoverageWAD) {
    liveAccountant(e);
    // Plausible-market hygiene: the revert happens inside the modifier's first, mandatory sync, before
    // any configuration field is read, so the mechanism is independent of the prestate.
    timestampHygiene(e);
    requireInvariant config_bounds_always_valid();
    require gSyncReverts;
    require gCallerAllowed(e.msg.sender, currentContract);
    require e.msg.value == 0;
    require to_mathint(newMinCoverageWAD) < WAD();

    setMinCoverage@withrevert(e, newMinCoverageWAD);

    assert !lastReverted,
        "an authorized parameter fix is executable even when the market sync cannot run";
}

// =============================================================================
// Property 14 — guard_liquidity_leg_can_be_vacuous  [EXPECTED TO FAIL]
// =============================================================================

/**
 * The packet a sync hands back must describe the market it was taken from: it must carry the committed
 * LPT mark, and a reported liquidity utilization of zero must be *genuine* (only possible when the
 * liquidity requirement is switched off or the senior claim is empty) rather than a placeholder.
 *
 * Expected result: VIOLATED. `preOpSyncTrancheAccounting` returns `lptRawNAV = 0` and
 * `liquidityUtilizationWAD = 0` as placeholders for the kernel to patch after committing the fresh
 * venue mark. If the packet that reaches the guard carries the unpatched placeholder, the guard's
 * liquidity clause `postOp.liquidityUtilizationWAD <= WAD` is trivially satisfied and a minLiquidity
 * increase can settle the market below the senior liquidity floor undetected.
 */
rule sync_packet_reports_true_liquidity_state(env e, uint256 collateralNAV) {
    require e.msg.sender == getKernel();
    require e.msg.sender != 0;
    timestampHygiene(e);
    requireInvariant config_bounds_always_valid();
    require initialized();
    require to_mathint(collateralNAV) <= SANE_NAV();
    require getLastCollateralNAV() <= SANE_NAV();

    RoycoDayAccountant.SyncedAccountingState state = currentContract.preOpSyncTrancheAccounting(e, collateralNAV);

    assert to_mathint(state.lptRawNAV) == getLastLPTRawNAV(),
        "the sync packet carries the committed LPT mark";
    assert state.liquidityUtilizationWAD == 0
        => (state.minLiquidityWAD == 0 || to_mathint(state.stEffectiveNAV) == 0),
        "a reported zero liquidity utilization is genuine, not a placeholder";
}

// =============================================================================
// Property 15 — zeroing_requirements_trivially_satisfies_the_guard  [EXPECTED TO FAIL]
// =============================================================================

/**
 * Setting minCoverage or minLiquidity to zero drives the corresponding utilization to zero *by
 * definition*, so the guard's "not worse than 100%" test is trivially satisfied while the requirement
 * itself is removed: with minCoverage == 0 the coverage gate and the `maxJTWithdrawal` bound become
 * vacuous (junior can redeem the entire loss-absorption buffer out from under senior), and with
 * minLiquidity == 0 `maxLPTWithdrawal` returns the full venue mark. The guard cannot distinguish
 * "healthy" from "unconstrained", so removing a requirement needs its own bound or a delay-based
 * justification.
 *
 * Expected result: VIOLATED — both setters accept zero.
 */
rule requirements_cannot_be_zeroed(method f, env e, calldataarg args)
    filtered {
        f -> f.contract == currentContract
            && f.selector != sig:initialize(IRoycoDayAccountant.RoycoDayAccountantInitParams).selector
    }
{
    liveAccountant(e);
    // Keep the counterexample a *plausible* market: without this, the reported prestate saturates every
    // configuration field and a reviewer may dismiss the finding as a modeling artifact. The attack does
    // not depend on it.
    requireInvariant config_bounds_always_valid();
    require getMinCoverageWAD() != 0;
    require getMinLiquidityWAD() != 0;

    f(e, args);

    assert getMinCoverageWAD() != 0 && getMinLiquidityWAD() != 0,
        "governance cannot switch off the coverage or liquidity requirement outright";
}

// =============================================================================
// Property 16 — premium_payment_must_consume_accrual_window
// =============================================================================

/**
 * Whenever a sync books a premium out of the senior slice it must consume the accrual window that
 * funded it: both time-weighted accumulators zeroed and `lastPremiumPaymentTimestamp` advanced to the
 * current block, in the same call. No accrual window may fund more than one premium payment.
 *
 * The observable used is the reported `lptLiquidityPremium` (the kernel mints it as ST shares to the
 * LPT, so a non-zero value is a real value transfer out of the senior slice).
 *
 * SCOPE NOTE on the observable: the JT risk premium has no field of its own in `SyncedAccountingState` —
 * it is folded into `jtEffectiveNAV` alongside the junior share of the collateral gain and any drawdown
 * repayment, so it cannot be isolated from the packet. The rule therefore witnesses the LPT leg only. A
 * violation confined to the JT leg (`maxLPTYieldShareWAD == 0`, non-zero JT risk premium) would escape
 * it — but both legs are computed from the same `stGain`, share the single
 * `elapsedSinceLastPremiumPayments` window, and are consumed by the same `premiumsPaid` flag, so the
 * defect being demonstrated is common to them by construction.
 *
 * Expected result: VIOLATED. The consumption gate is `premiumsPaid = (stGain > dustTolerance)` while
 * the premium computation itself is gated only on `stGain != 0`, so with an oversized dust tolerance a
 * gain with `stGain <= D` pays a premium out of a window that is never consumed, and the same window is
 * re-applied to every subsequent gain.
 */
rule premium_payment_consumes_accrual_window(env e, uint256 collateralNAV) {
    require e.msg.sender == getKernel();
    require e.msg.sender != 0;
    timestampHygiene(e);
    requireInvariant config_bounds_always_valid();
    requireInvariant premium_clock_behind_accrual_clock();
    require initialized();
    require to_mathint(collateralNAV) <= SANE_NAV();
    require getLastCollateralNAV() <= SANE_NAV();

    RoycoDayAccountant.SyncedAccountingState state = currentContract.preOpSyncTrancheAccounting(e, collateralNAV);

    assert to_mathint(state.lptLiquidityPremium) != 0
        => (getTwJT() == 0 && getTwLPT() == 0 && getPremiumClock() == to_mathint(e.block.timestamp)),
        "a premium payment consumes the accrual window that funded it";
}

/**
 * The same property under `dustTolerance == 0`, which is where it holds: with no dust allowance
 * `premiumsPaid` degenerates to `stGain != 0`, exactly the condition under which a premium can be
 * non-zero. This isolates the unvalidated admin parameter the general failure depends on.
 */
rule premium_payment_consumes_accrual_window_zero_dust(env e, uint256 collateralNAV) {
    require e.msg.sender == getKernel();
    require e.msg.sender != 0;
    timestampHygiene(e);
    requireInvariant config_bounds_always_valid();
    requireInvariant premium_clock_behind_accrual_clock();
    require initialized();
    require getDustTolerance() == 0;
    require to_mathint(collateralNAV) <= SANE_NAV();
    require getLastCollateralNAV() <= SANE_NAV();

    RoycoDayAccountant.SyncedAccountingState state = currentContract.preOpSyncTrancheAccounting(e, collateralNAV);

    assert to_mathint(state.lptLiquidityPremium) != 0
        => (getTwJT() == 0 && getTwLPT() == 0 && getPremiumClock() == to_mathint(e.block.timestamp)),
        "with no dust allowance, every premium payment consumes its accrual window";
}

// =============================================================================
// Property 17 — fixed_term_end_not_movable_by_duration_change
// =============================================================================

/**
 * A change to `fixedTermDurationSeconds` does not move the end timestamp of a term already in progress:
 * the stamp is written only on the PERPETUAL -> FIXED_TERM entry transition. The single permitted effect
 * on a running term is the zero-duration case, which terminates it (and, being the one setter that
 * touches checkpoints directly, must leave the lifecycle state internally consistent).
 *
 * The bracketing syncs cannot re-stamp a running term either: `preOpSyncTrancheAccounting` writes
 * `fixedTermEndTimestamp` only when it transitions *into* a fixed term, which contradicts the
 * antecedent "the market was already in a fixed term and still is".
 */
rule fixed_term_end_not_movable_by_duration_change(env e, uint24 newDurationSeconds) {
    liveAccountant(e);
    require gCallerAllowed(e.msg.sender, currentContract);
    require e.msg.value == 0;
    require gSyncCalls == 0;
    require !gSyncReverts;

    bool wasFixedTerm = !isMarketPerpetual();
    mathint end0 = getFixedTermEndTimestamp();

    setFixedTermDuration(e, newDurationSeconds);

    assert (wasFixedTerm && !isMarketPerpetual()) => getFixedTermEndTimestamp() == end0,
        "a duration change never moves the end of a term already in progress";
    assert newDurationSeconds == 0
        => (isMarketPerpetual() && getFixedTermEndTimestamp() == 0 && getLastJTImpermanentLoss() == 0),
        "the zero-duration case terminates the term and clears the drawdown ledger";
}

/**
 * The other half of the same property, discharged rather than argued: the accounting sync — which is what
 * the setter's guard runs before and after the duration write, and the only other writer of
 * `fixedTermEndTimestamp` — cannot re-stamp or extend a term already in progress either. The stamp is
 * written only on the PERPETUAL -> FIXED_TERM entry transition, so a market that is in a fixed term
 * before and after a sync keeps its end timestamp to the second.
 *
 * Together with `fixed_term_end_not_movable_by_duration_change` this closes the property against the
 * "governance repeatedly bumps the duration to keep senior and junior capital frozen" scenario: neither
 * the setter body nor either bracketing sync can move a live term's end.
 */
rule sync_does_not_restamp_running_fixed_term(env e, uint256 collateralNAV) {
    require e.msg.sender == getKernel();
    require e.msg.sender != 0;
    timestampHygiene(e);
    requireInvariant config_bounds_always_valid();
    require initialized();
    require to_mathint(collateralNAV) <= SANE_NAV();
    require getLastCollateralNAV() <= SANE_NAV();

    bool wasFixedTerm = !isMarketPerpetual();
    mathint end0 = getFixedTermEndTimestamp();

    currentContract.preOpSyncTrancheAccounting(e, collateralNAV);

    assert (wasFixedTerm && !isMarketPerpetual()) => getFixedTermEndTimestamp() == end0,
        "a sync never re-stamps the end of a term already in progress";
}

// =============================================================================
// Property 18 — setter_checkpoint_effects_confined_to_the_bracketing_syncs
// =============================================================================

/**
 * A parameter setter's net effect on the NAV checkpoints is exactly what its bracketing accounting
 * syncs produce: no setter writes `lastCollateralNAV`, `lastSTEffectiveNAV`, `lastJTEffectiveNAV` or
 * `lastLPTRawNAV` itself. `gSyncCalls >= 1` identifies the transitions that went through a sync (the
 * guarded setters and the YDM setters) without naming a selector; the accountant's own sync entrypoints
 * are excluded because they perform no sync of their own.
 *
 * Together with the fact that those bracketing syncs *are* `preOpSyncTrancheAccounting` +
 * `commitLiquidityProviderTrancheRawNAV` (M1), this confines every checkpoint effect of a setter to the
 * state machine: NAV conservation `C == S + J` and the state/IL coupling therefore survive every
 * governance call.
 */
rule setters_never_write_nav_checkpoints(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract }
{
    require gSyncCalls == 0;
    require !gSyncReverts;

    mathint c0 = getLastCollateralNAV();
    mathint s0 = getLastSTEffectiveNAV();
    mathint j0 = getLastJTEffectiveNAV();
    mathint p0 = getLastLPTRawNAV();

    f(e, args);

    assert gSyncCalls >= 1 => (getLastCollateralNAV() == c0 && getLastSTEffectiveNAV() == s0
            && getLastJTEffectiveNAV() == j0 && getLastLPTRawNAV() == p0),
        "a governance call never writes a NAV checkpoint outside of its bracketing syncs";
}

/**
 * The one setter that touches checkpoints directly — the zero-duration branch of
 * `setFixedTermDuration` — lands exactly on the configuration the state machine would force at a zero
 * duration (PERPETUAL, no drawdown, no term), and leaves NAV conservation intact because it moves no
 * NAV checkpoint.
 */
rule zero_duration_reset_is_internally_consistent(env e) {
    liveAccountant(e);
    require gCallerAllowed(e.msg.sender, currentContract);
    require e.msg.value == 0;
    require gSyncCalls == 0;
    require !gSyncReverts;

    mathint c0 = getLastCollateralNAV();
    mathint s0 = getLastSTEffectiveNAV();
    mathint j0 = getLastJTEffectiveNAV();

    setFixedTermDuration(e, 0);

    assert isMarketPerpetual() && getFixedTermEndTimestamp() == 0 && getLastJTImpermanentLoss() == 0,
        "the direct reset coincides with the state the market state machine forces at a zero duration";
    assert getLastCollateralNAV() == c0 && getLastSTEffectiveNAV() == s0 && getLastJTEffectiveNAV() == j0,
        "the direct reset moves no NAV checkpoint, so NAV conservation is untouched";
}

// =============================================================================
// Property 19 — liquidation_threshold_hair_trigger  [EXPECTED TO FAIL]
// =============================================================================

/**
 * The liquidation threshold must not be movable *downwards* by governance. Lowering it towards WAD
 * pre-arms the JT-funded self-liquidation bonus so that the first wei of coverage shortfall lets senior
 * redeemers extract junior effective NAV; because each bonus payment lowers J and therefore raises
 * coverage utilization, liquidation stays armed — a self-sustaining drain of the junior loss-absorption
 * buffer into senior exits.
 *
 * Expected result: VIOLATED. `coverageLiquidationUtilizationWAD` is bounded only from below by `> WAD`,
 * and the guard's threshold clause is satisfied by `postTheta > postCoverageUtilization`, which holds
 * trivially while the market is healthy — so `Theta = WAD + 1` is installable at will.
 */
rule liquidation_threshold_cannot_be_lowered(method f, env e, calldataarg args)
    filtered {
        f -> f.contract == currentContract
            && f.selector != sig:initialize(IRoycoDayAccountant.RoycoDayAccountantInitParams).selector
    }
{
    liveAccountant(e);
    requireInvariant config_bounds_always_valid();

    mathint theta0 = getCoverageLiquidationUtilizationWAD();

    f(e, args);

    assert getCoverageLiquidationUtilizationWAD() >= theta0,
        "governance cannot lower the liquidation threshold towards the coverage requirement";
}

// =============================================================================
// Property 20 — hundred_percent_protocol_fee_appropriates_all_tranche_yield  [EXPECTED TO FAIL]
// =============================================================================

/**
 * No fee setter may reach full appropriation: at 100% the entire senior residual gain, the entire
 * junior gain, the entire JT risk premium and the entire LPT liquidity premium are routed to the
 * protocol fee recipient as minted shares, so junior capital bears first loss and LPT capital provides
 * market-making depth for zero compensation while senior holders are diluted by their own gain.
 *
 * Expected result: VIOLATED. `MAX_PROTOCOL_FEE_WAD == WAD`, so all four setters accept exactly 100%, and
 * the guard inspects only coverage and liquidity utilization — never the fee fields, and never the size
 * of a single change.
 */
rule protocol_fees_cannot_reach_full_appropriation(method f, env e, calldataarg args)
    filtered {
        f -> f.contract == currentContract
            && f.selector != sig:initialize(IRoycoDayAccountant.RoycoDayAccountantInitParams).selector
    }
{
    liveAccountant(e);
    // Plausible-prestate hygiene only; the attack is independent of it (see `requirements_cannot_be_zeroed`).
    requireInvariant config_bounds_always_valid();
    require getSTProtocolFeeWAD() < WAD();
    require getJTProtocolFeeWAD() < WAD();
    require getJTYieldShareProtocolFeeWAD() < WAD();
    require getLPTYieldShareProtocolFeeWAD() < WAD();

    f(e, args);

    assert getSTProtocolFeeWAD() < WAD() && getJTProtocolFeeWAD() < WAD()
        && getJTYieldShareProtocolFeeWAD() < WAD() && getLPTYieldShareProtocolFeeWAD() < WAD(),
        "no protocol fee can be raised to full appropriation of the tranche's yield";
}

// =============================================================================
// Property 21 — ydm_swap_with_empty_data_resurrects_stale_per_market_state  [EXPECTED TO FAIL]
// =============================================================================

/**
 * Every swap must re-initialize the incoming instance for this market. YDM per-market state is keyed by
 * the calling accountant's address and survives being swapped away, so installing an instance that was
 * already initialized for this accountant in an earlier stint resurrects stale curve parameters and a
 * stale last-adaptation timestamp; the first accrual after the swap then applies the whole intervening
 * gap as one adaptation step.
 *
 * The check is observational: a raw call must have been issued to the incoming YDM during the swap.
 *
 * Expected result: VIOLATED. `_initializeYDM` skips the dispatch entirely when the supplied
 * initialization calldata is empty, so a swap with empty data resets nothing.
 */
rule ydm_swap_always_reinitializes_incoming_ydm(env e, address newYDM, bytes initializationData) {
    liveAccountant(e);
    // The un-annotated call already prunes every reverting path, so authorization and non-payability
    // need no explicit precondition.
    // Watch calls to the incoming YDM only; keep it distinct from the kernel so the best-effort sync
    // cannot be mistaken for the initialization dispatch.
    require newYDM != getKernel();
    require gWatchedTarget == newYDM;
    require gCallsToWatched == 0;
    // Plausible-prestate hygiene only; the attack is independent of it.
    requireInvariant config_bounds_always_valid();

    setJuniorTrancheYDM(e, newYDM, initializationData);

    assert gCallsToWatched > 0,
        "a YDM swap always re-initializes the incoming instance for this market";
}

// =============================================================================
// Property 22 — governance_calls_do_not_perturb_accrual_clocks
// =============================================================================

/**
 * The premium clock never runs ahead of the accrual clock. This is the invariant whose violation would
 * make the premium leg's `block.timestamp - lastPremiumPaymentTimestamp` subtraction underflow and brick
 * every pre-op sync (and with it the whole market) with no recovery path, since the guarded setters
 * themselves need two successful syncs.
 */
invariant premium_clock_behind_accrual_clock()
    getPremiumClock() <= getAccrualClock()
    filtered { f -> f.contract == currentContract }
    {
        preserved with (env e) {
            timestampHygiene(e);
        }
    }

/**
 * A restricted parameter setter or a YDM swap does not perturb the yield-share accrual state — the two
 * time-weighted accumulators and the two clocks — beyond what its own bracketing sync(s) do. This is the
 * packed-write regression check the property asks for: `minCoverageWAD`, `minLiquidityWAD`,
 * `fixedTermDurationSeconds`, `lastMarketState`, `fixedTermEndTimestamp`, `lastYieldShareAccrualTimestamp`
 * and `lastPremiumPaymentTimestamp` all share one storage slot that three of the setters write.
 */
rule governance_calls_preserve_accrual_state(method f, env e, calldataarg args)
    filtered { f -> f.contract == currentContract }
{
    timestampHygiene(e);
    requireInvariant premium_clock_behind_accrual_clock();
    require gSyncCalls == 0;
    require !gSyncReverts;

    mathint twJT0 = getTwJT();
    mathint twLPT0 = getTwLPT();
    mathint accrualClock0 = getAccrualClock();
    mathint premiumClock0 = getPremiumClock();

    f(e, args);

    assert gSyncCalls >= 1 => (getPremiumClock() <= getAccrualClock()
            && getAccrualClock() <= to_mathint(e.block.timestamp)),
        "a governance call leaves the premium clock at or behind the accrual clock, and both at or behind now";
    assert gSyncCalls >= 1 => (getAccrualClock() == accrualClock0
            || getAccrualClock() == to_mathint(e.block.timestamp)),
        "a governance call only ever advances the accrual clock to the current block";
    assert gSyncCalls >= 1 => (getPremiumClock() == premiumClock0
            || getPremiumClock() == to_mathint(e.block.timestamp)),
        "a governance call only ever advances the premium clock to the current block";
    assert gSyncCalls >= 1 => (getTwJT() == twJT0 && getTwLPT() == twLPT0),
        "a governance call's own body never touches the accrual accumulators";
}

/**
 * The accrual site itself (the body of every bracketing sync) maintains the clock discipline: after a
 * sync the accrual clock stands at the current block, the premium clock is at or behind it, and the
 * premium clock has either not moved or advanced to the current block — never past it.
 */
rule sync_maintains_accrual_clock_bounds(env e, uint256 collateralNAV) {
    require e.msg.sender == getKernel();
    require e.msg.sender != 0;
    timestampHygiene(e);
    requireInvariant premium_clock_behind_accrual_clock();
    requireInvariant config_bounds_always_valid();
    require initialized();
    require to_mathint(collateralNAV) <= SANE_NAV();
    require getLastCollateralNAV() <= SANE_NAV();

    mathint premiumClock0 = getPremiumClock();

    currentContract.preOpSyncTrancheAccounting(e, collateralNAV);

    assert getAccrualClock() == to_mathint(e.block.timestamp), "a sync checkpoints the accrual clock at the current block";
    assert getPremiumClock() <= getAccrualClock(), "the premium clock never overtakes the accrual clock";
    assert getPremiumClock() == premiumClock0 || getPremiumClock() == to_mathint(e.block.timestamp),
        "the premium clock either stands still or advances to the current block";
}

/**
 * Neither accumulator can grow by more than (that tranche's configured maximum yield share) x (the
 * window elapsed since the previous accrual) — the bound that keeps the premium legs inside the senior
 * gain. A premium payment resets the accumulator to zero, which is the other admissible outcome.
 */
rule sync_accrual_growth_is_bounded(env e, uint256 collateralNAV) {
    require e.msg.sender == getKernel();
    require e.msg.sender != 0;
    timestampHygiene(e);
    requireInvariant premium_clock_behind_accrual_clock();
    requireInvariant config_bounds_always_valid();
    require initialized();
    require to_mathint(collateralNAV) <= SANE_NAV();
    require getLastCollateralNAV() <= SANE_NAV();

    mathint twJT0 = getTwJT();
    mathint twLPT0 = getTwLPT();
    mathint accrualClock0 = getAccrualClock();
    mathint maxJT = getMaxJTYieldShareWAD();
    mathint maxLPT = getMaxLPTYieldShareWAD();

    currentContract.preOpSyncTrancheAccounting(e, collateralNAV);

    assert getTwJT() == 0 || getTwJT() <= twJT0 + maxJT * (to_mathint(e.block.timestamp) - accrualClock0),
        "the JT accumulator grows by at most the configured maximum share over the elapsed window";
    assert getTwLPT() == 0 || getTwLPT() <= twLPT0 + maxLPT * (to_mathint(e.block.timestamp) - accrualClock0),
        "the LPT accumulator grows by at most the configured maximum share over the elapsed window";
}

// =============================================================================
// Property 23 — unbounded_theta_raise_freezes_undercollateralized_market  [EXPECTED TO FAIL]
// =============================================================================

/**
 * A raise of the liquidation threshold must be bounded. `coverageUtilization >= Theta` is one of the
 * conditions that force the market state machine back to PERPETUAL, so raising Theta to a practically
 * unreachable value silently deletes that forcing condition: a market that subsequently takes a junior
 * drawdown then stays in FIXED_TERM — where the kernel blocks senior and junior deposits and
 * redemptions and LPT redemptions — while deeply undercollateralized, and the JT-funded
 * self-liquidation bonus that exists to force senior exits open never arms.
 *
 * Expected result: VIOLATED. The threshold is bounded only from below (`> WAD`); the guard's threshold
 * clause is satisfied by any raise unconditionally and regardless of magnitude, trivially so while the
 * market is healthy, so the pre-arming is invisible to it.
 */
rule liquidation_threshold_raise_is_bounded(method f, env e, calldataarg args)
    filtered {
        f -> f.contract == currentContract
            && f.selector != sig:initialize(IRoycoDayAccountant.RoycoDayAccountantInitParams).selector
    }
{
    liveAccountant(e);
    requireInvariant config_bounds_always_valid();
    require getCoverageLiquidationUtilizationWAD() <= MAX_SANE_LIQUIDATION_UTILIZATION_WAD();

    f(e, args);

    assert getCoverageLiquidationUtilizationWAD() <= MAX_SANE_LIQUIDATION_UTILIZATION_WAD(),
        "governance cannot raise the liquidation threshold out of reach";
}
