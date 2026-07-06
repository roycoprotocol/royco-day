# Royco Day — Protocol Findings Register

Central register of every confirmed divergence between production behavior and the product spec
(`CLAUDE.md`), surfaced by the test suite and independently re-verified against the current `src/`
(post-2026-07-06 pull). Each finding has a runnable pinning test named `test_FINDING_<n>_<...>` that
asserts **current** behavior and documents the **spec-expected** behavior in a comment, so CI stays
green while the divergence stays visible. `src/` is intentionally unmodified — the fixes are the
protocol team's decision.

Working notes and the full derivation history live in `docs/testing/agent-notes/13-spec-divergence-findings.md`.

## Summary

| # | Finding | Severity | Status | Pinning test file |
|---|---------|----------|--------|-------------------|
| 11 | Whitelist markets brick on the first senior gain (premium mint not whitelist-exempt) | **Major** | Confirmed | `test/unit/findings/PremiumMintDivergences.t.sol` |
| 5 | JT redemption stays coverage-gated after the liquidation breach | Medium | Confirmed | `test/unit/findings/SpecDivergences.t.sol` |
| 4 | ST deposits ARE liquidity-gated (CLAUDE.md contradicts itself) | Low code / Medium doc | Confirmed | `test/unit/findings/SpecDivergences.t.sol` |
| 3 | In-kind LT redemption bricks when the BPT slice floors to zero | Low-Medium | Confirmed | `test/unit/accountant/CarveOut.t.sol` |
| 6 | Every accountant parameter setter reverts while the kernel is paused | Low-Medium | Confirmed | `test/unit/findings/SpecDivergences.t.sol` |
| 13 | A dust-sized senior gain pays premiums but skips every protocol fee | Minor | Confirmed | `test/unit/findings/AccountantPremiumDivergences.t.sol` |
| 15 | Fixed-term end timestamp truncates to uint32 and can wrap into the past | Minor | Confirmed | `test/unit/findings/AccountantPremiumDivergences.t.sol` |
| 14 | Zero LT depth reads liquidityUtilization as uint256 max | Minor | **Split — needs human decision** | `test/unit/findings/AccountantPremiumDivergences.t.sol` |
| 7 | Intra-spec contradiction on FIXED_TERM deposits (production is a third matrix) | Doc-only | Confirmed | `test/unit/findings/SpecDivergences.t.sol` |
| 12 | Griefed premium reinvestment stages the premium (claimable, not forfeited) | None (regression guard) | Intended behavior | `test/unit/findings/PremiumMintDivergences.t.sol` |

Two earlier findings (LT deposits liquidity-gated; in-kind LT deposits coverage-gated) were **retracted**
after runtime verification showed production matches the spec — see the Retracted section at the end.

---

## Finding 11 — Whitelist markets brick on the first senior gain — **MAJOR**

A market deployed with the transfer whitelist enabled becomes permanently unusable the moment senior
yield is booked.

- **Spec expects**: the liquidity-premium mint is a privileged internal reassignment of senior appreciation
  to the LT ("a privileged internal mint that bypasses the deposit coverage gate"). It is not a user
  transfer and should not be screened by the tranche-transfer whitelist.
- **Production does**: with `enforceVaultSharesTransferWhitelist = true`, the premium is minted as senior
  shares **to the kernel**; that mint runs `RoycoDayKernel.preTrancheBalanceUpdateHook`, whose whitelist
  branch requires the recipient to hold `ST_LP_ROLE`. The kernel never holds it, so the mint reverts
  `ACCOUNT_NOT_WHITELISTED_TRANCHE_LP(kernel)`. Every pre-op sync runs this mint, so once any senior gain
  accrues a premium, **every** sync — hence every deposit and redemption — reverts. The market is bricked.
- **Where**: `src/libraries/logic/FeeAndLiquidityPremiumLogic.sol:51-52` (the mint),
  `src/kernels/base/RoycoDayKernel.sol:544-551` (the whitelist screen on the kernel recipient).
- **Reachability**: gated by the `enforceVaultSharesTransferWhitelist` config → kernel immutable
  `ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER`. `script/Deploy.s.sol:533` and the factory template
  (`BalancerV3DeploymentTemplate.sol:346`) only forward the config value — they never hardcode it — and the
  sole in-repo config (`script/config/MarketDeploymentConfig.sol:251`) sets it **`false`**. So no shipped
  deployment triggers this, and nothing in the deploy path grants the kernel/LT the tranche `deposit` role
  that would exempt it. It is a latent brick on a first-class supported configuration: any issuer who deploys
  with the flag `true` gets a market that dies on its first yield. Severity stays **Major** (a supported
  configuration is non-functional); the mitigation today is purely that the default ships the flag off.
- **Recommended fix**: carve the privileged premium mint (and any kernel-custodied balance move) out of
  the whitelist screen, mirroring the coverage-gate bypass the mint already receives.
- **Pinning test**: `test_FINDING_11_whitelistMarket_bricksOnFirstSeniorGainPremiumMint`.

## Finding 5 — JT redemption stays coverage-gated after the liquidation breach — **Medium**

Once coverage is in liquidation, ST and LT can exit but JT cannot, contradicting the spec and bleeding
junior value while junior holders are locked.

- **Spec expects**: "unless the liquidation utilization has been breached, in which case all withdrawals
  are allowed ... locking liquidity in protects no one." A JT redemption after the breach should succeed.
- **Production does**: the liquidation bypass exists only for LT redemptions (`ltRedeem`/`ltRedeemMultiAsset`
  pass `enforce = (coverageUtilization < liquidationThreshold)`), but `jtRedeem` passes `enforce = true`
  unconditionally, so in the wind-down state every JT redemption reverts `COVERAGE_REQUIREMENT_VIOLATED`.
  ST self-liquidation bonuses are paid out of `jtEffectiveNAV` during exactly this state, so junior value
  can bleed while junior holders are pinned.
- **Where**: `src/libraries/logic/RedemptionLogic.sol:101` (JT redeem, no bypass) vs `:137`/`:204` (the LT
  bypass); accountant gate `src/accountant/RoycoDayAccountant.sol:327-329`.
- **Recommended fix / decision**: extend the liquidation bypass to `JT_REDEEM`, or amend the spec to
  "all LT withdrawals are allowed". A product call.
- **Pinning test**: `test_FINDING_5_jtRedeem_staysCoverageGated_afterLiquidationBreach` (pins both halves:
  JT reverts, an LT redemption in the identical state succeeds through its bypass).

## Finding 4 — ST deposits ARE liquidity-gated — **Low code / Medium doc**

- **Spec conflict**: the two-metrics narrative says "no deposit is ever blocked on liquidity" and
  "Deposits are never liquidity-gated"; the canonical product-spec section (stated to govern) says "Each
  market sets a minimum percentage of liquidity required for senior tranche deposits."
- **Production does**: follows the canonical line — `ST_DEPOSIT` requires post-op `liquidityUtilization <=
  100%`, and `maxSTDeposit` binds on the liquidity requirement, so a senior deposit is blocked exactly as
  often as the metric is breached. Downstream integrators reading the two-metrics section will mis-predict
  reverts. Also a real deployment-sequencing constraint (see Finding 14).
- **Where**: `src/accountant/RoycoDayAccountant.sol:331-334` (gate), `:376-384` (`maxSTDeposit` binding),
  `src/libraries/logic/DepositLogic.sol:59` (stDeposit passes enforce = true).
- **Recommended fix**: reconcile CLAUDE.md to one behavior (the code is the conservative, defensible one).
- **Pinning test**: `test_FINDING_4_stDeposit_isLiquidityGated_underProvisionedMarketBlocksSeniorEntry`.

## Finding 3 — In-kind LT redemption bricks when the BPT slice floors to zero — **Low-Medium**

- **Spec expects**: "If a holder redeems while idle premium senior shares are still staged for the LT,
  those shares are sent directly to the redeemer ... so no premium is stranded." A small in-kind redemption
  whose BPT slice floors to zero but whose idle-share slice is positive should succeed.
- **Production does**: transferring idle ST shares moves no raw NAV, so the accountant sees
  `deltaLTRawNAV == 0` and reverts `INVALID_POST_OP_STATE(LT_REDEEM)`. An LT whose entire NAV is staged
  premium is temporarily un-redeemable, and small redeemers cannot claim their idle-share slice.
- **Where**: `src/accountant/RoycoDayAccountant.sol:263` (the LT_REDEEM op-shape require);
  `src/libraries/logic/RedemptionLogic.sol:111-139` (floor-scales both slices, always post-ops).
- **Recommended fix / decision**: allow the zero-BPT redemption shape, or round the BPT slice up so the
  op always moves nonzero raw NAV.
- **Pinning test**: `test_FINDING_3_ltRedeemZeroBPTSliceWithIdleShares_revertsInvalidPostOpState`.

## Finding 6 — Every accountant parameter setter reverts while the kernel is paused — **Low-Medium (operational)**

- **Expected (operational)**: an emergency pause is when governance most plausibly needs to remediate
  parameters (fees, coverage, liquidation threshold, term duration, dust tolerances).
- **Production does**: every setter carries `withSyncedAccounting`, whose modifier calls the kernel's
  `whenNotPaused` sync, so while paused every setter reverts `EnforcedPause` regardless of role. Only the
  two YDM swap setters survive (raw call, tolerated revert). Unpausing is the only remediation path.
- **Where**: `src/accountant/RoycoDayAccountant.sol:42-45` (modifier), `:847-950` (setters),
  `src/kernels/base/RoycoDayKernel.sol:313` (`whenNotPaused` on the sync).
- **Recommended fix / decision**: if pause must coexist with remediation, add a sync-less setter path;
  otherwise document as intended.
- **Pinning test**: `test_FINDING_6_accountantSetters_revertWhileKernelPaused`.

## Finding 13 — A dust-sized senior gain pays premiums but skips every protocol fee — **Minor**

- **Spec expects**: a distributed premium is real yield reassigned to JT/LT, so the configured protocol
  fee should be taken on it. The dust tolerance exists to suppress rounding artifacts, not to waive fees.
- **Production does**: the fee gate keys on `stGain > effectiveNAVDustTolerance`, while the premiums are
  computed and paid unconditionally. For `0 < stGain <= dust`, the JT and LT premiums are paid while all
  three protocol fees read zero — a systematic fee under-collection on every sub-dust gain.
- **Where**: `src/accountant/RoycoDayAccountant.sol:594` (the `premiumsPaid = stGain > dust` gate),
  `:631/:640/:646` (fees gated on it) vs `:624-625/:638` (premiums paid regardless).
- **Recommended fix**: gate fees on whether a premium was actually distributed, not on gain-vs-dust.
- **Pinning test**: `test_FINDING_13_dustGain_paysPremiumButSkipsProtocolFee`.

## Finding 15 — Fixed-term end timestamp truncates to uint32 and can wrap into the past — **Minor**

- **Spec expects**: entering FIXED_TERM sets the term end to a future timestamp that gates the return to
  PERPETUAL.
- **Production does**: the end is `uint32(block.timestamp + fixedTermDurationSeconds)`. Near the uint32
  ceiling (~year 2106) the sum wraps below the current time, so the market enters FIXED_TERM already
  elapsed and the next sync immediately drops it back to PERPETUAL, defeating the fixed-term lock.
- **Where**: `src/accountant/RoycoDayAccountant.sol:705` (truncating cast), `:667` (the elapsed check).
- **Recommended fix**: widen the stored end timestamp, or `require` the sum does not overflow uint32.
- **Pinning test**: `test_FINDING_15_fixedTermEndTimestamp_truncatesToUint32AndWrapsIntoPast`.

## Finding 14 — Zero LT depth reads liquidityUtilization as uint256 max — **Minor — SPLIT, needs a human decision**

The two verifiers split: one reads this as a divide-by-zero sentinel that bricks the first senior deposit
in a fresh `minLiquidity > 0` market; the other as the documented guardrail. Pinned as current behavior.

- **Production does**: `_computeLiquidityUtilization` returns `type(uint256).max` when `stEffectiveNAV > 0`,
  `minLiquidityWAD > 0`, and `ltRawNAV == 0`, so every liquidity-gated op reads the market as infinitely
  under-provisioned until LT depth exists.
- **Matches**: the CLAUDE.md open decision "ensure `ltRawNAV` is never zero against a positive
  `minLiquidity`, which would make `liquidityUtilization` infinite."
- **Where**: `src/libraries/logic/UtilizationLogic.sol:70-74`.
- **Decision needed**: enforce a nonzero-`ltRawNAV` seed invariant in code (reject the config or the first
  deposit with a named error), or keep it as a documented deployment-sequencing constraint. Do not resolve
  silently — the pin makes the choice loud.
- **Pinning test**: `test_FINDING_14_zeroLTDepth_readsLiquidityUtilizationAsMax`.

## Finding 7 — Intra-spec contradiction on FIXED_TERM deposits — **Doc-only**

- **Spec conflict**: the capital-realism section says "In FIXED_TERM, deposits and redeems are disabled for
  every tranche"; the canonical section says "Deposits are enabled at all times."
- **Production does**: neither — it implements the coherent middle: nothing that mints senior shares is
  allowed mid-term, everything that only deepens liquidity is. `stDeposit`/`jtDeposit` revert
  `DISABLED_IN_FIXED_TERM_STATE`, in-kind `ltDeposit` succeeds, `ltDepositMultiAsset` reverts with an ST
  leg and succeeds quote-only.
- **Where**: `src/libraries/logic/DepositLogic.sol` FIXED_TERM guards.
- **Recommended fix**: reconcile CLAUDE.md's two sentences to the production matrix.
- **Pinning test**: `test_FINDING_7_fixedTermDeposits_productionMatrix_intraSpecContradiction`.

## Finding 12 — Griefed premium reinvestment stages the premium (claimable, not forfeited) — **Intended behavior (regression guard)**

Not a defect — the documented staged-buffer design, pinned so a future regression fails loudly.

- **Production does (matches spec)**: when the single-sided reinvestment fails its min-BPT-out slippage
  gate, the mint stays staged in `ltOwnedSeniorTrancheShares`, the sync does not revert, `ltRawNAV` is
  unchanged (so the metric keeps the LDM paying), and the staged shares remain a claimable leg. An attacker
  forcing venue slippage only DEFERS deployment.
- **Where**: `src/libraries/logic/BalancerV3VenueLogic.sol:181-196` (tolerated-failure reinvestment).
- **Pinning test**: `test_FINDING_12_griefedReinvestment_stagesPremiumClaimableNotForfeited` (asserts the
  sync survives, the premium stages, `ltRawNAV` is unchanged).

---

## Retracted (production matches the spec — recorded to prevent re-litigation)

- **LT deposits are NOT liquidity-gated** (retracted 2026-07-05): the accountant gate only runs when the
  kernel requests enforcement; the in-kind LT deposit passes `enforce = false`, so an in-kind BPT deposit
  into a market with `liquidityUtilization > 100%` succeeds. Replaced by a positive conformance test.
- **In-kind LT deposits are NOT coverage-gated** (retracted 2026-07-05): same enforcement-flag mechanism —
  only the multi-asset LT deposit with an ST leg (which mints senior shares) is coverage-gated, which is
  spec-consistent. An in-kind BPT deposit into a coverage-breached market succeeds.
