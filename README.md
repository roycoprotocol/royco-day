# Royco Day [![CI](https://github.com/roycoprotocol/royco-day/actions/workflows/CI.yml/badge.svg)](https://github.com/roycoprotocol/royco-day/actions/workflows/CI.yml)

Royco Day transforms the risk and liquidity profile of any yield source by splitting it into three distinct tranches: a senior, junior, and liquidity tranche. The senior tranche is protected from incurring losses up to a guaranteed threshold in addition to having a guaranteed amount of secondary liquidity. The junior tranche serves as first-loss capital in exchange for a risk premium paid by the senior tranche. The liquidity tranche is market-making capital that provides secondary liquidity for senior shares in exchange for a liquidity premium paid by the senior tranche. It holds covered senior capital, so it ranks pari passu with the senior tranche on risk, forgoing liquidity for extra yield.

## Core Concepts

### NAV Types

Each market tracks and reconciles two types of NAVs (Net Asset Value) per tranche:

**Raw NAV**: The pure asset value of the tranche based on underlying prices, excluding any coverage adjustments or yield share (risk and liquidity premiums). This represents the actual market value of the tranche's holdings.

**Effective NAV**: The NAV after applying coverage obligations and yield share (risk and liquidity premiums). The effective NAV determines the actual redemption value for tranche LPs. The liquidity tranche has no separate effective NAV: its redemption value is its raw NAV plus any idle liquidity-premium senior shares not yet reinvested.

### Minimum Coverage Requirement

Each market enforces a minimum coverage requirement, ensuring that senior capital always retains guaranteed downside protection. Coverage utilization measures how much of the junior buffer is currently "used" by senior exposure:

```
                         (ST_RAW_NAV + (JT_RAW_NAV × β)) × MIN_COVERAGE
Coverage Utilization =   ─────────────────────────────────────────────
                                       JT_EFFECTIVE_NAV
```

**Parameters:**
- MIN_COVERAGE: The minimum required coverage percentage, validated at initialization to be strictly less than 100% (eg. 20% means JT must be able to cover 20% of ST losses at all times)
- β: A boolean co-investment flag capturing JT's sensitivity to the same downside stress that affects ST (0 if JT is in a risk-free investment, 1 if JT and ST are in the same underlying investment)

Coverage utilization rounds up, in favor of the senior tranche. Intuitively, when coverage utilization is less than or equal to 100%, the market is fully collateralized from a coverage lens. Consequently, when coverage utilization breaches 100%, the market has suffered sufficient losses such that the minimum coverage requirement is violated.

Markets target a slight excess of junior capital above the minimum coverage requirement to keep the junior tranche perpetually liquid. To maintain this target, the risk premium paid by seniors to juniors adapts to supply and demand signals. As coverage utilization approaches 100%, the junior's risk premium increases to attract more junior capital.

Each market also defines a **liquidation coverage utilization**, validated to be strictly greater than 100% so the market is only considered unhealthy once the minimum coverage requirement is violated. When coverage utilization exceeds this threshold, the market is deemed unhealthy and ST redeemers receive a senior tranche self-liquidation bonus funded by JT effective NAV, incentivizing seniors to exit to restore the market into a healthy state. A threshold of 150% means the market enters liquidation when JT's remaining buffer can only cover two-thirds of the required coverage relative to senior exposure.

### Minimum Liquidity Requirement

Beyond guaranteeing minimum coverage for senior shares, Day guarantees a minimum amount of secondary liquidity for them as well. The liquidity tranche (LT) holds market-making capital, a position in an AMM or another market-making venue pairing the senior tranche share against a quote stablecoin, so senior holders always have a venue to exit into. Liquidity utilization measures the senior liquidity demand against the depth the LT provides:

```
                        ST_EFFECTIVE_NAV × MIN_LIQUIDITY
Liquidity Utilization = ─────────────────────────────────
                                  LT_RAW_NAV
```

A dedicated instance of the market's Yield Distribution Model (YDM), driven by liquidity utilization, prices the liquidity premium paid to the LT out of senior yield. The LT's raw NAV is read from the venue's manipulation-resistant oracle and committed on every accounting sync. Redemptions that reduce pooled depth are gated so the venue can't be drained below the senior tranche's required liquidity floor (bypassed once liquidation coverage utilization is breached). A market with zero minimum liquidity behaves exactly like a plain senior/junior market.

## Architecture

### Factory

The **Factory** is a singleton contract that deploys and manages all Day markets. It is the privileged administrator of the protocol's shared access-control authority, and configures role-based permissions for every deployed market through it. Markets are deployed only through **deployment templates** the factory owner has registered and enabled, and each deployment is routed to a single enabled template.

A template encodes one market recipe and atomically deploys the full market at deterministic addresses, wiring every component's roles to the factory. This covers the senior, junior, and liquidity tranches, the kernel and accountant, the risk and liquidity premium yield models, and the liquidity tranche's market-making venue, oracle, and hook. Each template's component creation code is loaded and stored on-chain once when the template is initialized.

Templates are layered for extensibility. A base template standardizes the shared component parameters and the deterministic deploy machinery. A venue template adds the specific market-making venue, its oracle, and its role bindings. A concrete template pins the kernel recipe, meaning its yield source and pricing. Supporting a new yield source, oracle, or market-making venue only takes a new concrete template registered with the factory, with no change to the factory or existing markets.

### Tranches

Each market has ERC4626-style vault contracts representing its tranches:

**Senior Tranche (ST)**: The capital-protected tier. Senior LPs receive downside protection from the junior tranche when the underlying yield source experiences losses, the junior tranche absorbs them first. In exchange for this protection, senior LPs pay a risk premium (portion of their yield) to junior LPs, and a liquidity premium to liquidity LPs. Senior has first claim on any recoveries after a loss event.

**Junior Tranche (JT)**: The first-loss capital tier. Junior LPs provide a coverage buffer that protects senior capital from losses. In return, they earn a risk premium from senior yield. The size of this premium is determined by the market's Yield Distribution Model (YDM).

**Liquidity Tranche (LT)**: Covered senior capital that also provides liquidity. It holds a market-making venue position pairing the senior tranche share against a quote stablecoin, giving senior holders a venue to exit into. It earns a liquidity premium from senior yield, sized by a liquidity-driven instance of the market's Yield Distribution Model (YDM). The premium is minted as senior shares and reinvested into the venue, so the LT share is up-only and composable. Beyond depositing a pre-minted venue position, the LT supports an atomic multi-asset flow that mints the senior share, joins the venue, and mints the LT share in one transaction.

Tranches are ERC20Permit-enabled, pausable, and burnable, and support standard preview and deposit/redeem operations.

Royco tranches are natively composable across DeFi. Senior tranches transform high-risk vault tokens into leverage-eligible collateral for lending markets, unlocking net-new capital that wasn't accessible before.

Beyond lending, tranches can be paired on AMMs/CLOBs, split into fixed or variable rate exposure, and recursively tranched into layered risk structures.

### Kernel

The **Kernel** is the operational core of each market. It orchestrates all deposits and redemptions across the three tranches, including the liquidity tranche's multi-asset flows, routing assets between tranches and enforcing market constraints. Each concrete kernel composes **Quoter** logic that handles tranche-asset-to-NAV conversions using protocol-specific pricing (eg. ERC4626 share prices, Chainlink oracles, and the market-making venue's oracle for the liquidity tranche).

The Kernel enforces the coverage and liquidity requirements: it reverts operations that would leave the senior tranche undercollateralized or breach the liquidity floor, and validates each operation's post-op accounting delta. It also drives the coverage-neutral liquidity-premium share mint and its reinvestment, and manages blacklist screening for compliance requirements.

### Accountant

The **Accountant** maintains the financial state of each market. Before and after every operation, and via a read-only preview, it synchronizes tranche accounting by:

1. Reconciling any unrealized PnL since the last accounting sync via the deltas between the current and last checkpointed raw NAVs of each tranche
2. Applying coverage obligations on losses
3. Tracking impermanent losses (temporary losses that may recover)
4. Distributing yield from senior to junior (risk premium) as instructed by the market's YDM
5. Distributing yield from senior to the liquidity tranche (liquidity premium) as instructed by the liquidity-driven YDM instance
6. Accruing protocol fees

The junior risk premium is a reallocation of senior appreciation into junior effective NAV. The liquidity premium is minted as senior tranche shares credited to the liquidity tranche and then reinvested, and protocol fees are minted as shares, both against value already in the market. Minting the liquidity premium as senior shares reassigns appreciation without adding senior exposure, so it stays coverage-neutral and preserves the two-term conservation identity at wei precision, where senior raw NAV plus junior raw NAV equals senior effective NAV plus junior effective NAV.

### Yield Distribution Model (YDM)

A **YDM** takes a utilization and returns a yield share, the percentage of senior yield paid out. Each market runs two independent YDM instances. One is driven by coverage utilization and sets the risk premium paid to junior for providing coverage. The other is driven by liquidity utilization and sets the liquidity premium paid to the liquidity tranche. Utilization is the fraction of a capital pool's service capacity currently in use, the ratio of demand for the service the pool provides to its capacity to supply it. The model itself is utilization-agnostic, so "utilization" below refers to whichever such metric drives the instance.

Day supports multiple YDM implementations:

**Static Curve YDM**: A fixed piecewise curve that remains eternally static. The curve is defined by three anchor points: the yield share at 0% utilization, at the target utilization (the kink, set per instance), and at 100% utilization. Higher utilization means the pool earns more of the senior yield. Setting all three anchors at the same yield share results in a fixed yield share market.

**Adaptive Curve YDM V1**: The curve shifts up or down over time based on how far utilization deviates from target. When the curve adapts, the entire shape scales proportionally: the steeper the curve, the more aggressively JT yield share changes with utilization.

**Adaptive Curve YDM V2**: Similar to V1, but the entire curve translates vertically rather than scaling. The slopes remain constant because the fixed discount (reduction from target yield share at 0% utilization) and fixed premium (addition to target yield share at 100% utilization) are set at initialization.

## Market Dynamics

### Market States

Markets operate as perpetual instruments with full liquidity for all tranches under normal conditions. If senior capital incurs a loss, junior coverage is immediately applied and the market enters a fixed-term regime. This gives the underlying position time to recover before junior LPs realize any losses. If the position recovers, juniors are made whole and the market shifts back to a perpetual state. In the event that losses persist and coverage runs thin, seniors can exit early with their guaranteed protection intact.

The two states are:

**PERPETUAL**: The normal operating state governed by market forces, and the permanent state of a market configured with no fixed-term duration. The market is either healthy (no losses beyond the dust tolerance), severely undercollateralized (its liquidation coverage utilization breached), or uncollateralized (no junior NAV remaining against a non-zero senior NAV). All three tranches are liquid, subject to the coverage and liquidity requirements. While under or uncollateralized, the liquidity tranche shares the senior's liquidity profile and the liquidity requirement is exempt. Premiums and protocol fees accrue on senior yield, and adaptive-curve models adapt to the market's coverage and liquidity utilization.

**FIXED_TERM**: A temporary recovery state entered when junior coverage first absorbs a senior drawdown while coverage stays within the liquidation threshold, giving the underlying position time to recover before junior LPs realize any losses. Senior and junior deposits and redemptions are all blocked. This stops seniors from withdrawing coverage from existing juniors, and new juniors from diluting existing juniors, on arbitrary volatility. Liquidity tranche redemptions are also blocked so the LT keeps market-making the senior when secondary liquidity is most valuable, while liquidity tranche deposits stay open. No liquidity premium is paid and no protocol fees are taken, and the adaptive-curve models do not adapt, since utilization moves on underlying PnL rather than market forces during recovery.

**State Transitions**: A market configured with no fixed-term duration is permanently perpetual and never leaves the perpetual state. Otherwise the market enters FIXED_TERM from PERPETUAL when a senior drawdown is first absorbed by junior coverage while coverage stays within the liquidation threshold, which starts the fixed-term. It returns to PERPETUAL when the junior coverage impermanent loss fully clears, meaning the position recovered and junior was made whole, or when the fixed-term duration elapses. The market is additionally forced back to PERPETUAL on a liquidation breach or an uncollateralized market. When the return is forced, or the fixed-term elapses before the loss recovers, the junior coverage impermanent loss is reset, so junior forfeits its recovery claim.

### Impermanent Loss

When losses occur, they are handled differently based on which tranche experiences them:

**ST Losses**: JT provides coverage from its buffer up to its available capacity. The coverage provided is tracked as the JT coverage impermanent loss (a JT claim on future ST appreciation). Any ST loss exceeding JT's coverage capacity is absorbed by ST as senior tranche impermanent loss.

**JT Losses**: First reduce JT effective NAV. If JT effective NAV is depleted, excess losses spill over to ST as senior tranche impermanent loss.

**Recovery**: When appreciation occurs, senior tranche impermanent loss is recovered first (senior priority), then the JT coverage impermanent loss is repaid. Remaining gains are distributed as yield via the two YDM instances, the risk premium to junior and the liquidity premium to the liquidity tranche.

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
