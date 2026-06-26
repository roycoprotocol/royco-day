# Royco Day: Liquidity Tranche (LT)

Royco Day is the next iteration of the Royco protocol. It is a standalone fork of Royco Dawn, in its own repository, that adds a third tranche, the Liquidity Tranche (LT), to the senior/junior (ST/JT) system. Day is a clean break: the ST/JT engine is copied in and owned here, not inherited from Dawn, not shared with Dawn, and not coupled to it across repos. There is no requirement that Day's ST/JT match Dawn byte-for-byte. The fork is deliberate, chosen for auditability and end-to-end traceability: every line that executes for a Day market lives in this one repo, in order, with nothing shared with another product and no inheritance indirection. The cost, accepted knowingly, is manual parity: a fix to the Dawn ST/JT engine does not propagate here automatically and must be ported by hand.

If you are picking this up cold, read this file, then the waterfall library and the accountant's sync orchestrator. The LT is an overlay on the ST/JT senior-gain split; it does not change the loss waterfall or the conservation identity. That is the whole point of the design.

## Branch goal

Dawn guarantees a minimum coverage for senior shares. Royco Day adds a second service: secondary liquidity for senior shares. The LT is market-making capital that holds a Balancer pool of ST shares against a stablecoin, so ST holders have a venue to exit into. The LT is paid a liquidity premium out of ST yield, in the same way JT is paid a risk premium.

This separates two jobs that Dusk overloaded onto the junior tranche. In Dusk the JT was both first-loss coverage and pool liquidity, which forced one combined minimum tranche size. Here JT stays pure first-loss coverage exactly as Dawn, and the LT carries liquidity. Each issuer picks coverage and liquidity independently. The cost is more capital to raise.

## What the LT actually is

The LT is an ST holder that locks senior capital in a Balancer E-CLP BPT (ST shares paired against a quote stablecoin) to provide market-making liquidity, and earns extra senior yield (the liquidity premium) for doing so. It is fully covered senior, not self-insured. The premium compensates the illiquidity of the locked position and the impermanent loss of the LP, not waived coverage.

The LT share is pure BPT. The liquidity premium is deployed into the pool as BPT — directly when it can be added without leaking, and otherwise from a kernel-staged buffer held outside the LT share NAV until it deploys — so it grows the BPT rather than sitting in the share as a second asset. A depositor brings BPT (or its constituents) and receives a claim on BPT, with nothing else in the basket. That keeps the LT share a clean, appreciating, transferable token: Pendle-wrappable through the existing tranche SY wrapper, and usable as Morpho collateral. There is no separate staking or rewards contract, because a staking contract would tie rewards to an address rather than to the token and break that composability.

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

The `liqShare` mint happens as a post-sync step in `RoycoDayAccountant`, after the waterfall has computed the senior gain. It is NAV-neutral (a share mint against value already in the pool), so it sits outside the waterfall conservation entirely. The reinvestment that follows the mint is a kernel action, not an accounting one. It moves the minted shares into the BPT and is bounded by a min-BPT-out, but it does not touch the conservation identity.

## The yield split

On the up path of a sync, after JT coverage IL recovery clears:

1. JT risk premium (existing, unchanged): `riskShare = floor(stGain * jtFracWAD)`, routed to `jtEffectiveNAV` via the YDM. This is Dawn.
2. LT liquidity premium (new): `liqShare = floor(stGain * ltFracWAD)`, set by the LDM, minted as ST shares to the LT tranche and reinvested into the BPT.
3. ST keeps the residual.

The joint cap `maxLiquidityPremiumWAD + maxRiskPremiumWAD <= WAD` is validated at `initialize` and in both setters. Because both shares are fractions of the same senior gain, the combined draw cannot exceed it. Who pays: plain ST holders fund the premium through the dilution; the LT's own base partially self-funds and nets positive. The share math must be written out once to confirm the LT is not net paying its own premium.

## Premium deployment: gated single-sided add, staged buffer, auction fallback

The premium is deployed into the E-CLP BPT by single-sided adding the freshly minted ST shares, inside `Vault.unlock`, bounded by a min-BPT-out. This single-sided add is Route A, the default path for the regime this product targets: a near-peg pair with small, frequent adds. The deployed shares raise `ltRawNAV` directly, which delevers `liquidityUtilization` at the source rather than waiting for external deposits. The premium grows real depth, the share price stays up-only, and the LT share stays pure BPT.

Route A has a known, bounded cost. The kernel injects only senior into the pool, so the net pool delta is `(senior += V, quote += 0)`. The pool ends senior-heavy; an external arbitrageur rebalances it by injecting quote and lifting the senior overhang, capturing the rebalancing spread. The LT receives BPT worth roughly `V` minus that spread. The leak per add is approximately `V^2 / (2 * A * D)` in pool-curvature terms (with `A` the E-CLP near-peg amplification and `D` the senior-leg depth) plus a temporal term on the order of `sigma * V` from drift between the mint and the arb. For a near-peg pair done in small, frequent adds this is single-digit basis points of `V`, and it falls quadratically as `V` shrinks. So the first lever is cadence: the premium accrues every sync, and deploying it per sync rather than batching to infrequent oracle updates keeps `V` small and the leak negligible.

The single-sided add is gated, not unconditional. The kernel only single-sided adds when the realized slippage is below a threshold (on the order of 10 bps); above the threshold the add is deferred to the auction fallback below. The slippage gate is the primary manipulation defense — it makes a large, sandwichable lump add impossible, and the mere existence of the auction fallback deters manipulation even when it is rarely triggered. Two further defenses harden the gate. Swaps are blocked in the same block as a P&L sync, so an attacker cannot atomically sync-then-swap and cannot guarantee the back-run; the rate refreshes between the sync and any swap. And the pool fee schedule is set to recapture the rate-staleness LVR — preferably as a directional fee that charges the yield-direction trade more, rather than a flat fee, which would tax the legitimate ST-exit flow the LT exists to serve.

Un-deployed premium is held as a kernel-staged buffer of ST shares, outside every marked NAV. This is the load-bearing accounting decision for the deferred path. The staged shares are not in `ltRawNAV` (so the metric correctly still reads under-provisioned and keeps the LDM paying until real depth lands) and not in the LT share NAV (so the LT share stays pure BPT, the in-kind redemption stays a single-leg BPT slice, and the Pendle/Morpho composability is preserved). The premium therefore realizes to LT holders as BPT appreciation at deploy time, not at accrual: it is vesting-like, and an LT holder who redeems while a premium is staged forfeits its pro-rata slice to whoever is in the pool when it deploys. The staged shares remain senior claims inside `stEff`, so coverage still covers them and the mint stays NAV-neutral and coverage-neutral; they are value in transit, not value lost. The one invariant the staged buffer demands is a bound on its size: under sustained high slippage the buffer could grow while the metric never heals, so the staged pile is bounded either by its natural alignment with FIXED_TERM (where the LT is locked and unpaid, so nothing accrues to stage) or by an explicit LDM pause / forced deploy once the buffer exceeds a threshold of `ltRawNAV`.

The auction fallback drains the staged buffer at a controlled cost. It is a Dutch auction that starts at the ST share NAV (the fair upper bound) and decreases to a floor set by the time-weighted average pool quote for the one-sided deposit, then restarts. A solver that meets the clearing price supplies the quote leg against the staged senior, so the add lands balanced and the protocol pays the auction discount (NAV minus clearing price) instead of donating the uncontrolled arb spread. The auction is therefore the buffered supplier mechanism with a market-discovered incentive `c`, rather than a fixed 5-to-30-bps `c`. If no bidder meets the quote the cycle retries with no forced loss; an emergency button can force the deposit at market price, accepting a minor yield delay, so the buffer can always be drained. The open problem is solver-network bootstrapping: until a solver network exists the auction will not clear, so early-life the operative path is the gated single-sided add plus the emergency force-deploy, and the auction becomes load-bearing only once solvers are present.

Route B is rejected, with proof. Route B is the on-chain rebalance variant: swap half the minted senior to quote inside the pool, then add balanced. It nets the identical `(senior += V, quote += 0)` because the swap is internal to a pool the LT wholly owns, and it adds a sandwichable stale-rate internal swap on top. So Route B carries the same structural leak as Route A plus an extra sandwich, and is strictly dominated. Do not implement it. (An external swap on a separate venue nets the same delta without the internal sandwich, but imports external-venue MEV and a venue dependency, so it is not a default path either.)

Distributing the premium as claimable reward tokens is retained only as a documented break-glass, not the mechanism. It is safer against LP MEV, but it reintroduces exactly what the pure-BPT design removed: it ties value to an address rather than the token (breaking Pendle and Morpho composability) and makes the premium inert against `ltRawNAV`, so it stops being a restoring force on `liquidityUtilization`. In that mode the LDM's self-healing loop is gone — it is a different product, used only if every deploy path fails.

## The two metrics

### Coverage (unchanged from Dawn)

```
coverageUtilization = (stRaw_total + jtRaw * beta) * minCoverage / jtEffectiveNAV
```

`stRaw_total` is the vault mark of every ST share, including the LT's pooled base and its reinvested premium shares. No exclusion, no composition reads, swap-stable. The coverage utilization computation is the Dawn formula, carried over unchanged, and the LT never touches it. At zero liquidity a Day market's coverage is just the plain ST/JT coverage.

### Liquidity

```
liquidityUtilization = stEffectiveNAV * minLiquidity / ltRawNAV
```

`ltRawNAV` is the BPT value from Balancer's E-CLP oracle, the actual pool depth that backs ST exits. It is the BPT only. It coincides with the LT share NAV, because the LT share NAV is pure BPT: any un-deployed premium is staged outside the marked NAV and lands as BPT on deploy, so neither `ltRawNAV` nor the LT share carries it until it is real depth.

Both inputs are manipulation-resistant: `stEffectiveNAV` is total senior NAV (swaps in the pool do not change it), and `ltRawNAV` is the Balancer oracle. There is no composition subtraction in the numerator.

`liquidityUtilization` is allowed to drift above 100%. It has two restoring forces. The primary one is the deployed premium, which raises `ltRawNAV` directly as it lands (every sync when slippage permits a small add, or via the auction when it does not). The secondary one is external LT deposits, pulled in by a higher LDM premium when utilization is high, exactly as JT deposits clear coverage utilization in the YDM. Note the important limit: `liquidityUtilization` is a solvency mark, not realizable exit depth. It is the right input for pricing the premium. It is the wrong input for gating a redemption, because the BPT can mark healthy while the realizable quote leg is drained. The run gate is reserve-based and lives in the redemption logic, not on this metric. See redemption below.

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

## Accountant architecture: standalone, forked

`RoycoDayAccountant` is a standalone contract. It does not extend a Dawn base, and there is no inheritance from Dawn anywhere in the repo. It owns the full ST/JT engine directly: the loss waterfall, the coverage math, the state machine, the protocol fees, and the YDM resolution all live in this codebase and read top to bottom. The heavy math stays in libraries the accountant calls (the waterfall library, the coverage and utilization library) so it is not inlined twice, but the sync orchestration, the state, the setters, and the events are the accountant's own, with no shared base and no dead inherited surface.

The LT is added directly on top: a third set of config and state fields, an LDM resolved at sync time, and a post-sync overlay that computes the liquidity premium from the senior gain and signals the coverage-neutral premium-share mint. The accountant's sync entrypoints carry the LT pool mark (`ltRawNAV`) alongside the ST and JT marks, because the sync checkpoints all three.

There is no cross-repo guarantee and no differential anchor test against Dawn. Day's ST/JT correctness is established by Day's own test suite, on its own terms. A Day market at zero minimum liquidity should behave like a plain ST/JT market, and that is verified here, not asserted against another repo.

## Self-contained fork principle

- The repo is the unit of audit. Everything a Day market executes, deploy through redeem, lives here. There is no submodule on Dawn and no cross-repo source dependency, because that would re-introduce the coupling the fork exists to remove.
- No inheritance. Contracts are flat or compose through explicit libraries, never through a shared base that also serves Dawn. There are no inherited functions a Day contract does not use.
- Naming is flattened to Day. The senior/junior engine is the Day accountant's own. Carry over the good names from Dawn but drop the "this is the Dawn base" framing, since there is no base.
- The liquidity gate is orthogonal to coverage. It never modifies coverage config, the coverage requirement check, the coverage utilization computation, or the forced-perpetual conditions. The LT is strictly additional capital structure on top of a self-contained ST/JT engine.
- Parity is manual and intentional. Where Day's ST/JT logic mirrors Dawn's it does so by copy, and any later Dawn fix is ported deliberately. This is the trade made for end-to-end auditability.
- Storage layout and enum ordinals are chosen cleanly. There is no deployed Day market to stay compatible with, so `TrancheType` carries `LIQUIDITY` and `Operation` carries `LT_DEPOSIT`/`LT_REDEEM` as first-class members, not appended-for-compatibility ordinals.

## LT tranche and kernel

The LT tranche is a Royco vault tranche that holds the BPT and nothing else. The premium is deployed into the BPT, or staged outside the LT share NAV until it deploys, so the LT share is a pure BPT claim and the LT share NAV equals `ltRawNAV`.

Deposits: `ltDeposit` takes a pre-minted BPT. `ltDepositMultiAsset` is the atomic flow that pulls the ST asset and the quote stable, mints the ST share, performs the Balancer join, and mints the LT share inside `Vault.unlock`, bounded by `minBptOut`, a max-asset-in per token, and a deadline.

Redemptions: the default is the in-kind proportional BPT slice described above. The cash path is the bounded, reserve-capped exception. There is no separate premium leg to compute on redemption: deployed premium is already in the BPT, and un-deployed premium is staged outside the LT share NAV, so it lands as BPT on deploy and is realized to whoever holds the share then.

The kernel custodies the BPT, performs the joins and exits, executes the coverage-neutral premium-share mint, holds the staged premium buffer outside the marked NAV, and performs the gated single-sided add (or the auction-fallback deploy). The blacklist, seize, and zero-supply and zero-NAV boundaries carry over from the tranche base unchanged.

## Contract map

This is a self-contained repo, so there is no "new versus modified" split against an upstream. The key pieces:

- `RoycoDayAccountant`: the standalone accountant. Owns the ST/JT engine (waterfall, coverage, state machine, fees, YDM) and the LT overlay (LDM resolution, the post-sync coverage-neutral premium-share mint, the liquidity metric). Sync entrypoints carry `stRawNAV`, `jtRawNAV`, and `ltRawNAV`.
- The accounting and utilization libraries: the two-term loss waterfall and the coverage and liquidity utilization math, called by the accountant. Pure and stateless, the heavy logic kept out of the contract body.
- The LT-aware kernel: custodies the BPT, performs the joins and exits, executes the coverage-neutral premium-share mint, holds the staged premium buffer outside the marked NAV, performs the gated single-sided add and the auction-fallback deploy, and drives the three-NAV sync. It owns the ST/JT kernel logic directly as well.
- `RoycoLiquidityTranche`: the LT vault tranche, holding the BPT.
- The LDM (`src/ldm/*`): the liquidity distribution model, the general-purpose YDM family driven by `liquidityUtilization`.
- The Balancer E-CLP oracle adapter (`src/oracles/venues/balancer-v3/*`): reads Balancer's native E-CLP oracle for `ltRawNAV`, plus the rate provider and the pool hook. No valuation math is reimplemented. The abstraction lets any AMM or MM vault back the LT; Balancer E-CLP is first.
- The factory, deploy scripts, and config: a single Day deployment path that wires the market's tranches (ST, JT, LT) plus the kernel and accountant. There is no second legacy path to keep compiling, because this repo only ships Day markets.
- Reused as-is from the Dawn codebase: the blacklist batch screen (the LT picks it up through the existing hook) and the tranche Pendle SY wrapper (the LT share is a standard tranche token). These are copied in and owned here like everything else.

The tranche dispatch handles `SENIOR`/`JUNIOR`/`LIQUIDITY` with a revert default. Since the repo is fresh, enum ordinals and storage layout are chosen cleanly rather than appended for compatibility.

## Invariants

- Two-term NAV conservation holds at wei precision: `stRaw + jtRaw == stEff + jtEff`. The premium is covered ST shares inside `stEff`, never a third leg.
- All senior is covered. `computeCoverageUtilization` uses `stRaw_total` with no exclusion and no composition reads. Reinvesting the premium into the pool does not change which shares are covered.
- The premium mint is coverage-neutral: it adds no senior assets, only reassigns share ownership, so it does not move `coverageUtilization` or consume coverage capacity.
- The reinvestment is bounded by a min-BPT-out and changes `ltRawNAV`, not the conservation identity.
- The LT share is pure BPT, so the LT share NAV equals `ltRawNAV`. Un-deployed premium is staged outside the marked NAV (neither in `ltRawNAV` nor in the LT share NAV) and lands as BPT on deploy, so the premium is realized to LT holders on deploy, not on accrual.
- `maxLiquidityPremiumWAD + maxRiskPremiumWAD <= WAD`.
- LDM and YDM outputs depend only on the last committed checkpoint, so the waterfall stays pure.
- Coverage math and the PERPETUAL/FIXED_TERM machine remain ST/JT only.
- The cash redemption cap is the only live pool-balance read, one-directional, never feeding coverage or the premium.
- A Day market at zero minimum liquidity behaves like a plain ST/JT market, verified by Day's own suite rather than asserted against another repo.

## Build sequence

Each phase is independently testable.

- P0, fork and decisions gate. Stand up the repo from the Dawn copy, strip what Day does not use, drop the inheritance seams, and flatten naming to Day. Settle the coverage-neutral premium-mint mechanism, the who-pays share math, the in-kind redemption and reserve-capped cash path, the LDM floor against the real (rate-staleness plus near-peg IL) cost, and acceptance that JT covers the LT base.
- P1, data model. Land the tranche enum, the `Operation` members, and the LT config and state fields as first-class members, chosen cleanly. A Day market at zero minimum liquidity reduces to a plain ST/JT market; lock that in with a test.
- P2, accountant premium and metric. Implement the LDM-driven `liqShare`, the post-sync coverage-neutral ST-share mint, and the liquidity metric, driven by a directly supplied `ltRawNAV` with no Balancer wiring. Verify the zero-liquidity reduction here.
- P3, LT vault and kernel custody and deployment. Build `RoycoLiquidityTranche` holding the BPT, the deposit, redeem, max, and preview paths, the in-kind proportional redemption and the reserve-capped cash path, the gated single-sided add, the staged premium buffer, and the auction-fallback deploy. Preview must match execution.
- P4, Balancer oracle. Read `ltRawNAV` from Balancer's E-CLP oracle. Wire the rate provider (ST share NAV from the last committed sync) and the hook with the `router == kernel` carve-out.
- P5, deploy, factory, roles. Build the single Day market deployment path (tranches, kernel, accountant) and the LT kernel type and roles. Assert addresses, wiring, and roles for a freshly deployed Day market.
- P6, economics and pre-mainnet hardening. Calibrate the LDM floor against rate-staleness LVR and near-peg IL. Set the deploy cadence, the slippage-gate threshold, the directional fee, and the staged-buffer bound. Decide whether to enable the auction fallback (the buffered supplier with a market-discovered incentive) for a given market. Stress the redemption dynamics.

## Open decisions and pre-mainnet guardrails

- Coverage-neutral premium mint. The mint must add no senior assets and bypass the deposit coverage gate. Confirm the implementation reassigns share ownership only and cannot be mistaken for a new ST deposit that would consume coverage capacity.
- Who pays the premium. Confirm with the share math that plain ST holders fund the premium and the LT does not net pay its own premium.
- Deploy cadence and the arb tax. Size the single-sided add to keep the per-event leak small, favoring frequent small adds (deploy per sync, do not batch). Decide the min-BPT-out tolerance. Quantify the leak against `A` and `D` for each market.
- Slippage gate and the same-block-swap rule. Set the slippage threshold (~10 bps) above which the add defers to the auction. Block swaps in the same block as a P&L sync so an attacker cannot atomically sync-then-swap and guarantee the back-run.
- Staged buffer bound. Un-deployed premium is staged outside every marked NAV and realized to LT holders on deploy (vesting-like). Bound the staged pile so a stuck auction cannot grow it unboundedly: confirm its natural alignment with FIXED_TERM (locked, unpaid) or wire an explicit LDM pause / forced deploy once it exceeds a threshold of `ltRawNAV`.
- Directional fee. Decide the pool fee schedule that recaptures the rate-staleness LVR on the yield-direction trade. Prefer a directional fee over a flat fee, which would tax the legitimate ST-exit flow.
- LDM floor. The premium must clear rate-staleness LVR plus near-peg IL. Confirm the floor clears it at a feasible `maxLiquidityPremium` for the target markets.
- Auction fallback (buffered supplier). The Dutch auction from ST share NAV down to the TWAP one-sided-deposit quote is the buffered supplier with a market-discovered incentive `c`. Decide what the auction sells the staged senior for (quote vs BPT), the emergency force-deploy, and how to bootstrap the solver network — the primary open concern, since until solvers exist the auction will not clear.
- JT sizing. JT now covers the LT base. Accept the capital-efficiency cost, which is the price paid for deleting the coverage-perimeter exclusion and its complexity.
- Realizable depth versus the solvency mark. `ltRawNAV` from the Balancer oracle is a solvency value, not exit depth. The in-kind redemption and the reserve-capped cash path already insulate the run gate from this. Decide whether any additional composition-drift breaker is wanted, or accept and document the bound.
- ST supply seed. Ensure `ltRawNAV` is never zero against a positive `minLiquidity`, which would make `liquidityUtilization` infinite.
- Pool permissioning. Confirm the pool LP set equals the kernel, so external mint and burn cannot move the gate without the kernel knowing.
- Factory and indexer. The repo ships its own Day factory and deploy path from scratch, with no shared pre-deployed factory to upgrade. Stand up a Day-specific indexer/subgraph for the LT events and the three-NAV sync.

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
