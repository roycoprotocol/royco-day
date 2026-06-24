# Royco Day: Liquidity Tranche (LT)

This branch is the next iteration of the Royco protocol. It adds a third tranche, the Liquidity Tranche (LT), on top of the Dawn senior/junior (ST/JT) system. The work is strictly additive. ST and JT behave exactly as they do in Dawn. The live ST/JT markets are never upgraded, never recompiled, and never touch any new code path or storage field.

If you are picking this up cold, read this file, then `src/libraries/AccountingLib.sol` (the waterfall) and `src/accountant/RoycoAccountant.sol` (`_previewSyncTrancheAccounting`, the sync orchestrator). The LT does not change either of those at the conservation level. That is the whole point of the design.

## Branch goal

Dawn guarantees a minimum coverage for senior shares. Royco Day adds a second service: secondary liquidity for senior shares. The LT is market-making capital that holds a Balancer pool of ST shares against a stablecoin, so ST holders have a venue to exit into. The LT is paid a liquidity premium out of ST yield, in the same way JT is paid a risk premium.

This separates two jobs that Dusk overloaded onto the junior tranche. In Dusk the JT was both first-loss coverage and pool liquidity, which forced one combined minimum tranche size. Here JT stays pure first-loss coverage exactly as Dawn, and the LT carries liquidity. Each issuer picks coverage and liquidity independently. The cost is more capital to raise.

## What the LT actually is

The LT is an ST holder that locks senior capital in a Balancer E-CLP BPT (ST shares paired against a quote stablecoin) to provide market-making liquidity, and earns extra senior yield (the liquidity premium) for doing so. It is fully covered senior, not self-insured. The premium compensates the illiquidity of the locked position and the impermanent loss of the LP, not waived coverage.

The LT share is pure BPT. The liquidity premium is reinvested into the pool the moment it is paid, so it grows the BPT rather than sitting beside it. A depositor brings BPT (or its constituents) and receives a claim on BPT, with nothing else in the basket. That keeps the LT share a clean, appreciating, transferable token: Pendle-wrappable through the existing tranche SY wrapper, and usable as Morpho collateral. There is no separate staking or rewards contract, because a staking contract would tie rewards to an address rather than to the token and break that composability.

This is a deliberate reversal of an earlier idle-premium design. Parking the premium as idle ST shares beside the BPT was rejected for two reasons. It makes the LT share a two-asset basket, so a depositor who brings market-making capital is forced to also buy a slice of idle senior shares. And it makes the premium inert: idle shares do not grow `ltRawNAV`, so the premium that is supposed to fund liquidity does nothing for liquidity. For a tranche whose entire job is market-making, the premium has to be productive. Route A makes it productive.

## Capital structure

- ST is protected senior capital, deployed into a yield-bearing asset. It pays the JT a risk premium and the LT a liquidity premium out of its yield.
- JT is first-loss capital. It provides coverage to ST on losses until exhausted, and earns the JT risk premium via the YDM. Unchanged from Dawn.
- LT is covered senior capital that also provides liquidity. It holds the BPT, grown by its reinvested premium, and earns the liquidity premium via the LDM.

Hard constraint: `maxLiquidityPremiumWAD + maxRiskPremiumWAD <= WAD` (100% of ST yield).

## The premium is covered ST shares (the load-bearing decision)

The liquidity premium is a portion of senior yield set by the LDM. It is paid as newly minted ST shares credited to the LT tranche and then reinvested into the BPT. The mint half of this is what keeps the accounting simple, and it has three consequences.

1. Coverage-neutral. Minting the premium as ST shares reassigns senior appreciation from plain ST to the LT. The senior raw NAV (`stRaw`) is unchanged, because no assets enter or leave the protocol, only share ownership shifts. So `coverageUtilization` does not move, JT bears no extra burden, and there is no lever-up. The mint must therefore be a privileged internal mint that bypasses the deposit coverage gate, because it adds no senior exposure.

2. Everything senior stays covered. Plain ST, the BPT's ST-share leg, and the reinvested premium shares are all senior claims in the coverage perimeter. Coverage uses `stRaw_total`, the vault mark of all ST shares, exactly as Dawn. There is no `stRaw_covered = stRaw_total - ltLeg` subtraction. That deletes both the dual-mark problem (subtracting a Balancer mark from a vault mark) and the swap-manipulability of any such subtraction. Reinvesting the shares into the pool does not change this. The shares are still senior claims, whether they sit in the pool or are later bought out by an arbitrageur. Coverage is on every ST share that exists, regardless of who holds it.

3. The waterfall stays two-term. The premium shares are senior, so they live in `stEff`. The `liqShare` only decides how the senior appreciation of a sync is apportioned between plain ST and the LT. It does not add a third NAV leg. `AccountingLib` keeps `stRaw + jtRaw == stEff + jtEff` byte-for-byte. There is no 6-arg conservation, no LT leg in the checkpoint, and no change to `STEP_APPLY_JT_COVERAGE_TO_ST` or the attribution path.

The `liqShare` mint happens as a post-sync step in `RoycoDayAccountant`, after the unchanged Dawn waterfall has computed the senior gain. It is NAV-neutral (a share mint against value already in the pool), so it sits outside the waterfall conservation entirely. The reinvestment that follows the mint is a kernel action, not an accounting one. It moves the minted shares into the BPT and is bounded by a min-BPT-out, but it does not touch the conservation identity.

## The yield split

On the up path of a sync, after JT coverage IL recovery clears:

1. JT risk premium (existing, unchanged): `riskShare = floor(stGain * jtFracWAD)`, routed to `jtEffectiveNAV` via the YDM. This is Dawn.
2. LT liquidity premium (new): `liqShare = floor(stGain * ltFracWAD)`, set by the LDM, minted as ST shares to the LT tranche and reinvested into the BPT.
3. ST keeps the residual.

The joint cap `maxLiquidityPremiumWAD + maxRiskPremiumWAD <= WAD` is validated at `initialize` and in both setters. Because both shares are fractions of the same senior gain, the combined draw cannot exceed it. Who pays: plain ST holders fund the premium through the dilution; the LT's own base partially self-funds and nets positive. The share math must be written out once to confirm the LT is not net paying its own premium.

## Premium reinvestment (Route A): single-sided add

The premium is reinvested by single-sided adding the freshly minted ST shares into the E-CLP BPT, inside `Vault.unlock`, bounded by a min-BPT-out. This is Route A. It is the default and the only reinvestment path the protocol ships.

This is the right shape for a liquidity tranche because it makes the premium grow real depth. The reinvested shares raise `ltRawNAV` directly, which delevers `liquidityUtilization` at the source rather than waiting for external deposits to arrive. The LT share stays pure BPT. The premium is productive.

Route A has a known, bounded cost. The kernel injects only senior into the pool, so the net pool delta of a reinvestment is `(senior += V, quote += 0)`. The pool ends senior-heavy. An external arbitrageur rebalances it by injecting quote and lifting the senior overhang, and captures the rebalancing spread in doing so. So the LT receives BPT worth roughly `V` minus that spread. The leak per reinvestment is approximately `V^2 / (2 * A * D)` in pool-curvature terms (with `A` the E-CLP near-peg amplification and `D` the senior-leg depth) plus a temporal term on the order of `sigma * V` from drift between the mint and the arb. For a near-peg pair done in small, frequent adds this is single-digit basis points of `V`. Smaller and more frequent reinvestments shrink it, because the structural term falls with `V`.

Two things follow that the code must respect.

Route B is rejected, with proof. Route B is the on-chain rebalance variant: swap half the minted senior to quote inside the pool, then add balanced. It nets the identical `(senior += V, quote += 0)` because the swap is internal to a pool the LT wholly owns, and it adds a sandwichable stale-rate internal swap on top. So Route B carries the same structural leak as Route A plus an extra sandwich, and is strictly dominated. Do not implement it. Its only legitimate use is enabling adds on proportional-only pools, which does not apply here.

The buffered supplier is the no-leak upgrade. The only way to add real quote depth without donating the rebalancing spread is to source the quote leg directly, so the add is balanced. An external supplier (or the protocol treasury) provides quote against the minted senior, and the protocol pays a bounded incentive `c` (on the order of 5 to 30 basis points) instead of leaking the uncontrolled arb spread. This is the path to growing genuine two-sided depth at a controlled cost. Adopt it where a market can source the quote side. It is a strict improvement over Route A on cost, at the price of a supplier role to wire.

## The two metrics

### Coverage (unchanged from Dawn)

```
coverageUtilization = (stRaw_total + jtRaw * beta) * minCoverage / jtEffectiveNAV
```

`stRaw_total` is the vault mark of every ST share, including the LT's pooled base and its reinvested premium shares. No exclusion, no composition reads, swap-stable. `computeCoverageUtilization` is byte-for-byte Dawn, and at zero liquidity a Day market produces identical coverage to Dawn.

### Liquidity

```
liquidityUtilization = stEffectiveNAV * minLiquidity / ltRawNAV
```

`ltRawNAV` is the BPT value from Balancer's E-CLP oracle, the actual pool depth that backs ST exits. It is the BPT only. It is not the LT tranche's total NAV, though under Route A the two coincide, because the LT holds only BPT.

Both inputs are manipulation-resistant: `stEffectiveNAV` is total senior NAV (swaps in the pool do not change it), and `ltRawNAV` is the Balancer oracle. There is no composition subtraction in the numerator.

`liquidityUtilization` is allowed to drift above 100%. It has two restoring forces. The primary one is the reinvested premium, which raises `ltRawNAV` directly every sync. The secondary one is external LT deposits, pulled in by a higher LDM premium when utilization is high, exactly as JT deposits clear coverage utilization in the YDM. Note the important limit: `liquidityUtilization` is a solvency mark, not realizable exit depth. It is the right input for pricing the premium. It is the wrong input for gating a redemption, because the BPT can mark healthy while the realizable quote leg is drained. The run gate is reserve-based and lives in the redemption logic, not on this metric. See redemption below.

### LDM

The Liquidity Distribution Model is the general-purpose YDM, which now takes a utilization input directly, instantiated with a liquidity target and driven by `liquidityUtilization`. It is the same contract family as the JT's YDM. The floor matters: the premium must clear the LT's real holding cost, or providing liquidity is irrational. That real cost is small for the regime this product targets, for the reasons in the capital realism section. The LDM floor is calibrated against that cost, not against a generic volatile-pair LP cost.

### ltRawNAV from Balancer's E-CLP oracle

`ltRawNAV` is read from Balancer's native Gyro E-CLP manipulation-resistant oracle for the BPT. There is no ported valuation library, no custom recursion, and no bisection solver. The pool prices the ST share via a rate provider that reports the ST share NAV from the last committed sync, so the rate is a per-sync resolved input, not a within-call fixed point. The Balancer mark is single-block manipulation-resistant. It is a solvency value, not realizable exit depth, and can overstate liquidity under sustained quote depeg or arbitrage halt.

## Capital realism: the LT market-makes a covered asset

An earlier analysis flagged the LT as negative expected value on a generic LP cost stack of 1 to 3 percent per year. That framing is rejected. It modeled a generic volatile-pair LP and ignored two facts specific to this system.

The asset being market-made is covered. ST is protected by JT, so in the covered range an ST share cannot fall. The flow the LT faces is therefore not toxic. An informed seller exiting ahead of a loss does not pick the LT off, because the loss is absorbed by JT and the share does not drop. The only regime where the senior share actually falls is past coverage exhaustion, which is FIXED_TERM, where the LT is locked alongside everyone else and is not transacting. Adverse selection is bounded by coverage, not open-ended.

The state machine bounds the exposure. In FIXED_TERM, deposits and redeems are disabled for every tranche, so the LT cannot be run and is not exposed to a drawdown exit it cannot make. In PERPETUAL with healthy liquidity, the LT redeems like any ST holder. In PERPETUAL with stressed liquidity, LT redemption is subordinated to ST's claim. So the LT is paid a premium precisely in the states where it can transact, and is locked, covered, and unpaid in the state where everyone is locked.

The one real residual cost is rate-staleness LVR. The ST leg is priced at the last committed sync NAV, and a yield-bearing share marks up predictably between syncs, so an arbitrageur can buy ST cheap against the stale rate just before a sync. This is genuine and route-independent, but it is bounded by sync frequency (the rate refreshes on every kernel interaction, so an active market is barely stale) and it is recapturable by a directional fee that charges the yield-direction trade more. For a covered, near-peg, actively-synced market it is small.

The conclusion: the LT's real holding cost is rate-staleness LVR plus minor near-peg impermanent loss, not the generic stack. The LDM floor is sized to that, and is plausibly cleared by a modest premium plus swap fees, leaving the LT positive carry. The binding constraints are sync cadence and a directional fee, not capital flight.

## Redemption and the no-run guarantee

Redemption is structured so there is no run, without relying on a hard utilization gate or a lockup.

The default redemption is in-kind and proportional. An LT holder burns LT shares for a proportional slice of the BPT, taken as a sandwich-safe proportional `removeLiquidity`. This is ratio-invariant. It reads no composition, it cannot drain one side of the pool, and it gives no first-mover advantage, so there is no run fixed point. This is the path that makes lockups unnecessary, which is what preserves Pendle and Morpho composability.

A cash redemption path, where the holder wants the quote stable rather than a BPT slice, is a bounded exception. It is capped at `min(requested, quote_balance - ST_reserved_quote_claim)`. That cap is the only live pool-balance read in the system. It is one-directional, and it never feeds coverage or the premium. This is the actual run gate, and it is reserve-based, so it cannot be gamed by marking the BPT healthy.

The solvency metric prices the premium. The reserve cap gates the cash exit. These are two different numbers for two different jobs, and conflating them is the bug the run analysis surfaced.

FIXED_TERM locks everyone, including the LT, so the drawdown run vector does not exist. The LT's principal is covered through the lock.

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

The LT tranche is a Royco vault tranche that holds the BPT and nothing else. The premium is reinvested into the BPT, so the LT share is a pure BPT claim and the LT share NAV equals `ltRawNAV`.

Deposits: `ltDeposit` takes a pre-minted BPT. `ltDepositMultiAsset` is the atomic flow that pulls the ST asset and the quote stable, mints the ST share, performs the Balancer join, and mints the LT share inside `Vault.unlock`, bounded by `minBptOut`, a max-asset-in per token, and a deadline.

Redemptions: the default is the in-kind proportional BPT slice described above. The cash path is the bounded, reserve-capped exception. There is no separate premium leg to compute, because the premium is already in the BPT.

The kernel custodies the BPT, performs the joins and exits, executes the coverage-neutral premium-share mint, and performs the single-sided reinvestment add. The blacklist, seize, and zero-supply and zero-NAV boundaries carry over from the tranche base unchanged.

## Contract map

New:
- `src/accountant/RoycoDayAccountant.sol`: extends the Dawn accountant. Resolves the LDM and signals the post-sync coverage-neutral premium-share mint. Computes the liquidity metric. Separate impl and deploy salt.
- `src/interfaces/IRoycoLiquidityKernel.sol`, `src/kernels/base/RoycoLiquidityKernel.sol`, `src/kernels/liquidity/*`: the LT-aware kernel. Custodies and joins/exits the BPT, mints premium ST shares to the LT tranche, and reinvests them via the single-sided add.
- `src/tranches/RoycoLiquidityTranche.sol`: the LT vault tranche, holding the BPT.
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
- All senior is covered. `computeCoverageUtilization` uses `stRaw_total` with no exclusion and no composition reads. Reinvesting the premium into the pool does not change which shares are covered.
- The premium mint is coverage-neutral: it adds no senior assets, only reassigns share ownership, so it does not move `coverageUtilization` or consume coverage capacity.
- The reinvestment is bounded by a min-BPT-out and changes `ltRawNAV`, not the conservation identity.
- The LT share is pure BPT, so the LT share NAV equals `ltRawNAV`.
- `maxLiquidityPremiumWAD + maxRiskPremiumWAD <= WAD`.
- LDM and YDM outputs depend only on the last committed checkpoint, so the waterfall stays pure.
- Coverage math and the PERPETUAL/FIXED_TERM machine remain ST/JT only.
- The cash redemption cap is the only live pool-balance read, one-directional, never feeding coverage or the premium.
- `RoycoDayAccountant` with zero minimum liquidity equals `RoycoDawnAccountant`, byte-for-byte.

## Build sequence

Each phase is independently testable. ST and JT stay untouched throughout.

- P0, decisions gate. Settle the coverage-neutral premium-mint mechanism, the who-pays share math, the in-kind redemption and reserve-capped cash path, the LDM floor against the real (rate-staleness plus near-peg IL) cost, and acceptance that JT covers the LT base.
- P1, additive data model (inert). Land the append-only enum and LT config changes with LT fields defaulting to zero. Prove the storage layout is byte-identical for every pre-existing field with a `forge inspect` snapshot. The full existing suite stays green.
- P2, accountant premium and metric. Implement the LDM-driven `liqShare`, the post-sync coverage-neutral ST-share mint, and the liquidity metric, driven by a directly supplied `ltRawNAV` with no Balancer wiring. The anchor differential test (Day at zero liquidity equals Dawn) lands here.
- P3, LT vault and kernel custody and reinvestment. Build `RoycoLiquidityTranche` holding the BPT, the deposit, redeem, max, and preview paths, the in-kind proportional redemption and the reserve-capped cash path, and the single-sided reinvestment add. Preview must match execution.
- P4, Balancer oracle. Read `ltRawNAV` from Balancer's E-CLP oracle. Wire the rate provider (ST share NAV from the last committed sync) and the hook with the `router == kernel` carve-out.
- P5, deploy, factory, roles. Add the `deployMarketWithLT` path and the LT kernel type and roles. Regression: redeploy existing markets through the unchanged path and assert identical addresses, wiring, and roles.
- P6, economics and pre-mainnet hardening. Calibrate the LDM floor against rate-staleness LVR and near-peg IL. Set the reinvestment cadence and the directional fee. Stress the redemption dynamics. Decide whether to enable the buffered supplier for a given market.

## Open decisions and pre-mainnet guardrails

- Coverage-neutral premium mint. The mint must add no senior assets and bypass the deposit coverage gate. Confirm the implementation reassigns share ownership only and cannot be mistaken for a new ST deposit that would consume coverage capacity.
- Who pays the premium. Confirm with the share math that plain ST holders fund the premium and the LT does not net pay its own premium.
- Reinvestment cadence and the arb tax. Size the single-sided add to keep the per-event leak small, favoring frequent small adds. Decide the min-BPT-out tolerance. Quantify the leak against `A` and `D` for each market.
- Directional fee. Decide the pool fee schedule that recaptures the rate-staleness LVR on the yield-direction trade.
- LDM floor. The premium must clear rate-staleness LVR plus near-peg IL. Confirm the floor clears it at a feasible `maxLiquidityPremium` for the target markets.
- Buffered supplier. Decide per market whether to source the quote leg externally for a controlled incentive `c` rather than donate the rebalancing spread. This is the only path to no-leak two-sided depth growth.
- JT sizing. JT now covers the LT base. Accept the capital-efficiency cost, which is the price paid for deleting the coverage-perimeter exclusion and its complexity.
- Realizable depth versus the solvency mark. `ltRawNAV` from the Balancer oracle is a solvency value, not exit depth. The in-kind redemption and the reserve-capped cash path already insulate the run gate from this. Decide whether any additional composition-drift breaker is wanted, or accept and document the bound.
- ST supply seed. Ensure `ltRawNAV` is never zero against a positive `minLiquidity`, which would make `liquidityUtilization` infinite.
- Pool permissioning. Confirm the pool LP set equals the kernel, so external mint and burn cannot move the gate without the kernel knowing.
- Factory and ABI migration. New factory versus UUPS upgrade of the shared pre-deployed factory, the new accountant impl salt, and the indexer migration for the appended state.

## Resolved and removed

These earlier design problems are recorded here so they are not reopened.

- Three-term conservation and the 6-arg `enforceNAVConservation`. Removed. The waterfall stays two-term because the premium is covered ST shares in `stEff`, not a third NAV leg.
- The coverage-perimeter exclusion (`stRaw_covered = stRaw_total - ltPooledSeniorLeg`). Removed. Everything senior is covered.
- The dual-mark problem and the swap-manipulability of the perimeter subtraction. Removed with the subtraction.
- The idle-premium basket. Removed. Parking the premium as idle ST shares beside the BPT made the LT share a two-asset basket, forced depositors to buy idle shares, and made the premium inert against `ltRawNAV`. Route A reinvests the premium into the BPT instead, keeping the LT share pure BPT and the premium productive.
- Route B, the on-chain rebalance variant. Rejected with proof. It nets the same `(senior += V, quote += 0)` as Route A and adds a sandwichable internal swap, so it is strictly dominated.
- The LT self-insured-leg loss attribution and the line-45 underflow re-proof. Removed. The LT base is covered like any senior.
- The ported E-CLP valuation library, recursion, and bisection solver. Removed. `ltRawNAV` is Balancer's native oracle.
- A MasterChef-style rewards contract. Removed. The premium reinvests into the BPT and the LT share stays a composable token for Pendle and Morpho.
- The negative-EV capital framing on a generic LP cost stack. Rejected. The LT market-makes a covered asset, so adverse selection is bounded by coverage, and the real holding cost is rate-staleness LVR plus near-peg IL.
- Using `liquidityUtilization` as the redemption gate. Removed. It is a solvency mark used for pricing the premium. The run gate is the reserve-capped cash path.
