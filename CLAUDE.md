# Royco Day: Liquidity Tranche (LT)

This branch is the next iteration of the Royco protocol. It adds a third tranche, the Liquidity Tranche (LT), on top of the Dawn senior/junior (ST/JT) system. The work is strictly additive. ST and JT behave exactly as they do in Dawn. The live ST/JT markets are never upgraded, never recompiled, and never touch any new code path or storage field.

If you are picking this up cold, read this file, then `src/libraries/AccountingLib.sol` (the pure waterfall) and `src/accountant/RoycoAccountant.sol` (`_previewSyncTrancheAccounting`, the sync orchestrator). Those two files are where the design lives or dies.

## Branch goal

Dawn guarantees a minimum coverage for senior shares. Royco Day adds a second guarantee: a minimum secondary liquidity for senior shares at all times. The LT is market-making capital that holds a Balancer pool of ST shares against a stablecoin/yield bearing stablecoin, so ST holders always have a venue to exit into. The LT is paid a liquidity premium out of ST yield, in the same way JT is paid a risk premium.

This separates two jobs that Dusk overloaded onto the junior tranche. In Dusk the JT was both first-loss coverage and pool liquidity, which forced one combined minimum tranche size. Here JT stays pure first-loss coverage exactly as Dawn, and the LT carries liquidity. Each issuer picks coverage and liquidity independently from a menu. JT always clears at least the base yield of the underlying. The cost is more capital to raise and two enforced minimums.

## Capital structure

- ST is protected senior capital, deployed into a yield-bearing asset. It pays the JT a risk premium and the LT a liquidity premium.
- JT is first-loss capital. It provides coverage to ST on losses until exhausted, and earns the JT risk premium via the YDM. Unchanged from Dawn.
- LT is a separate self-backed capital pool. It holds a Balancer V3 Gyro E-CLP BPT, an LP of the ST vault share paired against a quote stablecoin. It earns the liquidity premium via a new Liquidity Distribution Model (LDM). Equivalent risk to ST, higher return, less liquid.

The three premiums are draws on the same residual senior appreciation, in a fixed order with a fixed joint cap. JT coverage repayment is first. The JT risk premium is second. The LT liquidity premium is third. ST keeps the residual, with a guaranteed retention floor.

Hard constraint: `maxLiquidityPremiumWAD + maxRiskPremiumWAD <= WAD` (100% of ST yield).

## Accountant architecture: modular libraries, Dawn base, Day extends

The accounting state machine is driven by pure library functions. The accountant contracts are thin orchestrators over them. This is already the shape of the code: `AccountingLib` holds `applyProfitAndLossWaterfall` (the pure waterfall), `applyStateTransition` (the PERPETUAL/FIXED_TERM machine), and `enforceNAVConservation`, and `RoycoAccountant._previewSyncTrancheAccounting` is a three-step coordinator (resolve YDM, run waterfall, apply state transition). Royco Day continues that direction.

Two layers:

1. Library layer. `AccountingLib` stays the Dawn anchor and is reused verbatim for the 2-tranche math, so the audited senior/junior waterfall is literally the same code. The LT premium leg is added as a parameterized extension: the liquidity-premium fraction is an input that is inert (zero) on the Dawn path. New pure Day-specific math (the liquidity metric, the BPT mark, the recomposition solver) lives in its own libraries so it is independently testable and verifiable.

2. Contract layer. The existing `RoycoAccountant` is the Dawn base (it may be renamed `RoycoDawnAccountant` only as a behavior-preserving rename, validated by the full Dawn suite plus a storage-layout snapshot). `RoycoDayAccountant` extends it. ERC-7201 is what makes inheritance safe here: the LT state goes in a fresh namespaced storage slot, so the derived contract's fields are additive and cannot collide with the base. The base exposes `virtual` seams (the sync orchestrator and the model-resolution helpers). `RoycoDayAccountant` overrides them to also resolve the LDM, carve the LT premium, and carry LT NAV. Coverage, the loss waterfall, and the state machine are inherited unchanged.

Why inheritance over a single parameterized accountant: it gives a structural guarantee that Dawn markets run the existing audited bytecode, not a conditional branch. `RoycoDayAccountant` is a separate implementation with its own deploy salt. The shared `IRoycoAccountant` signatures the live markets use stay byte-for-byte, which keeps `Deploy.s.sol` and the upgrade ops modules compiling and the live upgrade path intact. Day is new-markets-only. A live Dawn accountant proxy is never upgraded into a Day accountant.

The anchor test for the whole branch: `RoycoDayAccountant` configured with zero minimum liquidity must produce byte-for-byte identical state to `RoycoDawnAccountant`. This turns "ST/JT are unchanged" from a claim into a differential assertion.

## Additive and non-invasive integration principle

Every change obeys these rules.

- ST and JT accounting is untouched. The LT premium is inserted only inside `STEP_DISTRIBUTE_YIELD`, after `STEP_JT_COVERAGE_IMPERMANENT_LOSS_RECOVERY` and after the JT yield-share subtraction. Step-1 raw-to-effective attribution, the JT mark, ST loss and coverage, `jtCoverageImpermanentLoss` accrual, and `computeCoverageUtilization` are byte-for-byte.
- Shared interfaces stay byte-for-byte. LT entrypoints live on a new `IRoycoLiquidityKernel` and on `RoycoDayAccountant`, not on `IRoycoDawnKernel` or the shared `IRoycoAccountant`.
- All new storage is appended in fresh trailing slots. ERC-7201 namespace strings and slot constants are byte-identical. The fully packed accountant slot is never touched. The LDM reuses the existing accrual and distribution timestamps.
- Enum appends preserve existing ordinals. `TrancheType` gains `LIQUIDITY`, `Operation` gains `LT_DEPOSIT` and `LT_REDEEM`, at the end.
- The liquidity gate is orthogonal to coverage. It never modifies coverage config validation, the coverage requirement check, `computeCoverageUtilization`, or the forced-perpetual conditions. Coverage and liquidity are two independent minimums.

## Conservation model

The LT is a genuine self-backed pool with its own `ltRawNAV` and `ltEffectiveNAV`. NAV conservation generalizes to three terms:

    stRaw + jtRaw + ltRaw == stEff + jtEff + ltEff   (wei precision)

via a new 6-arg `enforceNAVConservation` overload. The 4-arg form is kept for the live markets. `ltRawNAV` is marked by the manipulation-resistant BPT oracle. LT raw deltas (BPT appreciation) are attributed 1:1 into `ltEffectiveNAV`, so carried-but-unredeemed premium is never erased. The liquidity premium is a zero-sum move from `stGain` into `ltEffectiveNAV`. At deposit, `ltEffectiveNAV` is seeded equal to `ltRawNAV`, so the premium adds strictly on top and conservation holds.

The rejected alternative booked the premium inside `jtEffectiveNAV`. It is rejected because `jtEffectiveNAV` feeds `computeCoverageUtilization`, `maxSTDepositGivenCoverage`, and `maxJTWithdrawalGivenCoverage`, so it would silently change the coverage gate, and because the kernel could not redeem an LT claim that only exists embedded in JT.

## The three-way ST-yield split

Inside `STEP_DISTRIBUTE_YIELD`, on the up path only, after JT coverage IL is fully recovered:

1. JT risk premium (existing, unchanged): `riskShare = floor(stGain * jtFracWAD)`. `jtEffectiveNAV += riskShare`; `stGain -= riskShare`.
2. LT liquidity premium (new): `liqShare = floor(stGain * ltFracWAD)`, computed against the already-reduced `stGain`, then clamped `liqShare = min(liqShare, stGain)`. `ltEffectiveNAV += liqShare`; `stGain -= liqShare`.
3. ST keeps the residual, subject to the retention floor `stMinRetentionWAD` so senior always clears positive net yield.

All legs round Floor, so leftover wei stays with ST. The protocol fee on the LT premium is gross and never netted, and is zeroed in fixed term alongside the ST and JT fees.

The joint cap is validated at `initialize` and in both setters. Because `liqShare` is computed on `stGain` after `riskShare` is removed, the effective draw is `riskFrac + (1 - riskFrac) * liqFrac`, which cannot exceed 100%. The `min` clamp is the load-bearing underflow guard on the time-weighted path, where two independent accumulators can momentarily sum above WAD. The per-sync sum `require` is a sanity assert.

The LDM, like the YDM, is pre-resolved against the last committed checkpoint, never against the candidate raw NAVs. This keeps the waterfall a pure function, so the max, preview, and recomposition-bisection paths can probe it repeatedly.

## LT spec

### BPT custody

The kernel is the sole custodian of the BPT, tracked in `ltOwnedYieldBearingAssets`. The LT tranche is a pure share token, WAD (18) decimals, denominated in NAV. It holds no assets. Burn-after-kernel ordering, the blacklist hook, seize bypass, and the zero-supply and zero-NAV boundaries carry over from the ST/JT tranche base unchanged.

### Deposits and redemptions

- `ltDeposit` takes pre-minted BPT. The vault transfers BPT to the kernel and credits the counter.
- `ltDepositMultiAsset` is the atomic flow. It pulls the ST yield-bearing asset and the quote stable, mints the ST share, performs the Balancer V3 join, and mints the LT share, inside `Vault.unlock`. It is bounded by `minBptOut`, a max-asset-in per token, and a deadline. The NAV floor alone cannot catch join-ratio MEV, so the asset-in bounds are required.
- LT redemption returns BPT via a sandwich-safe proportional `removeLiquidity`, plus the accrued premium leg paid in ST's yield-bearing asset. A redemption can pay up to three distinct assets, so `_withdrawAssets` groups by token address, sums within a group, and debits each owned-asset counter independently.

### LDM

The Liquidity Distribution Model mirrors the YDM. It is a per-accountant adaptive curve keyed by `msg.sender`, driven by `liquidityUtilization` instead of `coverageUtilization`. It adapts only in PERPETUAL and is frozen in fixed term. `previewLiquidityPremiumShare` and `liquidityPremiumShare` return a fraction in `[0, WAD]`, clamped to `[0, maxLiquidityPremiumWAD]`, asserted at every call site. A static LDM ships first; the adaptive curve follows.

### liquidityUtilization gating

    U_liq = ceil(stEffectiveNAV * minLiquidityWAD / ltRawNAV)

Enforced post-op on redemptions only, with the rule `U_liq <= WAD`. Deposits are never gated, because a deposit raises `ltRawNAV` and only lowers `U_liq`. The gate is bypassed when `coverageUtilizationWAD >= liquidationCoverageUtilizationWAD`, the exact existing liquidation predicate, so a true liquidation unblocks all withdrawals. `minLiquidityWAD == 0` fully disables the gate and the premium, which is the default for every existing market.

### Manipulation-resistant LT_RAW_NAV oracle

`LT_RAW_NAV` is computed at the fair point on the frozen E-CLP invariant, not at live balances. All venue inputs are frozen once per sync. After the freeze, valuing a candidate makes no external calls and reads no storage, so a mid-sync swap or donation cannot lift the mark above true fair value within a block. The E-CLP valuation math is reused verbatim from the Dusk branches (audit-pinned); only the call site changes. Because the BPT contains the ST shares it backs, marking it is recursive: the kernel solves a fixed point by constant-gas integer bisection and caches the result, and a rate provider proxies the same cached value so the pool and the accountant never disagree. Kernel-initiated joins and exits bypass the pool hook sync (`router == kernel`) so they never double-commit a checkpoint.

The fair-point mark is single-block manipulation-resistant. It is not realizable exit depth. Under sustained quote depeg, arbitrage halt, or composition drift it can overstate realizable liquidity. See open decisions.

## Contract map

New:
- `src/accountant/RoycoDayAccountant.sol`: extends the Dawn accountant with the LT premium, LDM resolution, liquidity metric and gate, LT fee collection, and LT setters. Separate impl and deploy salt.
- `src/interfaces/IRoycoLiquidityKernel.sol`, `src/kernels/base/RoycoLiquidityKernel.sol`, `src/kernels/liquidity/*`: the LT-aware kernel.
- `src/tranches/RoycoLiquidityTranche.sol`: the LT vault share.
- `src/interfaces/ILDM.sol`, `src/ldm/*`: the Liquidity Distribution Model.
- `src/interfaces/venues/ILiquidityVenueValuationOracle.sol`, `src/oracles/venues/balancer-v3/*`: the venue oracle abstraction, the ported E-CLP valuation lib, the rate provider, and the pool hook. The abstraction lets any AMM or MM vault (for example Agra) back the LT; Balancer E-CLP is first.
- `src/libraries/RoycoLTBisectionSolverLib.sol`: the recomposition fixed-point solver.

Modified (additive):
- `src/libraries/AccountingLib.sol`: 6-arg conservation, the LT premium leg behind an inert-on-Dawn parameter, LT excluded from coverage. Virtual-seam friendly.
- `src/accountant/RoycoAccountant.sol`: `virtual` seams for the sync orchestrator and model resolution. No behavior change on the Dawn path.
- `src/libraries/Types.sol`: append-only enum and struct fields.
- `src/interfaces/IRoycoAccountant.sol`, `src/interfaces/IRoycoDawnKernel.sol`: appended state, errors, events. Shared signatures unchanged.
- `src/kernels/base/RoycoDawnKernel.sol`: isolated edits only (`onlyTranche` widening, up-to-3-asset withdraw). ST/JT bodies unchanged.
- `src/tranches/base/RoycoVaultTranche.sol`: explicit `SENIOR`/`JUNIOR`/`LIQUIDITY` dispatch with a revert default.
- `src/factory/*`, `src/interfaces/IRoycoFactory.sol`: a `deployMarketWithLT` path adding the fifth CREATE3 proxy and `LT_LP_ROLE`. The existing 4-contract `deployMarket` is untouched.
- `src/libraries/DayUtilsLib.sol`: wire in `computeLiquidityUtilization` (present but unused); correct its docstring so `_ltRawNAV` is the genuine LT raw NAV, not `jtRawNAV`.
- `script/Deploy.s.sol`, `script/config/MarketDeploymentConfig.sol`, `script/upgrade/modules/*`: the LT deploy path and lockstep init updates. Existing literals and the live upgrade path unchanged.

Unchanged and reused: `src/auth/RoycoBlacklist.sol` (the LT inherits the 3-address batch screen for free by routing balance updates through the existing hook), and the Dusk E-CLP valuation library (ported verbatim, do not modify the ported math).

## Invariants

- NAV conservation holds at wei precision across all three tranches. The premium is funded from ST gain, never minted.
- JT coverage IL recovery is the first claim on ST appreciation. The LT premium sits strictly below it and below the JT risk premium.
- `maxLiquidityPremiumWAD + maxRiskPremiumWAD <= WAD`. The waterfall `min` clamp guarantees no underflow on any path.
- All premium legs round Floor (senior-favoring). The BPT mark rounds senior-favoring at every step.
- LDM and YDM outputs depend only on the last committed checkpoint, so the waterfall stays pure and the bisection stays valid.
- Coverage math and the PERPETUAL/FIXED_TERM machine remain ST/JT only.
- The kernel is the sole BPT custodian. ST share supply stays at least 1 for the life of an LT market.
- `RoycoDayAccountant` with zero minimum liquidity equals `RoycoDawnAccountant`, byte-for-byte.

## Build sequence

Each phase is independently testable. ST/JT stay untouched throughout. Balancer prior art is reused before any new math is written.

- P0, decisions gate. Ratify the conservation model, the accountant inheritance and salt strategy, and the LT-holds-the-BPT topology. Produce the written proof that the recomposition fixed point stays well-defined and the solver stays constant-gas with the premium leg present. Resolve or quarantine the E-CLP band-scaling math. Nothing is coded until these are closed.
- P1, additive data model (inert). Land all append-only enum, struct, and state changes with LT fields defaulting to zero. Prove the storage layout is byte-identical for every pre-existing field with a `forge inspect` snapshot. The full existing suite stays green.
- P2, accountant LT premium and liquidity metric. Implement the three-way split and the liquidity metric in `AccountingLib` plus `RoycoDayAccountant`, driven by a directly supplied `ltRawNAV`, with no Balancer wiring. The anchor differential test (Day at zero liquidity equals Dawn) and 3-tranche conservation property tests land here.
- P3, liquidity gate and LT custody. Wire LT deposit, redeem, max, and preview, the post-op redemption gate with the liquidation bypass, the 3-asset withdraw, and blacklist and seize parity, treating the BPT as a plain pre-minted asset. Preview must match execution.
- P4, Balancer venue oracle and solver. Replace the supplied mark with the frozen-input E-CLP oracle and the bisection fixed point. Wire the rate provider and the hook with the `router == kernel` carve-out. Manipulation-resistance and single-commit reentrancy tests land here.
- P5, deploy, factory, roles. Add the `deployMarketWithLT` path and the LT kernel type and roles. Regression: redeploy existing markets through the unchanged path and assert identical addresses, wiring, and roles.
- P6, economics and pre-mainnet hardening. Close the multi-block findings that per-sync tests cannot catch: the ST retention floor under correlated stress, the liquidity-depth metric versus the solvency mark, redemption griefing, and the pool permissioning and band-scaling checks against the deployed pool.

## Open decisions and pre-mainnet guardrails

These came out of the adversarial review and need a human before audit. The critical ones gate mainnet.

- Yield starvation under correlated stress. Risk-then-liquidity sequencing pays the LT the residual of a residual, so it is paid least exactly when liquidity is scarcest, and the two adaptive controllers compete for one scarce resource. Decision: adopt the `stMinRetentionWAD` floor, and decide whether the split should be pro-rata rather than strictly sequential.
- Fair-point mark versus realizable depth. The manipulation-resistant `LT_RAW_NAV` is a solvency value, not exit depth, and can overstate realizable liquidity under depeg or arbitrage halt. Decision: either drive the `U_liq` gate off a realizable quote-leg metric and add a composition-drift circuit breaker, or accept and document the bound.
- Redemption griefing on the 100% gate. The gate is depletable and first-mover, an ST appreciation event alone can retroactively block honest LT redemptions, and the last BPT unit is untrappable. Decision: a non-redeemable LT seed, a dedicated liquidity-liquidation threshold, a pro-rata throttle, or a Ceil-tolerance flip.
- Recomposition proof. Confirm the LT holds the BPT and JT stays a plain priced tranche, so there is one fixed-point variable, and prove the recursion stays 1-Lipschitz and monotone with the premium leg. Until proven, the bisection uniqueness and constant-gas guarantees do not transfer from the 2-tranche Dusk spec.
- E-CLP band scaling. The rate-scaling factor in the Gyro E-CLP band mapping is spec-pending and is the only post-freeze revert path. It must be verified against the deployed pool's token sort and rate convention before mainnet.
- ST supply seed. Specify where the non-redeemable minimum senior position is minted so the solver never divides by zero.
- Pool permissioning. Confirm the pool LP set equals the kernel, or rebase the liquidity metric on absolute owned quote depth, so external mint and burn cannot move the gate and the adapted premium without touching the kernel.
- FIXED_TERM premium policy. Make premium suppression in fixed term explicit rather than emergent. ST gain can reach the LT leg during dust-buffer restoration while still in FIXED_TERM.
- Factory and ABI migration. New factory versus UUPS upgrade of the shared pre-deployed factory (which changes all future deterministic addresses), the new accountant impl salt, and the indexer migration for the grown accounting state.
