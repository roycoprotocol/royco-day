# Mock vs real Balancer V3: fidelity notes

The mock Balancer layer (`MockBalancerVault`, `MockBPT`, `MockBPTOracle`) satisfies every call the
kernel's venue layer makes, with real-vault semantics wherever production behavior depends on them.
This table records what is mirrored faithfully and every deliberate delta, so a test author knows
which behaviors would differ on a fork.

## Mirrored faithfully

| Behavior | Real Balancer V3 | Mock |
| --- | --- | --- |
| Unlock/settle session | Every debt or credit opened by `addLiquidity` / `removeLiquidity` / `sendTo` must be closed by `settle` / `sendTo` before `unlock` returns, else `BalanceNotSettled` | Same transient debt/credit ledger, same error |
| Callback dispatch | `unlock` calls the callback FROM the vault's address (`onlyVault` callbacks pass), reverts bubble verbatim | Same |
| UNBALANCED add semantics | `maxAmountsIn` treated as exact amounts in, `BptAmountOutBelowMin(actual, min)` on a shorted mint | Same, same error shape |
| PROPORTIONAL remove semantics | `maxBptAmountIn` exact, floor-rounded constituent claims, `AmountOutBelowMin(token, actual, min)` | Same, same error shape |
| Minimum pool supply | `_POOL_MINIMUM_TOTAL_SUPPLY = 1e6` minted to `address(0)` at pool initialization (`ERC20MultiToken._mintMinimumSupplyReserve`), and any mint or burn leaving `totalSupply < 1e6` reverts `PoolTotalSupplyTooLow(newTotalSupply)` | Same: the first `mintPoolTokensTo` for a pool mints the 1e6 dead reserve in addition to the requested amount, and `_mintBpt` / `_burnBpt` enforce the floor with the imported `IERC20MultiTokenErrors.PoolTotalSupplyTooLow` |
| Owner-spends-freely allowance | `_allowance(pool, owner, spender)` returns `type(uint256).max` when `owner == spender` ("Owner can spend anything without approval"), so `transferFrom` by the owner needs no approval | Same exemption in `allowance` and `transferFrom` |
| Token registration order | Tokens registered sorted ascending by address, so the senior tranche share is NOT guaranteed index 0 | The fixture registers `[min(st, quote), max(st, quote)]`; the mock stores and reports whatever order it was given |
| Rate-scaled leg pricing | The E-CLP prices a rate-scaled token through `IRateProvider.getRate` read live on every pool operation, and the E-CLP oracle values that leg through the same provider | `setTokenRateProvider(token, provider)` on both the vault and the oracle; the fixture wires the kernel (the production rate provider) for the senior tranche share at deployment, so a post-sync rate refresh reaches the very next add/remove and the TVL mark exactly like production, and the senior leg can never read the raw ST-asset mark |

## Deliberate deltas (test conveniences that differ from a fork)

| Surface | Real Balancer V3 | Mock | Consequence for tests |
| --- | --- | --- | --- |
| `quote()` | `eth_call`-only: `quoteAndRevert` enforces `EVMCallModeHelpers.isStaticCall()`, so an on-chain transaction cannot call it | Revert-and-discard via an external self-call, callable mid-transaction | Kernel previews that self-call `quote` inside a test transaction work here but would revert `NotStaticCall` on a fork; preview-parity tests exercising previews mid-tx are mock-only by construction |
| Pool hooks | Production registers `RoycoDayBalancerV3Hooks`, which syncs the kernel's accounting before every external pool operation | No hook layer at all | External swaps/joins in mock-land do not pre-sync the kernel; any test simulating third-party pool flow must sync explicitly if it needs the production ordering |
| Add-liquidity pricing | E-CLP curve math: an UNBALANCED add pays curve-dependent swap fees on the imbalanced portion, so a single-sided add always mints less than linear fair value | Linear fair value at per-token WAD prices, haircut by a settable `unbalancedFeeBps` (default 0) | The default understates the single-sided leak: reinvest-gate calibration tests MUST set `unbalancedFeeBps` (or arm `setNextBptOutOverride`) to model the curve fee; a passing gate at 0 bps proves wiring, not economics |
| Nested `unlock` | Re-entrant unlock is a no-op re-entry (the vault is already unlocked, transient accounting is shared) | Each `unlock` frame increments a depth counter and the settlement check runs once per outer frame | Behaviorally equivalent for the kernel's single-unlock flows; a test nesting unlocks would see per-frame enforcement rather than shared-session semantics |
| Swap surface | Full swap/exact-in/exact-out surface | Not implemented (the kernel's venue layer never swaps) | Pool composition drift must be injected via `injectPoolBalance`, not swaps |
| BPT price source | `ltRawNAV` from Balancer's manipulation-resistant E-CLP oracle over real reserves | `MockBPTOracle`: AUTO mode prices the mock vault's pool balances at per-token WAD prices (senior leg via the live rate provider), MANUAL mode pins the TVL | Manipulation-resistance properties are asserted structurally, not economically |
| `mintPoolTokensTo` / `injectPoolBalance` | No equivalent (LPs go through `initialize` / `addLiquidity`) | Fixture-only helpers that seed depth or drift composition while keeping vault reserves truthful | Test-only surface; production invariants about who can mint BPT do not apply to it |

## Conventions

- `mintPoolTokensTo` token amounts are positional in the pool's REGISTRATION order (sorted by
  address). Use `DayMarketTestBase.stPoolTokenIndex` to place a senior or quote leg, never a literal
  index.
- The first `mintPoolTokensTo` for a pool mints the 1e6 dead reserve. `DayMarketTestBase`
  initializes every market's pool with a genesis seed whose value exactly backs the dead shares
  (`_initializePoolMinimumSupply`), so NAV-per-BPT starts at exactly 1.0 and hand-derived marks
  stay wei-exact while the minimum-supply semantics stay real.
- The senior tranche share's price in both stores is the kernel's `getRate` read live (the
  fixture wires the provider at deployment). Static `setTokenPriceWAD` / `setPriceWAD` writes for
  a provider-backed token are shadowed and the oracle's `bump` skips it, so `applyLTPnL` moves
  the quote leg only, exactly as a production rate-scaled leg cannot drift from its rate.
