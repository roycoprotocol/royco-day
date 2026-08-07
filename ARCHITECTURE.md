# ARCHITECTURE.md — Royco Day System Design Document

> **Audience**: Certora AutoProver (agentic formal verification) and engineers onboarding to the
> repo. This is the repo-specific design document: the full system architecture, component
> responsibilities, trust boundaries, end-to-end flows, and the system-wide invariant catalog.
> It is complementary to **`AUTOPROVER.md`**, which is the deep-dive verification brief for the
> `RoycoDayAccountant`. Read this document first for the design; use `AUTOPROVER.md` for the
> accountant's step-by-step logic, environment model, and property catalog. Together with the
> source they are intended to be sufficient context for a full formal verification engagement.
>
> Treat both documents as the protocol team briefing its formal verification team: they tell you
> how the system works and how we expect it to behave for correctness. They are **guides, not
> limits** — you are the verification specialist, and deriving your own properties (and
> challenging ours) is part of the engagement.

---

## Table of Contents

1. [What Royco Day is](#1-what-royco-day-is)
2. [Contract topology and deployment units](#2-contract-topology)
3. [Core design principles](#3-core-design-principles)
4. [Units, types, and math conventions](#4-units-types-and-math-conventions)
5. [Component design](#5-component-design)
   - 5.1 Tranches, 5.2 Kernel, 5.3 Liquidity venue (Balancer V3), 5.4 Accountant,
     5.5 YDMs, 5.6 Oracles, 5.7 Entry point, 5.8 Factory/templates/gatekeeper,
     5.9 Blacklist, 5.10 Cache, 5.11 Dispatch (execute/simulate)
6. [End-to-end flows](#6-end-to-end-flows)
7. [Market states and lifecycle](#7-market-states-and-lifecycle)
8. [Roles, governance, and trust model](#8-roles-governance-and-trust-model)
9. [System-wide invariant catalog](#9-system-wide-invariant-catalog)
10. [Assume/guarantee contracts between components](#10-assumeguarantee-contracts)
11. [Verification scoping guidance](#11-verification-scoping-guidance)
12. [Known caveats and repo hygiene notes](#12-known-caveats)
13. [Glossary](#13-glossary)

---

## 1. What Royco Day is

Royco Day transforms the risk and liquidity profile of any yield source by splitting it into
three tranches per **market**:

- **Senior Tranche (ST)** — the liquid, loss-protected asset. Senior LPs are protected from
  losses up to a guaranteed threshold (the junior buffer absorbs losses first) and are guaranteed
  a minimum amount of secondary liquidity. In exchange they pay two premiums out of their yield:
  a **risk premium** to the junior tranche and a **liquidity premium** to the liquidity provider
  tranche.
- **Junior Tranche (JT)** — first-loss capital. JT provides a coverage buffer that absorbs
  collateral losses before senior capital is touched; in return it earns the risk premium.
- **Liquidity Provider Tranche (LPT)** — market-making capital. It holds an AMM position pairing
  the ST share against a stablecoin (quote asset), so senior holders can always exit through the
  venue instantly. It earns the liquidity premium, which is minted as ST shares and reinvested
  into the venue, making the LPT share up-only and composable. LPT capital is covered senior
  capital: pari passu with ST on risk, forgoing liquidity for extra yield.

### The two NAV types

- **Collateral NAV** (`C`): the pure oracle value of the co-invested collateral backing ST and
  JT. Both deposit the *same* collateral asset, so one pool and one price back both.
- **Effective NAVs** (`S`, `J`): the senior and junior *claims* on the collateral NAV after
  applying loss absorption, impermanent-loss repayment, and yield distribution. These determine
  redemption value. **`C == S + J` exactly, always** — the NAV conservation invariant.
- The LPT has **no effective NAV in that identity**. Its redemption value = its **raw NAV**
  (`P`, the venue position marked by the venue's manipulation-resistant oracle) plus the value of
  any idle liquidity-premium ST shares not yet reinvested.

### The two requirements

- **Minimum coverage**: `J ≥ C · minCoverage`. Measured as
  `coverageUtilization = C · minCoverage / J` (≤ 100% ⇔ satisfied). A separate, strictly-above-
  100% **liquidation coverage utilization** threshold (`Θ`) marks the market unhealthy: beyond
  it, ST redeemers receive a **self-liquidation bonus** funded from JT effective NAV to
  incentivize senior exits, and JT deposits must restore health in one shot (no trickle-in
  recapitalization that would subsidize bonus exits).
- **Minimum liquidity**: `P ≥ S · minLiquidity`. Measured as
  `liquidityUtilization = S · minLiquidity / P`. Redemptions that reduce venue depth are gated so
  the venue can't be drained below the senior liquidity floor; a multi-asset LPT exit relaxes the
  floor in-flow by redeeming the senior legs it withdraws.

Two **Yield Distribution Model (YDM)** instances per market size the premiums: one driven by
coverage utilization (risk premium to JT), one by liquidity utilization (liquidity premium to
LPT). Higher utilization ⇒ larger share of senior yield paid out, attracting the scarce capital.

---

## 2. Contract topology

### Per market (deployed atomically by a template through the factory; 7 fresh addresses)

| Contract | Proxy model | Role |
|---|---|---|
| `RoycoSeniorTranche` | BeaconProxy | ST ERC20 share vault (thin façade over kernel) |
| `RoycoJuniorTranche` | BeaconProxy | JT ERC20 share vault |
| `RoycoLiquidityProviderTranche` | BeaconProxy | LPT ERC20 share vault (+ multi-asset flows) |
| `RoycoDayBalancerV3Kernel` | BeaconProxy | Operational core: custody, orchestration, venue |
| `RoycoDayAccountant` | BeaconProxy | Financial ledger: waterfall, premiums, fees, state machine |
| Gyro E-CLP pool (Balancer V3) | — | The LPT's market-making venue (`[ST share, quote]`) |
| BPT LP-oracle | — | Manipulation-resistant mark of the pool position |

Plus, selected per market but shared/pre-existing: two **YDM instances** (registered on the
template by shape name; per-market state keyed by accountant address), one **collateral asset
oracle** (immutable adapter, deployed outside the template), and the chain singletons below.

### Chain singletons (UUPS/ERC1967 proxies unless noted)

| Contract | Role |
|---|---|
| `RoycoAccessManager` | OZ AccessManager + permanent `wasEverConfigured` ledger; the single authority for every market |
| `RoycoFactory` | Template registry + deployment entrypoint + tranche→kernel registry |
| `RoycoFactoryGatekeeper` (non-proxy) | Holds `ADMIN_ROLE` on the access manager so the factory doesn't; writes role bindings exactly once per fresh target |
| `RoycoCreate3Deployer` (non-proxy) | CREATE3 primitive; addresses depend on salt only, namespaced per deployer |
| `RoycoDayEntryPoint` | Async request queue (T+n settlement) for all tranches |
| `RoycoBlacklist` | Chain-wide blacklist + Chainalysis sanctions overlay |
| Market syncer (periphery) | Batch keeper syncs |
| 5 `UpgradeableBeacon`s | One per market component kind; upgrading a beacon upgrades every market at once |

### Upgradeability

- Singletons: UUPS, `upgradeToAndCall` gated by `ADMIN_UPGRADER_ROLE`,
  `_authorizeUpgrade` requires the new implementation to have code.
- Market components: beacon proxies with **no per-proxy upgrade entrypoint**; beacon
  `upgradeTo` is gated by `ADMIN_UPGRADER_ROLE`.
- Every upgradeable contract uses **ERC-7201 namespaced storage** with an assembly slot
  accessor, and `_disableInitializers()` in the implementation constructor; `initialize(...)` is
  the constructor-equivalent behind the proxy.

### Code organization

Business logic lives in **external/public library functions** (`src/libraries/logic/*`) that the
kernel reaches by **delegatecall** — inside them `address(this)` is the kernel and `$` is the
kernel's ERC-7201 state. The kernel also **self-calls** (`onlySelf`) into venue driver functions.
The accountant, by contrast, is self-contained (only internal libraries).

---

## 3. Core design principles

These recur throughout the code and should anchor any formal reasoning:

1. **NAV conservation** — `C == S + J` to the wei, enforced by `require` in both accountant sync
   paths, re-established by construction in every flow. The liquidity premium is deliberately
   minted as *senior shares* (value reassignment inside `S`) precisely so this two-term identity
   and coverage are preserved.
2. **One price per operation** — the kernel's `withPriceCache` modifier pokes the collateral
   oracle as the operation's *first* action (oracle circuit-breaker halts everything before any
   conversion) and caches one collateral price and one ST share price for the whole operation
   frame, cleared on exit.
3. **Junior-first losses; restoration before yield** — losses deepen the JT impermanent loss
   (recoverable drawdown); gains repay it off the top before any pro-rata split, premium, or fee.
   Repayment is restoration, never yield, and is never fee'd.
4. **Coverage-neutral premium** — the LPT liquidity premium never adds senior exposure; it
   reassigns existing senior appreciation as ST shares held by the kernel for the LPT.
5. **Fail-shut pricing** — staleness enforced per oracle hop inside the oracle; a source update
   the deviation clock cannot observe holds the entry point's execution gate shut; previews
   simulate the poke so they fail identically to execution.
6. **Simulation purity** — previews run the *real* execution path and unwind via a
   result-carrying revert (`SIMULATION_RESULT`), so preview and execution can never disagree.
   (`DispatchLogic`, §5.11.)
7. **Checks-effects-interactions** — ledgers are debited and shares burned before any transfer;
   post-op accounting commits before remittance.
8. **Deterministic, mined deployment** — every address is CREATE2/CREATE3-predicted; the market
   id is mined so the ST share sorts as Balancer token0; a single source of truth
   (`RoycoDeterministic`) prevents derivation drift.
9. **Configure-once authority** — the gatekeeper writes role bindings for a fresh target exactly
   once, can never bind `PUBLIC_ROLE`/`ADMIN_ROLE`, and can never touch the manager, factory, or
   itself.
10. **Screened value movement** — every tranche share mint/burn/transfer passes through the
    kernel's `preTrancheBalanceUpdateHook`, which screens caller/from/to against the blacklist
    and pauses under kernel pause.

---

## 4. Units, types, and math conventions

(Full detail in `AUTOPROVER.md` §3; summary here.)

- `NAV_UNIT` — user-defined value type over `uint256`; the market's unit of account, **always
  WAD (18-dec) precision**. All bound operators are checked 0.8 arithmetic.
- `TRANCHE_UNIT` — native token units of a tranche's base asset (its own decimals, ≤ 18
  enforced at kernel init).
- **Tranche shares are always 18 decimals** regardless of the underlying, because shares are
  minted against NAV values.
- `WAD = 1e18` fixed point for all percentages/utilizations. No RAY anywhere.
- `RoycoUnitsMath` supplies typed `mulDiv` with explicit `Math.Rounding`; rounding directions
  are chosen per call site and documented (generally: **in favor of senior protection** for
  gates/utilizations, **in favor of the paying side** for premiums, floor for share mints).
- Share pricing uses **virtual shares/value** (`VIRTUAL_SHARES = 1`, `VIRTUAL_VALUE = 1`) à la
  OZ ERC4626 inflation defense:
  `shares = (supply + 1) · value / (totalValue + 1)` and its exact inverse for value.
- **Mint-dilution clamp** (`MAX_MINT_DILUTION_WAD = WAD − 1e6`): a single mint may own at most
  ~99.9999999999% of post-mint supply. It arms only in the collapsed-price regime (supply alive,
  backing near zero — the state a supply-inflation attack needs); healthy mints always price
  fairly and the bootstrap mint is exempt.

---

## 5. Component design

### 5.1 Tranches (`src/tranches/`)

`RoycoVaultTranche` (abstract base): ERC20 + Permit + Burnable, `AccessManaged` + `Pausable`.
Storage is just `{kernel, asset}`. The tranche is a **thin façade**: `deposit` pulls assets to
the *kernel* then dispatches `inkindDeposit`; `redeem` spends allowance then dispatches
`inkindRedeem`; the kernel mints/burns via `kernelMint`/`kernelBurn` (`onlyKernel` — an
immutable-address check deliberately *not* an AccessManager role, so minting is scoped to THIS
market's kernel). `previewDeposit`/`previewRedeem` are non-view SIMULATE dispatches.
`_update` (all transfers/mints/burns) calls the kernel's `preTrancheBalanceUpdateHook` first.

- **Senior**: adds `mintLiquidityPremiumShares(shares)` (`onlyKernel`) which mints **to the
  kernel** — the idle premium pile held for the LPT.
- **Junior**: no extra surface.
- **LPT**: base asset is the venue LP token (BPT). Adds `depositMultiAsset` /
  `redeemMultiAsset` (+ previews, + `maxRedeemMultiAsset`), which pull/push the collateral and
  quote legs and dispatch the composite kernel flows.
- LPT view-conversion caveat: `convertToAssets`/`convertToShares` deliberately exclude the idle
  premium ST shares (conservative floor, so reinvestment slippage can't drop the quoted share
  price); `previewDeposit`/`previewRedeem` are the accurate quotes.

`deposit`/`redeem`/`depositMultiAsset`/`redeemMultiAsset`/`burn`/`burnFrom` are `restricted`
(bound to `ST_LP_ROLE`/`JT_LP_ROLE`/`LPT_LP_ROLE`/`BURNER_ROLE` per market) — markets can be
permissioned or open depending on role grants (the entry point holds all three LP roles).

### 5.2 Kernel (`src/kernels/base/RoycoDayKernel.sol`)

The operational core and **sole custodian**: collateral assets, BPT, and the LPT's idle senior
shares all sit on the kernel. Three storage ledgers: `totalCollateralAssets` (shared by ST+JT —
coinvestment is structural, both tranches' `asset()` must equal the kernel's collateral asset),
`totalLPTAssets` (BPT), `lptOwnedSeniorTrancheShares` (idle premium pile).

Key modifiers: `onlyTranche` / `onlyLiquidityProviderTranche` (operation entrypoints),
`onlySelf` (venue drivers), `withPriceCache` (poke → cache → clear), `withLiquidityPremiumReinvestment`
(post-operation tail that deploys the idle premium pile; never reached by simulations because
the result-carrying revert exits first), `nonReentrant` (transient), `whenNotPaused`,
`restricted`.

Responsibilities:
- **Pricing**: converts collateral/LPT assets ⇄ NAV at the cached (or live) oracle price;
  optional L2 sequencer-uptime gate with post-restart grace; strictly positive price required.
- **Orchestration**: every deposit/redemption runs pre-op sync → operation → post-op sync
  (§6). The kernel — not the accountant — enforces the coverage/liquidity gates on the post-op
  state and blocks ST/JT ops (and LPT redemptions) during `FIXED_TERM`.
- **Accountant liaison**: the only caller of the accountant's mutating functions; also exposes
  `syncTrancheAccountingFromAccountant()` (guarded `msg.sender == accountant`) for the
  accountant's parameter-setter guard.
- **Blacklist chokepoint**: `preTrancheBalanceUpdateHook` screens every share movement.
- **Admin**: protocol fee recipient, self-liquidation bonus rate (< WAD), blacklist pointer
  (null disables screening), collateral oracle replacement (never null; always syncs at the
  incoming oracle's price, optionally at the outgoing one first), sequencer feed.

### 5.3 Liquidity venue (Balancer V3) (`src/kernels/base/liquidity-venue/balancer-v3/`)

A mixin the concrete kernel inherits — everything venue-specific lives here, so new venues
(Uniswap, Curve, …) plug in as new mixins + templates without touching kernel core, tranches, or
accounting.

- **Structural invariant**: the Gyro E-CLP pool has exactly two tokens, `token0 == seniorTranche`
  and `token1 == quoteAsset` — guaranteed by market-id mining at deployment, asserted at init,
  and hard-coded as indices in the venue logic.
- **The kernel IS the pool's senior-leg rate provider** (`getRate()`): returns the cached
  ST share price inside an operation frame (so an inline senior mint/burn cannot transiently move
  the pool's mark), else derives it from the accountant's *preview* directly (never recursing
  into the LPT mark), floored at 1 wei. `whenNotPaused` so the pool can't trade against a faulty
  kernel.
- **Venue drivers** (`onlySelf`, `whenVaultLocked` — the operation must open the outermost vault
  session): `addLiquidity` (unbalanced add of [ST shares, quote]), `removeLiquidity`
  (proportional), both via the vault-unlock callback pattern and both SIMULATE-capable (the
  simulation revert carries the post-op venue mark, which previews cache — the unwind discards
  the settled pool state).
- **LPT raw NAV mark**: `bptPrice = LPOracle.computeTVL() / bptTotalSupply` (floor — never
  overstate depth); zero BPT supply ⇒ zero NAV.
- **Liquidity premium reinvestment**: values the idle pile at the frame's ST share rate (ceil),
  converts to fair BPT at the oracle mark, applies `maxReinvestmentSlippageWAD` to set a min-out
  floor **against the oracle, never pool spot** (a manipulated pool cannot widen the tolerance),
  then attempts a **non-blocking** single-sided add: on failure the shares stay idle and an event
  is emitted; on success `lptOwnedSeniorTrancheShares` decreases and `totalLPTAssets` increases.

### 5.4 Accountant (`src/accountant/RoycoDayAccountant.sol`)

The market's financial ledger — a pure accounting state machine holding no assets. Full
step-by-step logic, storage layout, and the verification property catalog are in
**`AUTOPROVER.md`** (the primary verification target). Summary of its obligations:

- **Pre-op sync**: settle unrealized PnL through the waterfall (loss: junior-first into the JT
  impermanent loss, residual to senior; gain: IL repayment off the top, pro-rata split of the
  residual, premiums out of the senior slice via the time-weighted YDM outputs, protocol fees on
  post-repayment residual gains only), enforce conservation, run the market state machine,
  checkpoint `(marketState, C, S, J, IL)`.
- **LPT mark commit**: a separate `commitLiquidityProviderTrancheRawNAV` call, strictly *after*
  the kernel mints the sync's fee/premium shares (the venue mark prices the ST leg at the
  post-mint share rate).
- **Post-op sync**: strictly interpret the operation's NAV deltas (no waterfall, no fees),
  validate per-operation shape, re-checkpoint.
- **Capacity math**: `maxSTDeposit`, `maxJTWithdrawal`, `maxLPTWithdrawal`, rounding in favor of
  senior protection, padded by the dust tolerance.
- **Parameter governance**: setters gated by roles and by the `withSyncedAccounting` guard
  (sync before/after; coverage/liquidity may not worsen past 100%; a config change cannot push
  the market into liquidation).

### 5.5 YDMs (`src/ydm/`)

`IYDM`: `previewYieldShare(MarketState, utilizationWAD) → yieldShareWAD` (view) and
`yieldShare(...)` (may mutate adaptive state). All state keyed
`mapping(address accountant ⇒ …)` — one deployed instance serves many markets;
`initializeYDMForMarket` is called by the accountant (`msg.sender` is the key). The accountant
clamps every output at its configured max, and validates `maxJT + maxLPT ≤ WAD` so premiums
always fit within the senior gain.

| Model | Shape | Adaptation |
|---|---|---|
| `FixedYDM` | constant share (explicit `initialized` flag so a configured zero is expressible) | none |
| `StaticCurveYDM` | piecewise-linear through `(0, Y₀)`, `(U_T, Y_T)`, `(1, Y_full)`, `Y₀ ≤ Y_T ≤ Y_full ≤ WAD` | none |
| `AdaptiveCurveYDM_V1` | multiplicative: `Y(1) = S·Y_T`, `Y(0) = Y_T/S`, steepness `S` fixed at init | `Y_T` scales exponentially with time-integrated utilization deviation (Morpho-style), **only in PERPETUAL** |
| `AdaptiveCurveYDM_V2` | additive: fixed discount/premium spreads around `Y_T` | `Y_T` translates vertically; slopes constant; only in PERPETUAL |

Adaptive engine (`BaseAdaptiveCurveYDM`): normalized deviation `Δ ∈ [−WAD, WAD]` from the target
kink, adaptation speed `∝ Δ`, exponential update clamped to `[minY_T, maxY_T]`, trapezoidal
time-averaging for the returned share, `expWad` input capped below its overflow threshold. In
`FIXED_TERM` the curve is frozen (utilization moves on PnL, not market forces).

### 5.6 Oracles (`src/oracle/`)

One **collateral asset oracle** per market: price of 1 whole collateral asset in NAV units
(always 18-dec), doubling as the **update clock** for the entry point's execution gate (the
pricing source and the gating signal are the same object). Adapters are **fully immutable** — no
admin, no upgrade path; reconfiguration = redeploy + kernel repoint.

- Two-hop model: collateral → reference asset (live WAD conversion) → NAV (Chainlink feed), each
  hop with its own construction-fixed staleness threshold; both hops composed in a single floored
  `mulDiv`. Reported `updatedAt` is the **oldest** timestamped hop.
- Sources without timestamps get a **deviation clock** (`OracleClockBase`): checkpoints observed
  price deviations ≥ `MIN_DEVIATION_WAD`; a republish at an unchanged price is unobservable and
  conservatively holds the gate shut. `poke()` commits, `previewPoke()` never disagrees with it.
  The baseline can only be set at construction (enforced by a code-length check).
- Honesty invariant: `poke` must report only genuine source-update wall-clock times, zero when
  none observed, never manufactured or future timestamps — the entry point compares it directly
  against request timestamps.
- Concrete adapters: `ChainlinkPriceOracle` (identity hop), `ERC4626SharePriceOracle`
  (convertToAssets or previewRedeem, clocked), `IdleCDOTranchePriceOracle` (virtualPrice,
  clocked, AA/BB tranche validated), `MakinaSharePriceOracle` (machine timestamps its own
  accounting; no clock needed).

### 5.7 Entry point (`src/entrypoint/RoycoDayEntryPoint.sol`)

Asynchronous deposit/redemption queue implementing **T+n settlement** against oracle
front-running: users escrow assets/shares in a request; execution requires (a) a per-tranche
delay and (b), if configured, at least one collateral-oracle update observed *after* request
time.

**Yield neutrality** (the anti-free-option design): a request can never be worth more at
execution than at request time, though losses pass through.
- Deposits are pinned on a **share basis**: `equivalentSharesAtRequestTime` snapshotted
  (deliberately using the *unclamped* share conversion so the dilution clamp can't manufacture
  forfeiture); excess shares minted at execution are forfeited to the protocol.
- Redemptions are pinned on a **value basis**: `valueAtRequestTime` snapshotted (deliberately
  excluding any self-liquidation bonus so the bonus is never skimmed); value accrued while
  queued is skimmed as protocol fee shares.

Requests fill incrementally (partial fills rescale pro-rata), can be executed by third-party
keepers for an opt-in bonus (`executorBonusWAD`; a sentinel disables third-party execution), and
can be cancelled anytime for the original escrow. Batch executors self-delegatecall per item so
one failure doesn't kill the batch. Every flow syncs the market first and screens all parties
against the blacklist. The entry point holds the LP roles and `SYNC_ROLE`; it never talks to the
accountant directly — all accounting goes through the kernel.

### 5.8 Factory, templates, gatekeeper (`src/factory/`)

- **Factory**: `executeMarketDeployment(template, params)` is **permissionless**
  (`PUBLIC_ROLE`) — safe because protocol policy (fees, venue config, implementation set) lives
  on the admin-registered template, the deployer funds the genesis seed, and all addresses are
  namespaced by deployer. Only admin-enabled templates run; one active template per deployment
  (transient slot, no reentrancy); a valid result must include kernel + all three tranches, which
  are then registered `tranche → kernel`.
- **Template** (`RoycoDayBalancerV3MarketDeploymentTemplate`): one market recipe. Pins the five
  beacons, venue factories, blacklist, protocol fee config, and pool policy at construction
  (its CREATE2 salt hashes the full construction params — changing policy is a deliberate
  template redeploy). Deploys, in order: ST proxy → Gyro pool + BPT oracle → JT proxy → LPT
  proxy → accountant proxy → kernel proxy (address predicted first, asserted equal), then
  cross-validates the entire wiring (`MarketDeploymentValidationLogic.validateDeployment` — a
  mis-wired market fails loud), applies role bindings, registers periphery configs, and seeds
  the pool (genesis liquidity with `DEAD_SHARES = 1e12` burned to `0xdEaD` as permanent virtual
  depth). A collateral seed leg is only allowed when `minCoverage == 0` (the seed is the first
  deposit against an empty junior).
- **Gatekeeper**: the only holder of the manager's `ADMIN_ROLE`; configures each fresh target
  exactly once; refuses `PUBLIC_ROLE`/`ADMIN_ROLE` bindings and the core contracts as targets.
- **Parameter validation is mirrored**: `MarketDeploymentValidationLogic` pre-checks the same
  bounds `RoycoDayAccountant.initialize` enforces, so a bad config fails before any contract
  exists.

### 5.9 Blacklist (`src/auth/RoycoBlacklist.sol`, `BlacklistLogic`)

Chain singleton: local mapping ∪ Chainalysis sanctions list (optional) ∪ a virtual
`_isExogenouslyBlacklisted` hook for bespoke issuer integrations. `address(0)` is never
blacklisted. A **null blacklist pointer on the kernel disables screening entirely** (per-market
choice). Enforcement points: the kernel share-movement hook (every mint/burn/transfer), every
kernel deposit/redemption flow, and five entry-point sites (request/execute/cancel/claims).

### 5.10 Cache (`src/libraries/Cache.sol`)

Generic keyed **transient-storage** (EIP-1153) cache. One slot per `CacheKey` offset from an
ERC-7201 base; bit 255 is a set-marker so a cached zero is distinguishable from unset (values
must be < 2^255). Keys: `COLLATERAL_ASSET_PRICE`, `ST_SHARE_PRICE`, `LPT_ASSET_PRICE` (written
only by multi-asset *previews* at their venue frame mark), `IN_MULTI_ASSET_FLOW`,
`PENDING_LIQUIDITY_VIOLATION`. These implement the "one price per operation" frame and the
composite-flow deferred liquidity enforcement.

### 5.11 Dispatch (`src/libraries/logic/DispatchLogic.sol`)

The execute-vs-simulate transport: `EXECUTE` settles; `SIMULATE` runs the same code and unwinds
every mutation by reverting with `SIMULATION_RESULT(result)`; the caller decodes the payload
byte-for-byte identically in both modes. A simulation that *returns* is an error
(`SIMULATION_CANNOT_MUTATE_STATE`); any other revert bubbles verbatim. `_tryExecute` is the
best-effort variant (reinvestment attempts, YDM-swap syncs, probes).

---

## 6. End-to-end flows

### 6.1 The universal operation frame

Every state-mutating tranche operation runs inside the kernel as:

```
withPriceCache:            poke collateral oracle (circuit breaker) → cache price
1. PRE-OP SYNC:            accountant.preOpSyncTrancheAccounting(C_fresh)
                           → kernel mints fee + premium shares per returned state
                           → accountant.commitLiquidityProviderTrancheRawNAV(P_fresh)
2. GATES:                  FIXED_TERM blocks (ST/JT ops, LPT redemptions); blacklist screens
3. OPERATION:              price at the frame's cached rates; mutate ledgers; mint/burn shares
4. POST-OP SYNC:           accountant.postOpSyncTrancheAccounting(op, C_post, P_post, bonus)
                           → kernel enforces coverage (ST_DEPOSIT, JT_REDEMPTION ≤ 100%),
                             the JT-deposit liquidation gate, and liquidity
                             (ST_DEPOSIT, LPT_REDEMPTION ≤ 100%, deferred inside
                             multi-asset flows to the final settled leg)
5. REMIT:                  transfer claims to receiver (CEI)
tail:                      withLiquidityPremiumReinvestment deploys the idle premium pile
exit:                      price caches cleared
```

Previews run the identical path under `SIMULATE` and unwind at step 5.

### 6.2 In-kind deposit (any tranche)

Tranche pulls assets to the kernel → dispatch → screen → pre-op sync → (PERPETUAL required for
ST/JT) → value assets at the frame price → credit ledger → mint shares at
`value · (supply+1)/(claims.nav+1)` floor (must be non-zero) → post-op sync (`*_DEPOSIT` shape:
collateral delta only for ST/JT, venue delta only for LPT) → gates.

### 6.3 In-kind redemption (any tranche)

Screen caller/owner/receiver → pre-op sync → PERPETUAL required → scale the tranche's
`AssetClaims` by `shares/totalShares` (virtual-share basis) → **ST only**: apply the
self-liquidation bonus if `U_cov ≥ Θ` (bonus = min(configured %, coverage-utilization-neutral
max `redeemNAV · J / S`, J) — the neutrality cap prevents bank-run dynamics where one exit
consumes the remaining LPs' coverage) → debit ledgers → burn → post-op sync (bonus moves `J → 
redemption`, conservation holds) → remit.

### 6.4 LPT multi-asset flows

- **Deposit**: enter flow marker → ST leg (`inkindDeposit` of the collateral, shares minted to
  the kernel; liquidity violation recorded, not enforced) → venue add of [ST shares, quote] →
  LPT leg (`inkindDeposit` of the BPT out) → exit marker enforces any unhealed violation. In
  FIXED_TERM only the quote-only variant passes (minting the ST leg would be a senior deposit).
- **Redemption**: LPT leg (in-kind, claims = BPT + pro-rata idle premium shares, violation
  deferred) → venue proportional remove (quote straight to receiver, ST shares to kernel) → ST
  leg (`inkindRedeem` of all recovered ST shares to receiver) → exit marker. Because the ST leg
  shrinks `S` (and thus the liquidity requirement) in-flow, this admits exits the in-kind gate
  alone could not.

### 6.5 Async entry-point flow

Request (escrow + snapshot share/value reference + sync + screen) → wait (per-tranche delay ∧
oracle-update gate) → execute (re-sync, partial-fill rescale, forfeiture skim, optional keeper
bonus) or cancel (full escrow back).

### 6.6 Accountant parameter change

`restricted` setter → kernel-callback sync at old params → field write → kernel-callback sync at
new params → guard: coverage/liquidity not worsened past 100%, liquidation not triggered by
config. YDM swaps instead use a best-effort sync (the setter is the recovery path from a
sync-bricking YDM) and re-initialize the incoming YDM instance.

---

## 7. Market states and lifecycle

Two states, tracked by the accountant, enforced by the kernel:

- **PERPETUAL** — normal operation (and the permanent state when `fixedTermDuration == 0`). All
  tranches liquid subject to the coverage/liquidity gates; premiums and fees accrue; adaptive
  YDMs adapt. A perpetual market **never carries a JT impermanent loss** (any commit into
  PERPETUAL erases it).
- **FIXED_TERM** — temporary recovery window entered when a collateral drawdown first opens a
  non-dust JT impermanent loss while coverage stays within the liquidation threshold. ST/JT
  deposits and redemptions blocked (seniors can't pull coverage; new juniors can't dilute
  incumbents on transient volatility); LPT redemptions blocked (market-making is most valuable
  now) but LPT deposits stay open (quote-only). No liquidity premium, no protocol fees, no YDM
  adaptation.

Transitions (evaluated at every pre-op sync; the seven forcing conditions are enumerated in
`AUTOPROVER.md` §4.5): recovery (IL ≤ dust) or term expiry returns to PERPETUAL; a liquidation
breach (`U_cov ≥ Θ`) or an uncollateralized market (`J == 0` with `S > 0`) *forces* PERPETUAL —
in the forced/expired cases JT forfeits its recovery claim (IL erased as realized loss). A
post-deployment **grace period** prevents a young market from ever entering FIXED_TERM.

While `U_cov ≥ Θ` (necessarily PERPETUAL): ST redeemers earn the self-liquidation bonus from JT
NAV, and a JT deposit must settle below Θ in one shot.

---

## 8. Roles, governance, and trust model

All permissions live on the shared `RoycoAccessManager`. Role ids are keccak-derived
(`src/factory/Roles.sol`). The bindings that matter most for verification:

| Surface | Gate |
|---|---|
| Accountant `preOp`/`postOp`/`commitLPT` | `msg.sender == kernel` (code check, not a role) |
| Accountant YDM/coverage/liquidity/max-yield/fixed-term setters | `ADMIN_ACCOUNTANT_ROLE` (72h delay) |
| Accountant fee setters | `ADMIN_PROTOCOL_FEE_SETTER_ROLE` (72h) |
| Accountant `setDustTolerance` | `ADMIN_MARKET_OPS_ROLE` (deliberately separate) |
| Tranche `deposit`/`redeem` | `{ST,JT,LPT}_LP_ROLE` (immediate; held by the entry point; admin-grantable per market) |
| Tranche `kernelMint`/`kernelBurn`/premium mint | `onlyKernel` code check |
| Kernel oracle/venue-pricing setters | `ADMIN_ORACLE_ROLE` (72h) |
| Kernel sync entrypoints | `SYNC_ROLE` (immediate; keepers + entry point + syncer) |
| Pause / unpause | `ADMIN_PAUSER_ROLE` (immediate) / `ADMIN_UNPAUSER_ROLE` |
| Beacon & UUPS upgrades | `ADMIN_UPGRADER_ROLE` (72h) |
| Factory `executeMarketDeployment` | `PUBLIC_ROLE` — permissionless by design |

Governance separation (deploy-script role graph): the parameter multisig proposes (72h/24h
delays), a veto multisig (guardian) cancels, a dedicated pauser pauses, only the foundation
unpauses and holds root admin (72h, non-cancellable lockdown). **No party can both schedule and
cancel.**

Trust assumptions relevant to verification:
- The kernel is trusted by the accountant (sole mutator, supplies honest NAVs from oracle
  reads).
- YDM outputs are **untrusted** by the accountant (clamped; a bricking YDM is recoverable via
  the swap setter's best-effort sync).
- Oracles are trusted for price but designed to fail shut; the venue pool is untrusted
  (oracle-marked, slippage-floored).
- Governance is delay-gated and cannot, via the `withSyncedAccounting` guard, push a healthy
  market into violation or liquidation by parameter change.

---

## 9. System-wide invariant catalog

Numbered `GI-*` (global invariant). For accountant-local formal statements see `AUTOPROVER.md`
§6 (referenced as `A-*`, `B-*`, etc.). "Enforced" = a `require`; "maintained" = by construction.

| ID | Invariant | Where |
|---|---|---|
| GI-1 | `collateralNAV == stEffectiveNAV + jtEffectiveNAV` (wei-exact) | Enforced in accountant pre-op & post-op sync (= `A-1`); asserted by the invariant suite `invariant_collateralNAVEqualsStEffPlusJtEff` |
| GI-2 | `marketState == PERPETUAL ⇔ jtImpermanentLoss == 0` (dust-erased) | Maintained by the state machine (= `A-2`); suite `invariant_perpetualIffZeroImpermanentLoss` |
| GI-3 | The liquidity premium adds no senior exposure (coverage-neutral): premium mints move value claims, never assets, and `C` is untouched | Maintained: premium booked inside `S`, minted as ST shares to the kernel |
| GI-4 | JT impermanent-loss repayment precedes any distribution and is never fee'd | Maintained by waterfall ordering (= `D-3`) |
| GI-5 | `jtRiskPremium + lptLiquidityPremium ≤ stGain` | Enforced (accountant) and provably unreachable given the accrual-window lemma (= `I-2`) |
| GI-6 | Coverage gate: ST deposits and JT redemptions settle with `U_cov ≤ 100%` | Enforced kernel-side at post-op |
| GI-7 | Liquidity gate: ST deposits and LPT redemptions settle with `U_liq ≤ 100%`; inside a multi-asset flow, deferred to the final settled leg but always enforced at flow exit | Enforced kernel-side (`AccountingSyncLogic`) |
| GI-8 | JT deposits during liquidation must settle below Θ (no partial recapitalization subsidizing bonus exits) | Enforced kernel-side at post-op |
| GI-9 | Self-liquidation bonus ≤ min(configured %, coverage-utilization-neutral max, `J`) and is sourced from `J` | Maintained (`SelfLiquidationLogic`) + accountant post-op reverts on excess (= `C-5`) |
| GI-10 | One collateral price and one ST share rate per operation frame | Maintained (`withPriceCache` + Cache) |
| GI-11 | Preview ≡ execution: every preview runs the real path and unwinds via `SIMULATION_RESULT` | Maintained (DispatchLogic; = `D-11` for the accountant) |
| GI-12 | The LPT raw NAV is committed only after the sync's share mints (venue mark prices the post-mint senior rate); it never enters the PnL waterfall | Maintained (call ordering; = `F-1`/`F-2`) |
| GI-13 | Entry-point yield neutrality: a request is never worth more at execution than at request time | Maintained (share-pinned deposits, value-pinned redemptions, forfeiture skims) |
| GI-14 | Execution gate honesty: a queued request executes only after a delay and (if gated) an oracle update observed strictly after request time; unobservable updates keep the gate shut | Maintained (oracle clock honesty + entry point checks) |
| GI-15 | Every tranche share mint/burn/transfer is blacklist-screened and pause-gated | Maintained (`_update` → kernel hook) |
| GI-16 | Share pricing is inflation-resistant: virtual shares/value + genesis dead shares + mint-dilution clamp arming only in the collapsed-price regime | Maintained (ValuationLogic, template seeding) |
| GI-17 | Tranche capacity functions round in favor of senior protection and never admit an operation that would revert on dust | Maintained (accountant capacity math, = `G-*`) |
| GI-18 | Parameter changes cannot worsen coverage/liquidity past 100% nor trigger liquidation | Enforced (`withSyncedAccounting`) |
| GI-19 | Pool token order: ST is token0, quote is token1 | Enforced at venue init; guaranteed by market-id mining |
| GI-20 | Role bindings for a market are written exactly once, never `PUBLIC_ROLE`/`ADMIN_ROLE`, never on the core contracts | Enforced (gatekeeper) |
| GI-21 | A zero-min-liquidity market reduces exactly to a plain senior/junior market (liquidity machinery silent) | Maintained; suite `invariant_liquidityPremiumMachineryStaysSilent` |
| GI-22 | Kernel custody: assets move tranche→kernel before pricing, and kernel→receiver only after ledgers debit, shares burn, and post-op commits (CEI) | Maintained (flow ordering) |

---

## 10. Assume/guarantee contracts between components

These are the interface obligations each component relies on. When verifying one component,
assume its counterparties' guarantees; flag any proof that depends on them.

**Kernel → Accountant (the accountant may assume):**
- Only the kernel calls the three mutating functions, in the order: `preOp` → (fee/premium share
  mints, which never touch accountant storage) → `commitLPT` → operation → `postOp`.
- `_collateralNAV` arguments are honest oracle-marked values of the actual collateral ledger;
  `_lptRawNAV` is the venue-oracle mark; deltas passed to `postOp` reflect only the operation's
  own flows (the pre-op sync just zeroed the PnL delta within the same frame).
- The kernel enforces the coverage/liquidity/fixed-term gates on the returned states; the
  accountant's capacity functions are advisory to the kernel's gate math.

**Accountant → Kernel (the kernel may assume):**
- Conservation holds at every commit; returned premium/fee figures are sized so the kernel-side
  share-mint subtractions never underflow (`lptProtocolFee ≤ lptLiquidityPremium`;
  `stProtocolFee + lptLiquidityPremium ≤ stEffectiveNAV`).
- `preOp` never moves `lastLPTRawNAV`; `postOp` never changes market state or IL.
- Market-state transitions and IL erasure follow the documented seven-condition machine.

**Accountant → YDM:** outputs are clamped; a revert in `yieldShare` bricks syncs but the YDM
swap setter recovers (best-effort sync). **YDM → Accountant:** `previewYieldShare` equals what
`yieldShare` returns at the same instant (preview purity); per-market state is keyed by
accountant address.

**Kernel → Oracle:** `getPrice()` reverts on staleness (per hop) and non-positive prices;
`poke()` may revert as a circuit breaker; `updatedAt` is honest (oldest hop, never future/
manufactured, zero when unobserved). **Entry point → Oracle:** same honesty for the gate.

**Venue → Kernel:** `getRate()` is the senior-leg rate; the pool holds [ST, quote] in that
order; the LP oracle marks TVL manipulation-resistantly. **Kernel → Venue:** operations open the
outermost vault session; reinvestment floors are set against the oracle, not spot.

**Tranche → Kernel:** all value movement is dispatched to the kernel; mints/burns only via
`onlyKernel`. **Kernel → Tranche:** fair pricing of every mint/burn; the balance-update hook is
called on every `_update`.

**Template/Factory → everything:** a market's components are wired exactly as validated by
`MarketDeploymentValidationLogic.validateDeployment` (authorities, assets, tranche types, pool
tokens, accountant↔kernel↔YDM pointers all cross-checked at deployment).

---

## 11. Verification scoping guidance

- **Primary target: `RoycoDayAccountant`** — self-contained, arithmetic-heavy, carries the
  protocol's crown-jewel invariants. `AUTOPROVER.md` is the complete brief: verification closure
  file list (§1), environment model (§5), the expected-property catalog (§6 — a floor to build
  on, not a ceiling), pitfalls (§7). Do not link the real kernel or venue; model them per the
  brief.
- **Worthwhile secondary targets** (same modeling philosophy — small, mostly-pure units):
  - `UtilizationLogic` (pure; lemmas `H-*` in AUTOPROVER.md).
  - `ValuationLogic._convertToShares/_convertToValue` (virtual-share round-trip bounds; clamp
    arming condition; `shares→value→shares ≤ original`).
  - `FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint` (no-underflow
    given the accountant's guarantees; joint-pricing non-dilution).
  - `OracleClockBase` (poke/previewPoke agreement; monotone `_lastUpdatedAt`; deviation
    threshold semantics).
  - `Cache` (set-marker round trip; domain bound).
  - YDM curve math (output ≤ WAD; anchor-point equalities; V2 clamp bounds; adaptive `Y_T`
    within `[min, max]`; no adaptation in FIXED_TERM).
- **Poor formal targets** (integration-heavy; covered by the fuzz/invariant/fork suites):
  the Balancer venue drivers (vault graph), the entry point's full lifecycle (multi-block,
  multi-actor), factory deployment choreography.
- The repo's own test suite is a property gold mine: `test/invariant/` asserts GI-1/GI-2/GI-21
  live under a handler with independent mirrors; `test/fuzz/Accountant/` encodes the
  attribution, accrual-window, and dip-recover properties that AUTOPROVER.md formalizes.
  Cross-reference before inventing new properties.

---

## 12. Known caveats

- **Timestamps are uint32** in accountant storage (and uint32 casts on transition stamps).
  Verification must constrain `block.timestamp < 2^31` (see AUTOPROVER.md ASM-1); the repo
  knowingly tests wrap behavior (`Test_Uint32ClockWrap`).
- **`docs/testing/` is empty**; the prose documentation is `README.md` plus the script READMEs.
- **`script/upgrade/README.md` and `script/update/README.md` are stale** relative to `src/`
  (they reference removed accountant setters, UUPS tranches, and old delay values). The deploy
  README matches the code. Trust the source over those two READMEs.
- **Dust tolerance** (`dustTolerance`, NAV units) appears in three roles: premium/fee gating
  (`stGain > D`, `jtGain > D`), fixed-term entry/exit (`IL ≤ D` forces PERPETUAL, erasing dust
  remainders), and capacity padding. It is admin-settable (including to 0) at any time.
- A **null blacklist** on a kernel disables screening for that market by design.
- **The accountant is not pause-gated** (verified): it inherits `pause()`/`unpause()` from
  `RoycoAuth`, but none of its functions check the paused flag — pausing the accountant is inert
  for its own behavior. Operational pause lives on the kernel (`whenNotPaused` on every
  operation, sync, and the share-movement hook) and on the tranches/entry point.
- The accountant's `getState()` returns the full ERC-7201 struct — use it as the canonical
  state accessor in specs.
- Audits on file: `audit/Hexens-Royco-Day.pdf`, `audit/Olympix-Royco-Day.pdf`. Named regression
  tests exist for past findings (e.g.
  `Test_SeniorLeverageViaImpermanentLossRecovery_PoC`,
  `Test_CoverageCrossClaimFindings_Accountant`) — useful seeds for adversarial properties.

## 13. Glossary

| Term | Meaning |
|---|---|
| **Market** | One deployed tranche set (ST/JT/LPT + kernel + accountant + venue) over one collateral asset |
| **Collateral NAV (`C`)** | Oracle value of the co-invested ST+JT collateral |
| **Effective NAV (`S`, `J`)** | ST/JT claims on `C` after waterfall; `C = S + J` |
| **LPT raw NAV (`P`)** | Venue-oracle mark of the LPT's market-making position |
| **JT impermanent loss (`IL`)** | JT's recoverable drawdown; first claim on future gains; exists only in FIXED_TERM |
| **Coverage utilization (`U_cov`)** | `C·minCoverage / J`, ceil; > 100% ⇔ coverage violated |
| **Liquidity utilization (`U_liq`)** | `S·minLiquidity / P`, ceil |
| **Θ (liquidation coverage utilization)** | > 100% threshold arming the self-liquidation bonus |
| **YDM** | Yield Distribution Model: `(state, utilization) → share of senior yield` |
| **Risk premium** | Senior yield reallocated to JT effective NAV (YDM-sized) |
| **Liquidity premium** | Senior yield minted as ST shares to the LPT (coverage-neutral) |
| **Waterfall** | The pre-op PnL settlement: junior-first losses, IL repayment, pro-rata split, premiums, fees |
| **Fixed term** | Recovery window after a JT drawdown; primary flows frozen |
| **Self-liquidation bonus** | JT-funded bonus to ST redeemers while `U_cov ≥ Θ` |
| **Dust tolerance (`D`)** | NAV-unit tolerance for underlying rounding noise |
| **Kernel** | Per-market operational core and sole asset custodian |
| **Venue** | The kernel's market-making extension (Balancer V3 Gyro E-CLP currently) |
| **Frame / price cache** | One operation's transient pricing context (one collateral price, one ST rate) |
| **Simulation / SIMULATE** | Execute-and-unwind preview via `SIMULATION_RESULT` revert |
| **WAD** | `1e18` fixed-point unit |
