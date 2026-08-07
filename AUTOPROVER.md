# AUTOPROVER.md — Formal Verification Guide for `RoycoDayAccountant`

> **Audience**: Certora AutoProver (agentic formal verification). Treat this document as the
> protocol team briefing its formal verification team ahead of a **one-shot** engagement on
> `src/accountant/RoycoDayAccountant.sol`. It explains the contract step by step, describes the
> environment model we believe is faithful, and catalogs the correctness properties we expect to
> hold — with CVL-style statements, the auxiliary invariants our own reasoning needed, and
> rounding/overflow caveats — plus properties we believe are **false**, with the reasons.
>
> **You own the specification.** You are the specialist: derive your own properties from the code
> and this brief, reformulate ours where a better encoding exists, strengthen anything you can,
> and hunt for properties we missed (especially adversarial ones). The catalog in §6 is a floor
> and a map of our expectations, not a ceiling; §6.K records our reasoning about likely-false
> properties so you can spend your budget wisely, not to forbid you from testing that reasoning.
> If you falsify something we claim here, that is a finding — report it, don't suppress it.

---

## Table of Contents

1. [Verification target and scope](#1-verification-target-and-scope)
2. [Architecture context: who calls the Accountant and why](#2-architecture-context)
3. [Storage layout, units, and notation](#3-storage-layout-units-and-notation)
4. [Step-by-step explanation of the Accountant](#4-step-by-step-explanation)
   - 4.1 Initialization
   - 4.2 The three-phase sync protocol with the kernel
   - 4.3 `preOpSyncTrancheAccounting` — the PnL waterfall, in exact steps
   - 4.4 Yield-share accrual mechanics
   - 4.5 The market state machine
   - 4.6 `commitLiquidityProviderTrancheRawNAV`
   - 4.7 `postOpSyncTrancheAccounting` — operation deltas
   - 4.8 Capacity views (`maxSTDeposit`, `maxJTWithdrawal`, `maxLPTWithdrawal`)
   - 4.9 Admin setters and the `withSyncedAccounting` guard
5. [Environment modeling for the Prover (methods block, summaries, assumptions)](#5-environment-modeling)
6. [Property catalog](#6-property-catalog)
   - A. Valid-state invariants
   - B. Auxiliary invariants required for induction
   - C. Access control and revert conditions
   - D. `preOpSyncTrancheAccounting` transition rules
   - E. `postOpSyncTrancheAccounting` transition rules
   - F. Frame conditions (modifies clauses)
   - G. Capacity-function correctness
   - H. Utilization math lemmas
   - I. Unreachability (defense-in-depth `require`s that can never fire)
   - J. Stretch properties (attempt only if budget remains)
   - K. Properties we believe are false (or out of scope) — and why
7. [Practical prover guidance (timeouts, sanity, vacuity)](#7-practical-prover-guidance)

---

## 1. Verification target and scope

| | |
|---|---|
| **Target contract** | `src/accountant/RoycoDayAccountant.sol` (`RoycoDayAccountant`, 838 lines) |
| **Interface / state struct** | `src/interfaces/IRoycoDayAccountant.sol` (`RoycoDayAccountantState`, `RoycoDayAccountantInitParams`, errors, events) |
| **Types** | `src/libraries/Types.sol` (`MarketState`, `Operation`, `SyncedAccountingState`), `src/libraries/Units.sol` (`NAV_UNIT`), `src/libraries/Constants.sol` (`WAD`, `MAX_PROTOCOL_FEE_WAD`) |
| **Internal library linked in** | `src/libraries/logic/UtilizationLogic.sol` (pure, internal — verified in-line with the accountant), `src/libraries/logic/DispatchLogic.sol` (low-level call helpers) |
| **Solidity** | 0.8.35, checked arithmetic everywhere (verified: **zero `unchecked` blocks, zero loops** in the accountant — no loop-unrolling settings needed; the repo builds via-IR but that is irrelevant to CVL) |
| **Proxy model** | Beacon proxy; `initialize(...)` is the constructor-equivalent (the implementation constructor calls `_disableInitializers()`) |

**Verification closure** — the complete source set the accountant compiles against (everything
else in the repo is unnecessary for this engagement):

```
src/accountant/RoycoDayAccountant.sol          # target
src/interfaces/IRoycoDayAccountant.sol         # state struct, params, errors, events
src/interfaces/IRoycoDayKernel.sol             # only syncTrancheAccountingFromAccountant is used
src/interfaces/IYDM.sol
src/interfaces/IRoycoAuth.sol
src/libraries/Types.sol  Units.sol  Constants.sol
src/libraries/logic/UtilizationLogic.sol       # internal, inlined
src/libraries/logic/DispatchLogic.sol          # internal, inlined (_tryExecute, _dispatch)
src/base/RoycoBase.sol  src/auth/RoycoAuth.sol
lib/openzeppelin-contracts/contracts/utils/math/Math.sol
lib/openzeppelin-contracts-upgradeable: AccessManagedUpgradeable, PausableUpgradeable, Initializable
```

**In scope**: everything the Accountant itself computes and stores — the PnL waterfall, premium/fee
accounting, the market state machine, NAV checkpoints, capacity math, setters, access control.

**Out of scope** (kernel-side, do NOT try to verify here): share minting
(`FeeAndLiquidityPremiumLogic`), collateral valuation (`ValuationLogic`), coverage/liquidity
*enforcement* on operations (`AccountingSyncLogic.postOpSyncTrancheAccounting`'s `require`s), venue
marks, blacklist, the entry point. The Accountant is a **pure accounting state machine**: it holds
no assets, transfers no tokens, and mints no shares. It computes and checkpoints; the kernel acts.

---

## 2. Architecture context

A Royco Day market splits one collateral pool into a **senior tranche (ST)** (loss-protected),
a **junior tranche (JT)** (first-loss capital, paid a *risk premium* out of senior yield), and a
**liquidity provider tranche (LPT)** (market-making capital, paid a *liquidity premium* out of
senior yield, minted as ST shares). The Accountant is the market's ledger:

- **Collateral NAV** (`C`): oracle value of the co-invested ST+JT collateral. Supplied by the
  kernel on every call; the Accountant never prices anything itself.
- **Effective NAVs** (`S` for ST, `J` for JT): the two tranches' claims on `C` after loss
  absorption, impermanent-loss repayment, and premium distribution. **Core invariant of the whole
  protocol: `C == S + J` at every checkpoint, exactly, to the wei.**
- **JT impermanent loss** (`IL`): JT's recoverable drawdown. Losses are absorbed junior-first and
  booked into `IL`; future gains repay `IL` off the top before anything else. `IL` only exists
  while the market is in the `FIXED_TERM` recovery state.
- **LPT raw NAV** (`P`): the venue-oracle mark of the LPT's market-making position. Exogenous to
  the waterfall — committed separately, never part of the ST/JT PnL attribution.

**Callers**:

- The **kernel** (`RoycoDayKernel`, stored as `$.kernel`, immutable after init — there is no
  setter) is the *only* address that may call the three state-mutating sync functions:
  `preOpSyncTrancheAccounting`, `commitLiquidityProviderTrancheRawNAV`,
  `postOpSyncTrancheAccounting` (modifier `onlyRoycoKernel`, line 31).
- **Governance** (via OpenZeppelin `AccessManaged` `restricted` — `RoycoBase → RoycoAuth`) calls
  the twelve setters.
- **Anyone** may call the views: `previewSyncTrancheAccounting`, `maxSTDeposit`,
  `maxJTWithdrawal`, `maxLPTWithdrawal`, `getState`.
- The Accountant makes **outbound calls** to: the two YDM contracts
  (`yieldShare` / `previewYieldShare` — return a WAD-scaled fraction), the kernel
  (`syncTrancheAccountingFromAccountant`, only from setters), and an arbitrary YDM initialization
  call (`_initializeYDM`, only from `initialize` / the two YDM setters).
- The kernel's `syncTrancheAccountingFromAccountant` (guarded `msg.sender == accountant`) calls
  **back into** `preOpSyncTrancheAccounting` and `commitLiquidityProviderTrancheRawNAV`. This
  re-entrancy is by design and must be modeled (see §5).

A **YDM** (Yield Distribution Model) maps `(MarketState, utilizationWAD) → yieldShareWAD`, the
fraction of senior yield paid to JT (driven by *coverage utilization*) or to LPT (driven by
*liquidity utilization*). The Accountant treats YDM outputs as untrusted: every read is clamped by
`Math.min(·, maxJTYieldShareWAD)` / `Math.min(·, maxLPTYieldShareWAD)`.

### 2.1 Complete external-function inventory (the parametric-rule universe)

Own functions (all declared in `RoycoDayAccountant`):

| Function | Access | Mutates accountant storage? |
|---|---|---|
| `initialize(params)` | OZ `initializer` (once) | yes (all fields) |
| `preOpSyncTrancheAccounting(C')` | `onlyRoycoKernel` | yes |
| `commitLiquidityProviderTrancheRawNAV(P')` | `onlyRoycoKernel` | yes (`lastLPTRawNAV` only) |
| `postOpSyncTrancheAccounting(op, C', P', bonus)` | `onlyRoycoKernel` | yes |
| `previewSyncTrancheAccounting(C')` | open, `view` | no |
| `maxSTDeposit / maxJTWithdrawal / maxLPTWithdrawal (state)` | open, `view` | no |
| `getState()` | open, `view` | no |
| `setJuniorTrancheYDM / setLiquidityProviderTrancheYDM` | `restricted` | yes (YDM field; best-effort kernel sync) |
| 10 parameter setters (`set*`) | `restricted` + `withSyncedAccounting` | yes (own field; kernel-callback syncs) |

Inherited surface (from `RoycoAuth` = `AccessManagedUpgradeable` + `PausableUpgradeable`):
`pause()` / `unpause()` (`restricted`), `paused()`, `authority()`, `setAuthority(address)`
(callable only by the current authority), `isConsumingScheduledOp()`.

**Critical fact (verified)**: **no accountant function is pause-gated.** `pause()`/`unpause()`
exist and flip the OZ Pausable flag (its own ERC-7201 slot), but the accountant's logic never
checks `paused()` — pausing the accountant is inert for its own behavior (market pause lives on
the kernel). Consequences for specs: (a) parametric frame rules over `getState()` fields are
trivially preserved by `pause`/`unpause`/`setAuthority` (they touch only OZ slots); (b) no rule
should condition on the accountant's paused state.

The `restricted` modifier makes an external call to `authority().canCall(...)`; leave the
authority unresolved (NONDET) — an over-approximation that lets setter bodies be explored from
any caller, which is sound for invariants and frame rules. Positive access-control proofs for
setters (C-2) require concretely modeling the AccessManager; treat them as optional.

---

## 3. Storage layout, units, and notation

### 3.1 ERC-7201 storage

All state lives in one struct at slot
`0x3eb9440b0208b8d20dc454b361ed9d3f272aa9a4fb2bcc89d823d3b8e5663200`
(`Royco.storage.RoycoDayAccountantState`). Layout relative to that base slot:

| Offset | Fields (packed) | Notes |
|---|---|---|
| +0 | `stProtocolFeeWAD u64` \| `jtProtocolFeeWAD u64` \| `jtYieldShareProtocolFeeWAD u64` \| `lptYieldShareProtocolFeeWAD u64` | each ≤ `MAX_PROTOCOL_FEE_WAD = 1e18` (100%) |
| +1 | `minCoverageWAD u64` \| `minLiquidityWAD u64` \| `fixedTermDurationSeconds u24` \| `lastMarketState u8 (enum)` \| `fixedTermEndTimestamp u32` \| `lastYieldShareAccrualTimestamp u32` \| `lastPremiumPaymentTimestamp u32` | timestamps are **uint32** |
| +2 | `jtYDM address` \| `maxJTYieldShareWAD u64` | |
| +3 | `lptYDM address` \| `maxLPTYieldShareWAD u64` | |
| +4 | `twJTYieldShareAccruedWAD u128` \| `twLPTYieldShareAccruedWAD u128` | time-weighted accumulators (WAD·seconds) |
| +5 | `kernel address` \| `fixedTermCommenceableAtTimestamp u64` | kernel is set once in `initialize`, never mutated again |
| +6 | `coverageLiquidationUtilizationWAD u256` | > WAD always |
| +7 | `lastCollateralNAV` (`NAV_UNIT` = uint256) | checkpoint `C` |
| +8 | `lastSTEffectiveNAV` | checkpoint `S` |
| +9 | `lastJTEffectiveNAV` | checkpoint `J` |
| +10 | `lastJTImpermanentLoss` | checkpoint `IL` |
| +11 | `lastLPTRawNAV` | checkpoint `P` |
| +12 | `dustTolerance` (`NAV_UNIT`) | `D` |

`getState()` returns the entire struct by value — **prefer calling `getState()` in specs over raw
storage hooks**; it is a trivially faithful accessor.

### 3.2 Units

- `NAV_UNIT` is a user-defined value type over `uint256` (`Units.sol`). CVL sees plain `uint256`.
  All `+`/`-`/`*`/`/` operators on it are **checked** Solidity 0.8 arithmetic (they desugar to raw
  uint256 ops — `subNAVUnits` reverts on underflow, etc.). `saturatingSub` is `max(a-b, 0)`.
  `mulDiv` is OZ full-precision with explicit rounding.
- `WAD = 1e18` is the fixed-point unit for all percentages/utilizations. NAV_UNIT values are
  WAD-precision (18 decimals) in the market's quote unit.
- `MAX_NAV_UNITS = type(uint256).max` is used as "unlimited" in `maxSTDeposit`.

### 3.3 Notation used below

```
C   = lastCollateralNAV          C' = the _collateralNAV argument of the current call
S   = lastSTEffectiveNAV         J  = lastJTEffectiveNAV
IL  = lastJTImpermanentLoss      P  = lastLPTRawNAV
D   = dustTolerance              c  = minCoverageWAD        l = minLiquidityWAD
Θ   = coverageLiquidationUtilizationWAD
U_cov(C,c,J)  = ceilDiv(C·c, J)   with 0 if c==0 ∨ C==0, and uint256.max if J==0 (C>0, c>0)
U_liq(S,l,P)  = ceilDiv(S·l, P)   with 0 if S==0 ∨ l==0, and uint256.max if P==0 (S>0, l>0)
twJT, twLPT   = the two uint128 time-weighted yield-share accumulators
tA  = lastYieldShareAccrualTimestamp     tP = lastPremiumPaymentTimestamp
now = block.timestamp
x ∸ y = saturating subtraction max(x−y, 0)
```

Subscript `_0` = storage before the call; `_1` = storage after. Unprimed struct fields refer to the
returned `SyncedAccountingState`.

---

## 4. Step-by-step explanation

### 4.1 Initialization (`initialize`, lines 63–133)

Runs once (OZ `initializer`). Validates and stores the full config:

0. `__RoycoBase_init` → `__RoycoAuth_init` requires `initialAuthority != address(0)`
   (`NULL_ADDRESS`) and initializes AccessManaged + Pausable.
1. `kernel != address(0)` (`NULL_ADDRESS`).
2. All four protocol fees ≤ `MAX_PROTOCOL_FEE_WAD` (= WAD = 100%) (`MAX_PROTOCOL_FEE_EXCEEDED`).
3. `jtYDM != lptYDM` (`YDMS_CANNOT_BE_IDENTICAL`) — adaptive YDMs keep per-market curve state and a
   shared instance would interleave coverage- and liquidity-driven updates.
4. `minCoverageWAD < WAD` and `coverageLiquidationUtilizationWAD > WAD`
   (`INVALID_COVERAGE_CONFIG`) — the liquidation threshold is only breachable after real losses.
5. `minLiquidityWAD < WAD` (`INVALID_LIQUIDITY_CONFIG`).
6. `maxJTYieldShareWAD + maxLPTYieldShareWAD ≤ WAD` (`INVALID_MAX_YIELD_SHARE_CONFIG`) — this is
   what makes the premium-conservation `require` at line 498 unreachable (see property I-2).
7. Stores everything; sets `fixedTermCommenceableAtTimestamp = now + fixedTermGracePeriodSeconds`
   (a young market cannot enter `FIXED_TERM` during the grace window).
8. Calls each YDM with its raw init calldata iff nonempty (`_initializeYDM` → low-level call that
   bubbles reverts verbatim).

All NAV checkpoints (`C, S, J, IL, P`) and both accumulators start at **zero**; `lastMarketState`
starts `PERPETUAL` (enum zero); `tA = tP = 0`.

**Initialization witness**: `kernel != address(0)` holds iff `initialize` has run (nothing ever
writes `kernel` again). Use this as the antecedent for all "configured state" invariants.

### 4.2 The three-phase sync protocol with the kernel

Every kernel operation (deposit/redemption on any tranche) brackets itself like this:

```
1. PRE-OP    kernel → accountant.preOpSyncTrancheAccounting(C_fresh)
             (settles PnL since last checkpoint; commits S, J, IL, marketState)
2.           kernel mints fee + liquidity-premium ST/JT shares per the returned state
             (changes ST share supply ⇒ changes the ST share price ⇒ changes the venue mark)
3.           kernel → accountant.commitLiquidityProviderTrancheRawNAV(P_fresh)
             (P is committed only AFTER the mints so the venue's ST-leg rate reflects final state)
4. OPERATION the actual deposit/redemption moves assets
5. POST-OP   kernel → accountant.postOpSyncTrancheAccounting(op, C_post, P_post, bonus)
             (interprets the NAV deltas strictly as the operation's flows — NO PnL waterfall)
```

The ordering rationale (interface lines 247–259): the LPT's venue mark prices the ST leg at
`S / totalSTShares`, so committing `P` before the mints would record a mark against a stale senior
state. Keeping `P` out of the pre-op waterfall keeps it out of the PnL attribution and breaks the
senior-share-rate dependency loop.

**Consequence for the prover**: `preOpSyncTrancheAccounting` **never writes `lastLPTRawNAV`**, and
`commitLiquidityProviderTrancheRawNAV` writes **only** `lastLPTRawNAV`. These frame conditions are
properties F-1/F-2 below.

### 4.3 `preOpSyncTrancheAccounting(NAV_UNIT C')` — the PnL waterfall (lines 140–184, 389–585)

Only the kernel may call. Steps, in exact order:

**Step 0 — accrue yield shares** (`_accruePremiumYieldShares`, §4.4). Produces updated `twJT`,
`twLPT` (may early-return zeros on first-ever call or same-block repeat).

**Step 1 — waterfall** (`_previewSyncTrancheAccounting`, view). Loads checkpoints
`(C, S, J, IL)`; then:

**Loss branch** (`C' < C`), `L := C − C'`:
- `A := min(L, J)` — JT absorbs first. `J ← J − A`, `IL ← IL + A`, `L ← L − A`.
- Residual to senior: `S ← S − L` (never underflows: `L ≤ C = S + J` by conservation, and when a
  residual exists `A = J`, so residual `= L − J ≤ C − J = S`).

**Gain branch** (`C' > C`), `G := C' − C`:
1. **IL repayment off the top** (restoration, never yield, never fee'd):
   `R := min(G, IL)`; `IL ← IL − R`; `J ← J + R`; `G ← G − R`; and crucially the attribution
   baseline moves too: `C ← C + R` (so post-repayment, `C == S + J` again).
2. **Pro-rata attribution of the residual gain** `G`:
   `stGain := (C == 0) ? G : floor(G · S / C)`; `jtGain := G − stGain`. Floor rounds the split
   in JT's favor by ≤ 1 wei. (`C == 0` ⟹ `S == J == 0` by conservation; gain from zero accrues
   to senior.)
3. **JT gain leg**: if `jtGain > 0`: if `jtGain > D` book `jtProtocolFee = floor(jtGain ·
   jtProtocolFeeWAD / WAD)` (fee on JT's own yield); then `J ← J + jtGain`.
4. **ST gain leg — premiums** (only if `stGain > 0`):
   - `premiumsPaid := (stGain > D)` — a dust-sized senior gain pays no premium and takes no fee,
     but note the premium *math* still runs on it (the fee bookings are gated on `premiumsPaid`,
     the premium NAV movements are not).
   - `Δt := now − tP`. If `Δt == 0` (a premium already paid this block): use **instantaneous**
     shares instead of the accumulators: `Δt ← 1`,
     `twJT ← min(jtYDM.previewYieldShare(state_0, U_cov(C_0, c, J_0)), maxJT)`,
     `twLPT ← min(lptYDM.previewYieldShare(state_0, U_liq(S_0, l, P_0)), maxLPT)`
     (note: computed from the **storage checkpoints**, not the mid-waterfall values).
   - `jtRiskPremium := floor(stGain · twJT / (Δt · WAD))`,
     `lptLiquidityPremium := floor(stGain · twLPT / (Δt · WAD))`.
   - `require(jtRiskPremium + lptLiquidityPremium ≤ stGain)` (`PREMIUMS_EXCEED_SENIOR_YIELD`) —
     provably unreachable, see I-2.
   - Risk premium: if nonzero, add `floor(jtRiskPremium · jtYieldShareProtocolFeeWAD / WAD)` to
     `jtProtocolFee` (iff `premiumsPaid`); `J ← J + jtRiskPremium`; `stGain ← stGain −
     jtRiskPremium`.
   - Liquidity premium: if nonzero, `lptProtocolFee = floor(lptLiquidityPremium ·
     lptYieldShareProtocolFeeWAD / WAD)` (iff `premiumsPaid`); `stGain ← stGain −
     lptLiquidityPremium`. **The premium is NOT moved to `J`** — it stays a senior claim.
   - `stProtocolFee = floor(stGain · stProtocolFeeWAD / WAD)` (iff `premiumsPaid`; note: on the
     *post-premium* residual).
   - Book senior: `S ← S + stGain + lptLiquidityPremium`. The liquidity premium is booked back
     into `S` because it will be minted as **ST shares** held for the LPT — reassigning
     appreciation without adding senior exposure (coverage-neutral), preserving two-term
     conservation.

**Both branches** then hit `require(C' == S + J)` (`NAV_CONSERVATION_VIOLATION`, line 526) — an
exact arithmetic identity given the invariant `C == S + J` on entry (see I-1).

**Step 2 — market state machine** (§4.5) computes `resultingMarketState`, possibly erasing `IL`.

**Step 3 — commit** (back in `preOpSyncTrancheAccounting`, lines 158–183):
- If `premiumsPaid`: zero both accumulators, set `tP = now` (uint32 cast).
- Checkpoint `lastMarketState, C, S, J, IL` from the waterfall result. **`P` is untouched.**
- On `PERPETUAL → FIXED_TERM`: persist `fixedTermEndTimestamp` and emit `FixedTermCommenced`; on
  `FIXED_TERM → PERPETUAL`: delete it and emit `FixedTermEnded`.
- If `IL` was erased, emit `JuniorTrancheImpermanentLossReset`.

The returned `SyncedAccountingState` carries the committed values plus this sync's
`lptLiquidityPremium`, `stProtocolFee`, `jtProtocolFee`, `lptProtocolFee`,
`coverageUtilizationWAD = U_cov(C', c, J_1)`, and **placeholders** `lptRawNAV = 0`,
`liquidityUtilizationWAD = 0` (the kernel refreshes them after committing the fresh `P`).

`previewSyncTrancheAccounting(C')` (public view) is the same computation using
`_previewPremiumYieldShareAccrual` (view accrual, no writes) and returns only the state struct.

### 4.4 Yield-share accrual (`_accruePremiumYieldShares`, lines 593–622)

Time-weights the YDM outputs between syncs so premium size is path-independent w.r.t. call
frequency:

- **Bootstrap**: if `tA == 0` (first accrual ever), set `tA = tP = now`, return `(0, 0)`.
- **Same-block**: if `now == tA`, return current accumulators unchanged (no YDM call, no write).
- Otherwise: compute both utilizations **from checkpoints** (`U_cov(C, c, J)`,
  `U_liq(S, l, P)`), call `jtYDM.yieldShare(lastMarketState, U_cov)` (mutating — adaptive curves
  advance here) and clamp to `maxJT` (same for LPT/`maxLPT`), then
  `twJT += uint128(jtShare · (now − tA))`, `twLPT += uint128(lptShare · (now − tA))`,
  `tA = now`.

The uint128 casts are safe under `now < 2^32`: `share ≤ WAD = 1e18`, `elapsed < 2^32`, so each
increment `< 4.3e27 ≪ 2^127`; the checked `+=` would only overflow after ~1e13 years of maximal
accrual (comment at struct slot 4).

Accumulators are consumed and reset **only** when a premium actually pays (`premiumsPaid` in the
waterfall). The window arithmetic gives the key algebraic bound (property B-2):
`twJT + twLPT ≤ WAD · (tA − tP)` — every increment adds at most `WAD · elapsed` because
`maxJT + maxLPT ≤ WAD` at all times.

### 4.5 The market state machine (lines 528–563)

Two states: `PERPETUAL` (normal; all tranches liquid) and `FIXED_TERM` (recovery window after a
JT drawdown; kernel blocks ST/JT deposits+redemptions and LPT redemptions — enforcement is
kernel-side, not here). After the waterfall, the market is forced **PERPETUAL** iff **any** of:

1. `fixedTermDurationSeconds == 0` (market configured permanently perpetual),
2. `S == 0` (no senior capital to protect),
3. `J == 0` (junior buffer wiped — the dead restoration claim is extinguished),
4. `IL ≤ D` (loss fully repaid or dust-sized),
5. currently `FIXED_TERM` and `fixedTermEndTimestamp ≤ now` (term elapsed),
6. `U_cov(C', c, J) ≥ Θ` (liquidation breach — senior exits force open),
7. `now < fixedTermCommenceableAtTimestamp` (post-deployment grace period).

A PERPETUAL commit **always erases IL** (`IL ← 0`, `fixedTermEndTimestamp ← 0`); the erased amount
is reported (`jtImpermanentLossErased`) and, when the erasure was forced (cases 1, 2, 3, 5, 6),
junior's recovery claim is forfeited (losses become realized).

Otherwise the market is `FIXED_TERM`; the end timestamp is set to `now + fixedTermDurationSeconds`
**only on entry** (`PERPETUAL → FIXED_TERM`), never extended by subsequent syncs. Note the code
comment at line 558: while `FIXED_TERM` holds, `IL > D > stGain`-gating means the liquidity
premium and all protocol fees are structurally zero (fees require `premiumsPaid`, which requires a
gain that outruns the IL repayment and exceeds dust — at which point `IL ≤ D` would force
PERPETUAL). Property D-9 captures the provable form of this.

### 4.6 `commitLiquidityProviderTrancheRawNAV(NAV_UNIT P')` (lines 187–192)

Kernel-only. Writes exactly one field: `lastLPTRawNAV = P'`. Emits `LPTRawNAVCommitted`. No
validation — `P'` is trusted from the kernel's venue-oracle read. Called by the kernel after the
pre-op fee mints and again after liquidity-premium reinvestments.

### 4.7 `postOpSyncTrancheAccounting(op, C', P', bonus)` (lines 201–285)

Kernel-only. Runs **no waterfall, pays no premium, takes no fee** — it strictly interprets the
NAV deltas as the operation's own flows and re-checkpoints. Let
`ΔC := int(C') − int(C)` and `ΔP := int(P') − int(P)` (both computed via `computeNAVDelta`, which
requires both operands `< 2^255`).

| `op` | Required (else `INVALID_POST_OP_STATE(op)`) | Effect on checkpoints |
|---|---|---|
| `ST_DEPOSIT` | `ΔC > 0 ∧ ΔP == 0 ∧ bonus == 0` | `S ← S + ΔC` |
| `ST_REDEMPTION` | `ΔC < 0 ∧ ΔP == 0` (bonus free) | `J ← J − bonus`; `S ← S − (−ΔC − bonus)` |
| `JT_DEPOSIT` | `ΔC > 0 ∧ ΔP == 0 ∧ bonus == 0` | `J ← J + ΔC` |
| `JT_REDEMPTION` | `ΔC < 0 ∧ ΔP == 0 ∧ bonus == 0` | `J ← J − (−ΔC)` |
| `LPT_DEPOSIT` | `ΔP > 0 ∧ ΔC == 0 ∧ bonus == 0` | none (only `P` moves) |
| `LPT_REDEMPTION` | `ΔP < 0 ∧ ΔC == 0 ∧ bonus == 0` | none (only `P` moves) |

`bonus` is the **ST self-liquidation bonus**: when coverage utilization has breached `Θ`, senior
redeemers are paid a bonus out of JT effective NAV to incentivize exits; sizing/eligibility is
kernel-side (`SelfLiquidationLogic`) — here it is just a transfer from `J` to the redemption. The
checked NAV_UNIT subtractions give free revert conditions: `bonus > J_0` or `bonus > −ΔC` or
`(−ΔC − bonus) > S_0` all revert (C-5).

Then: `require(C' == S_1 + J_1)` — a tautology for every op given conservation on entry (I-3);
checkpoint `C, P, S, J`; and return the state (market state, `IL`, `fixedTermEndTimestamp`
unchanged from storage; all fee/premium fields zero; fresh `U_cov`, `U_liq`).

### 4.8 Capacity views (lines 305–373)

All three take an in-memory `SyncedAccountingState` (the caller supplies a fresh sync result;
these functions read only `dustTolerance` from storage) and round **in favor of senior
protection**:

- **`maxSTDeposit(state)`** = `min(x, x')` where
  `x  = (c == 0) ? ∞ : floor(J · WAD / c) ∸ (C + D)`  (coverage headroom)
  `x' = (l == 0) ? ∞ : floor(P · WAD / l) ∸ (S + D)`  (liquidity headroom)
- **`maxJTWithdrawal(state)`** = `floor( (J ∸ ceil((C + D) · c / WAD)) · WAD / (WAD − c) )`
  — solves `J − y ≥ (C − y)·c` for `y`; the `WAD − c` denominator is safe because `c < WAD`
  always (A-4).
- **`maxLPTWithdrawal(state)`** = `l == 0 ? P : P ∸ ceil((S + D) · l / WAD)`.

The `D` paddings deliberately under-report capacity so a maximal operation cannot revert on
post-op rounding.

### 4.9 Admin setters and `withSyncedAccounting` (lines 38–55, 671–790)

Twelve `restricted` setters. Two groups:

**YDM setters** (`setJuniorTrancheYDM`, `setLiquidityProviderTrancheYDM`): require the new YDM ≠
the *other* tranche's YDM; then a **best-effort** sync through the kernel
(`_tryExecute` — a reverting sync is tolerated because this setter is the only recovery path from
a sync-bricking YDM); then `_initializeYDM(new, data)` (nonzero address required; init call bubbles
reverts); then store.

**Parameter setters** (fees ×4, `setMinCoverage`, `setLiquidationCoverageUtilization`,
`setMinLiquidity`, `setMaxYieldShares`, `setFixedTermDuration`, `setDustTolerance`): each
revalidates its own bound (same predicates as `initialize`) and runs under `withSyncedAccounting`:

```
preOp  := kernel.syncTrancheAccountingFromAccountant()   // full sync at old params
<setter body>
postOp := kernel.syncTrancheAccountingFromAccountant()   // full sync at new params
require(postOp.U_cov ≤ WAD ∨ postOp.U_cov ≤ preOp.U_cov)                       // coverage no worse
require(preOp.Θ' ≤ postOp.Θ' ∨ postOp.Θ' > postOp.U_cov)                       // liquidation config no worse, or not currently in liquidation
require(postOp.U_liq ≤ WAD ∨ postOp.U_liq ≤ preOp.U_liq)                       // liquidity no worse
```

(`Θ'` = `coverageLiquidationUtilizationWAD` as carried in the state packet. In the code the two
coverage clauses are one combined `require` sharing the `INVALID_COVERAGE_CONFIG` error; the
liquidity clause is a separate `require` with `INVALID_LIQUIDITY_CONFIG`.) The kernel callback
re-enters the accountant (`preOpSyncTrancheAccounting` + `commitLiquidityProviderTrancheRawNAV`)
— so a parameter setter's net storage effect = its own field **plus** two full syncs.

`setFixedTermDuration(0)` additionally force-resets: erases `IL`, sets `PERPETUAL`, deletes
`fixedTermEndTimestamp` (the only setter that touches checkpoints directly).

---

## 5. Environment modeling

This is our recommended environment model, built from how the deployed system actually wires the
accountant. Deviating from it tends to produce spurious counterexamples or vacuous rules; you may
refine it, but document any deviation and its soundness argument in your report.

### 5.1 Contracts and summaries

**Verify `RoycoDayAccountant` as the primary contract.** Link nothing else concretely except a
kernel harness if needed (below).

**YDM calls** — `IYDM.yieldShare(MarketState, uint256)` (nonpayable) and
`IYDM.previewYieldShare(MarketState, uint256)` (view), both return `uint256`:

- For most properties: summarize both with a **shared deterministic ghost function**
  `ghost gYield(address ydm, uint8 state, uint256 util) returns uint256` (unconstrained value).
  Determinism (same args ⇒ same result, and `yieldShare` ≡ `previewYieldShare` at the same
  instant) is the YDM design contract and is required for D-11 (preview/exec equivalence). Do
  **not** constrain the returned magnitude — the accountant clamps it; leaving it unconstrained
  proves the clamp works.
- `NONDET` is acceptable for any property that does not compare two executions and does not
  assert exact premium values.

**Kernel callback** — `IRoycoDayKernel.syncTrancheAccountingFromAccountant()` returns
`SyncedAccountingState`. Reached **only** from the setters. Two workable models:

1. **(Faithful harness)** A harness contract installed as `$.kernel` whose
   `syncTrancheAccountingFromAccountant()` calls
   `accountant.preOpSyncTrancheAccounting(navC)` with a nondet `navC`, then
   `accountant.commitLiquidityProviderTrancheRawNAV(navP)` with a nondet `navP`, and returns the
   state with `lptRawNAV := navP` and `liquidityUtilizationWAD := U_liq(state.stEffectiveNAV,
   state.minLiquidityWAD, navP)` patched in — exactly mirroring
   `AccountingSyncLogic.preOpSyncTrancheAccounting` + `_commitLPTRawNAV` (the fee-share mints in
   between touch only kernel/tranche storage, never accountant storage). Required for rules
   about the `withSyncedAccounting` guard's semantics (J-3) and for exact end-state
   characterization of setters (F-5). Skeleton in §5.4.
2. **(NONDET summary — sound for invariants, and simpler)** A non-havocing `NONDET` summary is
   **sound for invariant preservation** by a compositional argument: the only storage the real
   callback mutates is accountant storage, and it mutates it exclusively by re-entering the
   accountant's own external functions (`preOpSyncTrancheAccounting`,
   `commitLiquidityProviderTrancheRawNAV`) — each of which you prove preserves the invariant
   independently. A setter's real execution is therefore a sequence of individually-preserving
   steps: [callback = preOp∘commit] → [own field write, proven preserving under the summary] →
   [callback]. Every step preserves ⇒ the composition preserves. The guard's `require`s compare
   unconstrained return values under this model (an over-approximation — more behaviors, still
   sound for invariants); just don't write guard-semantics rules under it.

**`_initializeYDM`'s low-level call** (`DispatchLogic._dispatch` → raw `call`): unresolved —
summarize as `NONDET` (return irrelevant; a revert path exists and is fine).

**`Math.mulDiv`**: leave concrete (Certora handles OZ mulDiv); expect nonlinear arithmetic — see
§7.

### 5.2 Global assumptions (state them as `require`s in every rule; they are protocol-level truths)

| # | Assumption | Justification |
|---|---|---|
| ASM-1 | `0 < e.block.timestamp < 2^31` | uint32 timestamp storage; chain reality. Also keeps `now + fixedTermDurationSeconds (u24) + grace (u24)` inside uint32. **Without this, uint32 truncation makes several timestamp properties false** (the repo knowingly tests wrap behavior in `Test_Uint32ClockWrap`). |
| ASM-2 | Monotonic time: within any multi-step rule, later env timestamps ≥ earlier ones | chain reality |
| ASM-3 | NAV magnitudes realistic: `C', P', bonus, D` and stored checkpoints `≤ 1e45` | avoids `int256` cast cliffs (`computeNAVDelta` requires < 2^255) and mulDiv overflow corners that are unreachable through the kernel (NAVs derive from token amounts × oracle prices). For **revert-completeness** rules (C-4/C-5) drop this and treat the cast reverts explicitly. |
| ASM-4 | For invariant induction start from the post-`initialize` state (constructor-equivalence). Use `kernel != 0` as the initialized predicate; all invariants are stated `kernel != 0 ⇒ …`. | proxy pattern; implementation constructor disables initializers |
| ASM-5 | `msg.sender == getState().kernel` when exercising the three kernel-only functions in transition rules (their access-control is proved separately in C-1) | matches deployment wiring |

### 5.3 Reachability setup for non-vacuity

Anchor sanity/vacuity checks on one concrete, healthy instantiation (mirrors test fixtures):
`c = 0.2e18`, `Θ = 1.5e18`, `l = 0.1e18`, `maxJT = 0.3e18`, `maxLPT = 0.2e18`, all fees
`= 0.1e18`, `fixedTermDurationSeconds = 7 days`, grace `= 0`, `D ∈ {0, 1e9}`, checkpoints e.g.
`C = 1_000e18, S = 800e18, J = 200e18, IL = 0, P = 100e18`.

### 5.4 Mechanics: harness, timestamps, and a starter spec shape

**Timestamp mechanics for invariants.** Invariants whose fields include timestamps (B-1, B-2)
need the standard preserved-block hygiene: in every preserved block,
`require e.block.timestamp > 0 && e.block.timestamp < 2^31 && e.block.timestamp >= getState().lastYieldShareAccrualTimestamp && e.block.timestamp >= getState().lastPremiumPaymentTimestamp`
(time moves forward relative to any stored checkpoint). A useful proven stepping-stone:
whenever `tP` is written, `tA` is written to the same value in the same call, so `tP == now ⇒
tA == now` at every write site.

**Faithful kernel harness (model 1), Solidity skeleton:**

```solidity
contract KernelHarness {
    IRoycoDayAccountant public accountant;
    uint256 public nondetC;   // constrain from CVL, or leave arbitrary
    uint256 public nondetP;
    function syncTrancheAccountingFromAccountant() external returns (SyncedAccountingState memory s) {
        s = accountant.preOpSyncTrancheAccounting(NAV_UNIT.wrap(nondetC));
        accountant.commitLiquidityProviderTrancheRawNAV(NAV_UNIT.wrap(nondetP));
        s.lptRawNAV = NAV_UNIT.wrap(nondetP);
        s.liquidityUtilizationWAD = /* U_liq(s.stEffectiveNAV, s.minLiquidityWAD, nondetP) */ 0;
    }
}
```
Install it as `params.kernel` at initialization (its address is the initialization witness).
For non-setter rules you can bypass the harness entirely: call the kernel-only functions with
`require e.msg.sender == getState().kernel`.

**Starter spec shape** (illustrative idiom, not a constraint — adapt freely):

```cvl
methods {
    function _.yieldShare(RoycoDayAccountant.MarketState s, uint256 u) external
        => ghostYield(calledContract, s, u) expect uint256;      // shared ghost ⇒ preview/exec agree
    function _.previewYieldShare(RoycoDayAccountant.MarketState s, uint256 u) external
        => ghostYield(calledContract, s, u) expect uint256;
    function _.syncTrancheAccountingFromAccountant() external => NONDET;  // model 2 (see 5.1)
    function getState() external returns (IRoycoDayAccountant.RoycoDayAccountantState) envfree;
}
ghost ghostYield(address, uint8, uint256) returns uint256;      // unconstrained magnitude

definition initialized() returns bool = getState().kernel != 0;

invariant navConservation()   // A-1
    initialized() => getState().lastCollateralNAV ==
        getState().lastSTEffectiveNAV + getState().lastJTEffectiveNAV
    { preserved with (env e) { require e.block.timestamp > 0 && e.block.timestamp < 2^31; } }
```

---

## 6. Property catalog

This catalog is **our expectation of correct behavior — a floor, not a ceiling**. Prove these,
reformulate them where a better encoding exists, and derive your own beyond them; the highest
engagement value often comes from properties the team didn't think to ask for. Priorities:
**P0** = core soundness (we consider these load-bearing), **P1** = high value, **P2** = valuable
if budget permits. Every property is stated over `RoycoDayAccountant` storage (via `getState()`)
and/or the returned `SyncedAccountingState`. All invariants carry the implicit antecedent
`kernel != 0` (ASM-4) and ASM-1/2/3 unless noted.

### A. Valid-state invariants (inductive over every external function)

- **A-1 (P0) NAV conservation** — the protocol's crown jewel:
  `lastCollateralNAV == lastSTEffectiveNAV + lastJTEffectiveNAV` (exact wei equality).
  *Induction*: init (0 == 0+0); `preOp` and `postOp` re-establish it by explicit `require`
  (and I-1/I-3 show those requires are identities); `commitLPT` and views don't touch the fields;
  setters via kernel-harness reduce to `preOp`+`commitLPT`.

- **A-2 (P0) State/IL coupling**:
  `lastMarketState == PERPETUAL ⇒ lastJTImpermanentLoss == 0`, and
  `lastMarketState == PERPETUAL ⇔ fixedTermEndTimestamp == 0`.
  *Note*: `FIXED_TERM ⇒ IL > dustTolerance` also holds inductively (the state machine forces
  PERPETUAL whenever `IL ≤ D`, `postOp` touches neither, and `setDustTolerance`'s trailing sync
  re-evaluates under the new `D`) — prove it under kernel-model 1 only.

- **A-3 (P1) FIXED_TERM implies live tranches**: `lastMarketState == FIXED_TERM ⇒
  lastSTEffectiveNAV > 0 ∧ lastJTEffectiveNAV > 0`. State this as a `preOp` postcondition
  (folded into D-8), **not** as a storage invariant: in the standalone model the kernel can call
  `postOp` with an ST/JT redemption that zeroes a tranche during FIXED_TERM without re-running
  the state machine. (In the integrated system the kernel gates ST/JT redemptions to PERPETUAL,
  so the global form likely holds end-to-end — but that argument lives outside this contract's
  boundary, so don't rely on it here.)

- **A-4 (P0) Config validity** (each field, whenever `kernel != 0`):
  `minCoverageWAD < WAD`; `minLiquidityWAD < WAD`; `coverageLiquidationUtilizationWAD > WAD`;
  `stProtocolFeeWAD ≤ 1e18 ∧ jtProtocolFeeWAD ≤ 1e18 ∧ jtYieldShareProtocolFeeWAD ≤ 1e18 ∧
  lptYieldShareProtocolFeeWAD ≤ 1e18`;
  `maxJTYieldShareWAD + maxLPTYieldShareWAD ≤ WAD`;
  `jtYDM != lptYDM ∧ jtYDM != 0 ∧ lptYDM != 0`.

- **A-5 (P0) Zero-collateral degeneracy** (corollary of A-1):
  `lastCollateralNAV == 0 ⇒ lastSTEffectiveNAV == 0 ∧ lastJTEffectiveNAV == 0`.

### B. Auxiliary invariants (needed as `requireInvariant` for other proofs)

- **B-1 (P0) Clock ordering**: `tA == 0 ⇒ (tP == 0 ∧ twJT == 0 ∧ twLPT == 0)`, and
  `tA != 0 ⇒ tP ≤ tA ≤ now` (under ASM-1; note both are set together in the bootstrap and `tP`
  is only ever set to a value ≤ the simultaneous `tA`).

- **B-2 (P0) Accrual window bound** — the load-bearing lemma:
  `twJT + twLPT ≤ WAD · (tA − tP)`.
  *Preservation*: each accrual adds `(jtShare + lptShare) · elapsed ≤ (maxJT + maxLPT) · elapsed
  ≤ WAD · elapsed` (by A-4, which holds at accrual time even across `setMaxYieldShares`) while
  `tA` advances by `elapsed`; a premium payment zeroes both accumulators and sets `tP = tA = now`.
  This lemma is what discharges I-2.

### C. Access control and revert conditions

- **C-1 (P0) Kernel-only surface**: `preOpSyncTrancheAccounting`,
  `commitLiquidityProviderTrancheRawNAV`, `postOpSyncTrancheAccounting` revert whenever
  `msg.sender != getState().kernel` (error `ONLY_ROYCO_KERNEL`), for **all** inputs and states.

- **C-2 (P1) Setter gating**: every `set*` function reverts when the AccessManager denies the
  caller (model `restricted` per Certora's AccessManaged idiom, or skip if the manager is
  summarized — then state C-2 only as "setters are the sole writers of config fields", covered by
  F-4).

- **C-3 (P0) Setter and initializer validation** (one-directional "reverts if"; additional
  revert paths exist — guard syncs, YDM init-call reverts):
  `setSeniorTrancheProtocolFee(f)` reverts if `f > 1e18`; same for the other three fees;
  `setMinCoverage(x)` reverts if `x ≥ WAD`;
  `setLiquidationCoverageUtilization(x)` reverts if `x ≤ WAD`; `setMinLiquidity(x)` reverts if
  `x ≥ WAD`; `setMaxYieldShares(a,b)` reverts if `a + b > WAD` (the uint64 sum is checked, so
  near-max inputs revert on overflow — either way A-4 is protected);
  `setJuniorTrancheYDM(y,·)` reverts if `y == getState().lptYDM` or `y == 0`;
  `setLiquidityProviderTrancheYDM(y,·)` reverts if `y == getState().jtYDM` or `y == 0`.
  `initialize` reverts if any §4.1 predicate fails (including `initialAuthority == 0` and
  `kernel == 0`).

- **C-4 (P1) `postOp` shape-check completeness** (per op, under ASM-5): the call reverts iff the
  corresponding row of the §4.7 table is violated, or a checked subtraction underflows (C-5), or
  an int256 cast fails. E.g. for `LPT_DEPOSIT`: reverts iff `¬(ΔP > 0 ∧ ΔC == 0 ∧ bonus == 0)`.

- **C-5 (P1) Bonus safety-by-revert**: `postOp(ST_REDEMPTION, C', P', bonus)` reverts if
  `bonus > J_0` or `bonus > C_0 − C'` or `(C_0 − C') − bonus > S_0`. (The accountant cannot be
  made to pay a bonus that exceeds the junior buffer or the redemption itself.)

- **C-6 (P2) Initialization once**: any second call to `initialize` reverts
  (`InvalidInitialization`).

### D. `preOpSyncTrancheAccounting(C')` transition rules (single call, `msg.sender = kernel`)

Let pre-state `(C_0, S_0, J_0, IL_0)` satisfy A-1/A-2/A-4/B-1/B-2 (`requireInvariant` them all).

- **D-1 (P0) Loss absorption is junior-first and exact**. If `C' < C_0`, with
  `L = C_0 − C'`, `A = min(L, J_0)`:
  `J_1 == J_0 − A`, `S_1 == S_0 − (L − A)`, and
  (`IL_1 == IL_0 + A` **or** `IL_1 == 0` — the state machine may erase). No revert (given
  ASM-1/3; note the YDM accrual call can revert only if the summarized YDM reverts — ghost
  summaries don't).

- **D-2 (P0) Senior is touched only after junior exhausts**:
  `C' < C_0 ∧ S_1 != S_0 ⇒ J_1 == 0`.

- **D-3 (P0) Gain repays IL before anything else**: if `C' > C_0`, `G = C' − C_0`,
  `R = min(G, IL_0)`: mid-waterfall `IL` drops by exactly `R` and `J` rises by exactly `R`
  before any attribution. Observable consequences to assert:
  - `G ≤ IL_0 ⇒` returned `stProtocolFee == jtProtocolFee == lptProtocolFee == 0 ∧
    lptLiquidityPremium == 0 ∧ J_1 == J_0 + G ∧ S_1 == S_0` (repayment is never fee'd and never
    reaches senior),
  - `IL_1 ∈ {IL_0 − R + (G−R > 0 ? 0 : 0), 0}` — i.e. `IL_1 == IL_0 − R` or `IL_1 == 0`
    (state-machine erasure).

- **D-4 (P0) Gain-branch value flow** (full generality). With `g = G − R`,
  `base = C_0 + R`, `stG = (base == 0) ? g : floor(g·S_0/base)`, `jtG = g − stG`, and premiums
  `pJ, pL` as computed (any values consistent with the ghost YDM):
  `S_1 == S_0 + stG − pJ` and `J_1 == J_0 + R + jtG + pJ` and `state.lptLiquidityPremium == pL`
  and `pJ + pL ≤ stG`. (Note `pL` never moves `J`; it stays inside `S_1`.)
  *Fallback relational form* if recomputing `pJ`/`pL` in CVL is awkward: assert
  `J_1 ≥ J_0 + R` (junior never loses on a gain), `S_1 ≤ S_0 + stG` (senior never receives more
  than its attribution), `(S_1 − S_0) + (J_1 − J_0) == G` (the gain is fully distributed), and
  `state.lptLiquidityPremium + (J_1 − J_0 − R − jtG) ≤ stG` (total premiums within the senior
  slice).

- **D-5 (P0) No-op stability**: `C' == C_0 ⇒ S_1 == S_0 ∧ J_1 == J_0` and the only possible
  checkpoint changes are `IL_1 ∈ {IL_0, 0}`, market state, `fixedTermEndTimestamp`, clocks and
  accumulators. Corollary (same-block idempotency): two consecutive `preOp(C')` calls in the same
  block leave all NAV checkpoints identical after the first.

- **D-6 (P0) Accumulator reset iff premiums pay**: returned-`premiumsPaid` is not exposed, so
  phrase on storage: after the call, `(twJT_1 == 0 ∧ twLPT_1 == 0 ∧ tP_1 == now)` **iff**
  (`C' > C_0` with post-repayment `stG > D`) **or** (`tA_0 == 0`, the bootstrap, which zeroes
  trivially with `tP_1 = now`)… For one-shot robustness, split into two implications:
  (i) `stG > D ⇒ twJT_1 == 0 ∧ twLPT_1 == 0 ∧ tP_1 == now`;
  (ii) `C' ≤ C_0 ∧ tA_0 != 0 ⇒ tP_1 == tP_0 ∧` accumulators only grow.

- **D-7 (P1) Fee formulas** (assert on the returned struct, gated exactly as the code gates):
  with `jtG`, `stG`, `pJ`, `pL` as in D-4 and `paid = (stG_pre_premiums > D)`:
  `state.jtProtocolFee == (jtG > D ? floor(jtG·jtFee/WAD) : 0) + (paid ∧ pJ > 0 ?
  floor(pJ·jtYsFee/WAD) : 0)`;
  `state.lptProtocolFee == (paid ∧ pL > 0 ? floor(pL·lptYsFee/WAD) : 0)`;
  `state.stProtocolFee == (paid ? floor((stG − pJ − pL)·stFee/WAD) : 0)`.
  Also the kernel-side consumption bounds: `state.lptProtocolFee ≤ state.lptLiquidityPremium` and
  `state.stProtocolFee + state.lptLiquidityPremium ≤ state.stEffectiveNAV` (these justify
  `FeeAndLiquidityPremiumLogic`'s "never underflows" comments).

- **D-8 (P0) State-machine soundness** (postcondition of `preOp`): `lastMarketState_1 ==
  PERPETUAL` **iff** at least one of the seven §4.5 conditions holds at the evaluated values, and
  `PERPETUAL ⇒ IL_1 == 0 ∧ fixedTermEnd_1 == 0`; `FIXED_TERM ⇒ IL_1 > D ∧ S_1 > 0 ∧ J_1 > 0 ∧
  U_cov(C', c, J_1) < Θ ∧ fixedTermEnd_1 != 0`. Entry stamps `fixedTermEnd_1 == now +
  fixedTermDurationSeconds` only when `lastMarketState_0 == PERPETUAL`; an ongoing term's end is
  never moved.

- **D-9 (P1) Fixed-term pays nothing**: `lastMarketState_1 == FIXED_TERM ⇒
  state.lptLiquidityPremium == 0 ∧ state.stProtocolFee == 0 ∧ state.lptProtocolFee == 0`
  (reason: `FIXED_TERM` requires `IL_1 > D`; a premium/fee requires `stG > D ≥ 0` which requires
  the gain to have fully repaid IL first, i.e. mid-waterfall `IL == 0 ≤ D` — contradiction).
  (`jtProtocolFee` from the pure-JT-gain leg is likewise impossible for the same reason —
  include it.)

- **D-10 (P0) `preOp` return placeholders**: `state.lptRawNAV == 0 ∧
  state.liquidityUtilizationWAD == 0`, and `state.coverageUtilizationWAD == U_cov(C', c, J_1)`,
  and returned NAV fields equal the new checkpoints.

- **D-11 (P1) Preview/execute agreement**: with both YDM functions summarized by the **same**
  ghost (§5.1), `previewSyncTrancheAccounting(C')` returns a struct equal field-for-field to what
  `preOpSyncTrancheAccounting(C')` returns from the same pre-state (and the preview writes
  nothing). *Caveat*: equality of the premium legs relies on `previewYieldShare ≡ yieldShare`
  under the shared ghost; flag this modeling assumption in the report.

### E. `postOpSyncTrancheAccounting` transition rules

Under ASM-5 and `requireInvariant` A-1:

- **E-1 (P0)** Each op's checkpoint effect matches the §4.7 table **exactly**, and
  `C_1 == C'`, `P_1 == P'` in every non-reverting case.
- **E-2 (P0) LPT ops are ST/JT-inert**: for `LPT_DEPOSIT`/`LPT_REDEMPTION` (and any op with
  `ΔC == 0`): `S_1 == S_0 ∧ J_1 == J_0 ∧ IL_1 == IL_0 ∧ lastMarketState_1 == lastMarketState_0`.
  More generally (mirrors fuzz test `Sync_LiquidityMarkNeverMovesSeniorOrJuniorAccounting`): the
  `P'` argument never influences `S_1`, `J_1`, `IL_1` for **any** op.
- **E-3 (P0) `postOp` never touches**: `lastMarketState`, `lastJTImpermanentLoss`,
  `fixedTermEndTimestamp`, `tA`, `tP`, `twJT`, `twLPT`, or any config field. Returned fee/premium
  fields are all zero.
- **E-4 (P1) Bonus conservation**: for `ST_REDEMPTION`, `(S_0 + J_0) − (S_1 + J_1) == C_0 − C'`
  — the bonus reallocates between tranches but total value leaves only via the redemption.

### F. Frame conditions (write-set completeness — parametric rules)

For each function, assert **no storage outside its write-set changes** (compare full `getState()`
before/after):

- **F-1 (P0)** `preOpSyncTrancheAccounting` writes ⊆ {`lastMarketState`, `fixedTermEndTimestamp`,
  `tA`, `tP`, `twJT`, `twLPT`, `lastCollateralNAV`, `lastSTEffectiveNAV`, `lastJTEffectiveNAV`,
  `lastJTImpermanentLoss`} — **notably never `lastLPTRawNAV`** and never any config/YDM/kernel
  field.
- **F-2 (P0)** `commitLiquidityProviderTrancheRawNAV` writes ⊆ {`lastLPTRawNAV`}.
- **F-3 (P0)** `postOpSyncTrancheAccounting` writes ⊆ {`lastCollateralNAV`, `lastLPTRawNAV`,
  `lastSTEffectiveNAV`, `lastJTEffectiveNAV`}.
- **F-4 (P0)** Config sole-writer: `stProtocolFeeWAD` changes only in
  {`initialize`, `setSeniorTrancheProtocolFee`}; analogously for every config field, `jtYDM`,
  `lptYDM`, `maxJT/maxLPT`, `minCoverage`, `Θ`, `minLiquidity`, `fixedTermDurationSeconds`,
  `dustTolerance`, `fixedTermCommenceableAtTimestamp` (only `initialize`), `kernel` (only
  `initialize`).
- **F-5 (P1)** Under kernel-model 1: each parameter setter's checkpoint effects are exactly those
  achievable by (sync ∘ own-field-write ∘ sync); `setFixedTermDuration(0)` may additionally
  zero `IL`/state/term directly.
- **F-6 (P0)** All views (`previewSyncTrancheAccounting`, `maxSTDeposit`, `maxJTWithdrawal`,
  `maxLPTWithdrawal`, `getState`) write nothing (compiler-guaranteed `view`, but assert once for
  the record via a parametric no-write rule).

### G. Capacity-function correctness

Pure algebra over the *passed-in memory struct* (only `dustTolerance` is read from storage).
Preconditions for every G rule: A-4 bounds on the struct's config fields
(`st.minCoverageWAD < WAD`, `st.minLiquidityWAD < WAD`) and — because the kernel only ever passes
synced states — **struct conservation**: `st.collateralNAV == st.stEffectiveNAV +
st.jtEffectiveNAV` (this is what gives `J ≤ C`, needed for G-2's `y ≤ J` step). Realistic
magnitude bounds per ASM-3.

⚠️ **Guard every safety claim on a non-zero result.** When the market is already in violation,
these functions correctly saturate to zero — and the "post-operation state satisfies the
requirement" claim is *false* for the degenerate zero result (the pre-state already violates).
The meaningful property is: *a non-zero reported capacity is safe to consume.*

- **G-1 (P0) `maxSTDeposit` is safe**: let `m = maxSTDeposit(st)`. If `m != 0` and
  `m < MAX_NAV_UNITS` then:
  - if `st.minCoverageWAD != 0`: `(st.collateralNAV + m + D) · st.minCoverageWAD ≤
    st.jtEffectiveNAV · WAD`, hence `U_cov(st.collateralNAV + m, c, st.jtEffectiveNAV) ≤ WAD`
    (a ceil-division of a product ≤ `J·WAD` cannot exceed `WAD`);
  - if `st.minLiquidityWAD != 0`: `(st.stEffectiveNAV + m + D) · st.minLiquidityWAD ≤
    st.lptRawNAV · WAD`.
  (Both follow because `m = min(x, x')` and `m != 0` forces each active leg's own bound `x`/`x'`
  to be non-saturated; monotonicity in `m ≤ x, x'` transfers the bound.)
- **G-2 (P0) `maxJTWithdrawal` is safe**: let `y = maxJTWithdrawal(st)`. If `y != 0` then
  `y ≤ st.jtEffectiveNAV` and `y ≤ st.collateralNAV` (needs struct conservation: `y ≤
  J·(WAD−c)/(WAD−c) = J ≤ C` since `surplus ≤ J − J·c`), and
  `(st.jtEffectiveNAV − y) · WAD ≥ (st.collateralNAV − y + D) · st.minCoverageWAD`.
  Derivation: `y·(WAD−c) ≤ surplus·WAD = (J − required)·WAD` with
  `required ≥ (C+D)·c/WAD` ⇒ `(J−y)·WAD ≥ required·WAD − y·c ≥ (C+D−y)·c`. If the prover
  struggles with the combined nonlinear step, split `y ≤ J` and the main inequality into
  separate lemmas.
- **G-3 (P0) `maxLPTWithdrawal` is safe**: let `z = maxLPTWithdrawal(st)`. Then
  `st.minLiquidityWAD == 0 ⇒ z == st.lptRawNAV`, and if `st.minLiquidityWAD != 0 ∧ z != 0`:
  `(st.lptRawNAV − z) · WAD ≥ (st.stEffectiveNAV + D) · st.minLiquidityWAD`
  (`z != 0` ⇒ `P > required` ⇒ `P − z == required == ceil((S+D)·l/WAD)`).
- **G-4 (P2) Monotonicity**: `maxSTDeposit` is monotone nondecreasing in `jtEffectiveNAV` and in
  `lptRawNAV`; `maxJTWithdrawal` monotone nondecreasing in `jtEffectiveNAV`; all three monotone
  nonincreasing in `dustTolerance`.

### H. Utilization math lemmas (`UtilizationLogic`, pure — cheap, prove first)

- **H-1 (P0)**: `U_cov(C,c,J) == 0 ⇔ (c == 0 ∨ C == 0)`;
  `c != 0 ∧ C != 0 ∧ J == 0 ⇒ U_cov == uint256.max`;
  otherwise `U_cov == ceilDiv(C·c, J)`; and `U_cov ≤ WAD ⇔ C·c ≤ J·WAD` (in the finite branch).
  Mirror for `U_liq`.
- **H-2 (P1)**: finite-branch monotonicity: `U_cov` nondecreasing in `C` and `c`, nonincreasing
  in `J`.

### I. Unreachability — defense-in-depth `require`s that never fire

These are the deepest, most valuable one-shot results: prove the checked conditions are
**arithmetic identities/consequences**, i.e. the error is unreachable from any state satisfying
the invariants.

- **I-1 (P0)** `NAV_CONSERVATION_VIOLATION` in `preOp` (line 526) is unreachable given A-1
  pre-state: loss branch `S_1 + J_1 = S_0 + J_0 − L = C'`; gain branch
  `S_1 + J_1 = S_0 + J_0 + R + g = C_0 + G = C'` (premiums cancel: `−pJ` from `S`, `+pJ` to `J`;
  `pL` subtracted then re-added to `S`).
- **I-2 (P0)** `PREMIUMS_EXCEED_SENIOR_YIELD` (line 498) is unreachable given B-1 + B-2 + A-4:
  timed path: `pJ + pL ≤ stG·(twJT + twLPT)/(Δt·WAD) ≤ stG·(WAD·(tA − tP))/((now − tP)·WAD) ≤
  stG` since `tA ≤ now`; same-block path: `Δt = 1`, shares clamped so `twJT + twLPT ≤ maxJT +
  maxLPT ≤ WAD = Δt·WAD`.
- **I-3 (P0)** `NAV_CONSERVATION_VIOLATION` in `postOp` (line 253) is unreachable given A-1:
  every op row preserves `S_1 + J_1 == C'` identically (§4.7 algebra).
- **I-4 (P1)** The loss-branch senior subtraction (line 433) and the gain-branch bookings never
  underflow/overflow given A-1 + ASM-3 (i.e., `preOp` is revert-free apart from YDM-call reverts
  and ASM-violating inputs — a liveness result: **the accounting sync cannot brick**).

### J. Stretch properties (only if budget remains)

- **J-1 (P2) Dip-recover path equivalence** (mirrors fuzz test
  `Sync_dipRecoverMatchesDirectPath`): within one block (so no time-weighted premium interference)
  and from an A-1/A-2-satisfying state with `IL_0 == 0`:
  `preOp(C_dip); preOp(C_final)` with `C_dip < C_0 ≤ C_final`, market staying `FIXED_TERM`-free
  or fully recovering, yields the same `(S, J, IL)` as a single `preOp(C_final)` — restrict to
  `D == 0` and the no-state-transition case to keep it tractable.
- **J-2 (P2) Attribution drift bound** (mirrors `Attribution_ResidualSplitConservesExactly…`):
  `stG + jtG == g` exactly, and `|stG·(C_0+R) − g·S_0| < (C_0+R)` (floor drift < 1 unit of the
  denominator, always favoring JT).
- **J-3 (P2) `withSyncedAccounting` guard semantics** under kernel-model 1: a parameter change
  that leaves `U_cov` over WAD **and** worse than before always reverts; a change with
  `postOp.U_cov ≤ WAD` never reverts on the coverage leg.

### K. Properties we believe are **false** (or out of scope) — and why

Recorded so you can spend budget wisely, not to forbid testing our reasoning. If you disagree
with a rationale here, a cheap falsification/confirmation run is a fine use of budget — but do
not sink deep effort into proving these as stated.

- ❌ "`U_cov ≤ WAD` / `U_liq ≤ WAD` always" — **false**. Markets can be under-collateralized /
  under-liquid; enforcement is kernel-side and only for specific operations.
- ❌ "`FIXED_TERM ⇒ now ≤ fixedTermEndTimestamp`" — **false**. Checkpoints are stale between
  syncs; the transition happens at the *next* sync after expiry.
- ❌ "`IL ≤ J`" or "`IL ≤ C`" — **false in general** (IL tracks cumulative drawdown; `J` shrinks
  as IL deepens; e.g. `J_0 = 100`, loss 100 ⇒ `J = 0`, `IL = 100`).
- ❌ Anything relating `lastLPTRawNAV` to "real" venue value, share supplies, share prices, or
  minted fee shares — kernel/tranche-side, exogenous here.
- ❌ A-3 as a global storage invariant (see A-3 note) — `postOp` can zero a tranche.
- ❌ Exact premium values across **multiple blocks with an unconstrained/adaptive YDM** — the
  ghost-summarized YDM output is arbitrary; only the clamped, window-bounded forms (D-4, I-2)
  are provable.
- ❌ "Setters preserve all NAV checkpoints" — **false**; `withSyncedAccounting` and the YDM
  setters run full syncs that legitimately move checkpoints; `setFixedTermDuration(0)` erases IL.
- ❌ Timestamp properties without ASM-1 — uint32 truncation breaks them (known, tested wrap
  behavior).
- ❌ `initialize` frontrunning/proxy-deployment concerns — deployment-template scope.

---

## 7. Practical prover guidance

1. **Order of attack**: H (pure lemmas) → A/B invariants → I (unreachability, reusing A/B via
   `requireInvariant`) → C → F (parametric frame rules) → D/E → G → J. The D/E rules should
   `requireInvariant` A-1, A-2, A-4, B-1, B-2 in their preconditions — without B-2, I-2 and the
   premium legs of D-4 will produce spurious counterexamples.
2. **Nonlinear arithmetic**: the waterfall stacks `mulDiv`s (attribution, premiums, fees). If a
   monolithic D-4 times out, split per leg (attribution only with premiums forced zero via
   `twJT == twLPT == 0 ∧ now == tP`; premium only with `IL_0 == 0 ∧ jtG == 0` by choosing
   `S_0 == C_0`), then compose. Choosing `D == 0` removes the dust gates from most rules; add a
   separate small rule for the `D > 0` gating behavior (D-7's conditionals).
3. **The enum**: `MarketState` is `uint8` in storage (`PERPETUAL = 0`, `FIXED_TERM = 1`); ghosts
   and hooks should treat any other value as unreachable (assert it once as a cheap invariant).
4. **Sanity/vacuity**: run `rule_sanity: basic`. The premium rules are the vacuity hazard — a
   reachable state with `stG > D > 0` requires `C' − C_0` large enough to clear `IL_0` and dust;
   use the §5.3 anchor state. D-9's antecedent (`FIXED_TERM` result) needs
   `fixedTermDurationSeconds != 0`, `now ≥ fixedTermCommenceableAtTimestamp`, `IL_1 > D`,
   `U_cov < Θ` simultaneously — seed accordingly (e.g. small fresh loss on the anchor state).
5. **Do not link the real kernel or real YDMs** — the Balancer-v3 kernel graph is enormous and
   irrelevant; the accountant's correctness is fully expressible against the models in §5.
6. **Extend the spec**: after the catalog is dispatched, spend remaining budget deriving your
   own properties — adversarial ones especially (can any call sequence inflate `J` without a
   gain? extract value through the dust gates? desynchronize `tP`/`tA`? exploit the same-block
   instantaneous path?). The repo's own regression tests
   (`Test_SeniorLeverageViaImpermanentLossRecovery_PoC`,
   `Test_CoverageCrossClaimFindings_Accountant`, `Test_SameBlockPremiumConservation`,
   `test/fuzz/Accountant/*`) mark the spots where bugs have historically lived — mine them for
   property ideas.
7. **Report honestly**: for every property, report VERIFIED / VIOLATED (with concrete
   counterexample trace) / TIMEOUT — and for VERIFIED rules list the assumptions (ASM-1..5,
   ghost-YDM determinism, kernel model choice) they depend on. A violation of A-1, B-2, I-1, I-2,
   or I-3 would be a critical protocol finding; treat any such counterexample as a bug candidate
   and re-derive it concretely against the Solidity before reporting. Novel properties you derive
   yourself belong in the report with the same rigor as the catalog's.
