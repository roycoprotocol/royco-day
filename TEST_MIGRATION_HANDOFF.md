# Test-Suite Migration Handoff — Coinvestment Collapse

Self-contained context for a Fable 5 agent taking over the test-suite migration of
`/Users/shivkapoor/royco-structured-products/royco-day`. Read this whole file first.

---

## 0. What happened to `src/` (already DONE, do not touch)

`src/` and `script/` were refactored to make the **coinvestment invariant structural**: the senior
tranche (ST) and junior tranche (JT) always hold the **identical collateral asset at one rate**, so the
old two-legged "ST asset + JT asset" model collapsed into a single collateral asset. `src/` + `script/`
compile clean (`~/.foundry/versions/v1.7.1/forge build src/ script/` → 0 errors) and are **canonical and
read-only**. Never edit `src/` or `script/` to make a test pass — if a test disagrees with `src`, the
test's expectation is what changes (derived from the semantics below), not `src`.

## 1. The rigor mandate (non-negotiable)

- Migrate to test **EXPECTED behavior, not implemented behavior**. Derive every expected value from the
  documented semantics in §3, by hand (leave the derivation in a comment where non-trivial). NEVER capture
  what the implementation returns and paste it as the expectation.
- The migrated suite must have the **SAME OR HIGHER rigor**. Every assertion that existed must survive in
  migrated form or be replaced by a strictly stronger one. Never loosen a wei-exact `assertEq` to an
  approximate/tolerance check. Never widen a tolerance. Never delete a test because porting it is
  inconvenient — if a test covered a state that is now unreachable (see §3.3), replace it with an
  equal-or-stronger assertion in the reachable domain, or convert it into a test that the invariant holds.
- `test/utils/RoycoTestMath.sol` is the **independent expected-value mirror**. It must be an independent
  re-derivation of the semantics, NOT a call into / line-by-line port of `src` logic. It has already been
  migrated (see §4) — keep it independent.
- Follow existing conventions exactly: comment style has **no em-dashes and no semicolons in comments**,
  terse user voice, mechanism + why only. Match each file's surrounding style, naming, and natspec.
- Rename tests whose names describe the two-legged model (e.g. anything asserting on separate st/jt raw
  NAVs) to describe what they now assert.

## 2. API changes (compile-breaking) — the mechanical rename table

**Accountant (`IRoycoDayAccountant`)**
- `preOpSyncTrancheAccounting(NAV_UNIT _collateralNAV)` — single arg (was `stRawNAV, jtRawNAV`)
- `previewSyncTrancheAccounting(NAV_UNIT _collateralNAV)` — single arg
- `postOpSyncTrancheAccounting(Operation _op, NAV_UNIT _collateralNAV, NAV_UNIT _ltRawNAV, NAV_UNIT _stSelfLiquidationBonusNAV, bool _enforce)` — 5 args (was 6, dropped the second raw NAV)
- Single `dustTolerance` (NAV_UNIT) replaces `stNAVDustTolerance` / `jtNAVDustTolerance` / `effectiveNAVDustTolerance`. Init-params field `dustTolerance`. Setter `setDustTolerance(NAV_UNIT)`. Event `DustToleranceUpdated(NAV_UNIT)`. `setSeniorTrancheDustTolerance` / `setJuniorTrancheDustTolerance` DELETED.
- State fields: `lastCollateralNAV` (was `lastSTRawNAV`/`lastJTRawNAV`), `dustTolerance`.

**Types.sol**
- `SyncedAccountingState`: `collateralNAV` replaces `stRawNAV` + `jtRawNAV`. Field order:
  `marketState, collateralNAV, ltRawNAV, stEffectiveNAV, jtEffectiveNAV, jtImpermanentLoss, ltLiquidityPremium, stProtocolFee, jtProtocolFee, ltProtocolFee, coverageUtilizationWAD, liquidityUtilizationWAD, fixedTermEndTimestamp, minCoverageWAD, coverageLiquidationUtilizationWAD, minLiquidityWAD`.
- `AssetClaims` is now **4 fields**: `{ TRANCHE_UNIT collateralAssets; TRANCHE_UNIT ltAssets; uint256 stShares; NAV_UNIT nav }` (was `stAssets + jtAssets + ltAssets + stShares + nav`). The single `collateralAssets` leg replaces both `stAssets` and `jtAssets`.

**Kernel (`IRoycoDayKernel`, `RoycoDayKernel`)**
- Construction params struct order: `seniorTranche, juniorTranche, collateralAsset, accountant, liquidityTranche, ltAsset, enforceVaultSharesTransferWhitelist` (single `collateralAsset`, was `stAsset` + `jtAsset`).
- Immutable/getter `COLLATERAL_ASSET()` (`ST_ASSET()` / `JT_ASSET()` DELETED).
- Ledger state: `totalCollateralAssets` (was `stOwned`+`jtOwnedYieldBearingAssets`), `totalLTAssets` (was `ltOwnedYieldBearingAssets`).
- Converters: `convertCollateralAssetsToValue(TRANCHE_UNIT)`, `convertValueToCollateralAssets(NAV_UNIT)`, `convertLTAssetsToValue(TRANCHE_UNIT)`, `convertValueToLTAssets(NAV_UNIT)`. (`stConvert*`/`jtConvert*`/`ltConvert*` DELETED.)
- Error `TRANCHE_ASSETS_MUST_BE_IDENTICAL` DELETED. `initialize` checks both tranches' `asset() == COLLATERAL_ASSET` via `TRANCHE_AND_KERNEL_ASSETS_MISMATCH`.
- ImmutableState carrier: 6 addresses incl. `collateralAsset` (no `stAsset`/`jtAsset`).
- `ltDepositMultiAsset(bool _isPreview, TRANCHE_UNIT _collateralAssets, uint256 _quoteAssets, TRANCHE_UNIT _minLTAssetsOut)` — param renamed from `_stAssets`.

**Liquidity tranche (`IRoycoLiquidityTranche`, `RoycoLiquidityTranche`)**
- `depositMultiAsset(uint256 _collateralAssets, ...)`, `previewDepositMultiAsset(uint256 _collateralAssets, ...)` — renamed from `_stAssets`.
- Event `MultiAssetDeposit(caller, receiver, collateralAssets, quoteAssets, ltAssetsMinted, shares)` — field renamed.

**Tranche (`IRoycoVaultTranche`, `RoycoVaultTranche`)**
- `getRawNAV()` is **DELETED entirely** (interface + implementation). Read the live marks off the kernel:
  collateral = `kernel.convertCollateralAssetsToValue(kernel.getState().totalCollateralAssets)`, LT =
  `kernel.convertLTAssetsToValue(kernel.getState().totalLTAssets)`. Test fixtures expose these as
  `_liveCollateralNAV()` / `_liveLTRawNAV()` (DayMarketTestBase for mock-market tests, Test_KernelSuiteBase
  for fork tests). Old per-tranche-surface parity asserts are vacuous and were removed.

**Cache**: key is `CacheKey.COLLATERAL_ASSET_RATE` (was `IDENTICAL_ST_JT_TRANCHE_TO_NAV_UNIT_RATE`).

**Deploy/config (`script/`)**: `MarketConfig` has `collateralAsset` + `dustTolerance` (was `seniorAsset`/`juniorAsset` + `stDustTolerance`/`jtDustTolerance`). Deployment template `DayParams` has `collateralAsset`.

**Deleted logic — do NOT recreate mirrors of these**
- `TrancheClaimsLogic._computeSTandJTClaimsOnRawNAVs` (both overloads). A tranche's claim IS its effective
  NAV converted once: `claims.nav = st/jtEffectiveNAV; claims.collateralAssets = convertValueToCollateralAssets(claims.nav)`.
- The accountant's zero-lastRaw special cases and the coverage-branch `jtFee` recompute.

## 3. Semantic decisions — the EXPECTED behavior (test THESE)

### 3.1 Single-NAV attribution
Each sync computes `deltaCollateralNAV = collateralNAV − lastCollateralNAV`, then
`deltaSTEffectiveNAV = floor(|deltaCollateralNAV| · stEffectiveNAV / lastCollateralNAV)` with the sign of
the delta re-applied (Floor on the magnitude → favors seniors on losses, juniors on gains), and
`deltaJTEffectiveNAV = deltaCollateralNAV − deltaSTEffectiveNAV` (**JT is the residual; all rounding drift
lands on JT**). The attribution helper returns 0 if `delta == 0` OR `claim == 0` OR `lastCollateralNAV == 0`.
**Conservation `collateralNAV == stEffectiveNAV + jtEffectiveNAV` holds EXACTLY after every sync** — this
is a wei-exact invariant to assert directly.

### 3.2 PnL waterfall (per attributed delta)
- **JT loss** adds to `jtImpermanentLoss` (JT's drawdown from high-water).
- **JT gain** FIRST recovers `jtImpermanentLoss` (restoration, never fee'd), THEN only the residual gain
  **above `dustTolerance`** accrues `jtProtocolFee`.
- **ST loss** consumes JT coverage first (adds to `jtImpermanentLoss`), residual hits `stEffectiveNAV`.
- **ST gain** first recovers JT IL (repayment, exact, never fee'd), then the premium block (JT risk
  premium + LT liquidity premium out of the senior gain; instantaneous branch when
  `elapsedSincePremiumPayment == 0`), then the residual ST gain accrues `stProtocolFee` if `premiumsPaid`.
- **NO coverage-branch fee recompute**: a `jtProtocolFee` computed on a JT gain **survives** even if a
  later coverage application in the same sync consumes JT NAV, including liquidation-forced PERPETUAL
  transitions (**fee survives forced-PERPETUAL** — pinned behavior).

### 3.3 Mixed-sign ST/JT deltas are UNREACHABLE
One collateral asset at one rate ⇒ the attributed ST and JT deltas always share the sign of
`deltaCollateralNAV`. Any old test that set divergent st/jt quoter rates, or fed mixed-sign raw deltas,
tests an unrepresentable state. Port it to the reachable domain (same-sign attribution) or convert it into
an invariant-holds test. Do not silently drop the coverage it provided.

### 3.4 Single `dustTolerance` gates
The JT fee dust gate (residual JT gain must exceed `dustTolerance`), the premium/`premiumsPaid` gate, the
conservation checks, and the state-machine dust-IL stickiness all use the one `dustTolerance`.

### 3.5 ≤1-wei tightenings from merged conversions
Three spots now do ONE conversion where the old code summed two: (a) the collateral mark = one conversion
of `totalCollateralAssets`; (b) claims granting converts `effectiveNAV` once per tranche; (c) the
self-liquidation bonus converts once (value→assets→value round trip). **Wei-exact pins may legitimately
shift by ≤1 wei** vs the old two-conversion pipeline. When re-pinning, derive the new value by hand from
the single-conversion arithmetic (comment the derivation; do not reference the old value). **A pin shift
> 1 wei is a red flag — STOP and report it, do not just re-pin.**

### 3.5b Terminology: "covered exposure" is gone
The concept formerly written "covered exposure" / `COVERED_EXPOSURE` (the st+jt raw sum coverage is computed
against) IS the collateral NAV — src comments now say `COLLATERAL_NAV` directly (see SelfLiquidationLogic's
derivation). Never write "covered exposure" or `coveredExposure` in migrated comments, natspec, or assert
labels; say collateral NAV.

### 3.6 Coinvestment surfaces in fixtures
Anywhere a fixture/base set **different ST and JT quoter rates** is now invalid — there is one rate for the
one collateral asset. Collapse to a single collateral rate helper.

### 3.7 max deposit / withdrawal (single collateral NAV + single dust)
- `maxSTDeposit`: coverage leg `floor(jtEffNAV·WAD/minCov) − (collateralNAV + dustTolerance)`, liquidity leg
  `floor(ltRawNAV·WAD/minLiq) − (stEffNAV + dustTolerance)`, saturating, `min` of the two; a zero
  requirement disables its leg.
- `maxJTWithdrawal`: `required = ceil((collateralNAV + dustTolerance)·minCov/WAD)`,
  `surplus = sat(jtEffNAV − required)`, result `floor(surplus·WAD/(WAD − minCov))`.
- `maxLTWithdrawal`: `minLiq == 0 → ltRawNAV`; else `sat(ltRawNAV − ceil((stEffNAV + dustTolerance)·minLiq/WAD))`.

### 3.8 self-liquidation bonus (single collateral leg)
`desiredBonus = floor(userClaimNAV·bonusWAD/WAD)`;
`maxNeutral = floor(userClaimNAV·jtEffNAV/stEffNAV)` (under conservation `exposure − jtEffNAV == stEffNAV`);
`bonusNAV = min(desired, jtEffNAV, maxNeutral)`, active only when `coverageUtil ≥ liquidationThreshold`.
Reported bonus = single collateral round-trip `floor(floor(bonusNAV·WAD/rate)·rate/WAD)`.

### 3.8b Attribution inline + seniority tie-break (adopted mid-migration)
The accountant's `_attributeDeltaToClaimOnCollateralNAV` helper is INLINED into STEP_APPLY_PNL_ATTRIBUTION
(the function no longer exists; `AttributionExposer` is deleted and helper-level production fuzz converted to
mirror-primitive properties, with production parity held at sync level). NEW SEMANTICS at the call site: a
delta marked from a **zero `lastCollateralNAV` checkpoint routes wholly to ST** (seniority tie-break), not to
the JT residual. Coherently, the wipeout disjunct in the state machine is now just `jtEffectiveNAV == 0`
(covers partial AND total wipes, erasing JT's dead restoration claim so a zero-mark recovery is a clean senior
gain). The mirror implements the tie-break at its sync call site; its standalone `attributeDeltaToClaimOnCollateralNAV`
primitive keeps the guard-to-zero behavior.

### 3.9 State-machine consolidation (adopted mid-migration — supersedes any older description)
The sync state machine was simplified to two branches with uniform consequences, and the JT_REDEEM postOp
IL-scaling was deleted. The semantics now are:

- **Resolution predicate** (PERPETUAL iff any): `il == 0`; permanently-perpetual config (`fixedTermDurationSeconds == 0`);
  term elapsed (`initial == FIXED_TERM && end <= now`); liquidation (`coverageUtil >= liquidationThreshold`);
  JT wipeout (`jtEff == 0 && stEff > 0`); dust drawdown from perpetual (`il <= dustTolerance && initial == PERPETUAL`).
- **PERPETUAL commit consequences (uniform)**: `ilErased = il; il = 0; end = 0`. EVERY perpetual commit clears
  the IL ledger — dust drawdowns from PERPETUAL are erased at commit (reset event fires with the ≤dust value),
  not retained-recoverable.
- **FIXED_TERM commit consequences**: keep IL; stamp `end = now + duration` only on the PERPETUAL→FIXED_TERM
  edge (stickiness keeps the original end). **NO fee zeroing** — it was deleted as dead code: under same-sign
  attribution any nonzero fee/premium requires a gain residual that fully recovered the IL, which resolves
  PERPETUAL instead. The mirror CHECKS this theorem (`FIXED_TERM_FEES_NONZERO` require) instead of zeroing.
- **New standing invariants (assert these globally, a strict rigor add)**:
  `lastMarketState == PERPETUAL ⟺ lastJTImpermanentLoss == 0` (biconditional: FIXED_TERM always carries il > 0,
  since the postOp scaling that could zero IL inside FIXED_TERM is gone and every PERPETUAL commit erases).
- **Unrepresentable states (tests of them must convert per §1/§3.3)**: PERPETUAL with il > 0 (any amount);
  FIXED_TERM with il == 0. The base's `_seedDustIL`, `_seedShrunkDustIL`, and `_seedNoILFixedTerm` regime seeds
  are DELETED accordingly. `_seedDustILFixedTerm` (sticky dust, il 5 ≤ dust 7, FIXED_TERM) survives unchanged.
  `_seedState` now supports il == 0 (PERPETUAL) or il > dust (FIXED_TERM) targets only.
- Old "dust IL persists recoverable through PERPETUAL" vectors become tests of the new erasure behavior:
  a ≤dust loss from PERPETUAL resolves PERPETUAL with il erased and the reset event emitted, and the next
  gain is a plain gain (fee-gated on > dust as always), not a recovery.

## 4. Progress so far

### DONE and verified
- `test/mocks/MockAccountantKernel.sol` — passthroughs collapsed to single `_collateralNAV`; the sync
  driver's `syncStRawNAV`/`syncJTRawNAV` merged into `syncCollateralNAV`; `setSyncNAVs(st, jt)` →
  `setSyncNAV(collateralNAV)`; `doPreOp`/`doPostOp` single-collateral-arg signatures.
- `test/utils/RoycoTestMath.sol` — the independent mirror, FULLY migrated (verified: no stale symbols).
  - `SyncInputs`: `collateralNAVLast` + `collateralNAVDelta` replace the four st/jt raw fields; `effectiveDust` → `dustTolerance`.
  - `SyncOutputs`: `collateralNAV` replaces `stRawNAV`+`jtRawNAV`.
  - `Claims`: 4 fields, `collateralAssets` replaces `stAssets`+`jtAssets`.
  - `attributeDeltaToClaimOnRawNAV` → `attributeDeltaToClaimOnCollateralNAV` (zero-guard now includes `lastCollateralNAV == 0`).
  - `computeCoverageUtilization(collateralNAV, minCoverageWAD, jtEffectiveNAV)` — single NAV.
  - `syncTrancheAccounting`: attribution collapsed to single delta → ST with JT residual; claims
    decomposition + zero-lastSTRaw special case removed; conservation now `collateralNAV == stEff + jtEff`.
  - `scaleClaims`: 4 fields. `maxSTDeposit`/`maxJTWithdrawal`/`maxLTWithdrawal`: single `collateralNAV` +
    single `dustTolerance` signatures. Self-liq bonus: struct uses `stEffectiveNAV` (not raw legs);
    `seniorTrancheSelfLiquidationBonusReported(in_, collateralNAVPerUnitWAD)` single-leg round trip.

**Key rippling struct/signature shapes the leaf tests must adopt** (from RoycoTestMath, already final):
- `SyncInputs`: fields are now `collateralNAVLast, stEffectiveNAVLast, jtEffectiveNAVLast, jtImpermanentLossLast, marketStateLast, fixedTermEndTimestampLast, collateralNAVDelta, ltRawNAVNew, ...(premium/fee fields unchanged)..., dustTolerance, minLiquidityWAD`.
- `SyncOutputs`: `collateralNAV` (not `stRawNAV`/`jtRawNAV`).
- `Claims`: `collateralAssets, ltAssets, stShares, nav`.
- `SeniorTrancheSelfLiquidationBonusInputs`: `stEffectiveNAV, jtEffectiveNAV, coverageUtilizationWAD, coverageLiquidationUtilizationWAD, bonusWAD, userClaimNAV`.
- `maxSTDeposit(collateralNAV, stEffectiveNAV, jtEffectiveNAV, ltRawNAV, minCoverageWAD, minLiquidityWAD, dustTolerance)`.
- `maxJTWithdrawal(collateralNAV, jtEffectiveNAV, minCoverageWAD, dustTolerance)`.
- `maxLTWithdrawal(ltRawNAV, stEffectiveNAV, minLiquidityWAD, dustTolerance)`.
- `seniorTrancheSelfLiquidationBonusReported(in_, collateralNAVPerUnitWAD)`.

- **The ENTIRE foundation (test/utils/ + test/mocks/) is now migrated and COMPILES CLEAN**
  (`forge build test/utils test/mocks` → 0 errors, fmt applied). New shapes leaf tests must adopt:
  - `AccountantTestBase`: constants renamed `SEED_ST_EFF` (1000e18) / `SEED_JT_EFF` (200e18) (were SEED_ST_RAW/SEED_JT_RAW);
    `_seedState(uint256 _stEff, uint256 _jtEff, uint256 _il, uint256 _ltRaw, MarketState _targetState)` — 5 args
    (was 7 with raws); the seed route is now: ST_DEPOSIT of stEff, JT_DEPOSIT of (jtEff + il), pre-op loss sync of
    exactly il (the loss lands wholly on JT as IL with stEff unchanged), commit lt; `_seedSymmetric(stEff, jtEff, ltRaw)`;
    `_seedDustIL` deploys with single `dustTolerance = 7` and lands (stEff 1000e18, jtEff 200e18−5, il 5, PERPETUAL,
    collateral 1200e18−5); `_seedLargeIL` lands (stEff 1000e18, jtEff 200e18, il 100e18, FIXED_TERM, collateral 1200e18);
    `_seedNoILFixedTerm` lands (collateral 1100e18−1, stEff 1000e18, jtEff 100e18−1, il 0, FIXED_TERM);
    `_seedDustILFixedTerm` deploys dust 7, lands (collateral 1200e18−5, stEff 1000e18, jtEff 200e18−5, il 5, FIXED_TERM);
    `_seedShrunkDustIL` uses the single `setDustTolerance(0)`; `_hardSyncSetterCalls()` returns 10 calls (was 11);
    `_specCoverageUtilization(collateralNAV, minCoverageWAD, jtEff)` — 3 args;
    `_bareState(collateralNAV, ltRaw, stEff, jtEff, minCoverageWAD, minLiquidityWAD)` — 6 args;
    `_checkpointState()` populates `st.collateralNAV`.
  - `AccountantFuzzTestBase`: `_mirrorInput(collateralNew, ltRawNew, twJT, twLT, elapsedSincePayment, jtRate, ltRate)`
    — 7 args (was 8 with st/jt raws).
  - `MockAccountantKernel`: `setSyncNAV(NAV_UNIT)` (was setSyncNAVs(st, jt)); `syncCollateralNAV` public var;
    `doPreOp(collateralNAV)`; `doPostOp(op, collateralNAV, ltRawNAV, bonus, enforce)` — 5 args.
  - `WaterfallSyncDriver`: `seedCheckpoint` writes `lastCollateralNAV` + single `dustTolerance` (callers building
    `RoycoDayAccountantState` seeds must use the new struct fields); `runSync(collateralNAV, twJT, twLT)` /
    `tryRunSync(collateralNAV, twJT, twLT)` — 3 args (were 4).
  - `Assertions`: `assertNAVConservation(collateralNAV, stEff, jtEff, ctx)` — 4 args (was 5).
  - `FixtureTypes`: `MarketParamsConfig.dustTolerance` (single, was st/jt pair); `FixtureCell` is
    `{name, collateralAsset, quoteAsset}` (stAsset/jtAsset merged). `TokenConfigs` cells already collapsed.
  - `DayMarketTestBase`: kernel construction uses `collateralAsset`; role binding uses single
    `setDustTolerance` selector; `_ensureLiquidityCapacityForSTDeposit`/`_acquireSTShares` use
    `convertCollateralAssetsToValue`/`convertValueToCollateralAssets`; `applySTPnL`/`applyJTPnL` remain aliases
    over the one vault rate (docs updated: single-tranche PnL isolation is unrepresentable).
  - `EntryPointTestBase.assertAssetClaimsZero`: sums the 4 claim fields.
  - `SelfLiquidationHarness`: identity conversions are now `convertValueToCollateralAssets`/`convertCollateralAssetsToValue`.
  - `FeeAndLiquidityPremiumHarness`: `setTotalLTAssets`/`setTotalCollateralAssets`/`totalCollateralAssets()`
    (were *OwnedYieldBearingAssets names); self-call surface `convertLTAssetsToValue`.
  - `LTEffectiveNAVDriver`: sets `kernelState.totalLTAssets`; self-call `convertLTAssetsToValue`.
  - `EntryPointRemitClaimsHarness`: `MockKernelAssets(collateralAsset, ltAsset, seniorTranche, quoteAsset)` — 4-arg
    constructor exposing `COLLATERAL_ASSET()` (ST_ASSET/JT_ASSET gone).
  - `TrancheClaimsExposer`: the `computeSTandJTClaimsOnRawNAVs` exposer is DELETED (src function gone); only
    `scaleAssetClaims` remains. Tests of the decomposition must be deleted or converted per §3.3.

### Leaf progress (updated live)
- DONE, compile-clean, fmt'd: test/concrete/Quoters (13 files, zero pin shifts); test/concrete/Tranches +
  test/concrete/EntryPoint (23 files, one hand-derived 1-wei remit-bonus shift); test/scenarios (2 files,
  §3.9-verified, biconditional + zero-fee-theorem asserts added); test/concrete/Accountant aux nine
  (Access/Init/Setters/Max/Bonus/Utilization/Fee/Uint32/Dilution — §3.9 dust-vector re-verify in flight).
- IN FLIGHT: concrete/Accountant sync eight, concrete/Kernel + concrete/Math, test/fuzz, test/invariant + test/fork.

### PENDING — leaf directories
Everything else under `test/` still carries stale symbols. Run this to see the live list:
```
cd /Users/shivkapoor/royco-structured-products/royco-day
grep -rln "stRawNAV\|jtRawNAV\|\.stAssets\|\.jtAssets\|ST_ASSET\|JT_ASSET\|stNAVDustTolerance\|jtNAVDustTolerance\|effectiveNAVDustTolerance\|setSeniorTrancheDustTolerance\|setJuniorTrancheDustTolerance\|stConvert\|jtConvert\|ltConvertTrancheUnits\|ltConvertNAVUnits\|OwnedYieldBearingAssets\|_computeSTandJTClaimsOnRawNAVs\|TRANCHE_ASSETS_MUST_BE_IDENTICAL\|syncStRawNAV\|syncJTRawNAV\|setSyncNAVs\|\.effectiveDust\|seniorAsset\|juniorAsset\|stDustTolerance\|jtDustTolerance" test/ | sort
```
Remaining foundation (do FIRST, everything imports these):
- `test/utils/`: `AccountantTestBase.sol`, `AccountantFuzzTestBase.sol`, `DayMarketTestBase.sol`,
  `EntryPointTestBase.sol`, `RoycoDayTestBase.sol`, `MarketParams.sol`, `FixtureTypes.sol`,
  `TokenConfigs.sol`, `Assertions.sol` (also check `MarketFuzzTestBase.sol`, `IKernelTestHooks.sol`).
- `test/mocks/` harnesses: `WaterfallSyncDriver.sol`, `FeeAndLiquidityPremiumHarness.sol`,
  `SelfLiquidationHarness.sol`, `TrancheClaimsExposer.sol`, `EntryPointRemitClaimsHarness.sol`,
  `LTEffectiveNAVDriver.sol`. (`AttributionExposer.sol` was already migrated during the src work.)

Then the leaf directories (largely mechanical against the API table + the RoycoTestMath shapes):
`test/concrete/{Accountant,Kernel,Quoters,Tranches,EntryPoint,Math}`, `test/fuzz/{Accountant,Kernel,Logic,EntryPoint}`,
`test/invariant/`, `test/scenarios/`, `test/fork/`.

Higher-judgment leaf files (need the §3 semantics, not just renames):
- `concrete/Accountant/Test_SyncTrancheAccounting_Accountant.t.sol`, `Test_PostOpSync_Accountant.t.sol`,
  `Test_CoverageCrossClaimFindings_Accountant.t.sol` (this one likely tests now-unreachable mixed-sign
  states — see §3.3), `Test_SeniorTrancheSelfLiquidationBonus.t.sol`, `Test_MaxDepositAndWithdrawal.t.sol`,
  `Test_FeeAndLiquidityPremium.t.sol`, `Test_PremiumDustAndFixedTermEdges.t.sol`, `ZZProbe.t.sol`.
- `fuzz/Accountant/TestFuzz_SyncTrancheAccounting.t.sol`, `TestFuzz_Attribution.t.sol` (fuzz bounds that
  gated on non-mixed-sign raw deltas can now be unconditional — the invariant makes mixed-sign unreachable).
- `fuzz/Logic/TestFuzz_SelfLiquidation.t.sol`, `fuzz/Kernel/TestFuzz_SeniorTrancheSelfLiquidationBonus.t.sol`.
- `concrete/Math/Test_RoycoTestMath.t.sol` — the mirror's own unit tests; must match the migrated mirror.

## 5. Recommended execution strategy

1. **Finish the foundation inline / in one focused pass** before any leaf work — the bases and harnesses
   are the highest-judgment shared layer and everything imports them. After each foundation file, sanity
   check with `~/.foundry/versions/v1.7.1/forge build test/utils test/mocks 2>&1 | head -50` and iterate
   until the only remaining errors are in leaf files.
2. **Then fan out leaf directories** as small, well-scoped parallel agents (one per directory or a couple
   of related files). Small scope matters: a single huge agent kept dying on connection errors here.
   Give each agent this file + the specific files + the instruction "expected behavior not implemented
   behavior, same-or-higher rigor, comment style no em-dashes/semicolons."
3. **Compile loop, chunked** (do not build the whole tree at once — slow, and it masks later batches; the
   first failing compile batch hides the rest). Chunks: `test/concrete`, `test/fuzz`, `test/invariant`,
   `test/scenarios`, then `test/fork`.
4. **Certification, chunked** (a full battery gets killed):
   - `~/.foundry/versions/v1.7.1/forge test --match-path 'test/concrete/**'`
   - `... --match-path 'test/fuzz/**'`
   - `... --match-path 'test/scenarios/**'`
   - `... --match-path 'test/invariant/**'`
   - fork tests need env + limited threads: `set -a; source .env; set +a` then
     `~/.foundry/versions/v1.7.1/forge test --match-path 'test/fork/**' --threads 2`
5. For every failure, decide from §3 whether the EXPECTED value moved (re-derive by hand, re-pin with a
   comment) or the test is genuinely catching a regression (STOP and report — do not edit `src`).
6. `~/.foundry/versions/v1.7.1/forge fmt test/` at the end. Do not commit (repo policy: no git writes on
   the user's behalf).

## 6. Gotchas discovered

- **Batch-masking**: `forge build` aborts at the first failing compile batch and hides later batches' errors.
  Fix the surfaced file, rebuild, repeat. Do not assume "one error left."
- **Stable forge**: `~/.foundry/versions/v1.7.1/forge` (the default `forge` on PATH may differ).
- **Big-agent connection failures**: a single agent covering the whole foundation died repeatedly mid-write
  on "Connection closed mid-response." Keep agents small and their edits idempotent (Read before re-edit).
- **`grep` over-matches**: the pending-file scan matches legitimate new symbols too (e.g. `doPreOp(` in the
  already-migrated MockAccountantKernel). Confirm with a Read before assuming a file is stale.
- **CI note** (unrelated but do not revert): royco-day CI runs `forge build && forge build src/ --sizes`.
