# Royco Day: Liquidity Tranche (LT)

This branch is the next iteration of the Royco protocol. It adds a third tranche, the Liquidity Tranche (LT), on top of the Dawn senior/junior (ST/JT) system. The work is strictly additive. ST and JT behave exactly as they do in Dawn. The live ST/JT markets are never upgraded, never recompiled, and never touch any new code path or storage field.

If you are picking this up cold, read this file, then `src/libraries/AccountingLib.sol` (the waterfall) and `src/accountant/RoycoAccountant.sol` (`_previewSyncTrancheAccounting`, the sync orchestrator). The LT does not change either of those at the conservation level. That is the whole point of the design.

## Branch goal

Dawn guarantees a minimum coverage for senior shares. Royco Day adds a second service: secondary liquidity for senior shares. The LT is market-making capital that holds a Balancer pool of ST shares against a stablecoin, so ST holders have a venue to exit into. The LT is paid a liquidity premium out of ST yield, in the same way JT is paid a risk premium.

This separates two jobs that Dusk overloaded onto the junior tranche. In Dusk the JT was both first-loss coverage and pool liquidity, which forced one combined minimum tranche size. Here JT stays pure first-loss coverage exactly as Dawn, and the LT carries liquidity. Each issuer picks coverage and liquidity independently. The cost is more capital to raise.

## What the LT actually is

The LT is an ST holder that locks senior capital in a Balancer E-CLP BPT (ST shares paired against a quote stablecoin) to provide market-making liquidity, and earns extra ST shares (the liquidity premium) for doing so. It is fully covered senior, not self-insured. The premium compensates the illiquidity of the locked position and the impermanent loss of the LP, not waived coverage.

The LT tranche is a standard Royco vault tranche, the same ERC4626-style contract family as ST and JT. The premium accrues into the LT share NAV, so the LT share is a transferable, appreciating yield-bearing token. That keeps it composable: it is Pendle-wrappable through the existing tranche SY wrapper, and usable as Morpho collateral. There is no separate staking or rewards contract, because a staking contract would tie rewards to an address rather than to the token and break that composability.

## Capital structure

- ST is protected senior capital, deployed into a yield-bearing asset. It pays the JT a risk premium and the LT a liquidity premium out of its yield.
- JT is first-loss capital. It provides coverage to ST on losses until exhausted, and earns the JT risk premium via the YDM. Unchanged from Dawn.
- LT is covered senior capital that also provides liquidity. It holds the BPT plus its accrued premium in ST shares, and earns the liquidity premium via the LDM.

Hard constraint: `maxLiquidityPremiumWAD + maxRiskPremiumWAD <= WAD` (100% of ST yield).

## The premium is covered ST shares (the load-bearing decision)

The liquidity premium is a portion of senior yield set by the LDM. It is paid as newly minted ST shares credited to the LT tranche, which raises the LT share NAV. This single decision is what keeps the accounting simple, and it has three consequences.

1. Coverage-neutral. Minting the premium as ST shares reassigns senior appreciation from plain ST to the LT. The senior raw NAV (`stRaw`) is unchanged, because no assets enter or leave the pool, only share ownership shifts. So `coverageUtilization` does not move, JT bears no extra burden, and there is no lever-up. The mint must therefore be a privileged internal mint that bypasses the deposit coverage gate, because it adds no senior exposure.

2. Everything senior stays covered. Plain ST, the BPT's ST-share leg, and the premium shares are all senior claims in the coverage perimeter. Coverage uses `stRaw_total`, the vault mark of all ST shares, exactly as Dawn. There is no `stRaw_covered = stRaw_total - ltLeg` subtraction. That deletes both the dual-mark problem (subtracting a Balancer mark from a vault mark) and the swap-manipulability of any such subtraction.

3. The waterfall stays two-term. The premium shares are senior, so they live in `stEff`. The `liqShare` only decides how the senior appreciation of a sync is apportioned between plain ST and the LT. It does not add a third NAV leg. `AccountingLib` keeps `stRaw + jtRaw == stEff + jtEff` byte-for-byte. There is no 6-arg conservation, no LT leg in the checkpoint, and no change to `STEP_APPLY_JT_COVERAGE_TO_ST` or the attribution path.

The `liqShare` mint happens as a post-sync step in `RoycoDayAccountant`, after the unchanged Dawn waterfall has computed the senior gain. It is NAV-neutral (a share mint against value already in the pool), so it sits outside the waterfall conservation entirely.

## The yield split

On the up path of a sync, after JT coverage IL recovery clears:

1. JT risk premium (existing, unchanged): `riskShare = floor(stGain * jtFracWAD)`, routed to `jtEffectiveNAV` via the YDM. This is Dawn.
2. LT liquidity premium (new): `liqShare = floor(stGain * ltFracWAD)`, set by the LDM, minted as ST shares to the LT tranche.
3. ST keeps the residual.

The joint cap `maxLiquidityPremiumWAD + maxRiskPremiumWAD <= WAD` is validated at `initialize` and in both setters. Because both shares are fractions of the same senior gain, the combined draw cannot exceed it. Who pays: plain ST holders fund the premium through the dilution; the LT's own base partially self-funds and nets positive. The share math must be written out once to confirm the LT is not net paying its own premium.

## The two metrics

### Coverage (unchanged from Dawn)

```
coverageUtilization = (stRaw_total + jtRaw * beta) * minCoverage / jtEffectiveNAV
```

`stRaw_total` is the vault mark of every ST share, including the LT's pooled base and its premium shares. No exclusion, no composition reads, swap-stable. `computeCoverageUtilization` is byte-for-byte Dawn, and at zero liquidity a Day market produces identical coverage to Dawn.

### Liquidity

```
liquidityUtilization = stEffectiveNAV * minLiquidity / ltRawNAV
```

`ltRawNAV` is the BPT value from Balancer's E-CLP oracle, the actual pool depth that backs ST exits. It is the BPT only. It is not the LT tranche's total NAV. The LT's idle premium shares appreciate the LT share but must never count toward `ltRawNAV`, or the premium would inflate the liquidity denominator and let the gate read healthy without any real depth being added.

Both inputs are manipulation-resistant: `stEffectiveNAV` is total senior NAV (swaps in the pool do not change it), and `ltRawNAV` is the Balancer oracle. There is no composition subtraction in the numerator.

`liquidityUtilization` is allowed to drift above 100%. The restoring force is the same as on the coverage side: a higher utilization makes the LDM pay a higher premium, which attracts external LT deposits, which grow `ltRawNAV` and bring utilization back down. This mirrors how the YDM clears coverage utilization with JT deposits. The premium is not compounded back into the pool. Compounding (minting ST shares and single-sided LPing them) was rejected: it adds scope and donates value to rebalancing arbitrageurs, and it is unnecessary once external deposits are the restoring force.

### LDM

The Liquidity Distribution Model is the general-purpose YDM, which now takes a utilization input directly, instantiated with a liquidity target and driven by `liquidityUtilization`. It is the same contract family as the JT's YDM. A gentle slope is appropriate, because utilization above 100% is an accepted state that the premium curve prices rather than a hard bound.

### ltRawNAV from Balancer's E-CLP oracle

`ltRawNAV` is read from Balancer's native Gyro E-CLP manipulation-resistant oracle for the BPT. There is no ported valuation library, no custom recursion, and no bisection solver. The pool prices the ST share via a rate provider that reports the ST share NAV from the last committed sync, so the rate is a per-sync resolved input, not a within-call fixed point. The Balancer mark is single-block manipulation-resistant. It is a solvency value, not realizable exit depth, and can overstate liquidity under sustained quote depeg or arbitrage halt. See open decisions.

## Accountant architecture: modular libraries, Dawn base, Day extends

The existing `RoycoAccountant` is the Dawn base. `RoycoDayAccountant` extends it as a separate implementation with its own deploy salt. ERC-7201 makes inheritance safe: LT config goes in a fresh namespaced storage slot, additive and collision-free. The base exposes a `virtual` post-sync seam. `RoycoDayAccountant` overrides it to resolve the LDM and signal the coverage-neutral premium-share mint. Coverage, the loss waterfall, and the state machine are inherited unchanged.

The shared `IRoycoAccountant` signatures the live markets use stay byte-for-byte, which keeps `Deploy.s.sol` and the upgrade ops modules compiling and the live upgrade path intact. Day is new-markets-only. A live Dawn accountant proxy is never upgraded into a Day accountant.

The anchor test for the whole branch: `RoycoDayAccountant` configured with zero minimum liquidity produces byte-for-byte identical state to `RoycoDawnAccountant`. This turns "ST and JT are unchanged" from a claim into a differential assertion.

## Additive and non-invasive integration principle

- ST and JT accounting is untouched, including `computeCoverageUtilization`, which is fed the same `stRaw_total` a Dawn market would feed it.
- Shared interfaces stay byte-for-byte. LT entrypoints live on a new `IRoycoLiquidityKernel` and on `RoycoDayAccountant`, not on `IRoycoDawnKernel` or the shared `IRoycoAccountant`.
- All new storage is appended in fresh trailing slots. ERC-7201 namespace strings and slot constants are byte-identical. The fully packed accountant slot is never touched.
- Enum appends preserve existing ordinals. `TrancheType` gains `LIQUIDITY`, `Operation` gains `LT_DEPOSIT` and `LT_REDEEM`, at the end.
- The liquidity gate is orthogonal to coverage. It never modifies coverage config, the coverage requirement check, `computeCoverageUtilization`, or the forced-perpetual conditions.

## LT tranche and kernel

The LT tranche is a Royco vault tranche that holds two things: the BPT (its market-making position) and the accrued premium in ST shares. The LT share NAV is the sum of both. `ltRawNAV`, used only by the liquidity metric, is the BPT alone. The premium shares sit idle in the tranche. They are never LP'd into the pool, so there is no single-sided add and no arb leakage.

Deposits: `ltDeposit` takes a pre-minted BPT. `ltDepositMultiAsset` is the atomic flow that pulls the ST asset and the quote stable, mints the ST share, performs the Balancer join, and mints the LT share inside `Vault.unlock`, bounded by `minBptOut`, a max-asset-in per token, and a deadline.

Redemptions: an LT holder redeems for a proportional slice of the BPT (or its ST-share and quote constituents via a sandwich-safe proportional `removeLiquidity`) plus a proportional slice of the accrued premium shares. There is no separate premium leg to compute, because the premium is part of the tranche's holdings and is already reflected in the LT share NAV.

Redemption gating is soft. There is no hard 100% gate, because utilization above 100% is accepted. The spiking premium discourages exit and pulls in entry. Whether a hard liquidation-style backstop is also needed at an extreme threshold is an open decision.

The kernel custodies the BPT, performs the joins and exits, and executes the coverage-neutral premium-share mint into the LT tranche. The blacklist, seize, and zero-supply and zero-NAV boundaries carry over from the tranche base unchanged.

## Contract map

New:
- `src/accountant/RoycoDayAccountant.sol`: extends the Dawn accountant. Resolves the LDM and signals the post-sync coverage-neutral premium-share mint. Computes the liquidity metric. Separate impl and deploy salt.
- `src/interfaces/IRoycoLiquidityKernel.sol`, `src/kernels/base/RoycoLiquidityKernel.sol`, `src/kernels/liquidity/*`: the LT-aware kernel. Custodies and joins/exits the BPT, mints premium ST shares to the LT tranche.
- `src/tranches/RoycoLiquidityTranche.sol`: the LT vault tranche, holding the BPT plus accrued premium ST shares.
- `src/interfaces/ILDM.sol`, `src/ldm/*`: the LDM, reusing the general-purpose YDM family driven by `liquidityUtilization`.
- `src/oracles/venues/balancer-v3/*`: a thin adapter that reads Balancer's native E-CLP oracle for `ltRawNAV`, plus the rate provider and the pool hook. No valuation math is reimplemented. The abstraction lets any AMM or MM vault back the LT; Balancer E-CLP is first.

Modified (additive):
- `src/accountant/RoycoAccountant.sol`: a `virtual` post-sync seam. No behavior change on the Dawn path.
- `src/libraries/Types.sol`: append-only enum and LT config fields. No LT NAV leg in the checkpoint.
- `src/interfaces/IRoycoAccountant.sol`, `src/interfaces/IRoycoDawnKernel.sol`: appended state, errors, events. Shared signatures unchanged.
- `src/kernels/base/RoycoDawnKernel.sol`: isolated edits only (`onlyTranche` widening, multi-asset withdraw for the LT's BPT or its constituents). ST/JT bodies unchanged.
- `src/tranches/base/RoycoVaultTranche.sol`: explicit `SENIOR`/`JUNIOR`/`LIQUIDITY` dispatch with a revert default.
- `src/factory/*`, `src/interfaces/IRoycoFactory.sol`: a `deployMarketWithLT` path adding the fifth CREATE3 proxy and `LT_LP_ROLE`. The existing 4-contract `deployMarket` is untouched.
- `src/libraries/DayUtilsLib.sol`: wire in `computeLiquidityUtilization` with `ltRawNAV` as the BPT mark.
- `script/Deploy.s.sol`, `script/config/MarketDeploymentConfig.sol`, `script/upgrade/modules/*`: the LT deploy path and lockstep init updates. Existing literals and the live upgrade path unchanged.

Unchanged and reused: `src/libraries/AccountingLib.sol` (two-term, byte-for-byte Dawn), `src/auth/RoycoBlacklist.sol` (the LT inherits the batch screen through the existing hook), and the existing tranche Pendle SY wrapper (the LT share is a standard tranche token).

## Invariants

- Two-term NAV conservation holds, byte-for-byte Dawn: `stRaw + jtRaw == stEff + jtEff`. The premium is covered ST shares inside `stEff`, never a third leg.
- All senior is covered. `computeCoverageUtilization` uses `stRaw_total` with no exclusion and no composition reads.
- The premium mint is coverage-neutral: it adds no senior assets, only reassigns share ownership, so it does not move `coverageUtilization` or consume coverage capacity.
- `ltRawNAV` (the liquidity denominator) is the BPT only. The LT's idle premium shares never inflate it.
- `maxLiquidityPremiumWAD + maxRiskPremiumWAD <= WAD`.
- LDM and YDM outputs depend only on the last committed checkpoint, so the waterfall stays pure.
- Coverage math and the PERPETUAL/FIXED_TERM machine remain ST/JT only.
- `RoycoDayAccountant` with zero minimum liquidity equals `RoycoDawnAccountant`, byte-for-byte.

## Build sequence

Each phase is independently testable. ST and JT stay untouched throughout.

- P0, decisions gate. Settle the coverage-neutral premium-mint mechanism, the who-pays share math, the soft redemption and bank-run handling, the LDM floor, and acceptance that JT covers the LT base.
- P1, additive data model (inert). Land the append-only enum and LT config changes with LT fields defaulting to zero. Prove the storage layout is byte-identical for every pre-existing field with a `forge inspect` snapshot. The full existing suite stays green.
- P2, accountant premium and metric. Implement the LDM-driven `liqShare`, the post-sync coverage-neutral ST-share mint, and the liquidity metric, driven by a directly supplied `ltRawNAV` with no Balancer wiring. The anchor differential test (Day at zero liquidity equals Dawn) lands here.
- P3, LT vault and kernel custody. Build `RoycoLiquidityTranche` holding the BPT plus premium shares, the deposit, redeem, max, and preview paths, and the soft redemption gate. Preview must match execution.
- P4, Balancer oracle. Read `ltRawNAV` from Balancer's E-CLP oracle. Wire the rate provider (ST share NAV from the last committed sync) and the hook with the `router == kernel` carve-out.
- P5, deploy, factory, roles. Add the `deployMarketWithLT` path and the LT kernel type and roles. Regression: redeploy existing markets through the unchanged path and assert identical addresses, wiring, and roles.
- P6, economics and pre-mainnet hardening. Calibrate the LDM floor against the expected IL and illiquidity. Decide the `ltRawNAV` solvency-versus-realizable-depth question. Stress the redemption dynamics.

## Open decisions and pre-mainnet guardrails

- Coverage-neutral premium mint. The mint must add no senior assets and bypass the deposit coverage gate. Confirm the implementation reassigns share ownership only and cannot be mistaken for a new ST deposit that would consume coverage capacity.
- Who pays the premium. Confirm with the share math that plain ST holders fund the premium and the LT does not net pay its own premium.
- LT redemption and bank-run. With no hard 100% gate, decide whether the spiking premium curve is sufficient or whether a hard liquidation-style backstop is needed at an extreme utilization.
- LDM floor. The premium must clear the expected impermanent loss plus illiquidity, otherwise providing liquidity is irrational.
- JT sizing. JT now covers the LT base. Accept the capital-efficiency cost, which is the price paid for deleting the coverage-perimeter exclusion and its complexity.
- Realizable depth versus the solvency mark. `ltRawNAV` from the Balancer oracle is a solvency value, not exit depth. Decide whether to rebase the liquidity metric on realizable quote depth with a composition-drift breaker, or to accept and document the bound.
- ST supply seed. Ensure `ltRawNAV` is never zero against a positive `minLiquidity`, which would make `liquidityUtilization` infinite.
- Pool permissioning. Confirm the pool LP set equals the kernel, so external mint and burn cannot move the gate without the kernel knowing.
- Factory and ABI migration. New factory versus UUPS upgrade of the shared pre-deployed factory, the new accountant impl salt, and the indexer migration for the appended state.

## Resolved and removed

The covered-ST-shares model removed several earlier design problems. They are recorded here so they are not reopened.

- Three-term conservation and the 6-arg `enforceNAVConservation`. Removed. The waterfall stays two-term because the premium is covered ST shares in `stEff`, not a third NAV leg.
- The coverage-perimeter exclusion (`stRaw_covered = stRaw_total - ltPooledSeniorLeg`). Removed. Everything senior is covered.
- The dual-mark problem and the swap-manipulability of the perimeter subtraction. Removed with the subtraction.
- Premium compounding (single-sided versus swap-to-balanced) and its arb leakage. Removed. The premium is not compounded; external deposits are the restoring force.
- The LT self-insured-leg loss attribution and the line-45 underflow re-proof. Removed. The LT base is covered like any senior.
- The ported E-CLP valuation library, recursion, and bisection solver. Removed. `ltRawNAV` is Balancer's native oracle.
- A MasterChef-style rewards contract. Removed. The premium accrues into the LT vault share NAV, which keeps the LT a composable token for Pendle and Morpho.
