/*
 * Formal specification of the configuration and checkpoint invariants of RoycoDayAccountant.
 *
 * All eleven properties are state invariants over the accountant's ERC-7201 namespaced storage,
 * so each is expressed as a CVL `invariant`: the Prover checks it on the constructor base case
 * (the uninitialized all-zero state) and shows that every method of the accountant preserves it.
 *
 * Reading the state: the accountant keeps its whole state in one namespaced struct exposed by the
 * `getState()` view function, which is declared `envfree` below (the Prover checks that claim). Every
 * field read below goes through a small helper CVL function that performs exactly that view call
 * with no `env`, so the invariant expressions cannot revert -- a reverting invariant expression
 * would make the check pass vacuously, and with a symbolic `env` even a non-payable view call can
 * revert on `msg.value != 0`.
 *
 * The scene does support ERC-7201 storage extension paths: both
 * `currentContract.ext_Royco_storage_RoycoDayAccountantState.<field>` and
 * `currentContract.ext_openzeppelin_storage_Initializable._initialized` resolve and read the same
 * storage `getState()` reads (verified by a throw-away probe rule, since the build log's
 * "Could not find storage layout for RoycoDayAccountant" warnings suggested otherwise). State that
 * the accountant itself exposes is still read through `getState()`: one typed, revert-free read of
 * the whole struct keeps the property text close to the source. The extension path is used for
 * exactly one thing the accountant does not expose -- OpenZeppelin's `Initializable._initialized`
 * flag, needed by `initializer_consumed_once_kernel_is_set` below.
 *
 * External calls made by the accountant (the kernel's `syncTrancheAccountingFromAccountant`
 * callback in `withSyncedAccounting`, the access manager's `canCall`, and the YDM dispatches) are
 * plain CALLs to addresses the Prover cannot resolve, so they take the default `AUTO` treatment
 * (HAVOC_ECF): other contracts' storage is havocked while the verified accountant's own storage is
 * preserved. That encodes a no-reentrancy assumption. It is benign here: the one reentrant path
 * that exists in reality is the kernel calling back into `preOpSyncTrancheAccounting` (or a YDM
 * initializer calling back into a `restricted` setter), and those methods are themselves induction
 * steps checked below, so every invariant is preserved by them. The one place where an unresolved
 * call *does* cost something -- an `AUTO`-summarized kernel round-trip lets a call to address(0)
 * succeed -- is handled explicitly, and documented, at the `preserved` block of Property 11.
 *
 * IMPORT NOTE (deviation, with evidence): `summaries/RoycoDayAccountant_base_summaries.spec`
 * cannot be imported as-is in this scene. It pulls in
 * `summaries/OpenZeppelin/OZ_Math-RoycoDayAccountant.spec`, which the Certora typechecker rejects:
 *     "Error in spec file (OZ_Math-RoycoDayAccountant.spec:12:21):
 *      enum `Rounding` does not have a member `Ceil`."
 * Reproducing that summary with the OpenZeppelin v4 spelling of the same enum value
 * (`Math.Rounding.Up`, numerically identical to v5's `Ceil`) is rejected in the same way:
 *     "Error in spec file (invariants.spec:57:21):
 *      enum `Rounding` does not have a member `Up`."
 * The build log for this scene shows solc's type metadata missing for the `Math` library ("Target
 * contract Math 'types' is not a dict but NoneType: None"), so no member of `Math.Rounding`
 * resolves under either OpenZeppelin spelling and the directional summary cannot be written at all.
 * (Other contracts' user-defined types do resolve -- see `isMarketPerpetual` below.) Consequence:
 * every other member of the base-summaries bundle is imported directly below, and the three `Math`
 * summaries that do not mention an enum member are reproduced verbatim. The directional
 * `mulDiv(x, y, d, Rounding)` summary is left out, so the real OpenZeppelin implementation runs
 * instead and delegates to the (summarized) three-argument `mulDiv` -- the sound direction.
 */
import "summaries/EIP712.spec";
import "summaries/FixedPointMathLib.spec";
import "summaries/Math.spec";
import "summaries/OpenZeppelin/OZ_SafeERC20.spec";
import "summaries/OpenZeppelin/OZ_ShortStrings.spec";
import "summaries/OpenZeppelin/OZ_Strings.spec";
import "summaries/custom_summaries.spec";

// -----------------------------------------------------------------------------
// Methods block
// -----------------------------------------------------------------------------

methods {
    // Stand-in for summaries/OpenZeppelin/OZ_Math-RoycoDayAccountant.spec (see IMPORT NOTE).
    //
    // All three bodies live in summaries/Math.spec and are *exact, total* models of the
    // corresponding OpenZeppelin functions rather than approximations, so none of them prunes an
    // execution the real code would have (no `require_*` on a partial domain appears in any of the
    // three):
    //   - `mulDivDownSummary(x, y, d)`: floor((x*y)/d) computed over the full 512-bit product, with
    //     `revert()` on `d == 0` and on a result that does not fit in uint256. That is exactly
    //     OpenZeppelin `Math.mulDiv`'s contract, including its two revert conditions, so failure is
    //     *modelled* (the caller's revert handling is verified) rather than assumed away.
    //   - `averageSummary(a, b)`: floor((a+b)/2) over mathint, i.e. OpenZeppelin's overflow-free
    //     average. The narrowing cast cannot fail (the true average of two uint256 values is a
    //     uint256), so nothing is pruned.
    //   - `sqrtSummaryDown(x)`: the unique r with r*r <= x < (r+1)*(r+1), i.e. floor(sqrt(x)), which
    //     exists for every x -- so, unlike the "precise" variant in Math.spec, this constrains
    //     rather than prunes. It replaces the Babylonian loop the Prover would otherwise unroll.
    // These are `internal` entries, so they carry the default `ALL` policy and fire at every call
    // site, including the call sites inside the un-summarized directional `mulDiv` overload.
    // Assumption excluded by all three: none. What is excluded is only the *cost* of the real
    // bit-twiddling implementations. None of the eleven properties below depends on these values
    // anyway (Property 1 is enforced by an in-code `require`, Properties 2-5 by dust-tolerance
    // comparisons and market-state branches, Properties 6-11 are pure configuration bounds).
    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator) internal returns (uint256) => mulDivDownSummary(x, y, denominator);
    function Math.average(uint256 a, uint256 b) internal returns (uint256) => averageSummary(a, b);
    function Math.sqrt(uint256 x) internal returns (uint256) => sqrtSummaryDown(x);

    // `getState()` reads storage only; it touches no `msg.*`/`block.*` field, so it is envfree.
    // The claim is verified by the Prover (`envfreeFuncsStaticCheck`). The entry names the method's
    // defining contract, not the harness that inherits it.
    function RoycoDayAccountant.getState() external returns (IRoycoDayAccountant.RoycoDayAccountantState) envfree;
}

// -----------------------------------------------------------------------------
// Named constants
// -----------------------------------------------------------------------------

/// @dev src/libraries/Constants.sol: `uint256 constant WAD = 1e18`
definition WAD() returns mathint = 1000000000000000000;

/// @dev src/libraries/Constants.sol: `uint256 constant MAX_PROTOCOL_FEE_WAD = 1e18`
definition MAX_PROTOCOL_FEE_WAD() returns mathint = 1000000000000000000;

// -----------------------------------------------------------------------------
// State accessors (one revert-free, env-free view call each)
// -----------------------------------------------------------------------------

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

function isMarketPerpetual() returns bool {
    // `MarketState` is declared at file level in src/libraries/Types.sol. In CVL it must be
    // qualified by a contract in the scene that sees the type; the unqualified spelling
    // (`MarketState.PERPETUAL`) and a file-qualified one (`Types.MarketState.PERPETUAL`) are both
    // rejected ("Variable `MarketState` has not been declared"), while qualifying with the
    // accountant works. There is no cast from an enum to mathint/uint256 in CVL, so the comparison
    // is against the enum member literal rather than against the numeric value 0.
    return currentContract.getState().lastMarketState == RoycoDayAccountant.MarketState.PERPETUAL;
}

function getFixedTermEndTimestamp() returns mathint {
    return currentContract.getState().fixedTermEndTimestamp;
}

function getFixedTermDurationSeconds() returns mathint {
    return currentContract.getState().fixedTermDurationSeconds;
}

function getMinCoverageWAD() returns mathint {
    return currentContract.getState().minCoverageWAD;
}

function getCoverageLiquidationUtilizationWAD() returns mathint {
    return currentContract.getState().coverageLiquidationUtilizationWAD;
}

function getMinLiquidityWAD() returns mathint {
    return currentContract.getState().minLiquidityWAD;
}

function getMaxJTYieldShareWAD() returns mathint {
    return currentContract.getState().maxJTYieldShareWAD;
}

function getMaxLPTYieldShareWAD() returns mathint {
    return currentContract.getState().maxLPTYieldShareWAD;
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

function getKernel() returns address {
    return currentContract.getState().kernel;
}

function getJTYDM() returns address {
    return currentContract.getState().jtYDM;
}

function getLPTYDM() returns address {
    return currentContract.getState().lptYDM;
}

/// OpenZeppelin `Initializable`'s version counter, read through the ERC-7201 extension path for
/// namespace `openzeppelin.storage.Initializable`. Zero means "the initializer has never been
/// consumed"; `initialize` sets it to 1 and the constructor's `_disableInitializers()` sets it to
/// `type(uint64).max`. This is a direct storage read from CVL, so no hook fires and it cannot revert.
function getInitializedVersion() returns mathint {
    return currentContract.ext_openzeppelin_storage_Initializable._initialized;
}

// -----------------------------------------------------------------------------
// Lemma 1: an accountant that was never initialized carries pristine checkpoints
// -----------------------------------------------------------------------------

/**
 * `$.kernel` is written by exactly one function, `initialize`, and `initialize` requires the value
 * it writes to be non-zero (`require(_params.kernel != address(0), NULL_ADDRESS())`), so
 * `$.kernel == 0` characterizes "this accountant has never been initialized" -- see the
 * `only_initialize_writes_kernel` justification rule below. In that state the whole namespaced
 * struct is still at its zero defaults; this lemma records the three checkpoint fields that the
 * market-state properties need: the market is PERPETUAL, no fixed term is recorded and no junior
 * impermanent loss is recorded.
 *
 * Why the lemma is inductive:
 *   - constructor: the whole struct is zero, so both sides hold (PERPETUAL is the zero member);
 *   - `initialize`: writes `$.kernel != 0`, so the antecedent becomes false;
 *   - the three checkpoint writers (`preOpSyncTrancheAccounting`, `postOpSyncTrancheAccounting`,
 *     `commitLiquidityProviderTrancheRawNAV`) all carry `onlyRoycoKernel`, i.e.
 *     `require(msg.sender == $.kernel)`. With `$.kernel == 0` they are reachable only from
 *     `msg.sender == address(0)`, which the generic `preserved` block below excludes, so they
 *     revert and change nothing;
 *   - `setFixedTermDuration(0)` writes exactly these three fields and writes them to their pristine
 *     values, so it preserves the lemma outright; every other value of its argument leaves them
 *     untouched;
 *   - no other method of the accountant writes any of the three fields.
 *
 * The single assumption is `msg.sender != 0` in the induction step, and it is a fact about the EVM
 * rather than about this protocol: address(0) has no code and cannot originate a transaction, so no
 * `msg.sender` observed by a real execution is zero. It has to be stated because CVL leaves
 * `e.msg.sender` fully symbolic. It only removes executions that cannot happen on chain.
 */
invariant uninitialized_accountant_is_pristine()
    (getKernel() == 0)
        => (isMarketPerpetual() && getFixedTermEndTimestamp() == 0 && getLastJTImpermanentLoss() == 0)
    filtered { f -> f.contract == currentContract }
    {
        preserved with (env e) {
            require e.msg.sender != 0;
        }
    }

// -----------------------------------------------------------------------------
// Lemma 2: a configured kernel implies the initializer has already been consumed
// -----------------------------------------------------------------------------

/**
 * Ties the accountant's own "am I configured?" witness to OpenZeppelin's `Initializable` version
 * counter. Inductive without any assumption:
 *   - constructor: `_disableInitializers()` leaves `_initialized == type(uint64).max != 0`
 *     (and were it absent, the antecedent would be false since `$.kernel == 0`);
 *   - `initialize`: the `initializer` modifier writes `_initialized = 1` and the body writes a
 *     non-zero `$.kernel`, so both sides are non-zero;
 *   - every other method writes neither quantity (`only_initialize_writes_kernel` proves the
 *     `$.kernel` half), so the implication is carried over unchanged.
 *
 * Consumer: Property 5's `preserved initialize(...)` block. Together with the `initializer`
 * modifier this makes the "initialize only ever runs on a never-configured accountant" fact a
 * *proved* one instead of a raw `require`: in a prestate with `$.kernel != 0` the lemma forces
 * `_initialized != 0`, and `initializer` then reverts, so the Prover discards the step by itself.
 */
invariant initializer_consumed_once_kernel_is_set()
    (getKernel() != 0) => (getInitializedVersion() != 0)
    filtered { f -> f.contract == currentContract }

// -----------------------------------------------------------------------------
// Justification rules for Lemma 2 and Property 5
// -----------------------------------------------------------------------------

/**
 * Starting from `$.kernel == 0`, no method of the accountant other than `initialize` can make the
 * kernel non-zero. Together with the constructor base case (where the kernel is zero) this says:
 * the only door from "never configured" to "configured" is `initialize`. It is the `$.kernel` half
 * of Lemma 2's induction argument, spelled out as a checked rule.
 */
rule only_initialize_writes_kernel(method f, env e, calldataarg args)
    filtered {
        f -> f.contract == currentContract
            && f.selector != sig:initialize(IRoycoDayAccountant.RoycoDayAccountantInitParams).selector
    }
{
    require getKernel() == 0;
    f(e, args);
    assert getKernel() == 0, "only initialize() can make the kernel non-zero";
}

/**
 * `initialize` is one-shot (OpenZeppelin's `initializer` modifier), so once it has succeeded it can
 * never run again. This is the trace-level counterpart of Lemma 2: Lemma 2 says a configured
 * accountant has consumed its initializer, and this rule says a consumed initializer cannot be
 * consumed twice. The complementary fact that a successful `initialize` leaves both `$.kernel` and
 * `$.coverageLiquidationUtilizationWAD` non-zero is checked by the `initialize` induction step of
 * `initialization_all_or_nothing` (Property 11).
 */
rule initialize_is_one_shot(method f, method g, env e1, env e2, calldataarg a1, calldataarg a2)
    filtered {
        f -> f.contract == currentContract
            && f.selector == sig:initialize(IRoycoDayAccountant.RoycoDayAccountantInitParams).selector,
        g -> g.contract == currentContract
            && g.selector == sig:initialize(IRoycoDayAccountant.RoycoDayAccountantInitParams).selector
    }
{
    f(e1, a1);
    g@withrevert(e2, a2);
    assert lastReverted, "initialize() can only ever succeed once";
}

/**
 * Non-vacuity witness for `initialize_is_one_shot`: the first `initialize` really is feasible, so
 * that rule is not discharged by an infeasible premise. (Rules start from unconstrained storage, so
 * the constructor's `_disableInitializers()` does not pin `_initialized` here.)
 */
rule initialize_can_succeed(method f, env e, calldataarg args)
    filtered {
        f -> f.contract == currentContract
            && f.selector == sig:initialize(IRoycoDayAccountant.RoycoDayAccountantInitParams).selector
    }
{
    f(e, args);
    satisfy getKernel() != 0;
}

// -----------------------------------------------------------------------------
// Property 1: NAV conservation
// -----------------------------------------------------------------------------

/**
 * The checkpointed collateral NAV always equals the sum of the two checkpointed tranche effective
 * NAVs. Holds in every state, including the uninitialized all-zero state (0 == 0 + 0).
 *
 * NOTE on the `filtered` clause (used on every invariant here): the verification scene contains a
 * second, independent accountant instance plus the kernel/tranche/YDM/oracle harnesses. This
 * invariant constrains the storage of the verified accountant only, so only its own methods are
 * induction steps. No other contract can write that storage: the accountant is not a delegatecall
 * target (`DispatchLogic` uses plain `_target.call(...)`) and is not UUPS-upgradeable, and every
 * reentrant entry point into it is itself one of the checked steps.
 */
invariant nav_conservation()
    getLastCollateralNAV() == getLastSTEffectiveNAV() + getLastJTEffectiveNAV()
    filtered { f -> f.contract == currentContract }

// -----------------------------------------------------------------------------
// Property 2: a perpetual market records no fixed-term end
// -----------------------------------------------------------------------------

invariant perpetual_implies_no_fixed_term_end()
    isMarketPerpetual() => (getFixedTermEndTimestamp() == 0)
    filtered { f -> f.contract == currentContract }

// -----------------------------------------------------------------------------
// Property 3: a perpetual market carries no JT impermanent loss
// -----------------------------------------------------------------------------

invariant perpetual_implies_zero_jt_impermanent_loss()
    isMarketPerpetual() => (getLastJTImpermanentLoss() == 0)
    filtered { f -> f.contract == currentContract }

// -----------------------------------------------------------------------------
// Property 4: a fixed term is only ever recorded against an outstanding JT drawdown
// -----------------------------------------------------------------------------

invariant fixed_term_implies_nonzero_jt_impermanent_loss()
    !isMarketPerpetual() => (getLastJTImpermanentLoss() != 0)
    filtered { f -> f.contract == currentContract }

// -----------------------------------------------------------------------------
// Property 5: a market configured without a fixed-term duration is always perpetual
// -----------------------------------------------------------------------------

/**
 * `initialize` is the one method that can lower `$.fixedTermDurationSeconds` to zero without
 * touching `$.lastMarketState` (the only other writer of the duration, `setFixedTermDuration`,
 * resets the market state to PERPETUAL in the same breath). It gets away with that because it only
 * ever runs on a never-configured accountant, whose `$.lastMarketState` is already PERPETUAL.
 *
 * The `preserved initialize(...)` block supplies exactly that prestate fact, and does so with two
 * proved lemmas rather than with a raw assumption:
 *   - `initializer_consumed_once_kernel_is_set()` rules out a prestate with `$.kernel != 0`: there
 *     `_initialized != 0`, and OpenZeppelin's `initializer` modifier then reverts, so the Prover
 *     drops the step on its own;
 *   - `uninitialized_accountant_is_pristine()` covers the surviving case `$.kernel == 0` by giving
 *     `$.lastMarketState == PERPETUAL`, which `initialize` does not write -- so the poststate is
 *     PERPETUAL whatever duration the caller passes.
 *
 * The statement itself is *not* weakened: it is still asserted in every state, including the
 * all-zero one, and `initialize` is still an induction step (no method is filtered out).
 */
invariant zero_fixed_term_duration_implies_perpetual()
    (getFixedTermDurationSeconds() == 0) => isMarketPerpetual()
    filtered { f -> f.contract == currentContract }
    {
        preserved initialize(IRoycoDayAccountant.RoycoDayAccountantInitParams params) with (env e) {
            requireInvariant initializer_consumed_once_kernel_is_set();
            requireInvariant uninitialized_accountant_is_pristine();
        }
    }

// -----------------------------------------------------------------------------
// Property 6: coverage configuration bounds (initialized accountant)
// -----------------------------------------------------------------------------

invariant coverage_config_bounds()
    (getKernel() != 0) => ((getMinCoverageWAD() < WAD()) && (getCoverageLiquidationUtilizationWAD() > WAD()))
    filtered { f -> f.contract == currentContract }

// -----------------------------------------------------------------------------
// Property 7: minimum liquidity bound (initialized accountant)
// -----------------------------------------------------------------------------

invariant min_liquidity_bound()
    (getKernel() != 0) => (getMinLiquidityWAD() < WAD())
    filtered { f -> f.contract == currentContract }

// -----------------------------------------------------------------------------
// Property 8: the maximum JT and LPT yield shares sum to at most 100%
// -----------------------------------------------------------------------------

invariant max_yield_shares_sum_bounded()
    (getMaxJTYieldShareWAD() + getMaxLPTYieldShareWAD()) <= WAD()
    filtered { f -> f.contract == currentContract }

// -----------------------------------------------------------------------------
// Property 9: every configured protocol fee is bounded by the maximum protocol fee
// -----------------------------------------------------------------------------

invariant protocol_fees_bounded()
    getSTProtocolFeeWAD() <= MAX_PROTOCOL_FEE_WAD()
        && getJTProtocolFeeWAD() <= MAX_PROTOCOL_FEE_WAD()
        && getJTYieldShareProtocolFeeWAD() <= MAX_PROTOCOL_FEE_WAD()
        && getLPTYieldShareProtocolFeeWAD() <= MAX_PROTOCOL_FEE_WAD()
    filtered { f -> f.contract == currentContract }

// -----------------------------------------------------------------------------
// Property 10: both YDMs are configured and distinct (initialized accountant)
// -----------------------------------------------------------------------------

invariant ydms_distinct_and_nonzero()
    (getKernel() != 0) => (getJTYDM() != 0 && getLPTYDM() != 0 && getJTYDM() != getLPTYDM())
    filtered { f -> f.contract == currentContract }

// -----------------------------------------------------------------------------
// Property 11: initialization is all-or-nothing
// -----------------------------------------------------------------------------

/**
 * The biconditional is kept in full: `initialize` is the only writer of `$.kernel` and it writes
 * `$.coverageLiquidationUtilizationWAD` in the same transaction (from a parameter it validates with
 * `require(_params.coverageLiquidationUtilizationWAD > WAD)`), while
 * `setLiquidationCoverageUtilization` -- the only other writer of the utilization -- also requires
 * its argument to exceed WAD, so it can never store zero.
 *
 * The one induction step that needs help is `setLiquidationCoverageUtilization` from a
 * *never-configured* prestate (`$.kernel == 0`, utilization `0`): there the setter would store a
 * non-zero utilization while leaving the kernel at zero, breaking the "<=" direction. On chain that
 * execution does not exist, for two independent reasons:
 *   1. the function is `withSyncedAccounting`, whose expansion begins with
 *      `IRoycoDayKernel($.kernel).syncTrancheAccountingFromAccountant()`. With `$.kernel == 0` that
 *      is a CALL to an account with no code: it succeeds with empty returndata, and solc's decoding
 *      of the returned `SyncedAccountingState` then reverts, so the setter cannot complete;
 *   2. the function is `restricted`, i.e. it needs a live grant from the market's access manager,
 *      which does not exist before the market is deployed and initialized.
 * Neither reason survives in the model: the kernel call is unresolved and served by `AUTO`, which
 * makes the call to address(0) succeed, and `AuthorityUtils.canCallWithDelay`'s `canCall` is
 * likewise unresolved, so the Prover may grant permission to anybody. The prestate fact is
 * therefore stated as an assumption, scoped to this single method. (It could instead be *modelled*,
 * by a wildcard expression summary on `_.syncTrancheAccountingFromAccountant()` that reverts when
 * `calledContract == 0` and otherwise returns an unconstrained `SyncedAccountingState`; that is
 * feasible in this scene but was left out, since it would also replace HAVOC_ECF's effects on other
 * contracts' storage at that call site for every rule in the file.)
 *
 * The assumption is *not* load-bearing for the property's content: with `$.kernel != 0` in the
 * prestate the step still has to show that the stored utilization is non-zero, which is what the
 * setter's `> WAD` validation gives. Both directions of the biconditional remain asserted in every
 * state and no method is filtered out.
 */
invariant initialization_all_or_nothing()
    (getKernel() != 0) <=> (getCoverageLiquidationUtilizationWAD() != 0)
    filtered { f -> f.contract == currentContract }
    {
        preserved setLiquidationCoverageUtilization(uint256 coverageLiquidationUtilizationWAD) with (env e) {
            require getKernel() != 0;
        }
    }
