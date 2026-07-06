# Royco Day — Testing Strategy & Scaffolding Plan

Status: DRAFT for review. No bulk test code is written until this is approved.
Scaffolding code (fixture interfaces, one exemplar per layer, one handler skeleton) lives in `test/scaffold/`.

**Inputs note.** The legacy test-suite analysis report lives at `royco-dawn/docs/testing/dawn-test-suite-audit.md` (3,002 lines) and was processed as a second pass **after** the independent analysis below was complete, per the execution protocol. It was used strictly as an idea catalog: adopted items are restated in §1.7 against this codebase with fresh `royco-day` file:line grounding; nothing in Sections 1–6 is asserted about this codebase on the report's authority. A direct audit of the legacy `royco-dawn` suite (~1,266 tests, 54 files) was run independently and corroborates the report's headline patterns (sign-only asserts ≈28% of value assertions, ~130 early returns, 18-dp mock monoculture). The report's Section 6 posed the LT design questions ([UNVERIFIED] there: LT loss-priority position, liquidity-utilization definition, bonus funding) as unanswerable from 2-tranche source — all three are now answered from this repo's code in §1.5 and §1.3, which supersede it.

---

## 1. Independent risk analysis

### 1.1 System map (what executes where)

| Component | File | Role |
|---|---|---|
| Accountant | [`src/accountant/RoycoDayAccountant.sol`](../src/accountant/RoycoDayAccountant.sol) | Waterfall, IL tracking, premiums, fees, utilizations, state machine, checkpoints. Only callable by kernel for mutations (`onlyRoycoKernel`, :36). |
| Kernel base | [`src/kernels/base/RoycoDayKernel.sol`](../src/kernels/base/RoycoDayKernel.sol) | Entry points per tranche; delegatecalls into logic libraries; holds all asset accounting state (ERC-7201). |
| Logic libs | `src/libraries/logic/*.sol` | Deposit/Redemption/AccountingSync/FeeAndLiquidityPremium/TrancheClaims/SelfLiquidation/Valuation/Utilization/Blacklist. Delegatecalled by kernel. |
| Tranches | `src/tranches/*` + `base/RoycoVaultTranche.sol` | ERC20 (18-dec shares, `RoycoVaultTranche.sol:304-306`), thin shells over kernel. LT adds multi-asset flows. |
| Quoters | `src/kernels/base/quoter/**` | TRANCHE_UNIT↔NAV_UNIT conversion: ERC4626 rate × Chainlink/admin oracle (ST/JT); BPT oracle TVL (LT). |
| Venue | `quoter/liquidity-tranche/balancer-v3/*` | Balancer V3 UNBALANCED add / PROPORTIONAL remove, premium reinvestment gate, rate provider, pool hooks. |
| YDMs | `src/ydm/*` | Static piecewise curve; adaptive curve (expWad drift). Shared instances keyed by accountant address. |
| Factory/deploy | `src/factory/*`, `script/Deploy.s.sol` | Market wiring, roles (AccessManager), UUPS proxies. |

Units: `NAV_UNIT` is always WAD-18 ([`Units.sol:7-11`](../src/libraries/Units.sol)); `TRANCHE_UNIT` is native token decimals. All share supplies are 18-dec because shares are minted from NAV values.

### 1.2 External/public surface and revert paths

Mutating surface (excluding admin setters):

| Entry | Path | Gates / revert paths |
|---|---|---|
| `ST.deposit` | tranche → `kernel.stDeposit` → `DepositLogic.stDeposit` | `whenNotPaused`+`restricted` (tranche), `onlySeniorTranche`, PERPETUAL only (`DepositLogic.sol:222`), post-op coverage **and liquidity** gate (`RoycoDayAccountant.sol:326-333` via enforce=true at `DepositLogic.sol:232`), `INVALID_VALUE_ALLOCATED`, `MUST_MINT_NON_ZERO_SHARES` (`RoycoVaultTranche.sol:91-97`), op-shape `INVALID_POST_OP_STATE` (`RoycoDayAccountant.sol:246`) |
| `JT.deposit` | → `jtDeposit` | PERPETUAL only (`DepositLogic.sol:258`); **no** requirement enforcement (`:268`) |
| `LT.deposit` (in-kind BPT) | → `ltDeposit` | any market state; no requirement enforcement (`DepositLogic.sol:283-303`) |
| `LT.depositMultiAsset` | → `ltDepositMultiAsset` | non-zero legs (`:334`); FIXED_TERM allows quote-only (`:339`); coverage+liquidity enforced iff ST leg > 0 (`:366`); venue `minLTAssetsOut` |
| `ST.redeem` | → `stRedeem` | PERPETUAL only (`RedemptionLogic.sol:52`); self-liquidation bonus applied ≥ liquidation threshold; no gate enforcement (`:66`) |
| `JT.redeem` | → `jtRedeem` | PERPETUAL only; coverage gate enforced (`:105`) |
| `LT.redeem` (in-kind) | → `ltRedeem` | PERPETUAL only; liquidity gate enforced unless `covUtil ≥ liqThreshold` pre-op (`:144-146`); op-shape check `RoycoDayAccountant.sol:262` |
| `LT.redeemMultiAsset` | → `ltRedeemMultiAsset` | as above + venue min-outs; burns ST shares from venue + idle pile (`RedemptionLogic.sol:176-217`) |
| `kernel.syncTrancheAccounting` | `restricted` (`RoycoDayKernel.sol:309-320`) | sync waterfall; conservation `require` (`RoycoDayAccountant.sol:651`); `PREMIUMS_EXCEED_SENIOR_YIELD` (`:624`) |
| `kernel.reinvestLiquidityPremium` | `restricted` (`:323`) | re-values idle premium at fresh rate; venue slippage gate tolerated-failure (`BalancerV3VenueLogic.sol:186-196`) |
| Balancer pool ops (external LPs/swappers) | hooks | pre-op sync unless `router == kernel` (`RoycoDayBalancerV3Hooks.sol:79-127`); pool-identity check |
| Share transfers | `RoycoVaultTranche._update:317-323` | blacklist batch screen + optional whitelist-on-transfer via AccessManager `canCall` (`RoycoDayKernel.sol:544-551`) |
| Oracle quoting | Chainlink quoter | `STALE_PRICE`, `INVALID_PRICE`, `SEQUENCER_DOWN`, `GRACE_PERIOD_NOT_OVER` — any of which bricks every flow incl. sync |

Admin setters (all `restricted`, most `withSyncedAccounting`): fees (≤ `MAX_PROTOCOL_FEE_WAD` = 100%), `setMinCoverage < WAD`, `setLiquidationCoverageUtilization > WAD`, `setMinLiquidity < WAD`, `setMaxYieldShares` (sum ≤ WAD, `RoycoDayAccountant.sol:985-988`), `setFixedTermDuration` (0 ⇒ force PERPETUAL + erase IL, `:917-929`), dust tolerances, YDM swaps (best-effort sync via raw call, `:822`), `setMaxReinvestmentSlippage < WAD`, `setBPTOracle`, blacklist/bonus/fee-recipient.

### 1.3 Accounting formulas and rounding sites

The complete inventory of rounding sites in the money path. `⌊⌋` = Floor, `⌈⌉` = Ceil. "Favors" states who keeps the dust.

| # | Formula | Site | Rounding | Favors |
|---|---|---|---|---|
| F1 | PnL attribution: `attributed = ⌊|Δraw| · claim / lastRaw⌋`, sign re-applied | `RoycoDayAccountant.sol:961-978` | Floor on magnitude | complementary tranche (JT absorbs residual, `:528-530`) |
| F2 | Coverage: `coverageApplied = min(stLoss, jtEff)` | `:561` | exact | — |
| F3 | IL recovery: `min(stGain, jtCoverageIL)` | `:580` | exact | — |
| F4 | Premiums: `⌊stGain · twShare / (elapsed·WAD)⌋` | `:621-622` | Floor | ST |
| F5 | Fees: `⌊gain · feeWAD / WAD⌋` (JT gain fee recomputed after coverage, `:564-567`) | `:552,629,638,643` | Floor | LPs |
| F6 | Conservation: `stRaw + jtRaw == stEff + jtEff` | `:651`, `:286` | exact require | — |
| F7 | Coverage utilization: `⌈(stRaw + β·jtRaw)·minCov / jtEff⌉`; 0 if minCov=0 or exposure=0; `uint.max` if jtEff=0 | `UtilizationLogic.sol:39-47` | Ceil | senior |
| F8 | Liquidity utilization: `⌈stEff·minLiq / ltRaw⌉`; 0/`uint.max` edges | `UtilizationLogic.sol:69-75` | Ceil | senior |
| F9 | Shares: `min(⌊supply·value/totalValue⌋, ⌊supply·(WAD−ε)/ε⌋)` with ε = `MINT_DILUTION_RESIDUAL_WAD` (1e6, a 1e-12 residual: one mint owns ≤ (1−ε/WAD) of post-mint supply, bind-first ordering); supply=0 ⇒ `value` 1:1 (clamp exempt); totalValue=0 ⇒ denominator **1 wei** | `ValuationLogic.sol` `_convertToShares`, `Constants.sol` | Floor (both branches) | existing holders |
| F10 | Value: `⌊totalValue·shares/supply⌋`; supply=0 ⇒ 0 | `ValuationLogic.sol:118-122` | Floor | remaining holders |
| F11 | Premium/fee carve-out: denominator `stEff − premium − fee` at pre-sync supply, both Floor | `FeeAndLiquidityPremiumLogic.sol:98-103` | Floor | pre-existing ST shares |
| F12 | LT effective NAV: `ltRaw + ⌊idleShares·stEff/stSupply⌋` | `ValuationLogic.sol:87-91` | Floor | pool leg |
| F13 | Claim scaling: all five fields `⌊claim·shares/totalShares⌋` | `TrancheClaimsLogic.sol:126-131` | Floor | remaining LPs |
| F14 | Claims decomposition: `stClaimOnJT = sat(stEff−stRaw)` etc. | `TrancheClaimsLogic.sol:193-200` | exact (given F6) | — |
| F15 | `maxSTDeposit`: `⌊jtEff·WAD/minCov⌋ − …` minus dust tolerances | `RoycoDayAccountant.sol:354-387` | Floor + dust slack | protocol |
| F16 | `maxJTWithdrawal`: K_S/K_J floors, retention, `+ 2 wei` fudge | `:401-441` (fudge `:422`) | mixed | protocol |
| F17 | `maxLTWithdrawal`: `ltRaw − ⌈stEff·minLiq/WAD⌉ − stDust` | `:451-459` | Ceil inner | senior |
| F18 | JT-redeem IL scale: `IL' = ⌊IL·jtEffAfter/jtEffBefore⌋` | `:278-281` | Floor | senior |
| F19 | Self-liq bonus: `min(⌊nav·bonusWAD/WAD⌋, jtEff, U-neutral max)` with U-neutral floors | `SelfLiquidationLogic.sol:44-66,120-128` | Floor | JT |
| F20 | ltRawNAV: `⌊oracleTVL·ownedBPT/bptSupply⌋` | `BalancerV3_LT_BPTOracle_Quoter.sol:128-133` | Floor | — |
| F21 | Reinvest gate: `minOut = ⌈fair·(WAD−maxSlip)/WAD⌉` | `BalancerV3VenueLogic.sol:180-184` | Ceil | LT |
| F22 | ST↔NAV quoting: `⌊assets·rateWAD/10^dec⌋` and ERC4626 rate composition | `IdenticalAssets_ST_JT_Oracle_Quoter.sol:140-142`, `IdenticalERC4626Shares_…:29,45-54` | Floor | protocol |
| F23 | TW accrual: `acc += share·Δt` (uint192); premium divides by `Δt_sincePayment·WAD`; same-block path uses instantaneous shares with `Δt = 1s` | `RoycoDayAccountant.sol:756-761, 594-619` | exact int | — |
| F24 | YDM static: `⌊slope·u/WAD⌋ + intercept`; adaptive: expWad, trapezoid avg `(y0+y1+2·ymid)/4`, clamps `[1bp@target, WAD]`, u capped at WAD | `StaticCurveYDM.sol:102-139`, `AdaptiveCurveYDM_V2.sol:159-252` | Floor | paying tranche |

### 1.4 State machine (from code, `RoycoDayAccountant.sol:653-704`)

States: `PERPETUAL`, `FIXED_TERM` (`Types.sol:23-26`).

Forced PERPETUAL (all erase `jtCoverageIL`): `fixedTermDuration == 0` ∨ (in FIXED_TERM ∧ `end ≤ now`) ∨ `covUtil ≥ liqThreshold` ∨ (`jtEff == 0 ∧ stEff > 0`). Else if `jtCoverageIL ≤ effectiveDust`: PERPETUAL if previously PERPETUAL or IL exactly 0; **stays FIXED_TERM if previously FIXED_TERM and 0 < IL ≤ dust** (`:684-693`). Else FIXED_TERM; end timestamp set only on PERPETUAL→FIXED_TERM entry (`:702`). In FIXED_TERM: premium and all fees zeroed (`:689-700`); YDM adaptation frozen (`AdaptiveCurveYDM_V2.sol:175-190`).

Per-op state matrix (already in §1.2): only in-kind LT deposit and quote-only multi-asset LT deposit are legal in FIXED_TERM.

### 1.5 LT position in the stack (derived, not assumed)

- The waterfall's inputs are `stRawNAV`/`jtRawNAV` only (`RoycoDayAccountant.sol:143-145`). `ltRawNAV` is committed outside it (`:196-201`) and its delta is booked directly at post-op (`:237,291`). **The LT bears 100% of its venue P&L; JT does not cover the BPT leg and BPT losses never touch ST/JT effective NAVs.**
- The LT's idle premium ST shares are ordinary senior claims inside `stEff` (mint reassigns ownership only, `FeeAndLiquidityPremiumLogic.sol:47-54`), so that leg *is* covered by JT like any senior share.
- Loss priority is therefore two-lane: `{JT → ST}` for tranche-asset P&L; `{LT alone}` for venue P&L. There is no third waterfall term.

This resolves the "define LT's exact position from the code" question; it is unambiguous, so no user clarification was needed.

### 1.6 Ranked risk list (drives everything below)

| Rank | Risk | Why |
|---|---|---|
| R1 | **Waterfall mis-attribution that conserves.** F6 is enforced in-contract, so the dangerous bug class is value moved to the *wrong tranche* while the sum stays exact (F1's claim decomposition, F2/F3 ordering, F4 windows, F5 recomputation at `:564-567`). No require catches it. | highest-value state corruption, silent |
| R2 | **Sync liveness.** Every flow (incl. all redemptions) runs through `preOpSync`. Any revert path inside it — `PREMIUMS_EXCEED_SENIOR_YIELD` (`:624`), `toNAVUnits(int<0)` (`Units.sol:94-98`), attribution underflow, a bricked YDM, a stale oracle — freezes the market. | protocol-wide DoS |
| R3 | **Preview/execution parity.** Six deposit/redeem flows each have a preview that re-implements the execution path's supply/NAV sequencing (e.g. `ltPreviewRedeemMultiAsset` must reproduce post-mint ST supply, `RedemptionLogic.sol:292-296`). Drift = mispriced mints/burns. | direct value transfer |
| R4 | **Gate consistency.** Three metrics (covUtil, liqUtil, liquidation threshold) × six ops × two market states × enforcement flags that differ per flow. Includes `max*` closed-form inversions (F15–F17) with hand-tuned dust slack and a `+2 wei` fudge (`:422`). | fund lockup or gate bypass |
| R5 | **LT premium lifecycle.** Mint sizing (F11), coverage-neutrality, idle-buffer accounting (`$.ltOwnedSeniorTrancheShares`), gated reinvestment with tolerated failure, both-legs redemption. Edge found in analysis: in-kind LT redeem with zero BPT slice but non-zero idle-share slice trips `INVALID_POST_OP_STATE` (`RoycoDayAccountant.sol:262`) — see Appendix B. | new, least-audited surface |
| R6 | **Unit/decimal conversion.** TRANCHE_UNIT native decimals → WAD NAV via quoter rate composition (F22); oracle decimals; BPT always 18. All current tests assume 18-dec. | classic 10^12 bug class |
| R7 | **Post-op shape requires.** `INVALID_POST_OP_STATE` demands *byte-exact* raw-NAV deltas per op (e.g. `deltaJT == 0` during ST deposit, `:246`). Holds only if the quoter rate is transaction-invariant (transient `Cache`, `Cache.sol:47-61`). Any same-tx rate drift (non-cached quoter path, donation, FoT token) bricks ops. | correctness-critical coupling |
| R8 | Self-liquidation bonus (F19): must not increase covUtil (bank-run invariant documented at `SelfLiquidationLogic.sol:73-89`). | bank-run dynamics |
| R9 | YDM math (F23/F24): tw-accrual window alignment between `lastYieldShareAccrualTimestamp` and `lastPremiumPaymentTimestamp`; expWad clamps; same-block instantaneous branch. | premium mispricing |
| R10 | Venue integration: hooks sync-bypass carve-out, rate-provider cache, UNBALANCED add + PROPORTIONAL remove min-outs, BPT oracle trust. | external-protocol coupling |
| R11 | Access control/pause/blacklist/whitelist-on-transfer; `restricted` on `syncTrancheAccounting` means role wiring is liveness-critical (hooks and accountant must be authorized callers). | config-dependent DoS/bypass |
| R12 | Upgradeability: ERC-7201 layouts ×3, UUPS `_authorizeUpgrade`, factory/template wiring. | one-shot deploy risk |

### 1.7 Second pass — patterns adopted from the report and the legacy-suite audit

From the direct legacy-suite audit (corroborated by the report's §2-addendum):

1. **Ban list confirmed as real, not hypothetical**: ~28% of the legacy suite's value assertions are sign/direction-only, `return;` appears ~130× in test bodies (mostly derived-then-skip guards, not `bound()`), and all non-fork paths run on an 18-dp mock monoculture. All three are Section 2/5 hard rules here.
2. **3×3 delta matrix** (ST {loss,flat,gain} × JT {loss,flat,gain}) as the unit-test backbone for the sync — extended to 3×3×{ltRaw loss/flat/gain}×{IL=0, 0<IL≤dust, IL>dust} for Day.
3. **Typed assertion helpers** for `NAV_UNIT`/`TRANCHE_UNIT` (this repo already has `test/base/Assertions.sol`) — keep, extend with context-string discipline.
4. **Regression PoCs as golden vectors**: the legacy savUSD attribution-bug PoC shows the exact bug class R1 targets; re-derive its scenario as a Day golden vector (attribution when one raw NAV is drained near zero).
5. **Documented-`vm.assume`** convention: every constraint carries a written distribution justification — adopted as a lint rule (§5).
6. **Abstract kernel suite with virtual hooks** (already begun in `test/kernels/abstract/AbstractKernelTestSuite.sol`) — keep the shape, but re-found it on the parameterized `TrancheFixture` below instead of fork-only configs.

Additional ideas adopted from the report (`dawn-test-suite-audit.md`), restated against this codebase:

7. **No-frozen-parameters rule** (report §3.3: the legacy suite ran its entire flow at one β, one coverage, one fee, one liquidation threshold). Every `MarketParamsConfig` field gets a mandated sweep set (§2.2), and `JT_COINVESTED` becomes an explicit fixture axis — it branches the coverage formula (`UtilizationLogic.sol:41`), `maxJTWithdrawal`'s K-split (`RoycoDayAccountant.sol:433`), and the self-liq bonus sourcing (`SelfLiquidationLogic.sol:110-128`), so both values run in CI (cells A–C true, D false).
8. **Zero-config reductions** (generalizing the report's param sweep, and closing a first-pass gap): `minLiquidityWAD = 0` must reduce a Day market to a plain ST/JT market — this is the repo's own P1 acceptance test (CLAUDE.md build sequence) and was missing from the first-pass catalog. Now invariant **I21**. Similarly pinned: `fixedTermDurationSeconds = 0` (permanently PERPETUAL, IL erased, `RoycoDayAccountant.sol:920-927`), `minCoverageWAD = 0` (coverage gate inert, `UtilizationLogic.sol:39`), fees at 0 and at `MAX_PROTOCOL_FEE_WAD` (= 100%, `Constants.sol:31` — including the zero-denominator fee-share mint edge where `ltEffectiveNAV − ltProtocolFee → 0` hits F9's 1-wei branch).
9. **Money-path event assertions** (report §3.7: legacy had 21 `expectEmit`, none on the money path). Exact-arg `vm.expectEmit` for `TrancheAccountingSynced`, `LiquidityTrancheRawNAVCommitted`, `FixedTermCommenced/Ended`, `JuniorTrancheCoverageImpermanentLossReset`, `*YieldShareAccrued` (`IRoycoDayAccountant.sol:129-210`) and tranche `Deposit`/`Redeem`/`MultiAssetDeposit`/`MultiAssetRedeem`. Added to §4.1.
10. **Guard-reachability vectors** (report A3: the legacy conservation revert had zero triggering tests). Every custom error gets at least one test that makes it fire — including `NAV_CONSERVATION_VIOLATION` via a mock-kernel harness feeding the accountant a deliberately non-conserving tuple, and the constructor wiring guards (`TRANCHE_AND_KERNEL_ASSETS_MISMATCH`, `JT_MUST_BE_COINVESTED` at `RoycoDayKernel.sol:122,133-135`; the quoter pool-config guards). `PREMIUMS_EXCEED_SENIOR_YIELD` is the deliberate exception: I6/I19 prove it *unreachable* instead.
11. **Staleness-through-the-flow discipline** (report A8: legacy mocks re-stamped `updatedAt` on every yield sim, so the staleness gate was never crossable). Codified as mock behavior in §2.4: `MockAggregatorV3` never auto-refreshes `updatedAt`; plus end-to-end vectors: warp past staleness → `stDeposit`/sync revert `STALE_PRICE`.
12. **Whitelist-deny + precedence matrix** (report A9: the deny path had zero tests). `ACCOUNT_NOT_WHITELISTED_TRANCHE_LP` (`RoycoDayKernel.sol:550`) deny path, whitelist-allow path, and blacklist-beats-whitelist precedence — folded into I20.
13. **Pause-interaction matrix** (report A15, sharpened by code here): pause is not just per-entry-point — all 11 accountant setters are `withSyncedAccounting` (`RoycoDayAccountant.sol:844-947`), whose modifier calls the kernel's `whenNotPaused` sync, so **every parameter setter reverts while the kernel is paused** (only the YDM swap setters survive, via tolerated raw call `:822,836`). Pinned as behavior + flagged as Appendix B.8.
14. **Multi-asset atomicity via revert injection** (report §6.2-I6): inject a failure into each leg of `ltDepositMultiAsset`/`ltRedeemMultiAsset` (venue min-out breach, venue revert, post-op gate) and assert full pre-state snapshot equality — no partial senior mint, no partial idle-pile debit. Now invariant **I22**.
15. **Mutation before/after metric** (report §5.6): record the mutation score once golden vectors exist (post-Phase B) and again after Phase F; the delta is the quantitative evidence the suite improved. Added to §4.6.
16. **Assertion-strength distribution as a CI artifact** (report §2′): the grep-derived macro distribution (`assertEq` vs `assertGt` vs `approxEq`) is published per PR so sign-only drift is visible before review. Added to §5.
17. **`[rpc_endpoints]` in `foundry.toml`** so fork suites fail loudly when RPC env is missing rather than silently skipping (report §3.8). Added to §4.7.

Explicitly not adopted: preview-vs-actual as the *only* pricing check (circular; both sides call the same code — preview-parity is one invariant, I11, and independent derivation is mandatory); the report's Python `--ffi` differential oracle (superseded by `RoycoTestMath` in-language plus the simulator trajectories, §4.4 — same exact-integer goal, no FFI dependency); its N-term conservation and vectorized-YDM generalizations (Day resolved these differently: conservation stays two-term with the premium inside `stEff`, and the YDM stays scalar-per-instance with two instances); its D5/D6/D8 exotic-decimals cells (>18-dp, 78-dp) — Day's quoter family scales through ERC4626 rates into WAD NAV and no >18-dp underlying is targeted; excluded with this justification rather than tested.

---

## 2. Test architecture specification

### 2.1 Directory layout & naming

```
test/
├── base/                       # existing BaseTest/Assertions, extended
│   ├── fixtures/
│   │   ├── TrancheFixture.sol      # THE fixture (see 2.2) — every test inherits it
│   │   ├── TokenConfigs.sol        # canonical token-matrix cells (see 2.3)
│   │   └── MarketParams.sol        # market parameter presets
│   ├── math/
│   │   └── RoycoTestMath.sol       # independent expected-value library (see 2.5)
│   └── mocks/                      # one configurable mock per external dependency (see 2.4)
├── unit/                       # concrete, golden-vector tests; mirrors src/ tree
│   ├── accountant/                 # Waterfall.t.sol, StateMachine.t.sol, Max*.t.sol, Setters.t.sol
│   ├── logic/                      # one file per logic library
│   ├── tranches/  ydm/  quoters/  auth/
├── fuzz/                       # property tests; mirrors unit/ tree; file suffix .fuzz.t.sol
├── invariant/
│   ├── handlers/DayMarketHandler.sol
│   ├── DayMarketInvariants.t.sol
│   └── modes/                      # handler weight profiles (calm / stressed / liquidation)
├── differential/               # vs RoycoTestMath replay + simulator trajectories
├── symbolic/                   # Halmos specs (excluded from forge CI profile)
├── fork/                       # real tokens + real Balancer, pinned blocks
└── scaffold/                   # this pass's exemplars; deleted once Phase A lands
```

Naming: `test_<Unit>_<behavior>` / `testFuzz_<Unit>_<property>` / `invariant_<ID>_<name>` (ID from §3) / `testFork_…`. Revert tests: `test_<Unit>_reverts_<condition>` with `vm.expectRevert(ExactError.selector)` — never bare `expectRevert()`.

### 2.2 Base fixture: `TrancheFixture`

One parameterized fixture; every test layer inherits it. Concrete interface in [`test/scaffold/TrancheFixture.sol`](../test/scaffold/TrancheFixture.sol). Shape:

- `TokenConfig` per role (ST asset, JT asset, quote asset): `{decimals, behavior bitmap: FEE_ON_TRANSFER(bps) | REBASING | NO_RETURN_VALUE | REVERT_ON_ZERO | BLOCKLIST | PAUSABLE | HOOK_ON_TRANSFER, erc4626: {yes/no, shareDecimals, initialRate}}`.
- `MarketParams`: `{minCoverageWAD, liquidationUtilWAD, minLiquidityWAD, maxJT/LT yield shares, fees×4, fixedTermDuration, dust tolerances×2, jtCoinvested, selfLiqBonusWAD, maxReinvestSlippageWAD, ydmKind + curve points}`.
- `setUp()` deploys the full market (factory path where possible so wiring is what production gets) against **mock** quoter/venue by default; fork variants override venue bindings.
- **Hard rule: no test may instantiate a token mock directly.** Tokens come only from `TokenConfigs` cells. The 18/18/18 cell exists but is *one cell*, selected explicitly — never a default constructor value.
- Yield/loss injection: `applySTPnL(int256 bps)`, `applyJTPnL`, `applyLTPnL` mutate the mock rate/oracle (not `deal`), so PnL flows through the same quoter path production uses.
- **No frozen parameters** (adopted from the report, §1.7-7/8): every `MarketParamsConfig` field must be exercised at more than one value somewhere in the suite. Mandated sweep sets: `jtCoinvested ∈ {true, false}` (CI, via cells A–D); `minCoverageWAD ∈ {0, 0.1e18, WAD−1}`; `minLiquidityWAD ∈ {0, 0.05e18, WAD−1}` (0 = the I21 reduction market); `coverageLiquidationUtilizationWAD ∈ {WAD+1, 1.0009e18, 5e18}`; each fee ∈ `{0, 0.1e18, MAX_PROTOCOL_FEE_WAD}`; `fixedTermDurationSeconds ∈ {0, 1 hour, 2 weeks}`; dust tolerances ∈ `{0, 1, 1e12}`; `maxReinvestmentSlippageWAD ∈ {0, 10bps, WAD−1}`; yield-share maxes covering `{0, sum == WAD exactly}`. A checklist in `MarketParams.sol` maps each field to the test file that sweeps it; CI greps that the map stays total.

### 2.3 Token matrix

Canonical cells (ST asset / JT asset / quote asset). ST/JT are ERC4626 shares in the shipped kernel family, so cells specify `(vault share dec, underlying dec)`:

| Cell | ST | JT | Quote | Purpose |
|---|---|---|---|---|
| A (CI) | 4626(18,18) | same vault | 6 (USDC-like) | production-shaped baseline (Neutrl-like) |
| B (CI) | 4626(6,6) | same | 18 | low-decimal shares: F22 scale factor exercises `10^(18+6−6)` path |
| C (CI) | 4626(18,6) | same | 6 | share/underlying decimal split |
| D (CI) | 4626(8,8) | different vault (18,18) | 6 | non-identical ST/JT assets, `jtCoinvested=false` |
| E (nightly) | 4626(18,18) + REVERT_ON_ZERO underlying | same | 6 + BLOCKLIST | zero-amount transfer paths (`TrancheClaimsLogic._withdrawAssets` skips zeros — verify) |
| F (nightly) | 4626(18,18) | same | 6 + NO_RETURN_VALUE (USDT-like) | SafeERC20 coverage on quote leg |
| G (nightly) | underlying FEE_ON_TRANSFER 10bps | same | 6 | **expected-failure cell**: documents that FoT breaks `INVALID_POST_OP_STATE`/solvency (kernel credits face amount, `DepositLogic.sol:229`) — asserts the *revert*, existence justifies exclusion policy |
| H (nightly) | REBASING underlying under 4626 | same | 6 | rebase between ops = raw-NAV drift; must flow through waterfall as PnL, not corrupt op-shape checks |
| I (nightly) | 4626(18,18) | same | 8 | 8-dec quote (WBTC-denominated markets) |

Sampling policy: cells A–D run in every CI pass across unit+fuzz+invariant (fixture is cell-parameterized; CI runs the suite 4×). E–I nightly. Excluded cell and why: ERC777-style reentrant hooks on ST/JT *shares* — shares are protocol-minted ERC20s, not external tokens, so hook-bearing share tokens are unreachable in production; hook-bearing **quote** tokens are covered by cell E/H behaviors plus the reentrancy suite (kernel is `nonReentrant` transient, `RoycoDayKernel.sol:24`). Rebasing *quote inside the Balancer pool* is excluded as Balancer-invalid (pools require standard tokens); documented here as a deployment-checklist item instead.

### 2.4 Mock inventory (one configurable mock each, no per-test copies)

| Mock | Replaces | Config surface |
|---|---|---|
| `MockERC20C` | all plain tokens | decimals, behavior bitmap above, per-address blocklist, fee bps |
| `MockERC4626C` | ST/JT vaults | wraps MockERC20C; settable `rate` (convertToAssets multiplier) with `setRate()/accrue(bps)`; optional preview-rounding skew |
| `MockAggregatorV3` | Chainlink feed + sequencer feed | settable answer/decimals/updatedAt/answeredInRound; modes: STALE, NEGATIVE, ZERO, REVERT, SEQUENCER_DOWN, GRACE_PERIOD |
| `MockBPTOracle` | `LPOracleBase` | settable `computeTVL()`; REVERT mode |
| `MockBalancerVault` + `MockVenue` | Balancer V3 vault/pool for non-fork layers | settable BPT supply, proportional-remove composition, add-liquidity BPT-out (to drive the slippage gate both ways), UNBALANCED-add fee haircut bps |
| `MockYDM` | both YDM slots | settable constant/scripted yield share; REVERT mode (sync-bricking YDM, exercises `setJuniorTrancheYDM` recovery path `RoycoDayAccountant.sol:816-827`) |

Real YDMs are also tested directly (unit/fuzz/symbolic); `MockYDM` exists so accountant tests pin premium shares to chosen constants instead of curve outputs.

Mock discipline (both adopted from report anti-patterns §3(b)/(c)): **(i)** `vm.mockCall` is banned on any quoting/oracle/venue path — behavior changes go through the mock's setters so the production math between mock and assertion actually executes; **(ii)** `MockAggregatorV3` never auto-refreshes `updatedAt` — yield simulation and freshness are independent knobs, so warping time genuinely crosses the staleness gate (the legacy suite's freshness-restamping mocks made `STALE_PRICE` unreachable end-to-end).

### 2.5 Independent expected-value library: `RoycoTestMath`

A test-only Solidity library re-deriving every formula F1–F24 **from the spec in this document**, mirroring rounding direction, written by a different path than the production code (no imports from `src/libraries/logic`; only `Math.mulDiv`). Unit and fuzz assertions compare production output to `RoycoTestMath` output — never to a second call of the contract under test. Golden vectors additionally hard-code literal expected numbers derived by hand in comments, so `RoycoTestMath` itself is validated in Phase B before anything depends on it.

Core functions: `attribute(delta, claim, lastRaw)`, `waterfall(WaterfallIn) → WaterfallOut` (full sync including IL, premiums, fees, state transition), `covUtil`, `liqUtil`, `sharesFor(value,totalValue,supply)`, `valueFor`, `carveOut(stEff,premium,fee,supply)`, `scaleClaims`, `maxSTDeposit/maxJTWithdrawal/maxLTWithdrawal`, `selfLiqBonus`, `staticYdm`, `adaptiveYdm` (integer, mirrors expWad via solady import — acceptable shared dep, it's a vendored pure function), `ltEffNav`.

---

## 3. Invariant catalog

Notation: `stR,jtR,ltR` raw NAVs; `stE,jtE` effective; `IL` = jtCoverageImpermanentLoss; `covU,liqU` utilizations; `S_x` share supply of tranche x; `idle` = `$.ltOwnedSeniorTrancheShares`; `Δop` = change across one operation. Layer key: **H** = stateful invariant handler, **F** = fuzz property, **S** = symbolic, **U** = unit/golden.

| ID | Formal statement | Layer | Notes |
|---|---|---|---|
| I1 | After every committed sync/op: `stR + jtR == stE + jtE` (0 dust — enforced at `RoycoDayAccountant.sol:286,651`) | H,F,S | Handler asserts on `getState()`, not by trusting the require: catches paths that skip commits |
| I2 | Solvency: `token.balanceOf(kernel) ≥ Σ owned` per asset: `stOwned+jtOwned` (same asset ⇒ summed), `ltOwned` BPT, `idle` ST shares. Strict equality in mock cells (no donations); `≥` in fork | H | ghost-tracked transfers in/out |
| I3 | Loss priority: within one sync, `stE_after < stE_before ⟹ jtE_after == 0 ∨ ΔstE_uncovered == stLoss − coverageApplied` where `coverageApplied = min(stLoss, jtE_pre)`; equivalently uncovered senior loss > 0 ⟹ JT buffer exhausted at application time | H,U | exact recomputation via RoycoTestMath, not sign checks |
| I4 | LT isolation: `stE + jtE` after a sync is independent of `ltR` (re-run waterfall with perturbed `ltR` in preview: identical `stE,jtE`) | F | proves two-lane priority of §1.5 |
| I5 | IL ledger: `IL` changes only by: `+coverageApplied` (F2), `−min(stGain,IL)` (F3), `×⌊jtE'/jtE⌋` on JT redeem (F18), `→0` on the four erasure conditions (§1.4). Ghost var replays exact sequence | H | |
| I6 | Premium bound: per sync, `jtPrem + ltPrem ≤ stGain_afterILRecovery` (require `:624` must **never** be the thing that saves us: handler asserts `twJT ≤ maxJT·Δt ∧ twLT ≤ maxLT·Δt` so the require is provably dead) | H,F | doubles as sync-liveness (I14) evidence |
| I7 | Coverage-neutral mint: across `_processFeesAndLiquidityPremium`: `ΔstR == 0 ∧ ΔcovU == 0 ∧ ΔS_st == premiumShares + feeShares ∧ Δidle == premiumShares − reinvested` | U,F | |
| I8 | Mint value bound (two-sided): `|valueFor(premiumShares, S_post, stE) − ltPrem| ≤ ε`, `ε = 2·⌈stE/S_post⌉ + 2` wei. Downward slack: premium-share floor (F9); upward slack: the *fee* carve-out's floor dust stays in the pot and accrues pro-rata to all post-mint shares incl. the premium shares; final valuation floor (F10) adds < 1. The one-sided `value ≤ prem` version was refuted by the fuzz exemplar in 28 runs — kept in `test/scaffold/FuzzExemplar.t.sol` as the worked example of derive-then-fuzz-validate | F,S | derived tolerance, not arbitrary |
| I9 | Gate post-conditions: successful `ST_DEPOSIT ∨ (LT_DEPOSIT ∧ stLeg>0)` ⟹ `covU ≤ WAD ∧ liqU ≤ WAD`; `JT_REDEEM` ⟹ `covU ≤ WAD`; `LT_REDEEM ∧ covU_pre < liqThreshold` ⟹ `liqU ≤ WAD`; and no gate is enforced on any other op (verified by constructing breach states where exempt ops still succeed) | H,U | both directions: enforcement and exemption |
| I10 | Max inversions: `maxDeposit()` deposited exactly succeeds; `maxDeposit() + slack + 1` reverts, `slack` = the documented dust terms of F15 (similarly maxRedeem/maxJTWithdrawal/maxLTWithdrawal). The `+2 wei` at `:422` gets a dedicated boundary vector | F,U | |
| I11 | Preview parity: same block, `previewDeposit/previewRedeem/previewDepositMultiAsset/previewRedeemMultiAsset` == executed results **exactly** for all six flows (multi-asset previews via staticcall-style snapshot-revert) | H,F | |
| I12 | State-machine legality: in FIXED_TERM every op in §1.2's forbidden set reverts `DISABLED_IN_FIXED_TERM_STATE` and sync yields `fees == prem == 0`; transition predicate equals §1.4's formula recomputed by RoycoTestMath | H,U | |
| I13 | Share-price monotonicity: `p_st = stE/S_st` non-decreasing across any op/sync **except** syncs where uncovered loss hit (`jtE==0`); `p_jt = jtE/S_jt` non-decreasing except JT-loss/coverage syncs; `p_lt = ltEffNav/S_lt` non-decreasing except venue-loss syncs. Deposit/redeem alone never move any price by more than the derived floor-dust bound `⌈p⌉/min(S)` | H | the anti-dilution invariant |
| I14 | Sync liveness: after any handler sequence, `syncTrancheAccounting()` succeeds (given oracle healthy). No sequence of legal ops may brick sync | H | R2; failures are P0 findings |
| I15 | Idle-premium conservation: `Σ premiumSharesMinted == idle + Σ reinvestedShares + Σ idleSharesPaidToRedeemers` (ghost ledger) | H | |
| I16 | `ltRawNAV` excludes idle: `ltR == ⌊TVL·ownedBPT/bptSupply⌋` and `ltEffNav == ltR + ⌊idle·stE/S_st⌋`; liqU uses `ltR` only | U,F | |
| I17 | Boundary semantics: first deposit mints `value` shares 1:1 (clamp exempt); `totalValue==0 ∧ supply>0` mint uses the 1-wei denominator clamped by the F9 mint-dilution cap (one mint owns ≤ (1−1e-12) of post-mint supply) — behavior pinned by unit vectors (`test/unit/market/MintDilutionClamp.t.sol`, RoycoTestMath.t.sol clamp vectors) and bounded in handler (no overflow, no free value: post-state still satisfies I1/I2) | U,H | |
| I18 | Sync idempotence: two syncs in one block with unchanged raw NAVs ⇒ second is a no-op (no fee/premium double-charge; same-block branch F23 pays only on real gain) | U,F | |
| I19 | Accrual-window integrity: `twAcc` resets iff `premiumsPaid`; `lastPremiumPaymentTimestamp` updates iff reset; `Σ accrual Δt == now − lastPremiumPayment` (contiguity — precondition of I6) | H | |
| I20 | AuthZ/pause/blacklist/whitelist: non-role callers revert on every `restricted` entry; paused ⟹ all mutating entries revert and all `max*` return 0; blacklisted `from`/`to`/`caller` cannot transfer/deposit/redeem (`BlacklistLogic`, `RoycoDayKernel.sol:529-555`); with `ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER`, a non-whitelisted `_to` reverts `ACCOUNT_NOT_WHITELISTED_TRANCHE_LP` (`:550`) and blacklist takes precedence over a passing whitelist check | U,F | exhaustive selector sweep generated from ABI |
| I21 | Zero-liquidity reduction: a market with `minLiquidityWAD == 0` (and `maxLTYieldShareWAD == 0`) is observationally equivalent to a plain ST/JT market — for any op/PnL sequence never touching LT entry points: identical `{stE, jtE, IL, covU, marketState}` trajectory to the same sequence on a market where the LT is never funded, `liqU == 0` throughout (`UtilizationLogic.sol:70`), `ltLiquidityPremium == 0` on every sync, and no LT gate ever binds. This is the repo's own P1 acceptance criterion (CLAUDE.md build sequence) | H,U | run the full handler suite on the reduction market as its own profile |
| I22 | Multi-asset atomicity: any revert inside `ltDepositMultiAsset`/`ltRedeemMultiAsset` (venue min-out breach at `DepositLogic.sol:357`/`RedemptionLogic.sol:196`, venue failure, post-op gate at `RoycoDayAccountant.sol:326-333`, op-shape check `:245-283`) leaves state byte-identical to pre-call: no partial senior mint (`DepositLogic.sol:353`), no partial idle-pile debit (`RedemptionLogic.sol:192`), no owned-asset credit. Verified by revert injection per leg + full state snapshot equality | H,U | report §6.2-I6, restated for Day's two multi-asset flows |

### Handler design (`DayMarketHandler`)

Skeleton: [`test/scaffold/DayMarketHandler.sol`](../test/scaffold/DayMarketHandler.sol).

- **Actors**: 3 ST LPs, 2 JT LPs, 2 LT LPs, 1 external Balancer LP/swapper, 1 admin, 1 keeper (sync/reinvest). Selected via bounded actor index.
- **Ops (weighted)**: stDeposit 15, stRedeem 10, jtDeposit 10, jtRedeem 8, ltDeposit 6, ltDepositMultiAsset 6, ltRedeem 6, ltRedeemMultiAsset 6, sync 10, reinvest 4, warp(1s–30d) 10, stPnL(±300bps) 8, jtPnL(±300bps) 4, ltPnL(±300bps) 4, adminParamNudge 2, externalPoolOp 1.
- **Ghost variables**: per-asset in/out transfer sums (I2), premium mint/reinvest/payout ledger (I15), IL event log (I5), per-tranche share-price high-water marks + loss-event flags (I13), accrual-window ledger (I19), last committed `SyncedAccountingState`.
- **Every handler op ends with**: try-sync (I14) + assert I1/I2/I13/I16 on committed state.
- **Naive-handler failure modes and mitigations** (each becomes a `modes/` profile):
  1. *Never any loss* → invariants trivially hold. Mitigation: PnL ops are first-class weighted actions on the mock rate, with a `stressed` profile weighting losses 3×.
  2. *Never crosses covUtil = 1 or the liquidation threshold* → gates untested. Mitigation: "aimed" ops — `depositExactlyMaxST()` (uses `maxDeposit()` output), `loseUntilLiquidation()` (computes the rate drop that sets `covU ≥ liqThreshold` from the closed form F7 and applies it).
  3. *Never enters FIXED_TERM* → half the state machine dead. Mitigation: `coveredDrawdown()` composite op (ST loss < jtE, then sync).
  4. *Premium never stages* → I15/I8 vacuous. Mitigation: MockVenue slippage mode toggled by handler so reinvestment alternates pass/fail; a profile with reinvest permanently failing grows the idle pile.
  5. *Zero-supply/empty-vault states unreachable* → F9 edges dead. Mitigation: `fullExit(tranche)` op; setUp variant that starts pre-seed.
  6. *Reverts silently swallowed* → weak. Rule: handler ops may only `vm.assume`-skip on **predicted** reverts (recomputed gate from RoycoTestMath); an unpredicted revert fails the run. This is the anti-early-return rule applied to handlers.

Profiles: calm / stressed / liquidation, plus the I21 reduction profile (zero-minLiquidity market, LT ops disabled, trajectory compared to a plain ST/JT run).

---

## 4. Layer-by-layer plan

### 4.1 Unit / golden vectors

Every formula F1–F24 gets vectors with hand-derived expected values in comments (derivation shown, rounding direction stated). Mandatory boundary set per formula: `0`, `1 wei`, max realistic (1e30 NAV guard), exact-threshold (`covU == WAD`, `liqU == WAD`, `covU == liqThreshold`, `IL == dust`, `IL == dust+1`), first depositor, empty vault, `supply>0 ∧ NAV==0`.

Priority blocks (order = risk rank):
1. **Waterfall matrix** (R1): 3(ΔST) × 3(ΔJT) × {IL=0, 0<IL≤dust, IL>dust} × {PERPETUAL, FIXED_TERM} — 54 deterministic vectors through `preOpSyncTrancheAccounting` with MockYDM pinned; each asserts full `SyncedAccountingState` field-by-field vs hand math, incl. the JT-fee recomputation branch (`:564-567`) and same-block instantaneous branch (`:597-619`).
2. **Premium/fee carve-out + LT NAV** (R5): F11 vectors incl. `premium+fee == stE` degenerate; I7/I8 checks; idle-pile redemption vectors incl. the zero-BPT/nonzero-idle edge (Appendix B.2).
3. **Gates and max*** (R4): F15–F17 inversion vectors at exact thresholds; enforcement-flag matrix of I9 (both directions).
4. **Self-liq bonus** (R8): F19 vectors at `covU == liqThreshold` exactly, `jtE == 0`, bonus clamped by each of the three min-terms in turn.
5. Quoters (R6): per-cell decimal vectors for F22, oracle-mode reverts — including staleness *through the flow* (warp past threshold with a non-refreshing mock → `stDeposit` and sync revert `STALE_PRICE`), not just in quoter isolation.
6. YDMs (R9): curve points at `u ∈ {0, kink−1, kink, kink+1, WAD, WAD+1}`, adaptation over `{0, 1s, 1d, 5y}` elapsed, clamp boundaries.
7. State machine, auth, pause, blacklist/whitelist, tranches, factory/deploy wiring (extend existing `DayMarketDeploymentTest`). Includes the pause-interaction matrix: per entry point paused/unpaused behavior, `max*` zeroing, and the pinned behavior that all `withSyncedAccounting` setters revert while the kernel is paused (§1.7-13, Appendix B.8).
8. Negative guard vectors + events (§1.7-9/10): one firing test per custom error across accountant/kernel/tranches/quoters (generated from the ABI error inventory; `NAV_CONSERVATION_VIOLATION` fired via a mock-kernel harness passing a non-conserving tuple; constructor wiring guards `TRANCHE_AND_KERNEL_ASSETS_MISMATCH`/`JT_MUST_BE_COINVESTED` via bad deployments); exact-arg `vm.expectEmit` for every money-path event (`TrancheAccountingSynced`, `LiquidityTrancheRawNAVCommitted`, `FixedTermCommenced/Ended`, `JuniorTrancheCoverageImpermanentLossReset`, yield-share accrual events, tranche `Deposit`/`Redeem`/`MultiAssetDeposit`/`MultiAssetRedeem`). Exception: `PREMIUMS_EXCEED_SENIOR_YIELD` gets an unreachability argument (I6/I19), not a firing test.
9. Reduction + fee boundaries (§1.7-8): the I21 zero-minLiquidity equivalence vectors; fees at 0 and `MAX_PROTOCOL_FEE_WAD` (100%), including the zero-denominator fee-share mint edge where `(ltEffectiveNAV − ltProtocolFee)` → 0 routes through F9's 1-wei branch (`FeeAndLiquidityPremiumLogic.sol:68-72`, `ValuationLogic.sol:106`).

### 4.2 Fuzz (per-function properties — stated as equations)

Global rules: `bound()` only, with a comment stating the induced distribution; **no `if (…) return`** — if an input is invalid, either bound it away or assert the revert. Bounds: NAVs `[0, 1e30]` wad, decimals per cell, bps deltas `[−10_000, 10_000]`, elapsed `[0, 10y]`.

| Target | Property (assertion) |
|---|---|
| `_attributeDeltaToClaimOnRawNAV` | `attributed == RoycoTestMath.attribute(...)` ∧ `|attributed| ≤ |Δ|` ∧ `sign(attributed) ∈ {0, sign(Δ)}` ∧ `attr(claim) + attr(lastRaw−claim) ∈ [Δ−1, Δ]` (floor split) |
| full sync (fuzzed raw deltas) | `state == RoycoTestMath.waterfall(pre, Δ)` field-exact; plus I1, I3, I4, I6 |
| `_computeSTFeeAndLiquidityPremiumSharesToMint` | supply after == pre + both share counts; `|valueFor(premShares) − prem| ≤ ε` and `|valueFor(feeShares) − fee| ≤ ε`, ε per I8 (two-sided); shares themselves match RoycoTestMath floors exactly |
| `_convertToShares/_convertToValue` | round-trip: `valueFor(sharesFor(v)) ∈ [v − ⌈totalValue/supply⌉ − 1, v]`; monotonicity in `v` |
| `covUtil/liqUtil` | exact equality with RoycoTestMath incl. all four zero-edges; `⌈⌉` bias: `utilization·denominator ≥ numerator·WAD` |
| `maxSTDeposit` then deposit | deposit(max) succeeds ∧ post `covU ≤ WAD ∧ liqU ≤ WAD`; deposit(max + slack + 1) reverts |
| `maxJTWithdrawal/maxLTWithdrawal` | same inversion shape (slack documented from F16/F17 terms) |
| deposit pricing (each tranche) | `shares == ⌊value · S_pre / navPre⌋` with `value == RoycoTestMath` quote of assets; depositor cannot gain: `valueFor(shares, S_post, navPost) ≤ value` |
| redeem claims | `claims == scaleClaims(totalClaims, shares, S)` exact; redeemer cannot extract > pro-rata + bonus |
| selfLiqBonus | `covU_post ≤ covU_pre` whenever bonus > 0 (the documented invariant, fuzzed over full state space) |
| preview parity (×6 flows) | exact equality, same block |
| StaticCurveYDM | `y == RoycoTestMath.staticYdm(u)`; piecewise-linear: y(kink⁻)≤y(kink); cap at WAD |
| AdaptiveCurveYDM_V2 | output ∈ `[max(0, avgYT − FD), min(WAD, avgYT + FP)]`; `previewYieldShare == yieldShare` return value; state-freeze in FIXED_TERM; expWad clamp never reverts for elapsed ≤ 100y |
| accrual | I19 relation under fuzzed op/warp interleavings |
| tranche `_update` | blacklist/whitelist matrix: revert iff predicate says so |

### 4.3 Stateful invariant

Implements §3 via `DayMarketHandler`. Foundry native. Profiles: CI `runs=256, depth=64, fail_on_revert=false` (handler-predicted reverts only — see rule 6); nightly `runs=2048, depth=256` plus the four weight profiles (§3) × token cells A–D. Add Medusa/Echidna in Phase F for coverage-guided depth on the same handler (handler written vm-agnostic where possible).

### 4.4 Differential

Two oracles, two tolerance regimes:
1. **`RoycoTestMath` (primary, exact).** Same-language independent reimplementation; tolerance: **0** for every integer formula (it mirrors rounding). Used inside unit/fuzz layers — this is the main defense against R1.
2. **`royco-day-simulator` (trajectory oracle, bounded).** The TS engine mirrors the waterfall/YDM/LT spec but in IEEE-754 floats with documented drift (its own audit reports conservation residual ≤ 1.5e-8 rel). Use: generate N scenario trajectories (op sequences + PnL paths) in the simulator, replay through the Solidity market in a Foundry script, compare per-step `{stE, jtE, IL, covU, liqU, premiums}` with **relative tolerance 1e-6 per step, non-accumulating** (re-anchor simulator state to on-chain state each step so float drift cannot compound); flag any step where direction disagrees (sign of ΔstE etc.) regardless of magnitude. Formulas the simulator admits it approximates (cross-claim attribution) get direction-only… no — get *excluded* from magnitude comparison and covered exclusively by oracle 1; exclusion list checked into the differential harness with justification per entry.

### 4.5 Symbolic (Halmos; Kontrol as stretch for the waterfall)

| Target | Property |
|---|---|
| `UtilizationLogic._computeCoverageUtilization/_computeLiquidityUtilization` | ceil bias, zero-edge totality (never reverts), monotonicity in numerator/denominator |
| `ValuationLogic._convertToShares/_convertToValue` | round-trip loss bound (I8's ε), no revert for `supply,value ≤ 2^128` |
| `_attributeDeltaToClaimOnRawNAV` | `|out| ≤ |Δ|`; split additivity within 1; totality given `claim ≤ lastRaw` |
| `_computeSTFeeAndLiquidityPremiumSharesToMint` | joint-pricing: neither carve-out dilutes the other (price equality cross-mul within 1) |
| `TrancheClaimsLogic._computeSTandJTClaimsOnNAV` | given I1 precondition: four claims ≥ 0, `stCl_st + jtCl_st == stR`, `stCl_jt + jtCl_jt == jtR` |
| `SelfLiquidationLogic._computeMaxCoverageUtilizationNeutralBonus` | `covU_post ≤ covU_pre` for the returned bound (the `:73-89` derivation, machine-checked) |
| `StaticCurveYDM._yieldShare` | `y ≤ WAD`; continuity at kink within slope-floor dust |
| Waterfall core (extracted pure harness of `:500-651`) | I1 (conservation) and I3 (priority) for symbolic 128-bit inputs — Kontrol if Halmos times out |

### 4.6 Mutation

Tool: **Gambit** (Certora) generating mutants for `src/accountant`, `src/libraries/logic`, `src/ydm`; kill-suite = unit + fuzz (CI profile). Gate: **≥90% mutants killed** on those paths (rounding-direction flips, `<`↔`<=`, operand swaps are exactly the R1 bug class; a floor→ceil mutant that survives means an assertion is tolerance-sloppy). Cadence: weekly scheduled job + mandatory before audit handoff; not per-PR (runtime). Record a baseline score at end of Phase B and re-measure after Phase F — the delta is the quantitative evidence the assertion standard works (report §5.6's before/after method).

### 4.7 Fork

Pinned-block policy: one canonical mainnet block per integration, bumped monthly by PR (never floating). Add an `[rpc_endpoints]` block to `foundry.toml` referencing the env vars so fork suites fail loudly when RPC is unset instead of silently skipping (§1.7-17). List:
- Balancer V3 vault + a real Gyro E-CLP pool + `LPOracleBase` oracle: full LT lifecycle (deposit BPT, multi-asset join/exit, reinvest against real pool math, hooks sync path with a real external router). This is the only layer where F20/F21 meet real math.
- Neutrl snUSD + RedStone feed (existing `Neutrl_snUSD.t.sol` config): ST/JT ERC4626+Chainlink quoting, staleness behavior at the pinned block.
- USDC (6-dec) and USDT (missing-return) as quote legs of the real pool.
- Chainlink sequencer-uptime path on an L2 fork (Arbitrum) if markets deploy there [UNVERIFIED — deployment targets; confirm chains before building].

**IMPLEMENTED (2026-07-06): the deep Balancer-venue fork batteries** (`test/fork/balancer/base/*`, ~49 tests, chained under the `Neutrl_snUSD` leaf so one config carries the kernel battery plus the venue batteries): A real E-CLP swaps + hook coupling (band-exact execution pricing, fee-to-BPT within derived bounds, pause blast-radius, range-boundary reverts, capacity/band geometry); B `getRate` rate-provider coherence (committed NAV-per-share equality, transient-cache freeze, WITH_RATE wiring via `getPoolTokenRates`); C real `computeTVL` (TVL∈[MtM·α, MtM] band, manipulation resistance quantified as fee-bounded TVL vs 10x composition moves, rate-leg composition, mid-`unlock` read); D external LP via the canonical Router (hook sync, kernel-ledger isolation, the single-sided-add leak law, invariant-ratio cap); E the liquidity gate on real oracle numbers (ceil-mirror equality across states, bind/release at WAD, yield-driven breach); F reinvest decomposition (wealth-conservation identity, leak law through the production path, gate flip at the measured haircut, shipped-10bp grounding, invariant-ratio-cap tolerated failure); G proportional-remove composition after skew; H FIXED_TERM x pool liveness. Key derived law (verified on fork, documented in `BalancerVenueForkBase._expectedSingleSidedAddLeak`): a single-sided add of value V leaks `(1-w)·V·(f + (1-q))` — imbalance fee plus INTERNAL-price absorption — the dominant term is the internal price gap, not the fee. Real-math facts pinned: single-sided ADDS never trip `AssetBoundsExceeded` (the range wall binds swaps only; the slippage gate is the only deploy protection on a skewed pool), and the venue's genuine reinvest failure mode is the 5x invariant-ratio cap. New spec-divergence pins: `test_FINDING_8` (swaps are NOT blocked in the sync block — CLAUDE.md's same-block-swap rule is unimplemented), `test_FINDING_9` (through-pool rate-staleness LVR is structurally impossible: the hook sync + the Vault's post-`onBeforeSwap` rate reload refute the CLAUDE.md arb for pool flows), `test_FINDING_10`/`10b` (the pool LP set is permissionless and the liquidity gate is depth-blind in BOTH directions: external exits drain real depth without moving the gate, external adds cannot release a binding gate — answers the CLAUDE.md "Pool permissioning" open item).

### 4.8 Port vs rewrite (default: rewrite)

| Legacy asset | Decision | Justification |
|---|---|---|
| `Assertions` typed helpers | port | mechanical, already re-exists in `test/base/Assertions.sol` |
| 3×3 delta-matrix *structure* | port structure, rewrite assertions | structure is the right enumeration; legacy assertions include sign-only checks — every ported vector gets hand-derived expected values |
| savUSD attribution-bug PoC scenario | port as golden vector | regression value; re-derived numerically for Day's accountant |
| YDM curve tests (Static/Adaptive) | port with re-derived expectations | same contracts family; replace `assertApproxEqAbs(…,1e12)` tolerances with derived bounds |
| Abstract kernel suite shape | keep (already in repo), re-found on TrancheFixture | fork-config pattern is good; 18-dec hardcoding is not |
| Everything else (~1,200 tests) | rewrite | early-return/assume patterns and circular preview checks disqualify wholesale porting; cheaper to regenerate against RoycoTestMath than to audit each |

---

## 5. CI and quality gates

| Gate | Threshold | Justification |
|---|---|---|
| Line coverage (src/accountant, src/libraries/logic, src/ydm) | ≥ 98% | pure math, no excuse |
| Branch coverage (same) | ≥ 95% | below-95 exceptions require a written unreachability note (e.g. `stProtocolFee` zeroing at `:690` marked "Formality") |
| Branch coverage (kernel, tranches, quoters, auth) | ≥ 90% | some Balancer-callback branches only reachable on fork; fork layer counted in nightly coverage merge |
| Branch coverage (factory/templates/scripts) | ≥ 80%, scripts excluded | deploy assertions live in DayMarketDeploymentTest |
| Mutation score (accountant+logic+ydm) | ≥ 90% killed | §4.6 |
| Fuzz runs | PR: 1,000/test (override `[profile.ci.fuzz] runs`); nightly: 50,000 + 4 token cells | current repo default of 200 (`foundry.toml:54`) is a smoke setting, not a gate |
| Invariant | PR: 256×64; nightly: 2048×256 × 3 profiles × cells A–D | §4.3 |
| Weak-assertion lint | CI grep-based deny + review checklist | deny in `test/` (scaffold excluded): `assertTrue(true)`, `assertGt(*, 0,` without adjacent `// direction-only:` justification tag, `assertApproxEq*` whose tolerance operand is a literal not named `*_DERIVED_BOUND`/`maxNAVDelta()`, `return;` inside a `test`/`testFuzz` body, bare `vm.expectRevert()` |
| `vm.assume` budget | rejected-input rate < 20% per test (forge reports); every assume has a justification comment | prevents silent input-space collapse |
| Assertion-strength distribution artifact | grep-derived macro counts (`assertEq` / `assertGt` / `approxEq` / `expectRevert`) published per PR as a trend artifact | makes sign-only drift visible before review (report §2′ method); informational, non-blocking |
| `vm.mockCall` ban on quoting paths | CI grep: no `vm.mockCall` targeting quoter/oracle/venue selectors in `test/` | mock-setter discipline (§2.4); prevents the staleness-gate-defeat anti-pattern |
| Param-sweep totality | `MarketParams.sol` field→test map stays total (CI grep) | no-frozen-parameters rule (§2.2) |
| Gas snapshots | `forge snapshot` diff posted, informational, non-blocking | per prompt default |
| Build | `forge build` + lint config as-is; symbolic and mutation excluded from PR path | runtime |

---

## 6. Phased implementation roadmap

Effort in engineer-days (ED), single senior test engineer, assumes strategy approved as-is.

| Phase | Content | Depends on | Effort | Exit criteria (measurable) |
|---|---|---|---|---|
| **A** | `TrancheFixture`, `TokenConfigs` cells A–I, all six mocks, `RoycoTestMath` skeleton, CI skeleton (profiles, lint greps, coverage job) | — | 6 ED | fixture deploys a full market in cells A–D; `forge test` green on a smoke test per cell; CI runs matrix and lint |
| **B** | Unit + golden vectors for core accounting (§4.1 blocks 1–4) + `RoycoTestMath` completion; **blocks everything downstream** because the expected-value machinery is validated here | A | 10 ED | all 54 waterfall vectors + carve-out/gate/bonus vectors pass with literal hand-derived expectations; RoycoTestMath output == literals on every vector; branch coverage on accountant ≥ 90% already |
| **C** | Fuzz layer (§4.2, full table) in cells A–D | B | 8 ED | every listed property implemented; 50k-run nightly green 3 consecutive nights; assume-rejection < 20% everywhere |
| **D** | Invariant handler + catalog (§3), 4 profiles (calm / stressed / liquidation / I21-reduction) | B (C parallel-ok) | 8 ED | all 22 invariants have a passing handler run at 2048×256; forced-regime profiles demonstrably reach: FIXED_TERM, covU>WAD rejection, liquidation breach, staged-premium > 0, zero-supply (assert via ghost coverage counters); the I21 reduction profile matches a plain ST/JT trajectory |
| **E** | Heterogeneous matrix expansion: cells E–I across B–D layers; expected-failure cell G documented | B,C,D | 4 ED | nightly matrix green; cell G produces the documented revert; per-cell coverage report |
| **F** | Differential (RoycoTestMath replay harness + simulator trajectories), symbolic specs (§4.5), mutation baseline + gate | B–D | 8 ED | 100 simulator trajectories replayed within tolerance; all §4.5 properties proven or documented-timeout; mutation ≥ 90% or gap list ticketed |
| **G** | Fork suite (§4.7) | A (+ real-market configs) | 5 ED | LT lifecycle green against real Balancer at pinned block; snUSD suite green; monthly block-bump job wired |

Total ≈ 49 ED. Critical path A→B→{C,D}→E.

---

## Appendix A — [UNVERIFIED] items for human review

1. `LPOracleBase.computeTVL()` manipulation-resistance properties and return-value decimals — taken from Balancer's vendored implementation and the subagent's read; the fork layer (Phase G) is specified to validate empirically. Confirm the oracle contract actually deployed per market matches `lib/balancer-v3-monorepo`'s `LPOracleBase`.
2. Deployment chains (mainnet only vs L2s) — affects sequencer-uptime fork tests (§4.7).
3. Whether any governance/config layer excludes fee-on-transfer and rebasing underlyings at market-creation time; no code-level guard was found in `DepositLogic` (it credits face amounts, `DepositLogic.sol:229,265,299`). Cell G assumes exclusion-by-policy and tests the failure mode.
4. Factory/template internals (`src/factory/*`) were reviewed only via the existing deployment tests, not line-by-line; role-wiring invariants (I20, R11) cite behavior asserted in `test/deploy/DayMarketDeploymentTest.sol`.
5. Venue-layer file:line citations in §1.2/§1.3 rows F20–F21 and the hooks row were produced by a subagent read of those files; spot-checked for consistency but not re-read line-by-line by the author of this document.

## Appendix B — Possible protocol findings (not test-designed-around; flagged for the team)

1. **Doc/code divergence — liquidity gate on senior deposits.** CLAUDE.md states "Deposits are never liquidity-gated / no deposit is ever blocked on liquidity," but `postOpSyncTrancheAccounting` enforces `liquidityUtilizationWAD ≤ WAD` for `ST_DEPOSIT` (`RoycoDayAccountant.sol:331-333`) and `maxSTDeposit` binds on the liquidity requirement (`:373-383`). Code is the more conservative behavior; either the spec or the code should change. Tests will pin current code behavior with a note.
2. **In-kind LT redemption can revert when the BPT slice floors to zero.** For a small `_shares` redemption where `⌊ltAssets·shares/S⌋ == 0` but `⌊idle·shares/S⌋ > 0` (or where the LT holds only idle shares and no BPT), `deltaLTRawNAV == 0` and `totalSTAndJTRedemptionNAV == 0`, failing `require(deltaLTRawNAV < 0 || …)` at `RoycoDayAccountant.sol:262` → `INVALID_POST_OP_STATE(LT_REDEEM)`. Transferring idle ST shares moves no raw NAV, so such redemptions appear bricked until BPT depth exists. Needs a product decision (allow? round up BPT slice?).
3. **No auction fallback / staged-buffer bound / same-block-swap rule in code.** CLAUDE.md describes a Dutch-auction deploy fallback, a staged-buffer bound, and blocking swaps in the sync block. Implemented reality: gated single-sided reinvest with tolerated failure (`BalancerV3VenueLogic.sol:186-196`), an unbounded idle pile, and hooks that *sync before* external ops rather than block them (`RoycoDayBalancerV3Hooks.sol:79-127`). The strategy tests what exists; the deltas are listed here so nobody assumes test coverage of unimplemented mechanisms.
4. **`_convertToShares` zero-NAV branch uses a 1-wei denominator** (`ValuationLogic.sol`): a deposit into a tranche with live supply and zero NAV dilutes the unbacked holders. STATUS (amended): the unbounded `supply × value` mint was confirmed catastrophic by the invariant campaigns (three wipe-and-deposit cycles pushed the JT supply to ~1e77, after which every further mint — deposits and the sync's own fee mint — panics, permanently bricking the market) and is now bounded by the **mint-dilution clamp**: a single mint owns at most `(1 − 1e-12)` of the post-mint supply (`MINT_DILUTION_RESIDUAL_WAD`, `Constants.sol`, rationale in its comment), clamping (never reverting) with bind-first ordering so the fair-shares mulDiv cannot panic first. Residual risk, accepted by decision (no absolute supply ceiling): the cap computation itself overflows once supply ≳ 1.158e65, so ~4 total-wipe cycles still end in a Panic — pinned by `test_FINDING_11` in `test/unit/findings/SpecDivergences.t.sol`. I17 pins the clamped behavior.
5. **`PREMIUMS_EXCEED_SENIOR_YIELD` as a liveness cliff** (`RoycoDayAccountant.sol:624`): reachable only if the accrual-window contiguity argument (I19) breaks — e.g. any future path that resets `lastPremiumPaymentTimestamp` without clearing accumulators, or `setMaxYieldShares` semantics changing mid-window. Currently believed unreachable; I6/I19 exist to keep it that way and to catch regressions.
6. **`TrancheType`/ordinal comment drift**: `Types.sol:122` says ordinals are "appended to preserve … compatibility with live markets," while the repo principle says ordinals were chosen fresh. Cosmetic, but one of them is wrong.
7. **FoT/rebasing underlying breaks op-shape/solvency invariants** (see Appendix A.3): `stDeposit` credits `_assets` as received (`DepositLogic.sol:229`) with no balance-diff check; a fee-on-transfer underlying silently over-credits `stOwnedYieldBearingAssets`. If policy excludes such tokens, consider an on-chain balance-diff assertion anyway; cell G documents the failure.
8. **All accountant parameter setters brick while the kernel is paused.** Every config setter (`setSeniorTrancheProtocolFee` … `setJuniorTrancheDustTolerance`, `RoycoDayAccountant.sol:844-947`) carries `withSyncedAccounting`, whose modifier (`:42-45`) calls `IRoycoDayKernel(KERNEL).syncTrancheAccounting()` unguarded; the kernel's sync is `whenNotPaused` (`RoycoDayKernel.sol:309-320`), so during an emergency pause governance cannot adjust fees, coverage, liquidity, liquidation threshold, term duration, or dust tolerances — only the two YDM swap setters survive (raw call with tolerated revert, `:822,836`). If pausing is expected to coexist with parameter remediation, this needs a bypass (or is fine and should be documented as intended). Tests pin current behavior either way. (Surfaced by the report's pause-mid-flow pattern A15; verified here directly.)

## Appendix C — Agent working-notes cache (`docs/testing/agent-notes/`)

Dense, file:line-cited working notes produced during the AbstractKernelTestSuite build (2026-07-04) and cached so future work (agent or human) starts from them instead of re-reading the tree. Citations reflect the tree at that date — verify line numbers before relying on them.

| File | Contents |
|---|---|
| `docs/testing/agent-notes/01-kernel-flows-map.md` | Every kernel entrypoint (signature, caller, modifiers, state gating, enforcement flags, min-outs), preview/max functions and their execution counterparts, every custom error + firing condition, money-path events, per-Operation op-shape checks, owned-asset accounting movements, zero-amount edges |
| `docs/testing/agent-notes/02-accountant-map.md` | Full sync pipeline order, PERPETUAL/FIXED_TERM machine, the gate matrix per Operation (coverage/liquidity/liquidation-bypass), max* closed forms incl. dust slack, errors, events, `SyncedAccountingState` fields, admin setters |
| `docs/testing/agent-notes/03-test-infra-map.md` | BaseTest inherited-member inventory, typed assertion helpers, IKernelTestHooks seams, tranche-facing call surface with unit types, roles/actors/pranking, LT call surface |
| `docs/testing/agent-notes/04-venue-quoter-map.md` | ltRawNAV computation, reinvestment gate + tolerated-failure semantics, multi-asset venue paths, hooks sync carve-out, transient quoter cache invariance, venue-neutral vs venue-specific observables |
| `docs/testing/agent-notes/05-battery-design-summary.md` | The kernel-suite battery design at a glance: sections, helper inventory, key decisions |
| `docs/testing/agent-notes/06-battery-spec-full.md` | The complete AbstractKernelTestSuite battery spec: every helper signature and every test with arrange/act/assert detail (the file the authoring agents implemented from) |
| `docs/testing/agent-notes/07-adversarial-findings.md` | Verified findings from the adversarial review of the finished suite, incl. any REAL protocol findings surfaced by failing assertions (written when the build workflow completes) |
| `docs/testing/agent-notes/08-accountant-property-map.md` | The complete testable-property map of RoycoDayAccountant (harness architecture, properties A1-J9 with line cites, branch inventory, the two documented-unreachable branches) driving `test/accountant/Accountant.t.sol` |
| `docs/testing/agent-notes/09-phase-a-spec.md` | Phase A authoring spec: exact mock surfaces (`test/mocks/`, one per file), the manual TrancheFixture deploy recipe (factory path is fork-only), TokenConfigs cells with the cell-D redefinition (identical-assets kernel constraint), RoycoTestMath skeleton scope, smoke-test exit criteria |
| `docs/testing/agent-notes/10-royco-test-math-phase-a.md` | RoycoTestMath Phase A record: implemented-vs-stub split, the design decisions taken where §1.3's English underdetermined the math (F7/F8 zero-edge precedence, carveOut via F9 edges, staticYdm branch-at-target and double-floor semantics), and the Phase B TODO checklist |
| `docs/testing/agent-notes/12-waterfall-golden-matrix-spec.md` | Phase B spec for §4.1 blocks 1-4: the normative sync pipeline order (P0-P9 with verified line cites and the premiums-imply-PERPETUAL sharpening), WaterfallIn/Out struct mapping with required amendments (4th fee rate, instantaneous-branch inputs), the three Phase-A seam calibrations (all confirmed), the 54-cell matrix (regimes R1-R6 with staging routes, hand-derived expected tuples, W55-W60 auxiliaries), and the block 2-4 vector enumerations |
| `docs/testing/agent-notes/13-spec-divergence-findings.md` | The live spec-divergence ledger: numbered production-vs-CLAUDE.md divergences (spec quote, actual, file:line, severity, `test_FINDING_*` pin each) — findings 1-2 retracted with the retraction evidence, finding 3 (zero-BPT-slice LT redeem, Appendix B.2), findings 4-7 (ST deposits liquidity-gated, JT redemption without the liquidation bypass, setters bricked while the kernel is paused, the FIXED_TERM deposit intra-spec contradiction). Extend, never duplicate — pins live in `test/unit/findings/SpecDivergences.t.sol` and `test/unit/accountant/CarveOut.t.sol` |
| `docs/testing/agent-notes/14-phase-ab-build-report.md` | Phase A+B build report: fixture recipe decisions (identical-assets + forced-jtCoinvested constraints, auto-seed circularity, sorted pool registration, wei-exact genesis), mock fidelity model, vector counts (28 smoke, 117 RoycoTestMath self-vectors incl. 17 W-cells, +33 matrix tests, blocks 2-4 = 10/8/10), the 19-finding review and the over-refutation correction (findings 4-7 remediation), final suite counts, Phase C-F carry-forwards. Also holds the fixture build record that would have been note 11 (never written separately, numbering jumps 10 → 12) |
| `docs/testing/agent-notes/17-test-conventions.md` | The consolidation contract for the audit/prune/refine pass: taxonomy and conventions modeled exclusively on royco-iam's RecipeMarketHub tests (concrete/fuzz mirrors, layered utils bases, Test_/TestFuzz_/RevertIf_ naming), Day-specific extensions (invariant/symbolic/scenarios/fork layers), prune rules, and the current→target migration map |

Maintenance rule: any future multi-agent workflow over this repo caches its reconnaissance maps, specs, and verified findings here (numbered, one file per artifact) and keeps this table current.
