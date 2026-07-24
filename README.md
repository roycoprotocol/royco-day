# Royco Day [![CI](https://github.com/roycoprotocol/royco-day/actions/workflows/CI.yml/badge.svg)](https://github.com/roycoprotocol/royco-day/actions/workflows/CI.yml)

Royco Day transforms the risk and liquidity profile of any yield source by splitting it into three distinct tranches: a senior, junior, and liquidity provider tranche. The senior tranche is protected from incurring losses up to a guaranteed threshold in addition to having a guaranteed amount of secondary liquidity. The junior tranche serves as first-loss capital in exchange for a risk premium paid by the senior tranche. The liquidity provider tranche is market-making capital that provides secondary liquidity for senior shares in exchange for a liquidity premium paid by the senior tranche. It holds covered senior capital, so it ranks pari passu with the senior tranche on risk, forgoing liquidity for extra yield.

## Core Concepts

### NAV Types

Each market tracks and reconciles two types of NAVs (Net Asset Value):

**Collateral NAV**: The pure value of the coinvested collateral backing the senior and junior tranches, marked through the market's collateral asset oracle. The senior and junior tranches deposit the same collateral asset, so one collateral pool and one price back both.

**Effective NAV**: The senior and junior claims on the collateral NAV after applying coverage obligations and yield share (risk and liquidity premiums). The effective NAV determines the actual redemption value for tranche LPs, and the two effective NAVs always sum exactly to the collateral NAV. The liquidity provider tranche has no effective NAV: its redemption value is its raw NAV (the venue position marked by the venue's oracle) plus any idle liquidity-premium senior shares not yet reinvested.

### Minimum Coverage Requirement

Each market enforces a minimum coverage requirement, ensuring that senior capital always retains guaranteed downside protection. Coverage utilization measures how much of the junior buffer is currently "used" by senior exposure:

```
                          COLLATERAL_NAV × MIN_COVERAGE
Coverage Utilization =   ───────────────────────────────
                                JT_EFFECTIVE_NAV
```

Intuitively, when coverage utilization is less than or equal to 100%, the senior tranche is fully collateralized from a coverage lens. Consequently, when coverage utilization breaches 100%, the market has suffered losses such that the minimum coverage requirement is violated.

Markets target a slight excess of junior capital above the minimum coverage requirement to keep the junior tranche perpetually liquid. To maintain this target, the risk premium paid by seniors to juniors adapts to supply and demand signals. As coverage utilization approaches 100%, the risk premium increases to attract more junior capital.

Each market also defines a **liquidation coverage utilization**, validated to be strictly greater than 100% so the market is only considered unhealthy once the minimum coverage requirement is violated. When coverage utilization exceeds this threshold, the market is deemed unhealthy and ST redeemers receive a senior tranche self-liquidation bonus funded by JT effective NAV, incentivizing seniors to exit to restore the market into a healthy state. A threshold of 150% means the market enters liquidation when JT's remaining buffer can only cover two-thirds of the required coverage relative to senior exposure.

### Minimum Liquidity Requirement

Beyond guaranteeing minimum coverage for senior shares, Day guarantees a minimum amount of secondary liquidity for them as well. The liquidity provider tranche (LPT) holds market-making capital, a position in an AMM or another market-making venue pairing the senior tranche share against a quote stablecoin, so senior holders always have a venue to exit into. Liquidity utilization measures the senior liquidity demand against the depth the LPT provides:

```
                        ST_EFFECTIVE_NAV × MIN_LIQUIDITY
Liquidity Utilization = ─────────────────────────────────
                                  LPT_RAW_NAV
```

When liquidity utilization is less than or equal to 100%, the senior tranche is considered sufficiently liquid. Markets target a slight excess of market-making capital above the minimum liquidity requirement to keep the senior tranche perpetually liquid. To maintain this target, the liquidity premium paid by seniors to the market makers adapts to supply and demand signals. As liquidity utilization approaches 100%, the liquidity premium increases to attract more market-making capital.

The LPT's raw NAV is read from the venue's manipulation-resistant oracle to ensure that trades and exogenous venue operations do not impact the instantaneous valuation of the market-making depth. Redemptions that reduce depth are gated so the venue can't be drained below the senior tranche's required liquidity floor. A multi-asset redemption relaxes that floor in-flow by redeeming the senior shares the depth is paired against, shrinking the requirement alongside the withdrawal. A market with zero minimum liquidity behaves exactly like a plain senior/junior market.

## Architecture

### Factory

The **Factory** is a singleton contract that deploys and manages all Day markets. It is the privileged administrator of the protocol's shared access-control authority, and configures role-based permissions for every deployed market through it. Markets are deployed only through **deployment templates** the factory owner has registered and enabled, and each deployment is routed to a single enabled template.

A template encodes one market recipe and atomically deploys the full market at deterministic addresses, wiring every component's roles to the factory. This covers the senior, junior, and liquidity provider tranches, the kernel and accountant, the risk and liquidity premium yield models, and the liquidity provider tranche's market-making venue, oracle, and hook. Each template's component creation code is loaded and stored on-chain once when the template is initialized.

A single template deploys every market: one kernel serves all collateral integrations because the collateral asset oracle carries the integration-specific pricing. Supporting a new yield source only takes a new collateral asset oracle passed into the deployment, with no change to the template, the factory, or existing markets. Supporting a new market-making venue takes a new venue template.

### Tranches

Each market has ERC4626-style vault contracts representing its tranches:

**Senior Tranche (ST)**: The capital-protected tier. Senior LPs receive downside protection from the junior tranche when the underlying yield source experiences losses, the junior tranche absorbs them first. In exchange for this protection, senior LPs pay a risk premium (portion of their yield) to junior LPs, and a liquidity premium to liquidity LPs. Senior has first claim on any recoveries after a loss event.

**Junior Tranche (JT)**: The first-loss capital tier. Junior LPs provide a coverage buffer that protects senior capital from losses. In return, they earn a risk premium from senior yield. The size of this premium is determined by the market's Yield Distribution Model (YDM).

**Liquidity Provider Tranche (LPT)**: Covered senior capital that also provides liquidity. It holds a market-making venue position pairing the senior tranche share against a quote stablecoin, giving senior holders a venue to exit into. It earns a liquidity premium from senior yield, sized by a liquidity-driven instance of the market's Yield Distribution Model (YDM). The premium is minted as senior shares and reinvested into the venue, so the LPT share is up-only and composable. Beyond depositing a pre-minted venue position, the LPT supports an atomic multi-asset flow that mints the senior share, joins the venue, and mints the LPT share in one transaction — and a symmetric multi-asset exit that unwinds the venue position back to the senior share's underlying and quote. Because the multi-asset exit redeems its senior legs in-flow, it shrinks the liquidity requirement alongside the withdrawal, admitting redemptions the in-kind gate alone could not.

Royco tranches are natively composable across DeFi. Senior tranches transform assets into leverage-eligible collateral for lending markets, unlocking net-new capital that wasn't accessible to issuers before.

Beyond lending, tranches can be paired on AMMs/CLOBs, split into fixed or variable rate exposure, and recursively tranched into layered risk structures.

### Kernel

The **Kernel** is the operational core of each market. It orchestrates all deposits and redemptions across the three tranches, including the liquidity provider tranche's multi-asset flows, routing assets between tranches and enforcing market constraints. The kernel prices the collateral asset in NAV units through the market's collateral asset oracle, caching one consistent rate per operation, and values the LPT position through the market-making venue's manipulation-resistant oracle.

The Kernel enforces the coverage and liquidity requirements: it reverts operations that would leave the senior tranche undercollateralized or breach the liquidity floor, and validates each operation's post-op accounting delta. It also drives the coverage-neutral liquidity-premium share mint and its reinvestment, and manages blacklist screening for compliance requirements.

### Collateral Asset Oracle

Each market prices its collateral asset through a single **collateral asset oracle** exposing the price of 1 whole collateral asset in NAV units. The oracle also serves as the update clock for the entry point's execution gate, so the price the kernel marks with and the update signal requests gate on can never come from different sources. Integration-specific pricing lives entirely in oracle adapters: a direct Chainlink feed, an ERC4626 or Makina share price composed with a feed, or an Idle CDO tranche's virtual price composed with a feed. Pull-based sources derive update times from observed price deviations and carry an admin tick for the update-without-a-price-change blind spot.

The kernel gates every price it consumes: an L2 sequencer uptime check with a post-restart grace period, a staleness check against the oracle's update timestamp, and a strictly positive price. The oracle is poked as the first action of every operation, so an oracle-level circuit breaker can halt the market before a single conversion prices against its rate, and preview paths simulate the poke so they fail shut identically. The oracle is admin-replaceable with an accounting sync on both sides of the swap, and can never be unset.

### Accountant

The **Accountant** maintains the financial state of each market. Before and after every operation, and via a read-only preview, it synchronizes tranche accounting by:

1. Reconciling any unrealized PnL since the last accounting sync via the delta between the current and last checkpointed collateral NAV
2. Repaying the junior coverage impermanent loss off the top of any gain, then splitting the residual pro-rata across the restored senior and junior claims
3. Absorbing losses junior-first (tracked as junior's impermanent loss, a temporary loss that may recover), with only the uncovered residual reaching senior
4. Distributing yield from senior to the junior tranche (risk premium) as instructed by the market's YDM
5. Distributing yield from senior to the liquidity provider tranche (liquidity premium) as instructed by the liquidity-driven YDM instance
6. Accruing protocol fees on the post-repayment residual gains only

The junior risk premium is a reallocation of senior appreciation into junior effective NAV. The liquidity premium is minted as senior tranche shares credited to the liquidity provider tranche and then reinvested, and protocol fees are minted as shares, both against value already in the market. Minting the liquidity premium as senior shares reassigns appreciation without adding senior exposure, so it stays coverage-neutral and preserves the NAV conservation property, where the collateral NAV always equals the sum of the senior and junior effective NAVs to the wei.

### Yield Distribution Model (YDM)

A **YDM** takes a utilization and returns a yield share, the percentage of senior yield paid out. Each market runs two independent YDM instances. One is driven by coverage utilization and sets the risk premium paid to junior for providing coverage. The other is driven by liquidity utilization and sets the liquidity premium paid to the liquidity provider tranche. Utilization is the fraction of a capital pool's service capacity currently in use, the ratio of demand for the service the pool provides to its capacity to supply it. The model itself is utilization-agnostic, so "utilization" below refers to whichever such metric drives the instance.

Day supports multiple YDM implementations:

**Static Curve YDM**: A fixed piecewise curve that remains eternally static. The curve is defined by three anchor points: the yield share at 0% utilization, at the target utilization (the kink, set per instance), and at 100% utilization. Higher utilization means the pool earns more of the senior yield. Setting all three anchors at the same yield share results in a fixed yield share market.

**Adaptive Curve YDM V1**: The curve shifts up or down over time based on how far utilization deviates from target. When the curve adapts, the entire shape scales proportionally: the steeper the curve, the more aggressively JT yield share changes with utilization.

**Adaptive Curve YDM V2**: Similar to V1, but the entire curve translates vertically rather than scaling. The slopes remain constant because the fixed discount (reduction from target yield share at 0% utilization) and fixed premium (addition to target yield share at 100% utilization) are set at initialization.

### Entry Point

The **Entry Point** enables asynchronous deposit and redemption flows on Royco tranches. Instead of transacting on a tranche directly, users queue a request that escrows their assets or shares. The request only becomes executable after a per-tranche delay. This delay prevents oracle front-running: entering or exiting on information the market's oracles haven't priced in yet. Tranches configured with the oracle gate enabled add a second gate through the market's collateral asset oracle, resolved live from the kernel. Execution waits for at least one oracle update observed after the request, so anything known at request time is priced into the mark first. Push-based oracles timestamp their own updates. For pull-based sources, the oracle derives conservative update times from observed price deviations.

Requests are yield-neutral. Any yield accrued on the escrowed assets or shares while a request waits is forfeited to the protocol. A request can never be worth more at execution than at request time, though losses still pass through. Without this, the queue itself would be a free option: queue a request, watch the market, and execute only if it wins. Yield neutrality makes queueing costless for a user who intends to transact, and worthless for one who doesn't.

Together, the delay and yield neutrality enable Royco market to employ effective T+n settlement. No request settles against a freshly published price, and nothing is gained by queueing ahead of one. A faulty price update on the tranched asset stays contained locally rather than settling into mints and redemptions.

Requests are flexible. They fill incrementally as tranche capacity frees up. Third-party keepers can execute them in exchange for an opt-in bonus, so a user needs to take no further action after queueing. A request can be cancelled at any time to reclaim the originally escrowed assets or shares.

## Market Dynamics

### Market States

Markets operate as perpetual instruments with full liquidity for all tranches under normal conditions. If senior capital incurs a loss, junior coverage is immediately applied and the market enters a fixed-term regime. This gives the underlying position time to recover before junior LPs realize any losses. If the position recovers, juniors are made whole and the market shifts back to a perpetual state. In the event that losses persist and coverage runs thin, seniors can exit early with their guaranteed protection intact.

The two states are:

**PERPETUAL**: The normal operating state governed by market forces, and the permanent state of a market configured with no fixed-term duration. The market is either healthy (no losses beyond the dust tolerance), severely undercollateralized (its liquidation coverage utilization breached), or uncollateralized (no junior NAV remaining against a non-zero senior NAV). All three tranches are liquid, subject to the coverage and liquidity requirements. Premiums and protocol fees accrue on senior yield, and adaptive-curve models adapt to the market's coverage and liquidity utilization.

**FIXED_TERM**: A temporary recovery state entered when junior coverage first absorbs a senior drawdown while coverage stays within the liquidation threshold, giving the underlying position time to recover before junior LPs realize any losses. Senior and junior deposits and redemptions are all blocked. This stops seniors from withdrawing coverage from existing juniors, and new juniors from diluting existing juniors, on arbitrary volatility. Liquidity provider tranche redemptions are also blocked so the LPT keeps market-making the senior when secondary liquidity is most valuable, while liquidity provider tranche deposits stay open (multi-asset deposits accept only the quote leg during a fixed term, since minting the senior leg is a senior deposit). No liquidity premium is paid and no protocol fees are taken, and the adaptive-curve models do not adapt, since utilization moves on underlying PnL rather than market forces during recovery.

**State Transitions**: A market configured with no fixed-term duration is permanently perpetual and never leaves the perpetual state. Otherwise the market enters FIXED_TERM from PERPETUAL when a senior drawdown is first absorbed by junior coverage while coverage stays within the liquidation threshold, which starts the fixed-term. It returns to PERPETUAL when the junior coverage impermanent loss clears to within the market's dust tolerance, meaning the position recovered and junior was made whole (any dust remainder is erased), or when the fixed-term duration elapses. The market is additionally forced back to PERPETUAL on a liquidation breach or an uncollateralized market. When the return is forced, or the fixed-term elapses before the loss recovers, the junior coverage impermanent loss is reset, so junior forfeits its recovery claim.

### Impermanent Loss

When losses occur, they are handled differently based on which tranche experiences them:

**Losses**: A collateral loss is absorbed junior-first: the junior buffer (its effective NAV) takes the whole loss up to exhaustion, and every unit absorbed is tracked as the junior coverage impermanent loss, JT's first claim on future collateral appreciation. Only the loss exceeding JT's remaining buffer is borne by senior effective NAV, and a market whose junior buffer is exhausted against live senior exposure is uncollateralized, which forces the perpetual state and resets JT's recovery claim.

**Recovery**: When the collateral appreciates, the junior coverage impermanent loss is repaid off the top of the gain before any distribution, restoring junior's claim at its original proportions so a dip-and-recover path lands exactly where the direct path would. The residual gain splits pro-rata across the restored claims: junior's share is junior yield, and senior's share pays the risk premium to junior and the liquidity premium to the liquidity provider tranche via the two YDM instances, accrues protocol fees, and the remainder accrues to senior. Repayment is restoration, never yield, so it is never fee'd.

**JT Coverage IL Reset**: The JT coverage impermanent loss is reset (JT forfeits its claim) when the market is forced back to PERPETUAL. This happens when the fixed-term duration elapses, on a liquidation breach, or on an uncollateralized market (no junior NAV remaining against a non-zero senior NAV).


## Extended Capabilities

**Depeg Protection**: Markets backed by synthetic assets use oracles that value the underlying based on actual, fundamental value of their backing rather than secondary market prices.

If a depeg occurs, the loss is absorbed by junior coverage rather than passed through at stale valuations.

**Recursive Tranching**: Tranches can be used as inputs into new markets, enabling layered risk structures.

Tranching a yield source produces Senior A and Junior A. Retranching Senior A produces Senior B and Junior B:

```
Senior:    Senior B
Mezzanine: Junior B
Equity:    Junior A
```

This process can be repeated indefinitely to create arbitrarily deep capital structures.

**Compliance Screening**: Every tranche share mint, redemption, and transfer is screened against a market blacklist and a sanctions overlay, so restricted accounts cannot hold or move tranche shares. Markets can be deployed for permissioned, institutional flow without changing the core mechanism.
