# Royco Day: Liquidity Tranche (LT)

Royco Day is a structured-risk protocol that adds a third tranche, the Liquidity Tranche (LT), to a senior/junior (ST/JT) system. The ST/JT engine is owned here directly — not inherited, not shared with another product, and not coupled across repos. This is a deliberate choice for auditability and end-to-end traceability: every line that executes for a Day market lives in this one repo, in order, with nothing shared with another product and no inheritance indirection. The cost, accepted knowingly, is that the engine is maintained here directly rather than pulled from a shared base.

If you are picking this up cold, read this file, then the waterfall library and the accountant's sync orchestrator. The LT is an overlay on the ST/JT senior-gain split; it does not change the loss waterfall or the conservation identity. That is the whole point of the design.

## Branch goal

The ST/JT system guarantees a minimum coverage for senior shares. Royco Day adds a second service: secondary liquidity for senior shares. The LT is market-making capital that holds a Balancer pool of ST shares against a stablecoin, so ST holders have a venue to exit into. The LT is paid a liquidity premium out of ST yield, in the same way JT is paid a risk premium.

This separates two jobs that a single junior tranche would otherwise overload: first-loss coverage and pool liquidity, which would force one combined minimum tranche size. Here JT stays pure first-loss coverage and the LT carries liquidity. Each issuer picks coverage and liquidity independently. The cost is more capital to raise.

## Product requirements (canonical spec)

This is the product spec Royco Day implements. Where the engineering detail elsewhere in this file predates it, this spec governs. The one material update it makes over the older detail below: the **idle liquidity premium is claimable, not forfeited** — while a tranche of premium is staged as ST shares it is part of the LT's effective NAV, and a holder who redeems receives its pro-rata slice of those ST shares directly.

Product requirements:
- Minimum coverage guaranteed for the senior tranche shares (the ST/JT system serves this).
- Minimum secondary liquidity required for the senior tranche shares at all times (the new LT service).
- Yields must economically make sense for all tranches.

Capital structure:
- Senior tranche: protected capital, deployed into a yield-bearing asset; pays the JT a risk premium and the LT a liquidity premium out of its yield.
- Junior tranche: first-loss capital that covers senior losses until exhausted; deployed into the same yield-bearing asset as senior or the RFR; paid a risk premium from senior yield. Max risk premium set 0-100% of ST yield.
- Liquidity tranche: market-making capital providing constant secondary liquidity for senior; deployed into a BPT in a pool between the senior tranche share and a stablecoin; the underlying pool is a rate-scaled AMM; works with any AMM or MM vault (e.g. Agra) but Balancer E-CLP to start; equivalent risk to the senior tranche (higher return, but less liquid); paid a liquidity premium from senior yield. Max liquidity premium set 0-100% of ST yield.

The liquidity premium:
- Comes from ST assets and is immediately used to mint ST shares to the LT. What is done with those ST shares:
  - If they can be single-sided LP'd into the pool at or below a market-defined max slippage, do so immediately.
  - Otherwise the ST shares are auctioned for BPT, starting at the effective NAV of the ST shares (maybe a premium) with a lower bound on the sale price. (Open: is an auction the best modality? auction for BPT or for quote assets?)
  - If a user redeems LT shares while idle ST shares still sit in the LT, those ST shares are sent directly to them.

The senior and junior tranches operate as the base ST/JT system — the LT overlay makes no changes to the coverage utilization formula, the loss waterfall, or the deposit and redemption logic.

The liquidity tranche specification:
- `maxLiquidityPremium + maxRiskPremium <= 100%`.
- Deposits and redemptions: deposit BPT, or use the multi-asset flow (takes ST assets and stables and does the ST-share mint -> BPT mint -> LT-share mint atomically). Redeem BPT and ST's yield-bearing asset (the liquidity premium); the multi-asset flow redeems the ST shares from the BPT plus any idle prior liquidity premium.
- `LT_RAW_NAV` uses Balancer's manipulation-resistant oracle.
- Each market sets a minimum percentage of liquidity required for senior tranche deposits.
- `liquidityUtilization = (ST_EFF_NAV * MIN_LIQUIDITY_%) / LT_RAW_NAV`. Assumption: arbitrage keeps the pool near balance in a healthy state, so `LT_RAW_NAV` is a sufficient metric for guaranteeing secondary liquidity of some size.
- An LDM (the same model family as the YDM) takes this `liquidityUtilization` and returns the portion of ST yield paid as the liquidity premium to the LT, in ST's underlying assets.
- Valid operations based on the `liquidityUtilization` after an operation:
  - Senior (ST) deposits are liquidity-gated: they are enabled in a perpetual state only if `liquidityUtilization <= 100%` after the deposit. Junior deposits and in-kind liquidity deposits (which only deepen coverage/`ltRawNAV`) are not liquidity-gated.
  - Redemptions are enabled in a perpetual state only if `liquidityUtilization <= 100%` after the redemption — unless the liquidation utilization has been breached, in which case all withdrawals are allowed.
  - FIXED_TERM overrides all of the above: it blocks every operation on every tranche (all deposits and all redemptions), so the liquidity-gate rules apply only in the PERPETUAL state.

Why this shape:
- Pros: each issuer picks from a menu of coverage and liquidity options (curator/LP-advised); no combo-meal problem where the junior tranche serves as both coverage and liquidity under one enforced minimum tranche size; the junior tranche earns at least the base yield of the underlying investment; less complexity (more auditable, verifiable, and secure; faster time to market); the LT can be put in Pendle and money markets.
- Cons: more capital to raise; two enforced minimums (coverage + liquidity) make for a questionable UX.

## What the LT actually is

The LT is an ST holder that locks senior capital in a Balancer E-CLP BPT (ST shares paired against a quote stablecoin) to provide market-making liquidity, and earns extra senior yield (the liquidity premium) for doing so. It is fully covered senior, not self-insured. The premium compensates the illiquidity of the locked position and the impermanent loss of the LP, not waived coverage.

The LT share is BPT plus any transiently-staged liquidity-premium ST shares. The premium is minted as ST shares to the LT and turned into BPT — single-sided added directly when slippage is at or below the market threshold, otherwise auctioned for BPT — so the steady state is BPT and the share appreciates as real pool depth. Until a tranche of premium deploys, its ST shares sit in the LT as a claimable leg of the LT's effective NAV: a holder who redeems while premium is staged receives its pro-rata slice of those ST shares directly. Both legs are committed senior claims and up-only, so the LT share stays a clean, appreciating, transferable token: Pendle-wrappable through the existing tranche SY wrapper, and usable as Morpho collateral. There is no separate staking or rewards contract, because a staking contract would tie rewards to an address rather than to the token and break that composability.

The idle ST shares are value in transit, not a permanent second asset: the steady state is pure BPT, and the staged shares exist only between premium accrual and deployment. They are claimable (a redeemer is made whole on its premium slice) but they do not count toward `ltRawNAV`, so the liquidity metric still reads under-provisioned and keeps the LDM paying until real depth lands — the premium stays a restoring force on `liquidityUtilization`. What stays rejected is the reward-token variant (distributing the premium as claimable tokens tied to an address): it breaks Pendle/Morpho composability and makes the premium inert against `ltRawNAV`.

## Capital structure

- ST is protected senior capital, deployed into a yield-bearing asset. It pays the JT a risk premium and the LT a liquidity premium out of its yield.
- JT is first-loss capital. It provides coverage to ST on losses until exhausted, and earns the JT risk premium via the YDM. The LT overlay does not change it.
- LT is covered senior capital that also provides liquidity. It holds the BPT, grown by its reinvested premium, and earns the liquidity premium via the LDM.

Hard constraint: `maxLiquidityPremiumWAD + maxRiskPremiumWAD <= WAD` (100% of ST yield).

## The premium is covered ST shares (the load-bearing decision)

The liquidity premium is a portion of senior yield set by the LDM. It is paid as newly minted ST shares credited to the LT tranche and then reinvested into the BPT. The mint half of this is what keeps the accounting simple, and it has three consequences.

1. Coverage-neutral. Minting the premium as ST shares reassigns senior appreciation from plain ST to the LT. The senior raw NAV (`stRaw`) is unchanged, because no assets enter or leave the protocol, only share ownership shifts. So `coverageUtilization` does not move, JT bears no extra burden, and there is no lever-up. The mint must therefore be a privileged internal mint that bypasses the deposit coverage gate, because it adds no senior exposure.

2. Everything senior stays covered. Plain ST, the BPT's ST-share leg, and the reinvested premium shares are all senior claims in the coverage perimeter. Coverage uses `stRaw_total`, the vault mark of all ST shares. There is no `stRaw_covered = stRaw_total - ltLeg` subtraction. That deletes both the dual-mark problem (subtracting a Balancer mark from a vault mark) and the swap-manipulability of any such subtraction. Reinvesting the shares into the pool does not change this. The shares are still senior claims, whether they sit in the pool or are later bought out by an arbitrageur. Coverage is on every ST share that exists, regardless of who holds it.

3. The waterfall stays two-term. The premium shares are senior, so they live in `stEff`. The `liqShare` only decides how the senior appreciation of a sync is apportioned between plain ST and the LT. It does not add a third NAV leg. `AccountingLib` keeps `stRaw + jtRaw == stEff + jtEff` byte-for-byte. There is no 6-arg conservation, no LT leg in the checkpoint, and no change to `STEP_APPLY_JT_COVERAGE_TO_ST` or the attribution path.

The `liqShare` mint happens as a post-sync step in `RoycoDayAccountant`, after the waterfall has computed the senior gain. It is NAV-neutral (a share mint against value already in the pool), so it sits outside the waterfall conservation entirely. The reinvestment that follows the mint is a kernel action, not an accounting one. It moves the minted shares into the BPT and is bounded by a min-BPT-out, but it does not touch the conservation identity.

## The yield split

On the up path of a sync, after JT coverage IL recovery clears:

1. JT risk premium (existing, unchanged): `riskShare = floor(stGain * jtFracWAD)`, routed to `jtEffectiveNAV` via the YDM. This is the base ST/JT risk premium.
2. LT liquidity premium (new): `liqShare = floor(stGain * ltFracWAD)`, set by the LDM, minted as ST shares to the LT tranche and reinvested into the BPT.
3. ST keeps the residual.

The joint cap `maxLiquidityPremiumWAD + maxRiskPremiumWAD <= WAD` is validated at `initialize` and in both setters. Because both shares are fractions of the same senior gain, the combined draw cannot exceed it. Who pays: plain ST holders fund the premium through the dilution; the LT's own base partially self-funds and nets positive. The share math must be written out once to confirm the LT is not net paying its own premium.

## Premium deployment: gated single-sided add, staged buffer, auction fallback

The premium is deployed into the E-CLP BPT by single-sided adding the freshly minted ST shares, inside `Vault.unlock`, bounded by a min-BPT-out. This single-sided add is Route A, the default path for the regime this product targets: a near-peg pair with small, frequent adds. The deployed shares raise `ltRawNAV` directly, which delevers `liquidityUtilization` at the source rather than waiting for external deposits. The premium grows real depth, the share price stays up-only, and the LT share trends to pure BPT as each staged tranche of premium deploys.

Route A has a known, bounded cost. The kernel injects only senior into the pool, so the net pool delta is `(senior += V, quote += 0)`. The pool ends senior-heavy; an external arbitrageur rebalances it by injecting quote and lifting the senior overhang, capturing the rebalancing spread. The LT receives BPT worth roughly `V` minus that spread. The leak per add is approximately `V^2 / (2 * A * D)` in pool-curvature terms (with `A` the E-CLP near-peg amplification and `D` the senior-leg depth) plus a temporal term on the order of `sigma * V` from drift between the mint and the arb. For a near-peg pair done in small, frequent adds this is single-digit basis points of `V`, and it falls quadratically as `V` shrinks. So the first lever is cadence: the premium accrues every sync, and deploying it per sync rather than batching to infrequent oracle updates keeps `V` small and the leak negligible.

The single-sided add is gated, not unconditional. The kernel only single-sided adds when the realized slippage is below a threshold (on the order of 10 bps); above the threshold the add is deferred to the auction fallback below. The slippage gate is the primary manipulation defense — it makes a large, sandwichable lump add impossible, and the mere existence of the auction fallback deters manipulation even when it is rarely triggered. Two further defenses harden the gate. The pool hook forces a P&L sync before every swap and the Vault reloads the ST-share rate immediately after that sync, so every pool swap prices at the freshly-committed rate — through-pool stale-rate arbitrage is impossible, an attacker cannot swap against a stale rate. And the pool fee schedule is set to recapture the rate-staleness LVR — preferably as a directional fee that charges the yield-direction trade more, rather than a flat fee, which would tax the legitimate ST-exit flow the LT exists to serve.

Un-deployed premium is held as a kernel-staged buffer of ST shares, outside every marked NAV. This is the load-bearing accounting decision for the deferred path. The staged shares are not in `ltRawNAV` (so the metric correctly still reads under-provisioned and keeps the LDM paying until real depth lands) but they ARE in the LT share's effective NAV as a claimable leg, so the in-kind redemption gives the redeemer its BPT slice plus its pro-rata slice of the idle ST shares directly. The premium is claimable, not forfeited: a holder who redeems while a premium is staged is made whole on its slice rather than leaving it to whoever is in the pool when it deploys. The staged shares remain senior claims inside `stEff`, so coverage still covers them and the mint stays NAV-neutral and coverage-neutral; they are value in transit, not value lost. The one invariant the staged buffer demands is a bound on its size: under sustained high slippage the buffer could grow while the metric never heals, so the staged pile is bounded either by its natural alignment with FIXED_TERM (where the LT is locked and unpaid, so nothing accrues to stage) or by an explicit LDM pause / forced deploy once the buffer exceeds a threshold of `ltRawNAV`.

The auction fallback drains the staged buffer at a controlled cost. It is a Dutch auction that starts at the ST share NAV (the fair upper bound) and decreases to a floor set by the time-weighted average pool quote for the one-sided deposit, then restarts. A solver that meets the clearing price supplies the quote leg against the staged senior, so the add lands balanced and the protocol pays the auction discount (NAV minus clearing price) instead of donating the uncontrolled arb spread. The auction is therefore the buffered supplier mechanism with a market-discovered incentive `c`, rather than a fixed 5-to-30-bps `c`. If no bidder meets the quote the cycle retries with no forced loss; an emergency button can force the deposit at market price, accepting a minor yield delay, so the buffer can always be drained. The open problem is solver-network bootstrapping: until a solver network exists the auction will not clear, so early-life the operative path is the gated single-sided add plus the emergency force-deploy, and the auction becomes load-bearing only once solvers are present.

Route B is rejected, with proof. Route B is the on-chain rebalance variant: swap half the minted senior to quote inside the pool, then add balanced. It nets the identical `(senior += V, quote += 0)` because the swap is internal to a pool the LT wholly owns, and it adds a sandwichable stale-rate internal swap on top. So Route B carries the same structural leak as Route A plus an extra sandwich, and is strictly dominated. Do not implement it. (An external swap on a separate venue nets the same delta without the internal sandwich, but imports external-venue MEV and a venue dependency, so it is not a default path either.)

Distributing the premium as claimable reward tokens is retained only as a documented break-glass, not the mechanism. It is safer against LP MEV, but it reintroduces exactly what the pure-BPT design removed: it ties value to an address rather than the token (breaking Pendle and Morpho composability) and makes the premium inert against `ltRawNAV`, so it stops being a restoring force on `liquidityUtilization`. In that mode the LDM's self-healing loop is gone — it is a different product, used only if every deploy path fails.

## The two metrics

### Coverage (unchanged by the LT overlay)

```
coverageUtilization = (stRaw_total + jtRaw * beta) * minCoverage / jtEffectiveNAV
```

`stRaw_total` is the vault mark of every ST share, including the LT's pooled base and its reinvested premium shares. No exclusion, no composition reads, swap-stable. The coverage utilization computation is the base ST/JT formula, and the LT never touches it. At zero liquidity a Day market's coverage is just the plain ST/JT coverage.

### Liquidity

```
liquidityUtilization = stEffectiveNAV * minLiquidity / ltRawNAV
```

`ltRawNAV` is the BPT value from Balancer's E-CLP oracle, the actual pool depth that backs ST exits. It is the BPT only and excludes any idle, not-yet-deployed premium ST shares, which keeps the liquidity metric reading under-provisioned until real depth lands. The LT share's effective NAV (its deposit/redeem and oracle price) is `ltRawNAV` plus that claimable idle premium, so the two coincide only once all staged premium has deployed.

Both inputs are manipulation-resistant: `stEffectiveNAV` is total senior NAV (swaps in the pool do not change it), and `ltRawNAV` is the Balancer oracle. There is no composition subtraction in the numerator.

`liquidityUtilization` gates depth-reducing redemptions and senior deposits, not junior or in-kind liquidity deposits. A junior deposit or an in-kind LT deposit only raises coverage/`ltRawNAV`, so it is never blocked on liquidity; a senior deposit raises `stEffectiveNAV` (the liquidity numerator) and is gated on post-op `liquidityUtilization <= 100%`, exactly as the canonical spec requires ("a minimum percentage of liquidity required for senior tranche deposits"). Redemptions that reduce the pooled depth — the in-kind and the multi-asset LT redemptions — are valid only in a PERPETUAL market and only if `liquidityUtilization <= 100%` after the redemption settles, so an LT holder can exit down to the senior tranche's required liquidity floor but cannot pull depth below it. The single exception is a breached liquidation coverage utilization: once coverage is in liquidation, every withdrawal is allowed and the redemption bypasses this gate, because the senior tranche is being wound down and locking liquidity in protects no one. The gate is on the post-redemption market state, both of whose inputs (total senior NAV and the Balancer oracle mark) are single-block manipulation-resistant, so it cannot be gamed within a block. Between syncs `liquidityUtilization` can still drift above 100% from senior appreciation; the two restoring forces are the deployed premium, which raises `ltRawNAV` directly as it lands (every sync when slippage permits a small add, or via the auction when it does not), and external LT deposits pulled in by a higher LDM premium when utilization is high, exactly as JT deposits clear coverage utilization in the YDM.

### LDM

The Liquidity Distribution Model is the general-purpose YDM, which now takes a utilization input directly, instantiated with a liquidity target and driven by `liquidityUtilization`. It is the same contract family as the JT's YDM. The floor matters: the premium must clear the LT's real holding cost, or providing liquidity is irrational. That real cost is small for the regime this product targets, for the reasons in the capital realism section. The LDM floor is calibrated against that cost, not against a generic volatile-pair LP cost.

### ltRawNAV from Balancer's E-CLP oracle

`ltRawNAV` is read from Balancer's native Gyro E-CLP manipulation-resistant oracle for the BPT. There is no ported valuation library, no custom recursion, and no bisection solver. The pool prices the ST share via a rate provider that reports the ST share NAV from the last committed sync, so the rate is a per-sync resolved input, not a within-call fixed point. The Balancer mark is single-block manipulation-resistant. It is a solvency value, not realizable exit depth, and can overstate liquidity under sustained quote depeg or arbitrage halt.

## Capital realism: the LT market-makes a covered asset

An earlier analysis flagged the LT as negative expected value on a generic LP cost stack of 1 to 3 percent per year. That framing is rejected. It modeled a generic volatile-pair LP and ignored two facts specific to this system.

The asset being market-made is covered. ST is protected by JT, so in the covered range an ST share cannot fall. The flow the LT faces is therefore not toxic. An informed seller exiting ahead of a loss does not pick the LT off, because the loss is absorbed by JT and the share does not drop. The only regime where the senior share actually falls is past coverage exhaustion, which is FIXED_TERM, where the LT is locked alongside everyone else and is not transacting. Adverse selection is bounded by coverage, not open-ended.

The state machine bounds the exposure. In FIXED_TERM, deposits and redeems are disabled for every tranche, so the LT cannot be run and is not exposed to a drawdown exit it cannot make. In PERPETUAL with healthy liquidity, the LT redeems like any ST holder. In PERPETUAL with stressed liquidity, LT redemption is subordinated to ST's claim. So the LT is paid a premium precisely in the states where it can transact, and is locked, covered, and unpaid in the state where everyone is locked.

The one residual cost is rate-staleness LVR — but not through the pool. The ST leg is priced at the last committed sync NAV, and a yield-bearing share marks up predictably between syncs; however the pool hook forces a sync before every swap and the Vault reloads the ST-share rate immediately after, so a pool swap can never execute against a stale rate (through-pool stale-rate arbitrage is structurally impossible). The residual LVR is therefore confined to any external venue that prices the ST share off a stale mark, and even there it is bounded by sync frequency (the rate refreshes on every kernel interaction) and recapturable by a directional fee that charges the yield-direction trade more. For a covered, near-peg, actively-synced market it is small.

The conclusion: the LT's real holding cost is rate-staleness LVR plus minor near-peg impermanent loss, not the generic stack. The LDM floor is sized to that, and is plausibly cleared by a modest premium plus swap fees, leaving the LT positive carry. The binding constraints are sync cadence and a directional fee, not capital flight.

## Redemption and the no-run guarantee

Redemption is gated on `liquidityUtilization`, the same metric that prices the premium. A redemption that reduces the pooled depth is valid only in a PERPETUAL market and only if `liquidityUtilization` stays at or below 100% after it settles. That is the no-run guarantee: an LT holder can always exit down to the senior tranche's required liquidity floor, but not past it, so the pool cannot be drained below the depth senior exits depend on. There is no lockup and no first-mover advantage to model, because the gate is on the post-redemption market state, not on queue position.

Two redemption flows reduce depth and both are gated identically. The default is in-kind and proportional: an LT holder burns LT shares for a proportional slice of the BPT, taken as a sandwich-safe proportional `removeLiquidity`. The multi-asset flow additionally unwinds the senior leg of that slice (plus any idle, not-yet-reinvested premium senior shares) back to the senior tranche's yield-bearing asset, so the holder leaves in underlying rather than BPT. Both remove a whole LP token — senior leg and quote leg — from the pool while unwinding only the small senior leg, so both raise `liquidityUtilization`, and both must leave it at or below 100%. The proportional `removeLiquidity` reads no composition and cannot drain one side of the pool, so the gate is the only thing standing between a redemption and the senior liquidity floor.

The single exception is a breached liquidation coverage utilization. Once coverage is in liquidation, every withdrawal is allowed and the redemption bypasses the liquidity gate, because the senior tranche is being wound down and there is nothing left to protect. FIXED_TERM otherwise locks every tranche, including the LT, so the drawdown run vector does not exist and the LT's principal is covered through the lock.

If a holder redeems while idle premium senior shares are still staged for the LT, those shares are sent directly to the redeemer as part of the redemption, so no premium is stranded.

## Accountant architecture: standalone

`RoycoDayAccountant` is a standalone contract. It does not extend any shared base, and there is no inheritance anywhere in the repo. It owns the full ST/JT engine directly: the loss waterfall, the coverage math, the state machine, the protocol fees, and the YDM resolution all live in this codebase and read top to bottom. The heavy math stays in libraries the accountant calls (the waterfall library, the coverage and utilization library) so it is not inlined twice, but the sync orchestration, the state, the setters, and the events are the accountant's own, with no shared base and no dead inherited surface.

The LT is added directly on top: a third set of config and state fields, an LDM resolved at sync time, and a post-sync overlay that computes the liquidity premium from the senior gain and signals the coverage-neutral premium-share mint. The accountant's sync entrypoints carry the LT pool mark (`ltRawNAV`) alongside the ST and JT marks, because the sync checkpoints all three.

There is no cross-repo dependency and no differential anchor test against another codebase. Day's ST/JT correctness is established by Day's own test suite, on its own terms. A Day market at zero minimum liquidity should behave like a plain ST/JT market, and that is verified here, not asserted against another repo.

## Self-contained repo principle

- The repo is the unit of audit. Everything a Day market executes, deploy through redeem, lives here. There is no submodule and no cross-repo source dependency, because that would re-introduce the coupling this design exists to remove.
- No inheritance. Contracts are flat or compose through explicit libraries, never through a shared base that also serves another product. There are no inherited functions a Day contract does not use.
- Naming is flat to Day. The senior/junior engine is the Day accountant's own, with no shared-base framing, since there is no base.
- The liquidity gate is orthogonal to coverage. It never modifies coverage config, the coverage requirement check, the coverage utilization computation, or the forced-perpetual conditions. The LT is strictly additional capital structure on top of a self-contained ST/JT engine.
- The ST/JT engine is self-contained. It is owned and maintained here directly rather than pulled from a shared base. This is the trade made for end-to-end auditability.
- Storage layout and enum ordinals are chosen cleanly. There is no deployed Day market to stay compatible with, so `TrancheType` carries `LIQUIDITY` and `Operation` carries `LT_DEPOSIT`/`LT_REDEEM` as first-class members, not appended-for-compatibility ordinals.

## LT tranche and kernel

The LT tranche is a Royco vault tranche that holds the BPT plus any idle, not-yet-deployed liquidity-premium ST shares. The premium is deployed into the BPT (gated single-sided add, else auction); while staged, the idle ST shares are a claimable leg of the LT's effective NAV, sent to a redeemer directly on redemption. `ltRawNAV` is the BPT only; the LT share's effective NAV is `ltRawNAV` plus the staged premium.

Deposits: `ltDeposit` takes a pre-minted BPT. `ltDepositMultiAsset` is the atomic flow that pulls the ST asset and the quote stable, mints the ST share, performs the Balancer join, and mints the LT share inside `Vault.unlock`, bounded by `minBptOut`, a max-asset-in per token, and a deadline.

Redemptions: the in-kind proportional BPT slice and the multi-asset unwind described above, both gated on `liquidityUtilization <= 100%` after the redemption (bypassed only once liquidation coverage is breached). There is no separate premium leg to compute on redemption: deployed premium is already in the BPT, and un-deployed premium is staged outside the LT share NAV, so it lands as BPT on deploy and is realized to whoever holds the share then; any idle premium senior shares are sent directly to the redeemer.

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
- Owned here like everything else: the blacklist batch screen (the LT picks it up through the existing hook) and the tranche Pendle SY wrapper (the LT share is a standard tranche token).

The tranche dispatch handles `SENIOR`/`JUNIOR`/`LIQUIDITY` with a revert default. Since the repo is fresh, enum ordinals and storage layout are chosen cleanly rather than appended for compatibility.

## Invariants

- Two-term NAV conservation holds at wei precision: `stRaw + jtRaw == stEff + jtEff`. The premium is covered ST shares inside `stEff`, never a third leg.
- All senior is covered. `computeCoverageUtilization` uses `stRaw_total` with no exclusion and no composition reads. Reinvesting the premium into the pool does not change which shares are covered.
- The premium mint is coverage-neutral: it adds no senior assets, only reassigns share ownership, so it does not move `coverageUtilization` or consume coverage capacity.
- The reinvestment is bounded by a min-BPT-out and changes `ltRawNAV`, not the conservation identity.
- The LT share's effective NAV is the BPT depth plus any idle, not-yet-deployed liquidity-premium ST shares (a claimable leg). `ltRawNAV` is the BPT only: staged premium is excluded so the liquidity metric reads under-provisioned and keeps the LDM paying. The staged premium is claimable on redemption (sent to the redeemer directly), not forfeited.
- `maxLiquidityPremiumWAD + maxRiskPremiumWAD <= WAD`.
- LDM and YDM outputs depend only on the last committed checkpoint, so the waterfall stays pure.
- Coverage math and the PERPETUAL/FIXED_TERM machine remain ST/JT only.
- Redemptions that reduce the pooled depth (the in-kind and multi-asset LT redemptions) are valid only if `liquidityUtilization` stays at or below 100% afterward, in a PERPETUAL market, and are bypassed once liquidation coverage is breached. Senior deposits are liquidity-gated (post-op `liquidityUtilization <= 100%`); junior and in-kind liquidity deposits are not.
- A Day market at zero minimum liquidity behaves like a plain ST/JT market, verified by Day's own suite rather than asserted against another repo.

## Build sequence

Each phase is independently testable.

- P0, foundation and decisions gate. Stand up the repo, strip what Day does not use, drop any inheritance seams, and keep naming flat to Day. Settle the coverage-neutral premium-mint mechanism, the who-pays share math, the in-kind and multi-asset LT redemptions both gated on `liquidityUtilization <= 100%`, the LDM floor against the real (rate-staleness plus near-peg IL) cost, and acceptance that JT covers the LT base.
- P1, data model. Land the tranche enum, the `Operation` members, and the LT config and state fields as first-class members, chosen cleanly. A Day market at zero minimum liquidity reduces to a plain ST/JT market; lock that in with a test.
- P2, accountant premium and metric. Implement the LDM-driven `liqShare`, the post-sync coverage-neutral ST-share mint, and the liquidity metric, driven by a directly supplied `ltRawNAV` with no Balancer wiring. Verify the zero-liquidity reduction here.
- P3, LT vault and kernel custody and deployment. Build `RoycoLiquidityTranche` holding the BPT, the deposit, redeem, max, and preview paths, the in-kind proportional redemption and the multi-asset unwind, both gated on `liquidityUtilization <= 100%` after the redemption, the gated single-sided add, the staged premium buffer, and the auction-fallback deploy. Preview must match execution.
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
- Realizable depth versus the solvency mark. `ltRawNAV` from the Balancer oracle is a solvency value, not exit depth, so the `liquidityUtilization <= 100%` redemption gate guarantees a solvency floor, not a realizable-exit floor: the BPT can mark healthy while the quote leg is drained. The proportional in-kind removal cannot itself drain one side. Decide whether any additional composition-drift breaker is wanted, or accept and document the bound.
- ST supply seed. Ensure `ltRawNAV` is never zero against a positive `minLiquidity`, which would make `liquidityUtilization` infinite.
- Pool permissioning. Confirm the pool LP set equals the kernel, so external mint and burn cannot move the gate without the kernel knowing.
- Factory and indexer. The repo ships its own Day factory and deploy path from scratch, with no shared pre-deployed factory to upgrade. Stand up a Day-specific indexer/subgraph for the LT events and the three-NAV sync.

## Resolved and removed

These earlier design problems are recorded here so they are not reopened.

- Three-term conservation and the 6-arg `enforceNAVConservation`. Removed. The waterfall stays two-term because the premium is covered ST shares in `stEff`, not a third NAV leg.
- The coverage-perimeter exclusion (`stRaw_covered = stRaw_total - ltPooledSeniorLeg`). Removed. Everything senior is covered.
- The dual-mark problem and the swap-manipulability of the perimeter subtraction. Removed with the subtraction.
- The idle-premium framing. Reconciled to the claimable model per the product spec. The premium is minted as ST shares to the LT and deployed into BPT (gated single-sided add, else auction); while staged, the idle ST shares are a claimable leg of the LT's effective NAV (a redeemer receives its slice directly) and stay outside `ltRawNAV` so the metric keeps the LDM paying. What stays rejected is the reward-token variant (premium tied to an address), which breaks composability and makes the premium inert.
- Route B, the on-chain rebalance variant. Rejected with proof. It nets the same `(senior += V, quote += 0)` as Route A and adds a sandwichable internal swap, so it is strictly dominated.
- The LT self-insured-leg loss attribution and the line-45 underflow re-proof. Removed. The LT base is covered like any senior.
- The ported E-CLP valuation library, recursion, and bisection solver. Removed. `ltRawNAV` is Balancer's native oracle.
- A MasterChef-style rewards contract. Removed. The premium reinvests into the BPT and the LT share stays a composable token for Pendle and Morpho.
- The negative-EV capital framing on a generic LP cost stack. Rejected. The LT market-makes a covered asset, so adverse selection is bounded by coverage, and the real holding cost is rate-staleness LVR plus near-peg IL.
- Using `liquidityUtilization` as the redemption gate. This is the gate. A redemption that reduces the pooled depth is valid only if `liquidityUtilization` stays at or below 100% afterward, in a PERPETUAL market, and is bypassed once liquidation coverage is breached. The earlier reserve-capped cash path is dropped: the solvency mark, computed from total senior NAV and the Balancer oracle (both single-block manipulation-resistant), is the gate. Senior deposits are liquidity-gated (post-op `liquidityUtilization <= 100%`); junior and in-kind liquidity deposits are not.
