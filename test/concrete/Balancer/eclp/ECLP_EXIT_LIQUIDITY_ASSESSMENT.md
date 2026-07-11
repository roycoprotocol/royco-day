# The Senior-Share / Stablecoin E-CLP — Measured Assessment & Design Guide

A Gyro E-CLP pairing the senior-tranche share (**ST**, ~8%/yr, junior-protected so its rate
effectively only rises) against a yield-bearing stablecoin (**~3%/yr**), tilted stable-heavy so it
serves as **exit liquidity**: seniors dump ST into it, stables come out.

Every number in this document is **measured on-chain** by the test file in this folder — the real
Balancer V3 vault and the real `GyroECLPPool` deployed locally from the vendored monorepo, with
only the two rate providers mocked. Nothing is hand-derived and then trusted. Regenerate all of it:

```
forge test --match-path test/concrete/Balancer/eclp/Test_ECLPExitLiquidityPoolEconomics.t.sol -vv | grep -E "METRIC|VERDICT"
```

*(Raw logs report `bp*1e4`; this document converts to plain bp. "The 99.99 pool" / "the 90/10
pool" refer to the two measured candidates defined in §2.)*

---

## 1. The mental model — three ideas that explain every number below

### Idea 0: what "price 1.0" actually means (read this first)

The pool's price is **not a token ratio — it is NAV-for-NAV, in literal dollars**. In these pools
a rate provider returns **NAV units: dollars with 18 decimals of precision** (1e18 = $1.00 per
share/token). Balancer multiplies every raw balance by its rate before doing pool math, so the
scaled balances the curve trades on are *dollar values*: the ST leg's marked NAV (growing ~8%/yr,
the kernel's share rate = effective NAV / supply) against the stable's accrued dollar value
(~3%/yr). **Price 1.0 therefore means one marked dollar of ST buys exactly one marked dollar of
stablecoin** — an exiter is paid precisely what the oracle says their shares are worth. Every band number is relative to that: β = 1 + 0.53 bp reads "the pool will pay
at most a 0.53 bp *premium over marked NAV* for ST"; α = 1 − 15 bp reads "it sells stables until
ST trades 15 bp *under* its marked NAV, then stops."

In raw tokens the exchange rate drifts on purpose: today 1 ST ≈ 1.00 stables; after a year of
8%-vs-3% accrual the *same* scaled peg corresponds to 1 ST ≈ 1.049 stables. The rate providers
absorb all appreciation so the band never has to — both tokens always register `WITH_RATE`, and
each rate updates the moment its token is marked to market. **The two assets mark on very
different clocks**: the stablecoin effectively per second, the ST share only at each
mark-to-market (potentially monthly). Between ST marks the pool trades at the *last posted* NAV
while true value accrues underneath (~2.19 bp/day) — that fair-vs-mark gap resets to zero at
every mark and is what powers every arb figure in §4. Throughout this document, **"fair" means
the true accrued rates**; the pool (like every other venue in the protocol) can only ever
*transact* at the marks.

### Idea 1: the pool is an ellipse arc, and the tilt is just where the peg sits on it

An E-CLP trades along a stretched, tilted circle. The price of ST (in stables) can only move
inside a band **[α, β]**. Composition is pinned to position in the band:

```
 price:   α  ──────────────────────────────────────────  β
          │                                              │
  holds:  ALL ST  ......... mixed .........  ALL STABLES │
          │                                              │
          │  ←  the "drain runway": as seniors dump ST   │←  the peg (fair price 1.0)
          │     and pull stables, price walks left       │    sits a hair below β
```

There is **no separate tilt knob**. "99.99% stables at balance" simply means the peg sits so close
to β that the pool is one hair away from its all-stables corner. Both candidates in this document
are built exactly this way; they differ only in the size of that hair.

### The five knobs, intuitively

An E-CLP is a circle that has been **stretched** (λ), **tilted** (the rotation c/s), and then
**cropped** to a price window ([α, β]). Each knob answers one plain question:

| Knob | The question it answers | Intuition | Value used here |
|---|---|---|---|
| **β** (upper price bound) | *How stable-heavy is the pool at balance, and how much room does the price have above the peg?* | At β the pool holds only stables. Jam the peg against β → almost-all-stables at rest. β − 1 is also the premium a pinned pool quotes for ST — keep it **below the fee** and the pinned state is unexploitable (the fee shield, Idea 3) | 1 + 4.74e-8 (99.99 pool) / 1 + 5.3e-5 (90/10) |
| **α** (lower price bound) | *How far can exits push the price down before the pool runs out of stables to sell?* | The drain runway. A deeper α keeps quoting exits further below peg — at ever-worse prices. Production crops it at −15 bp: exits stay cheap (~2 bp worst case) but absorption stops there. A multi-% tail (the Python guide's α = 0.90) keeps absorbing at costs that grow to hundreds of bp. This is the §7 open product choice | peg − 15 bp |
| **Rotation (c, s)** | *At which price is liquidity most concentrated?* | The tilt angle of the ellipse puts the "flat spot" of the curve — maximum depth — at one price. c = s = √2/2 is a 45° rotation: depth peaks at price 1.0, the peg. This is why concentration is highest exactly at the balance point and decays toward α (the "less concentrated as it drains" requirement — measured in ten density buckets) | 45° (peak at 1.0) |
| **λ** (stretch) | *How flat is the flat spot?* | The zoom lens. High λ makes the curve nearly a straight line around the peg — huge depth, near-zero slippage for at-balance trades — at the cost of curving harder near the band edges. λ = 4000 is why at-balance exits and LP adds measure ~0 bp while 95%-drained trades pay ~2 bp | 4000 |
| **Fee** | *Who pays whom for liquidity — and how stale can the oracle get?* | LP income per trade, but doing double duty here: it is the **shield** (must exceed β − 1) and the **staleness budget** (breakeven ST-mark staleness = fee ÷ 2.19 bp/day of drift → 0.73 days at 1 bp) | 1 bp |

*(A sixth item you'll see in the code — `DerivedEclpParams`, the tau/u/v/w/z/dSq constants — is
not a knob at all: it is the same five choices pre-chewed into 38-decimal trigonometry, computed
offline at 100-digit precision and hardcoded because deriving it on-chain is infeasible. The
pipeline that produced them first reproduced all nine mainnet production parameter sets before
being trusted with these.)*

The design tensions live *between* the knobs: β trades tilt against headroom; α trades exit-cost
against exit-capacity; λ trades at-peg depth against edge behavior; the fee trades trader cost
against shield margin and staleness tolerance. The rest of this document is those four tensions,
priced by measurement.

### Idea 2: this pool *lives* at β — and that's a feature, not a failure

The ST leg out-earns the stable leg (8% vs 3%). Its oracle marks discretely (e.g. daily), so
**between marks, the pool's ST price is stale-low relative to reality**. Arbitrageurs therefore
always have the same trade available: buy the pool's (slightly underpriced) ST. Buying ST pushes
the price **up, toward β**. The result — measured, not theorized — is that the pool spends nearly
all of its life **pinned at β, holding almost pure stables**, with exit flow briefly pushing it
down-band and arbers recycling it back up.

Two consequences that recur everywhere below:

- **Pinned-at-β is the operating state, not a brick.** A β-pinned pool is stables-full — which is
  maximum readiness for its actual job (handing stables to exiting seniors). It never stops
  quoting exits.
- **Arbers are the pool's unpaid rebalancing bots.** Every unit of ST that exiters push in gets
  bought back out by arbers within hours, at a margin capped by the fee. The pool self-restocks
  its stables continuously.

> Note for readers of the earlier Python guide: that analysis concluded price drifts *down toward
> α*. That is what happens if rates were applied continuously with nobody trading. With
> production's discrete ST marks and live arbitrage — what these tests actually simulate — the
> drift between marks runs **up toward β**. Section 8 reconciles all such differences.

### Idea 3: the fee shield — the single inequality that makes everything benign

Since the pool lives at β, the question "can anyone extract from it there?" reduces to one number:
the gap **β − 1** (how far above fair the pool prices ST when pinned). An arber's only move
against a β-pinned pool is selling ST into it at β; that is profitable only if the premium beats
the fee. So:

**If `β − 1 < fee`, the band is fee-shielded**: nobody can profitably trade against the pinned
pool, one-sided seeding cannot be exploited, and β-pinning is loss-free. Both candidates satisfy
this with the production 1 bp fee:

| | β − 1 | vs 1 bp fee |
|---|---|---|
| 99.99 pool | 0.0005 bp | **2000× margin** |
| 90/10 pool | 0.53 bp | 2× margin |

Every "loss = $0.00" result in this document is this inequality doing its work, and the tests
prove it both ways: they assert `β·(1−fee) < 1` structurally, *and* they drop the fee to the pool
minimum (0.01 bp) to confirm the loss appears the instant the shield is thinner than the band.

---

## 2. The two measured candidates

Both use the production band floor (α = peg − 15 bp), rotation at price 1, λ = 4000, 1 bp fee,
both legs registered `WITH_RATE`, initialized exactly at their balance points. Parameters were
derived with a 100-digit mpmath pipeline that first reproduced all nine mainnet production
parameter sets, then solved β for each tilt; the on-chain composition check confirms both to
4+ decimal places.

| | **99.99 pool** (`tilt9999`) | **90/10 pool** (`tilt9010`) |
|---|---|---|
| Stables at balance (measured) | 99.9900% | 90.0000% |
| β | 1 + 4.74e-8 | 1 + 5.2988e-5 |
| ST inventory at balance (per $10M of stables) | ~$1,000 | ~$1.11M (≈1000×) |
| What the ST inventory is | a rounding error | a real second leg |

Everything the pool does on its stable side — the drain prices, the depth ladder, the exit costs —
was measured **identical** between the two (it depends only on α/rotation/λ, which they share).
The tilt decision is purely about how much ST the pool holds at rest, and §4–6 price exactly what
that inventory costs and earns.

---

## 3. The three decisions

### Decision 1 — Is single-sided stablecoin **initialization** valid?

**Yes on both. Max loss after fees and arb: $0.00 — exactly, at every seed size.**

| Measured (T6) | 99.99 pool | 90/10 pool |
|---|---|---|
| Seeder loss, production 1 bp fee — $10k / $100k / $1M seeds | 0 / 0 / 0 | 0 / 0 / 0 |
| Optimal-arb profit available against the fresh pool | 0 | 0 |
| Penalty vs seeding at the balanced ratio | 0 | 0 |
| Diagnostic at the 0.01 bp pool-minimum fee | 0 | 0.0254 bp, scale-invariant |
| Conservation check (seeder loss ≡ arber profit) | 0 wei residual | 0 wei residual |

**Why.** Seeding stables-only opens the pool at its all-stables corner — pinned at β, quoting ST
at a premium of β − 1. That premium is the *entire* prize available to an arber, and on both
candidates it is smaller than the fee they would pay to collect it (Idea 3). The arb never fires;
the seeder keeps 100.00% of the seed. The 0.01 bp-fee diagnostic proves this isn't a measurement
blind spot: with the shield removed, the 90/10 pool loses exactly its curve convexity (0.0254 bp,
matching the offline invariant-math prediction), identical at $10k and $1M — scale-invariance is
what AMM geometry demands, and it held to the wei.

*Practical note: this validates dust-seeding at deployment (e.g. $1 of USDC in the deploy script),
closing the permissionless-initialization frontrun window at zero cost.*

### Decision 2 — Is **always LPing single-sided into stables** valid?

**Yes on both. Worst measured lifecycle cost ≈ 2 bp — and only for entering *and* exiting a
95%-drained pool. At or near balance the cost rounds to zero, and over a simulated year the LP
beats simply holding the stablecoin.**

| Measured | 99.99 pool | 90/10 pool |
|---|---|---|
| Entry at balance (0.1%–50% of TVL adds) | 0.0000 bp | 0.096–0.100 bp |
| Entry at 95% drained, 50%-of-TVL add (worst state) | 1.90 bp | 2.01 bp |
| Add→remove round trip at balance | 0.0001 bp | 0.198 bp |
| Round trip at 95% drained | 1.88 bp | 1.89 bp |
| **Whale: $1M single-sided into a $500k pool (2× TVL)** | **0.0000 bp = $0.0033** | **0.0391 bp = $3.92** |
| Whale round trip | 0.0000 bp | 0.0666 bp |
| Whale ladder $100k → $2M, per-dollar cost | 0 throughout | 0.087 → 0.024 bp (*falls* with size) |
| **1-year sim: LP return vs 3% stable-hold** | **+1.85 bp/yr** | **+16.87 bp/yr** |
| — lost to arbers within that year | 0.36 bp/yr | 0.03 bp/yr |

**Why, piece by piece:**

- *Entering costs ~nothing because you are adding the token the pool already is.* Balancer charges
  fees only on the non-proportional slice of an unbalanced add. Adding stables to a 99.99%-stable
  pool is proportional to four decimal places — the fee base is ~0. At 90/10 the imbalanced slice
  is the 10% ST share, so cost ≈ 10% × 1 bp ≈ 0.1 bp. The measured costs matched the law
  `cost ≈ w_ST · fee + impact` at every drain state.
- *The whale add gets cheaper per dollar as it gets bigger* — backwards until you see that a
  2×-TVL stable add mostly *is* proportional re-seeding, and the tiny β-gap caps how far its
  implicit swap can push the price (post-add spot landed 1.6e-8 / 1.8e-5 under β). There is no
  standing arb afterwards on either pool: the displacement is inside the fee shield.
- *Exiting a drained pool costs ~2 bp, and that's the product working.* Withdrawing stables from a
  pool whose job all week was handing stables to exiting seniors is demanding the scarce asset;
  the 15 bp band floor caps even that at ~2 bp all-in. (Conversely — measured as the "documented
  deviation (e)" in the test header — a *fair-valued* single-sided stable add into a drained pool
  is a **gain**: you are the rebalancer the pool is paying. The 2 bp figure above is the
  conservative spot-numeraire cost.)
- *The LP beats holding because fee income plus carry outruns arb leakage* at disciplined oracle
  cadence. The 90/10 pool earns ~9× more purely because ~3% of its capital (time-average; see §5)
  sits in the 8% asset rather than ~0.25%.

**The conditionality:** these results assume the oracle-cadence invariants of §4. They are ops
requirements, not tilt properties — but Decision 2's "yes" is contingent on them.

### Decision 3 — Is the composition valid, and which tilt should ship?

**Both compositions are economically sound under the cadence invariants of §4. They fail
identically (cadence failures hit both tilts alike) and differ in exactly two measured ways: LP
carry, and sensitivity to operational failure.** The final recommendation is in §7.

| | **99.99 pool** | **90/10 pool** |
|---|---|---|
| **Pros** | One-time arb per rate event: **$0.04**; every LP flow costs 0.00 bp; fee-shield margin 2000×; nearly immune to even *monthly*-stale ST marks (0.05 bp/yr) | Real two-sided depth (can sell users up to 10% of TVL in ST vs 0.01%); **+16.87 bp/yr** realized LP carry; *lower* relative arb leak in the year sim (0.03 vs 0.36 bp/yr — its fee income on real inventory swamps the leak) |
| **Cons** | Effectively a one-way valve (buy-side inventory 0.01% of TVL); LP carry ≈ nil (+1.85 bp/yr) | 1000× the one-time recycle arb per exit batch ($14–$193, still fee-capped and non-repeatable); **50 bp/yr carry drag if ST marks ever go stale to ~monthly**; routine LP costs 0.1–0.2 bp instead of 0.00 |
| **Identical between them** | Exit absorption and drain prices (shared quote ladder); concentration profile (peaks at balance, decays to 8% of peak at the −15 bp floor); 1.37 bp/day drift capture; ~2 bp round trip through a drained pool; the cadence failure modes | |

---

## 4. The arb picture in full (what rate updates can and cannot extract)

| Scenario (T2, T7) | 99.99 pool | 90/10 pool |
|---|---|---|
| Synchronized daily marks — **steady-state extraction**, all 5 drain states | **0** | **0** |
| Synchronized daily — one-time recycle of freshly-exited inventory | $0.04 at balance; ~$179 drained | $14.39 at balance; ~$193 drained |
| Providers offset by 12h | 0 | 0 |
| **ST daily / stable weekly (cadence mismatch)** | **53.1 bp/yr — NASTY** | **49.9 bp/yr — NASTY** |
| **Extreme: stable per-second, ST monthly** — arb margin | one-time $0.0096 | one-time $31.10 |
| — forced-rotation **carry drag** (see below) | **0.05 bp/yr** | **50.0 bp/yr** |
| — exiter execution haircut at mid-month | 33.8 bp | 33.2 bp |
| — pool pinned/inert | 99% of the horizon | 99% of the horizon |
| Breakeven ST staleness at 0.5 / 1 / 1.5 bp fee | 0.36 / **0.73** / 1.09 days | identical (drift is tilt-independent) |

**Why steady-state extraction is zero (the anti-LVR result).** An arb needs two things: a stale
price *and inventory to trade against it*. Drift only ever runs one way (up — Idea 2), so the only
trade is buying the pool's ST. Once bought, the fee shield blocks selling it back (β·(1−fee) < 1),
so **each unit of ST can be recycled at most once**. No refill, no repeat. The feared "LVR faucet"
has no water supply. This held at every drain state, every cadence, both tilts — the tests
measured literal zeros, with the one-time recycle explicitly separated out and itself fee-capped.

**Why cadence mismatch is the one genuine hazard.** If the stable's provider marks weekly while
ST marks daily, the *ratio* of the two oracles oscillates in both directions through the fee band
— and two-way oscillation is exactly the repeatable arb that one-way drift structurally forbids.
Measured: ~50 bp/yr of TVL on both tilts. The fix is operational (synchronize the providers), not
geometric.

**Why stale ST marks cost carry, not principal (the T7 discovery).** Under monthly ST marks the
arber strips the ST leg within 12–18 hours of each mark going stale — and then simply *holds the
ST instead of the LP* until the next mark. The strip margin itself is pennies; the real transfer
is that the arber, not the LP, now earns the 8%-vs-3% spread on that inventory. Measured to three
decimal places: carry drag = **ST inventory share × 5%/yr** (50.0 bp/yr at 90/10, 0.05 at 99.99).
The LP's worst case is thus *forfeiting the upside*, landing ≈ at the plain stablecoin hold —
principal is never in the blast radius. The second casualty is exiters: selling ST against a
month-stale mark under-pays them by the accumulated drift (~33 bp mid-month, ~65 bp at month-end),
so stale marks destroy execution quality even where the LP barely bleeds.

**Which regime is production?** Rates update the moment each token marks to market — the stable
effectively **per second**, the ST share potentially **per month**. That is exactly the T7 rows
above, so read them as the operating case, not a stress case. Three consequences:

1. **The one genuinely repeatable arb cannot occur.** The ~50 bp/yr cadence-mismatch extraction
   required the *stable* leg to be the stale one (two-way oscillation of the oracle ratio). With
   a per-second stable, the ratio only ever drifts one way — into the fee-shielded, β-pinned,
   one-time-strip regime.
2. **The 0.73-day breakeven tells you which regime you're in, not what to demand of ops.** Monthly
   ST marks sit ~41× past it, so the strip-and-carry-drag dynamics of T7 are simply *on*: the
   month's ST-vs-stable yield spread on the pool's ST inventory accrues to arbers instead of LPs
   (inventory share × 5%/yr), and each mark resets the cycle.
3. **Exiters transact at the last posted NAV** — up to ~65 bp under true accrued value at
   month-end. This is consistent, not a rip-off: marked NAV is the only value at which *any*
   protocol venue transacts ST; the unrealized accrual belongs to whoever holds the share across
   the next mark (post-strip, the arber). But it does mean intra-month exit pricing inherits the
   marking calendar, at any tilt.

**The one non-negotiable invariant left: fee ≥ β − 1** (1 bp covers both candidates) — the fee
shield is what keeps the permanently-β-pinned, monthly-marked pool unexploitable.

---

## 5. LP yield, honestly: the balance point is not where the pool lives

The naive carry calculation says the 90/10 pool should earn `10% × 5% = 50 bp/yr` over holding
stables. The year simulation measured **+16.87 bp/yr**. The gap is not leakage — it's occupancy:

| Measured (year sim, with exit flow + stress week) | 99.99 pool | 90/10 pool |
|---|---|---|
| ST share **at the balance point** (design intent) | 0.01% | 10% |
| ST share **time-average under flow** (measured) | 0.25% | 3.28% |
| Realized carry ≈ avg share × 5% | ~1.3 bp | ~16.4 bp |
| Total LP excess vs 3% hold (carry + fees − costs) | **+1.85 bp/yr** | **+16.87 bp/yr** |

Exit flow pushes ST in; arbers promptly recycle it out; the pool re-parks near β, stables-full.
So *any* tilt's realized ST occupancy — and therefore its carry — sits well below its balance
point. The tilt sets a ceiling; flow sets the realized average. Three implications:

- The true yield gap between the candidates is **~15 bp/yr of TVL**, not ~50 — *and that is under
  daily ST marks*.
- **Under the production marking calendar (monthly ST marks), even that inverts**: T7 measured the
  90/10 LP ceding its whole spread to arbers (−50 bp/yr vs holding its own seed, landing ≈ at the
  plain stablecoin hold), while the 99.99 LP loses 0.05 bp/yr. Slow marks convert the 90/10's
  yield case into its liability; the 99.99 pool barely notices.
- If LP yield is a first-class product goal, this pool is the wrong lever — its own mechanics
  suppress inventory, and the marking calendar taxes whatever inventory remains. In the Day
  system the LT holders' real compensation is the **liquidity premium** the kernel mints;
  in-pool carry is a garnish at any tilt.

---

## 6. What doesn't change with tilt (confirmed tilt-invariants)

Measured identical (not merely similar) between the two candidates:

- **Exit absorption and drain pricing** — the quote-side ladder depends only on α/rotation/λ.
  Every drain-anchor price, density bucket, and consumed-fraction matched between tilts.
- **Concentration profile** — density peaks at the balance point and decays monotonically to ~8%
  of peak at the −15 bp floor: the "concentrated at balance, less as it drains" requirement,
  photographed in ten buckets.
- **Round trip through a drained pool** ≈ 2.0 bp = exactly two fee legs.
- **The cadence-mismatch failure mode** (mismatched provider cadences leak on both tilts alike).
- **One-shot $1M exit haircut** (1.24 bp) and daily drift capture (1.37 bp).

The corollary is the sharpest sentence in this document: **choosing the tilt buys and risks
nothing about exit liquidity itself.** It only chooses how much ST inventory sits in the pool at
rest — which is simultaneously the LP's carry (§5) and the arber's food (§4).

---

## 7. Recommendation

**Ship the 99.99/0.01 pool**: 1 bp fee, both legs `WITH_RATE`, synchronized daily-or-faster
marks, production 15 bp α floor, dust-seeded single-sided in stables at deployment (Decision 1
makes this free). Parameters: the `_eclpParamsA` / `_derivedParamsA` literals in the test file,
already validated on-chain.

The reasoning, given the goals (exit liquidity; no bricking; no meaningful arbs; LP yield as a
secondary good) **and the production marking calendar (stable per-second, ST potentially
monthly — the §4 operating regime)**:

- Exit capacity is tilt-invariant (§6) — the extreme tilt gives up **zero** mandate performance.
- Its arb surface is microscopic ($0.04/event) and its fee-shield margin (2000×) survives fee
  changes, parameter drift, and rounding without anyone thinking about it.
- **Under monthly ST marks it is the only candidate whose economics survive intact**: carry drag
  0.05 bp/yr vs the 90/10's 50 bp/yr — slow marks turn the 90/10's entire yield argument into a
  structural cession to arbers (§5), which removes the main reason to prefer it.
- The residual LP-carry sacrifice is therefore ~0 in the production regime (and at most
  ~15 bp/yr even under daily marks).
- The pool "wants" to live stables-full regardless of tilt; 99.99 ratifies the equilibrium the
  90/10 design would spend all year fighting — and a β-pinned, stables-full pool is maximum
  readiness for exits, at any marking cadence.

**When to revisit:** if in-pool LP carry is promoted to a primary goal **and ST marking moves to
~daily or faster** (both are required — under monthly marks the carry goes to arbers regardless),
the measured fallback is 90/10 at 1 bp (2× shield margin, +16.87 bp/yr under daily marks, worst
case ≈ the hold). Pushing further (e.g.
85/15 with a 1.5–2 bp fee to re-widen the shield and the staleness breakeven) is *extrapolated,
not measured* — re-run this battery on those parameters before believing it; that is what the
suite is for. The other standing design question is band width: the production −15 bp floor caps
all drain costs at ~2 bp but stops absorbing exits below −15 bp; a multi-% α-tail (as in the
Python benchmark's family) keeps absorbing at costs that grow to hundreds of bp. That is a product
choice about *how* exits should degrade, orthogonal to the tilt.

---

## 8. Reconciliation with the independent Python benchmark

The benchmark (a high-precision offline model, validated to ~1e-48 against the library's price
formulas) and this suite agree on the geometry and laws, and differ where its assumptions differ
from production wiring or its parameter family (α = 0.90, λ = 1000) differs from production's
(α = peg − 15 bp, λ = 4000).

| Benchmark claim | On-chain result | Status |
|---|---|---|
| Tilt is achievable only via band asymmetry (peg jammed under β); rotation cannot do it | Implemented exactly so; 99.9900% / 90.0000% measured at peg | **Confirmed** |
| Solved β = 1.0000023 for the 99.99% tilt | β = 1 + 4.74e-8 here | **Both right** — β for a given tilt shrinks as λ rises and α tightens; different family, same geometry |
| Round trip = exactly two fee legs | 1.9998 bp measured | **Confirmed** |
| Single-sided fee leak ≈ (1−w)·fee ≈ 0 at extreme tilt | 0.0000 bp (99.99), 0.0999 bp ≈ w·fee (90/10) | **Confirmed; law generalizes** |
| Adding the scarce asset to a drained pool *pays you* (rebalancer's credit) | Fair-valued add cost measured negative at drained states | **Confirmed** |
| BPT oracle's curve-minimum mark coincides with the peg | Analytically sound (min of x+y is where marginal price = 1); not exercised by this suite | **Plausible, untested here** |
| Price always drifts *down toward α*; β never approached | **Inverted in production wiring**: between discrete ST marks fair value rises above the stale mark, arbers buy the ST leg, the pool pins at **β** ~99% of the time (measured). The downward-drift result holds only for continuously-applied rates with no trading | **Corrected** — and β-pinning is benign *because of the fee shield*, which the benchmark's 90% family (β−1 = 23.5 bp > fee) does not have |
| "No arbs from rate changes" as a universal | True same-block; false across marks: 50 bp/yr under cadence mismatch, inventory-share × 5%/yr carry drag under stale marks | **Conditional** — it is an ops invariant, not a geometric one |
| Deep-drain exit slippage 4.5 → 490 bp | 0.25 → 1.9 bp here | **Both right — band width**: 10% α-tail vs 15 bp floor. The open product choice flagged in §7 |
| Whale add loses ~$81 to a standing arb (their 90% family) | $0 here — the displacement lands inside the fee shield | **Both right** — their 90% band's β-gap (23.5 bp) exceeds the fee; production's (0.53 bp) does not. Same physics, opposite regime |
| `disableUnbalancedLiquidity` plausibly enabled for this pool | **Must stay off**: the Day kernel's own LT deposits and premium reinvestment *are* unbalanced adds | **Corrected** (product constraint) |

---

## 9. Caveats — what these tests do *not* show

- **Senior write-downs are not modeled.** The junior-protected 8%-up-only rate is the design
  premise; a genuine ST NAV drop would exercise α-side dynamics these runs never reach.
- **The EclpLPOracle / `computeTVL` marking path is not in this harness** (the kernel fork suites
  cover it); the benchmark's curve-minimum claim stays analytically-argued only.
- **Both mock tokens are 18-dec**; 6-dec (USDC-style) decimal plumbing is covered elsewhere.
- **The fair-value model is the mocked rates.** Real-world deviations between the marked rate and
  tradable reality (venue basis, redemption queues) are outside scope.

---

## 10. Test map & glossary

| Contract (all in `Test_ECLPExitLiquidityPoolEconomics.t.sol`) | Covers |
|---|---|
| `Test_PoolEconomics_ECLPExitLiquidity` | T1 composition & concentration profile; T2 rate-update arbs, cadence grids, breakeven sweeps; T3 single-sided add & round-trip costs across drain states; T4 wiring and numeric edge behavior |
| `Test_YearSimulation_ECLPExitLiquidity` | T3 one-year LP PnL vs the 3% hold (daily marks, exit flow, stress week) |
| `Test_WhaleAddAndGenesis_ECLPExitLiquidity` | T5 the $1M-into-$500k whale add, size ladder, round trip; T6 one-sided genesis at $10k/$100k/$1M with optimal arb + wei-exact conservation ledger |
| `Test_ExtremeCadence_ECLPExitLiquidity` | T7 per-second stable / monthly ST marks: strip dynamics, carry drag, exiter haircuts, minimum safe cadence |

**Glossary.** *Carry*: the 5%/yr yield spread earned by whoever holds ST instead of stables — the
LP when marks are fresh, the arber when they're stale. *Fee shield*: the inequality β − 1 < fee
that makes the β-pinned state unexploitable. *β-pinning*: the pool resting at its all-stables
corner — the measured default state, benign under the shield. *One-time recycle*: the capped arb
of buying freshly-exited ST inventory once; non-repeatable because the shield blocks refills.
*Carry drag*: carry redirected to arbers under stale marks (= inventory share × 5%/yr). *Drain
anchor Dxx*: the pool state after xx% of its stables have been taken by exiters.
