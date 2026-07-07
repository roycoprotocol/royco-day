# Royco Day — Known Issues

Canonical catalog of every known issue in the Royco Day codebase, compiled from the protocol
team's `FINDINGS.md` register and two independent audits (a full-codebase security audit and a
test-coverage audit), re-verified against the current `src/` after the `cb085e32` pull (2026-07-07).

Each issue lists its mechanism, `file:line`, severity, status, and the pinning test (where one
exists). This document supersedes the prose in `FINDINGS.md`, which documents only a subset of the
findings the test suite actually pins.

**Status legend** — *Confirmed*: a real divergence from spec/intent, pinned to current behavior.
*Intended*: documented behavior pinned as a regression guard. *Informational*: a trust-model or
by-design property, not a defect. *Pinned*: has a runnable `test_FINDING_<n>`/`check_*` test asserting
current behavior; *Unpinned*: documented only.

`src/` is intentionally unmodified — the fixes are the protocol team's decision. Pinning tests assert
**current** behavior and document the **spec-expected** behavior in a comment, so CI stays green while
the divergence stays visible.

---

## 1. Severity summary

| Severity | Count | Findings |
|---|---|---|
| Major | 1 | 11 (whitelist-market brick — config-gated, OFF in shipped config) |
| Medium | 1 | 5 (JT redeem stays coverage-gated post-breach) |
| Low–Medium | 5 | 3, 6, 23, 27, and doc-severity of 4 |
| Low | ~16 | 19, 24, 25, 26, 28, 29, 30, 31, 32, 33, 34, 35, 36, 20, 21, 22, + uint64-sum edge |
| Minor | 6 | 13, 14, 15, 16, 17, 18, 11b |
| Doc-only | 2 | 7, and the doc drifts in §4 |
| Informational / by-design | — | §4 (trust-model), the fork-observed items 8/9/10 |

No critical or high-severity issues were found. The codebase is mature: the accounting core is
verified to wei precision across concrete, fuzz, symbolic, invariant, and fork layers, and the
one sync-liveness bug (the mint-dilution overflow) was closed by the clamp in `b7d04a2f`.

---

## 2. Register findings (F3–F33)

Pinned in the test suite and re-confirmed at current source lines.

| # | Mechanism | Where | Severity | Status | Pin |
|---|---|---|---|---|---|
| 3 | In-kind LT redeem whose scaled BPT+idle slice moves no ST/JT/LT raw-NAV delta reverts `INVALID_POST_OP_STATE(LT_REDEEM)`; a holder whose entire slice is staged idle premium cannot exit in-kind | `RoycoDayAccountant.sol:262-263`; `RedemptionLogic.sol:111-139` | Low-Med | Confirmed | `Test_FeeAndLiquidityPremium.t.sol:360` |
| 4 | ST deposits ARE liquidity-gated (canonical spec), contradicting the two-metrics "deposits never liquidity-gated" prose | `RoycoDayAccountant.sol:331-334,376-384`; `DepositLogic.sol:59` | Low code / Med doc | Confirmed | `Test_SpecDivergences.t.sol:78` |
| 5 | JT redeem stays coverage-gated after a liquidation breach — the breach bypass is wired only for ST/LT redeem, so junior value can bleed (self-liq bonus paid from `jtEffectiveNAV`) while JT holders are pinned | `RedemptionLogic.sol:101` vs `:137/:204`; `RoycoDayAccountant.sol:327-329` | Medium | Confirmed | `Test_SpecDivergences.t.sol:123` |
| 6 | Every accountant setter reverts while the kernel is paused (`withSyncedAccounting`→`whenNotPaused` sync); only the two YDM setters (tolerated-revert raw call) survive | `RoycoDayAccountant.sol:42-45,847-950`; `RoycoDayKernel.sol:313` | Low-Med (ops) | Confirmed | `Test_SpecDivergences.t.sol:169` |
| 7 | FIXED_TERM deposit behavior is a coherent third matrix vs two contradicting spec sentences ("disabled for every tranche" vs "enabled at all times") | `DepositLogic.sol` FIXED_TERM guards | Doc-only | Confirmed | `Test_SpecDivergences.t.sol:225` |
| 8 | Swaps are NOT blocked in the same block as a P&L sync; the implementation syncs-before-swap instead | fork venue | Informational | Confirmed | `Test_BalancerSwapRateOracleBase.t.sol:244` |
| 9 | Through-pool rate-staleness LVR is structurally impossible (the Vault reloads token rates after `onBeforeSwap`) — refutes the CLAUDE.md LVR concern for through-pool flows | fork venue; Balancer `Vault.sol:225-235` | Informational (refutation) | Confirmed | `Test_BalancerSwapRateOracleBase.t.sol:267` |
| 10 / 10b | The pool LP set is permissionless: an external LP exit drains real tradable depth while the gate stays blind, and external depth cannot release a binding gate (`ltRawNAV` counts kernel BPT only) | fork venue; `ValuationLogic.sol:43-46` | Informational (design bound) | Confirmed | `Test_BalancerLPGateReinvestBase.t.sol:165,816` |
| 11 | **Whitelist market bricks on first senior gain**: with `enforceVaultSharesTransferWhitelist=true`, the premium/fee mint whose `_to` is the kernel / fee-recipient fails the `_update` whitelist screen (those addresses hold no LP role), reverting every sync once yield accrues | `FeeAndLiquidityPremiumLogic.sol:51-52`; `RoycoDayKernel.sol:544-551`; `BalancerV3DeploymentTemplate.sol:440-444` | **Major** (config-gated; OFF in shipped `MarketDeploymentConfig.sol:251`) | Confirmed | `Test_PremiumMintDivergences.t.sol:50` |
| 11b | Mint-dilution clamp leaves a residual overflow cliff at supply ≈ 1.16e65 | `ValuationLogic.sol:117-129`; `Constants.sol:53` | Minor (accepted) | Confirmed | `Test_SpecDivergences.t.sol:306` |
| 11c | A replayed liquidation/JT-supply-inflation sequence cannot brick the sync (post-clamp regression guard) | — | Guard | Intended | `Test_JTSupplyInflationSequenceReplay.t.sol:68` |
| 12 | A griefed reinvestment stages the premium as claimable idle ST shares (not forfeited); the sync survives and `ltRawNAV` is unchanged | `BalancerV3VenueLogic.sol:181-196` | Intended (guard) | Intended | `Test_PremiumMintDivergences.t.sol:84` |
| 13 | A dust-sized senior gain (`0 < stGain ≤ dust`) pays JT/LT premiums but skips every protocol fee (fees gate on `premiumsPaid = stGain > dust`, premiums do not) | `RoycoDayAccountant.sol:594,624-646` | Minor | Confirmed | `Test_AccountantPremiumDivergences.t.sol:41` |
| 14 | Zero LT depth reads `liquidityUtilization` as `uint256.max` — a divide-by-zero sentinel that gates the first senior deposit in a fresh `minLiquidity>0` market (needs a product decision: seed invariant vs documented constraint) | `UtilizationLogic.sol:70-74` | Minor (split) | Confirmed | `Test_AccountantPremiumDivergences.t.sol:83` |
| 15 | The fixed-term end timestamp is `uint32(block.timestamp + duration)`; near the uint32 ceiling (~2106) the sum wraps below `now`, defeating the term lock | `RoycoDayAccountant.sol:705,667` | Minor | Confirmed | `Test_AccountantPremiumDivergences.t.sol:112` |
| 16 | The YDM adaptation clock's uint32 wrap slams `yieldShareAtTarget` to its min/max bound (V1/V2) | `BaseAdaptiveCurveYDM.sol` clock | Minor | Confirmed | `Test_ClockWrapDivergences.t.sol:42,93` |
| 17 | The yield-share accrual clock's uint32 wrap accrues a phantom 2^32 seconds; the premium-window wrap can make a gain sync revert `PREMIUMS_EXCEED_SENIOR_YIELD` | `RoycoDayAccountant.sol` accrual/premium clocks | Minor | Confirmed | `Test_ClockWrapDivergences.t.sol:144,185` |
| 18 | The Makina quoter's zero stored rate silently zeroes tranche NAV instead of reverting | `IdenticalMakinaShares_..._Quoter.sol:75` | Minor | Confirmed | `Test_MakinaAdminOracleQuoter.t.sol:416` |
| 19 | `setChainlinkOracle` accepts a live feed paired with a zero staleness threshold, which then bricks every read (`updatedAt >= now` only) | `IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol:178` | Low | Confirmed | `Test_AdminAndOracleGates.t.sol:110` |
| 20 | A stranger can front-run template `initialize` and `register` still succeeds; empty init arrays count as "initialized" so a later deploy reverts `CREATION_CODE_NOT_SET` | `BaseDeploymentTemplate.sol` init | Low (factory) | Confirmed | `Test_TemplateInitialization.t.sol:65,97` |
| 21 | marketId derivation collides for shifted name boundaries and same-block reruns | `DeployScript` marketId | Low (factory) | Confirmed | `Test_DeployScriptConfig.t.sol:180` |
| 22 | A zero tranche returned from a template poisons the zero-address registry key and the `getMarket` sentinel | `RoycoFactory` registry | Low (factory) | Confirmed | `Test_FactoryTrancheRegistry.t.sol:61` |
| 23 | A zero-minOut reinvest floor adds without slippage protection; a sync bricks when the oracle reports zero TVL against a positive BPT supply | `BalancerV3VenueLogic.sol`; `BalancerV3_LT_BPTOracle_Quoter.sol:134,143` | Low-Med | Confirmed | `Test_BalancerHooksAndReinvest.t.sol:112,156` |
| 24 | `convertToAssets` on an empty tranche panics (div-by-zero) instead of returning zero claims | `RoycoVaultTranche.sol:210` | Low | Confirmed | `Test_TrancheViewEdges.t.sol:44` |
| 25 | LT `maxRedeem` reports zero on an idle-premium-only NAV even though the full balance is redeemable | `RoycoVaultTranche.sol:241`; LT max path | Low | Confirmed | `Test_TrancheViewEdges.t.sol:84` |
| 26 | A cache write with the top bit set is silently read back top-bit-stripped (the `CACHE_SET_MASK` marker collides with an over-large value) | `Cache.sol:54-61` | Low | Confirmed | `Test_CacheDivergences.t.sol:35` |
| 27 | A zero composite conversion rate: backward conversion div-by-zero panics; forward conversion silently zeroes both tranche NAVs; a sync commits a full loss and the `maxDeposit` view panics | `IdenticalAssets_ST_JT_Oracle_Quoter.sol:144,149`; ERC4626/Makina legs | Low-Med | Confirmed | `Test_QuoterZeroRateDivergences.t.sol:83,109,147` |
| 28 | `ltRedeemMultiAsset` ignores `minQuoteAssetsOut` when the venue slice is zero | `RedemptionLogic.sol` multi-asset unwind | Low | Confirmed | `Test_SpecDivergences.t.sol:360` |
| 29 | The senior self-liquidation bonus setter accepts a rate above 100% (no `≤WAD` cap); impact is bounded because the bonus is downstream-clamped by `min(desired, jtEff, uNeutralMax)` | `RoycoDayKernel.sol:503` | Low | Confirmed | `Test_AdminAndGates.t.sol:75` |
| 30 | A huge dust tolerance disables protocol fees and fixed-term entry | `RoycoDayAccountant.sol:935-948,594` | Low | Confirmed | `Test_Setters_Accountant.t.sol:235` |
| 31 | The accrual increment cast silently truncates past uint192 | `RoycoDayAccountant.sol` accrual accumulator | Low | Confirmed | `Test_YieldShareAccrual_Accountant.t.sol:314` |
| 32 | `setSanctionsList` accepts a target that cannot answer `isSanctioned` | `RoycoBlacklist.sol:88` | Low | Confirmed | `Test_BlacklistScreening.t.sol:342` |
| 33 | Zero-share kernel mints succeed while the tranche is paused | `RoycoVaultTranche.sol:137-152`; pause path | Low | Confirmed | `Test_ShareSurfaces.t.sol:153` |

---

## 3. New findings from this audit (F34–F36)

Surfaced by the 2026-07-07 re-audit; not in the register.

| # | Mechanism | Where | Severity | Status | Pin |
|---|---|---|---|---|---|
| 34 | A `StaticCurveYDM` constructed at `TARGET == WAD` (permitted by the shared `BaseYDM` `(0, WAD]` gate) constructs fine but `initializeYDMForMarket` reverts: the upper-segment slope divides by `WAD − TARGET == 0`. The static YDM is permanently un-initializable at a 100% target. Adaptive models are unaffected (their `WAD − TARGET` branch is unreachable). | `StaticCurveYDM.sol:86,151`; `BaseYDM.sol:26` | Low (deploy-time brick) | **Pinned** | `Test_StaticCurveYDMInitDivergences.t.sol` (`test_FINDING_34_...`) |
| 34b | Secondary edge: a target *very close* to `WAD` overflows the `uint64` slope via `SafeCast.toUint64` (e.g. `TARGET = WAD−1` with a normal spread yields a 4e35 slope) | `StaticCurveYDM.sol:151` | Low | Documented | in the F34 pin file |
| 35 | The accountant's `_initializeYDM` invokes `initializeYDMForMarket` only when the init calldata is non-empty and performs no post-check, so an empty-calldata attach leaves the curve uninitialized; the first `yieldShare` then reverts `UNINITIALIZED_YDM`, bricking the sync hot path until an admin re-sets the YDM | `RoycoDayAccountant.sol:1002`; `StaticCurveYDM`/`BaseAdaptiveCurveYDM` uninitialized guard | Low (config brick) | **Pinned** | `Test_StaticCurveYDMInitDivergences.t.sol` (`test_FINDING_35_...`) |
| 36 | CREATE3 `_deployYDM` omits the `require(!alreadyDeployed)` that `_deployImpl`/`_deployProxy` enforce, so a `(marketId, tag)` salt collision silently reuses the first YDM and drops the second deployment's target-utilization constructor arg. Adjacent to F21 (marketId collision) | `BaseDeploymentTemplate.sol:199-201` vs `:181,189` | Low (tied to F21) | Unpinned | — |
| — | `_validateYieldShareConfig` does `require((uint64 + uint64) <= WAD)`; when the two inputs sum past `2^64 − 1` the checked `uint64` addition `Panic(0x11)`s before the intended `INVALID_MAX_YIELD_SHARE_CONFIG`. Admin-only, error-quality (F30 pins the dust-sum sibling) | `RoycoDayAccountant.sol:989` | Low (admin, error-quality) | Unpinned | — |

**Recommended fixes** (documented, not implemented here): reject `TARGET == WAD` in the `StaticCurveYDM`
constructor (or special-case the upper slope to 0); have `_initializeYDM` require a non-empty init
payload (or verify the curve reads initialized); add the `!alreadyDeployed` guard to `_deployYDM`; widen
the yield-share-sum operands before the `≤ WAD` check.

---

## 4. Informational / trust-model / by-design

Re-confirmed at current lines. These are properties of the design or trust boundaries, not defects.

- **Unbound `restricted` selectors default to AccessManager role 0.** The factory's `pause`/`unpause`
  and the **entire** `RoycoBlacklist` admin surface (`blacklistAccounts`/`unblacklistAccounts`/
  `setSanctionsList`, plus pause/unpause/upgrade) are never bound via `setTargetFunctionRole`, so they
  resolve to `ADMIN_ROLE`. `RoycoFactory.sol` init; `RoycoBlacklist.sol:44,49,88`. The blacklist is never
  wired by the deployment template.
- **No Chainlink min/maxAnswer band.** The only numeric price gate is `answer > 0` plus staleness and
  round-completeness, so a circuit-breaker-pinned positive answer within the staleness window is accepted.
  `IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol:163-167`.
- **Sequencer-vs-oracle guard polarity inconsistency + unimplemented fallback.** The oracle setter permits
  a zero-threshold live oracle (`:178`) while the sequencer setter forbids a zero-grace active feed (`:195`);
  the "admin rate as fallback" natspec (`:177`) is not implemented — the feed is queried unconditionally at
  `:159`.
- **Admin-oracle & Makina quoter families are unbounded price authorities** with no staleness/deviation/
  sanity band, and have zero behavioral tests (no shipped kernel wires them).
  `IdenticalAssets_ST_JT_AdminOracle_Quoter.sol`; `IdenticalMakinaShares_..._Quoter.sol`.
- **Staged premium buffer is unbounded** — no code cap; under sustained reinvest failure it can grow.
  Matches the CLAUDE.md open guardrail. `BalancerV3VenueLogic.sol`; `FeeAndLiquidityPremiumLogic.sol:53`.
- **Active template = transient AccessManager root.** `grantMarketRole`/`setMarketTargetFunctionRole`/
  `executeAsFactory` impose no per-call role/target filter; security reduces to who registers templates.
  `RoycoFactory.sol:208-233`.
- **Reinvest tolerated-failure swallows all reverts** including inner-frame out-of-gas (deferral-only, no
  accounting corruption; now observable via `LiquidityPremiumReinvestmentFailed`).
  `BalancerV3VenueLogic.sol:188-198`.
- **Fixed-offset assembly returndata decoding with no length checks** (honest-Vault assumption; standard
  Balancer pattern). `BalancerV3_LT_BPTOracle_Quoter.sol:193-257`; `BalancerV3VenueLogic.sol:203-205`.
- **Op-scoped (tx-scoped-transient, never op-cleared) `ST_SHARE_RATE` cache**; `Cache._clear` was removed.
  Freshness relies on every `getRate` consumer being preceded by a same-op sync. `Cache.sol`;
  `BalancerV3_LT_BPTOracle_Quoter.sol:160-180`.
- **Blacklist hot-path external Chainalysis `staticcall`** couples share-movement liveness to that contract
  (gated by both `roycoBlacklist != 0` and `sanctionsList != 0`). `BlacklistLogic.sol:34-44`;
  `RoycoBlacklist.sol:129-132`.
- **Realizable depth vs solvency mark.** The `liquidityUtilization <= 100%` redemption gate guarantees a
  solvency floor from the Balancer oracle, not a realizable-exit floor: the BPT can mark healthy while the
  quote leg is drained. `UtilizationLogic.sol`; CLAUDE.md.
- **Doc drifts.** `mint` natspec says `restricted` but the impl is `onlyKernel`
  (`IRoycoVaultTranche.sol:158` vs `RoycoVaultTranche.sol:155`); `onlyLiquidityTranche`'s comment says
  "junior" (`RoycoDayKernel.sol:77`); a `seize` surface is referenced in CLAUDE.md but absent from `src/`;
  `MUST_DEPOSIT_NON_ZERO_ASSETS` is declared but never thrown (`IRoycoLiquidityTranche.sol:16`).

---

## 5. Test-coverage gaps

Risks in the test suite (not code defects), from the coverage audit. Parts B and C of the test plan
(`.claude/plans/elegant-soaring-flurry.md`) address the ones that can be closed by writing tests.

- **CI skips `test/fork/**` when RPC secrets are unset** (`CI.yml:66`). On such a run, factory/role wiring,
  all real E-CLP / BPT-oracle / `getRate` math, and oracle-poison-through-a-flow have **zero always-running
  coverage** — the highest-severity deploy and venue risks. *(Structural CI/tooling issue — out of scope for
  the test-writing plan; Part B mitigates the risk by adding always-running mock coverage.)*
- **`forge coverage` is not wired and is infeasible** (stack-too-deep under `via_ir` even at `--ir-minimum`),
  so none of `testing-strategy.md §5`'s numeric gates (98% line / 95% branch / ≥90% mutation) are enforced.
  *(Structural — out of scope.)*
- **`FINDINGS.md` register is materially incomplete**: it documents F3–7 and F11–15 in prose while the suite
  pins F3–33 (~21 undocumented), and both `FINDINGS.md` and `testing-strategy.md` reference the pre-reorg
  `test/unit|base|scaffold/` tree that no longer exists. *(This document supersedes the register.)*
- **Preview/execution parity** has no stateful-invariant enforcement; multi-asset **deposit** parity is only
  a ±30bps inequality (`Test_BalancerHooksAndReinvest.t.sol:282-291`), never exact or fuzzed. *(Part B4.)*
- **Conservation is proven symbolically only to 1e30** (mixed-sign quadrants to 1e27); the **same-block
  premium branch** (`RoycoDayAccountant.sol:600-622`) is statically excluded from every waterfall symbolic
  proof (fuzz-only for conservation), and the accrual-budget lemma is assumed, not composed. *(Part B6.)*
- **`max*` inverse boundary is fuzz-only at one fixed config** (20% coverage / 5% liquidity). *(Part C0 §7
  covers it at the live fork config.)*
- **FIXED_TERM per-entrypoint revert matrix is fork-only.** *(Part B5.)*
- **`jtCoinvested = false` is covered only at the accountant layer** — the shipped identical-asset kernel
  forces `JT_COINVESTED = true`, so there is no full-market/kernel-driven `false` axis by construction.
  Inherent; documented.
- **The ~1e45 B.4 supply cliff is outside every symbolic and fuzz domain** (all capped at 1e30); it is
  bounded only by the invariant handler's 1e45 clamp.

---

*Compiled 2026-07-07 against `src/` at pull `cb085e32`. Finding numbers align with the suite's
`test_FINDING_<n>` pins; the next free number is 37.*
