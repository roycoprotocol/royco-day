# Tilted E-CLP Exit-Liquidity Pool — Objective Assessment

Every number in this document is measured by `Test_ECLPExitLiquidityPoolEconomics.t.sol` in this
folder, against the **real Balancer V3 vault and real `GyroECLPPool`** deployed locally from the
vendored monorepo — only the two rate providers are mocked. Regenerate everything with:

```
forge test --match-path test/concrete/Balancer/eclp/Test_ECLPExitLiquidityPoolEconomics.t.sol -vv | grep -E "METRIC|VERDICT"
```

**The two candidates**, both initialized exactly at their balance point, both with the senior-tranche
share (ST) earning 8%/yr and a yield-bearing stablecoin quote earning 3%/yr, both legs `WITH_RATE`,
1 bp swap fee, production band floor (α = peg − 15 bp), rotation at price 1, λ = 4000:

| | **tilt9999** | **tilt9010** |
|---|---|---|
| Stablecoin share at balance | 99.99% (measured 99.9900%) | 90.00% (measured 90.0000%) |
| β (solved for the tilt) | 1 + 4.74e-8 | 1 + 5.2988e-5 |
| ST inventory at balance ($10M-quote pool) | ~$1,000 | ~$1.11M (1000×) |

Units below: raw logs use `bp*1e4`; this document shows plain bp. Dollar figures assume the test
fixtures ($10–11M TVL main pools; $500k whale pool).

---

## Decision 1 — Is single-sided stablecoin **initialization** valid?

**Max loss after fees and arb: $0.00 on both tilts, at every seed size tested.**

| Measured (T6) | tilt9999 | tilt9010 |
|---|---|---|
| Seeder loss at production 1 bp fee ($10k / $100k / $1M seeds) | **0 / 0 / 0** | **0 / 0 / 0** |
| Optimal-arb profit against the fresh pool | 0 | 0 |
| Loss vs balanced (90/10 or 99.99/0.01) seeding | 0 | 0 |
| Diagnostic: loss at the pool-minimum 0.01 bp fee | 0 | 0.0254 bp (scale-invariant) |
| Conservation residual (seeder loss − arber profit) | 0 wei | 0 wei |

**Why (the intuition):** initializing with stables only opens the pool pinned at β — its
most-expensive-ST corner. The *only* thing an arber can harvest is the gap between β and fair
(1.0), because selling ST into the pool executes at most at β net of the fee. On both designs that
gap (0.0005 bp and 0.53 bp respectively) is **smaller than the 1 bp fee**, so the arb is
unprofitable at any size and never fires: **the fee shields the entire band**. This was asserted
structurally (`β·(1−fee) < 1`) and then confirmed empirically with an optimal-size arb search.
The 0.01 bp-fee diagnostic proves the machinery finds the arb the instant the shield is thinner
than the band — tilt9010 then loses exactly the curve convexity (0.0254 bp, matching the offline
invariant-math prediction), and the loss is scale-invariant, as AMM geometry demands.

**Verdicts:** tilt9999 — **valid, loss-free**. tilt9010 — **valid, loss-free** (keep the fee ≥ β−1,
i.e. ≥ 0.53 bp, which the production 1 bp satisfies).

---

## Decision 2 — Is **always LPing single-sided into stables** valid?

**Max lifecycle loss after fees and arb: ≈ 2 bp, and only when both entering and exiting a
95%-drained pool. At or near balance the cost rounds to zero. Over a simulated year the LP beats
the 3% stable-hold benchmark on both tilts.**

| Measured | tilt9999 | tilt9010 |
|---|---|---|
| Entry cost at balance (T3, spot-numeraire, 0.1–50% TVL adds) | 0.0000 bp | 0.096–0.100 bp |
| Entry cost at 95% drained (worst state, 50% TVL add) | 1.90 bp | 2.01 bp |
| Add + remove round trip at balance (T3) | 0.0001 bp | 0.198 bp |
| Round trip at 95% drained | 1.88 bp | 1.89 bp |
| **Whale: $1M single-sided into a $500k pool (2× TVL)** (T5) | **0.0000 bp ($0.0033)** | **0.0391 bp ($3.92)** |
| Whale round trip (add then single-sided remove) | 0.0000 bp | 0.0666 bp |
| Whale ladder $100k → $2M (per-dollar slippage) | 0 at all sizes | 0.0869 → 0.0242 bp (falls with size) |
| **1-year simulation: LP excess return vs 3% hold** (daily marks, exit flow, stress week) | **+1.85 bp** | **+16.87 bp** |
| — of which lost to arbers | 0.36 bp/yr | 0.03 bp/yr |

**Why (the intuition):**
- *Entry is nearly free because you are adding the token that already is the pool.* An unbalanced
  add is charged fees only on its non-proportional fraction. Into a 99.99%-stable pool a stable add
  is proportional to 4 decimal places → cost literally rounds to 0 wei. Into 90/10 the imbalanced
  fraction is the 10% ST share → cost ≈ 10% × 1 bp fee ≈ 0.1 bp. The measured law `cost ≈ w_ST×fee
  + impact` held at every drain state.
- *The whale add gets cheaper per dollar as it gets bigger*, which surprises until you see that a
  2×-TVL add mostly looks like re-seeding the pool proportionally — and the tiny β-gap caps how far
  the implicit swap can move the price (post-add spot sits 1.6e-8 / 1.8e-5 below β).
- *The real cost is exiting a drained pool* — 1.9 bp — and that is not a leak, it is the price of
  demanding stables from a pool whose job was to hand stables to exiting seniors all week. The
  15 bp band floor caps it: nothing in this design can make a single-sided LP lose more than
  ~band-depth + fees, and measured worst case is ~2 bp.
- *The LP beats holding* because fee income on exit flow exceeds arb leakage at sane oracle
  cadence: tilt9010 earns ~9× more (+16.87 bp vs +1.85 bp) simply because 10% of its capital sits
  in the 8% asset instead of 0.01% (`SIM_excess_carry`: $159.6k-equivalents vs $6.4k per year of sim).

**Verdicts:** tilt9999 — **valid; costs indistinguishable from zero at every size**, minimal carry.
tilt9010 — **valid; ≤0.2 bp at balance, ~2 bp worst-case drained, and the best LP economics of the
two** — *conditional on oracle cadence discipline (Decision 3)*.

---

## Decision 3 — Is the pool composition valid? Pros and cons

**Both compositions are economically sound under the required wiring (both legs `WITH_RATE`,
synchronized marks at ≥daily cadence, 1 bp fee). They fail the same two ways (wiring, not tilt)
and differ mainly in what they are *for*.**

### The arb picture (T2, T7)

| Rate-update scenario | tilt9999 | tilt9010 |
|---|---|---|
| Synchronized daily marks: steady-state extraction (all 5 drain states) | **0** | **0** |
| Synchronized daily: one-time recycle of fresh exit inventory | $0.04 at balance / ~$179 drained | $14.39 at balance / ~$193 drained |
| Async 12h offset between the two providers | 0 | 0 |
| **ST daily / quote weekly (cadence mismatch)** | **53.1 bp/yr — NASTY** | **49.9 bp/yr — NASTY** |
| **Extreme: quote per-second, ST monthly (T7)** — arb margin | one-time $0.0096 | one-time $31.10 |
| — **forced-rotation carry drag** | **0.05 bp/yr** | **50.0 bp/yr** |
| — mid-cycle exiter execution haircut (day 15) | 33.8 bp | 33.2 bp |
| — pool pinned/inert | 99% of horizon | 99% of horizon |
| Breakeven ST cadence at 1 bp fee (0.5 / 1 / 1.5 bp) | 0.36 / **0.73** / 1.09 days | same (drift is tilt-independent) |
| Quote leg registered STANDARD instead of WITH_RATE | **pool dead by day 18** | **pool dead by day 18** |

**Why (the intuition):**
- *Steady-state extraction is zero at sane cadence because of β-pinning.* The balance point sits
  essentially at β. Fair value only ever drifts upward (8% > 3%), so the only arb is buying the
  pool's ST — and the pool holds almost none (tilt9999) or a bounded amount (tilt9010). Once
  bought, β·(1−fee) < 1 blocks re-selling it back, so **each unit of exit inventory can be recycled
  at most once**. No inventory, no repeatable arb: the "LVR faucet" everyone fears simply has no
  water supply.
- *The nasty cases are cadence bugs, not tilt properties.* A weekly quote leg oscillates the fair
  ratio both ways through the fee band and creates a genuinely repeatable ~50 bp/yr extraction on
  **both** tilts; the fix is synchronizing the two providers, not choosing a tilt.
- *Stale ST marks convert yield into arb-food.* Under monthly ST marks the arber strips the ST leg
  within 12–18 hours of the mark going stale and simply *holds it instead of the LP*: the LP's
  loss is not the strip margin (pennies) but ceding the 5%/yr ST-vs-stable yield spread on the
  whole ST allocation — measured at exactly `inventory share × 5%`: 50.0 bp/yr for 90/10, 0.05
  bp/yr for 99.99/0.01. Meanwhile exiters get executed against the stale mark: **−33 bp at
  mid-month on both tilts**. Even where the LP barely bleeds (tilt9999), the pool stops being fair
  exit liquidity. **Minimum safe ST update cadence at a 1 bp fee ≈ every 0.73 days; ship daily or
  faster.**
- *`STANDARD` quote wiring kills either pool in ~18 days* because the un-modeled 3%/yr quote drift
  walks the scaled price out of the 15 bp band floor. This is a hard wiring requirement, not a knob.

### Pros and cons

| | **tilt9999 (99.99/0.01)** | **tilt9010 (90/10)** |
|---|---|---|
| **Pros** | Arb surface is microscopic (one-time $0.04 at balance); every single-sided-LP cost measures 0.00 bp at balance incl. the 2×-TVL whale; genesis trivially safe; nearly immune even to *monthly* ST marks (0.05 bp/yr) | Real two-sided depth (max buyable ST = 10% of TVL vs 0.01%); 9× the LP carry (+16.87 bp/yr vs hold); *lower* relative arb leak in the year sim (0.03 vs 0.36 bp/yr — fee income on real inventory swamps it); genesis equally loss-free |
| **Cons** | Effectively one-way: the buy side can absorb only 0.01% of TVL, so it is an exit valve, not a market; negligible LP carry; permanently parked at β (benign, but any ST buy interest hits a wall) | 1000× the one-time recycle arb per exit batch (~$14–193, still fee-capped); **50 bp/yr carry drag if ST marks ever go stale to ~monthly**; 0.1–0.2 bp routine LP costs instead of 0.00 |
| **Choose it when** | The pool's only job is letting seniors exit into stables | You also want entry liquidity, LP yield, and a real order book against the band |

Shared and independently confirmed on both: identical quote-side density ladder (concentration
peaks at balance, decays monotonically to 8% of peak at the −15 bp floor — the "less concentrated
as it drains" requirement), 1.37 bp/day drift capture, one-shot $1M exit haircut 1.24 bp, round
trip through the drained pool ≈ 2.0 bp = exactly two fee legs.

---

## Reconciliation vs the independent Python benchmark

| Benchmark claim | On-chain result | Status |
|---|---|---|
| 99.99% tilt achievable only via band asymmetry (peg just under β), not rotation | Implemented exactly so; measured 99.9900% at peg | **Confirmed** |
| Solved β = 1.00000231 (for α=0.90, λ=1000) | β = 1 + 4.74e-8 (for α=0.9985, λ=4000) | **Consistent** — different (α, λ) family, same geometry; β shrinks as λ and α tighten |
| Composition ~insensitive to rate jumps at peg | Steady-state extraction 0 at every drain/cadence; max buyable ST 0.01% TVL | **Confirmed** (mechanism identical) |
| Round trip = exactly two fee legs (−2.000 bp) | 1.9998 bp measured at D50 | **Confirmed** |
| Single-sided fee leak ≈ (1−w)·fee ≈ 0 at 99.99% | 0.0000 bp measured (0.0999 bp at 90/10 = w_ST·fee) | **Confirmed, law generalizes** |
| Price drifts *down toward α*; β is the fragile edge | **Diverges:** measured fair ratio drifts *up*; the pool pins at **β** within hours-to-days and that pinned state is the benign steady state (it is what caps every arb) | **Benchmark direction inverted**; its "β-fragility" case is in fact the operating mode, and it is protective |
| Drain exit slippage 4.5 → 490 bp (3% → 83% drained) | 0.25 → 1.9 bp across D25 → D95 | **Both right — different bands.** Benchmark used a 10% α-tail; these tests keep the production 15 bp floor, which caps all drain costs at ~2 bp but stops absorbing exits ~15 bp below peg. This is the single biggest open *design choice*, not a math dispute |
| STANDARD quote wiring exits the band "in ~months" | Dead by **day 18** on both tilts | **Direction confirmed, speed 3× worse** (again band-width: a 15 bp floor is crossed much sooner than a 10% one) |
| EclpLPOracle curve-minimum mark coincides with peg | Not exercised — no LP oracle in this harness | **Untested here** (kernel-integration suite covers `computeTVL` separately) |

---

## Caveats and limits

- The harness prices **at external fair rates from mocked providers**; real-world senior NAV is
  junior-protected but not literally monotonic — a genuine ST write-down (not modeled) would test α-side
  behavior that these runs never reach.
- Both tokens are 18-dec; USDC-style 6-dec plumbing is covered by the kernel fork suites, not here.
- The EclpLPOracle/`computeTVL` marking claims from the benchmark remain unverified in this file.
- The band-width question (15 bp production floor vs a multi-% tail) changes drain economics by two
  orders of magnitude and deserves its own decision before mainnet.

## Recommended production settings implied by the numbers

1. **Register both legs `WITH_RATE`.** STANDARD quote wiring is an 18-day time bomb at any tilt.
2. **Synchronize the two rate providers and mark at least daily** (breakeven 0.73 days at 1 bp fee;
   the only "nasty arb" found anywhere came from mismatched cadences, ~50 bp/yr).
3. **Keep the fee ≥ β−1** (1 bp covers both candidates) — it is the shield that makes one-sided
   genesis and β-pinning loss-free.
4. **Seed single-sided in stables freely** — measured loss $0.00 at production fee, any size.
5. **Pick the tilt by product intent**, not by fear of arbs: 99.99/0.01 as a pure exit valve,
   90/10 for a two-sided venue with real LP carry. At disciplined cadence both are clean; only
   stale ST marks separate them (0.05 vs 50 bp/yr), so if ST marks may ever lapse, that asymmetry
   is the decision.

## Test map (all in `Test_ECLPExitLiquidityPoolEconomics.t.sol`)

| Contract | Covers |
|---|---|
| `Test_PoolEconomics_ECLPExitLiquidity` | T1 composition/concentration, T2 rate-update arbs + breakeven sweeps, T3 single-sided add/round-trip costs, T4 wiring & numeric edges |
| `Test_YearSimulation_ECLPExitLiquidity` | T3 one-year LP PnL vs 3% hold (daily marks, exit flow, stress week) |
| `Test_WhaleAddAndGenesis_ECLPExitLiquidity` | T5 $1M-into-$500k whale add + ladder + round trip; T6 one-sided genesis loss at $10k/$100k/$1M with optimal arb + conservation ledger |
| `Test_ExtremeCadence_ECLPExitLiquidity` | T7 per-second quote / monthly ST marks: strip dynamics, carry drag, exiter haircut, min safe cadence |
