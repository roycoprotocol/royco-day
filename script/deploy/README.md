# Deployment pipeline

The deployment is decomposed into per-component scripts, each with its own configuration, each idempotent
(re-running reuses anything already at its deterministic address), and each broadcasting its own transactions.
Downstream scripts accept upstream component addresses at construction in a struct; the CLI entrypoints derive
defaults from `RoycoDeterministic` predictions, so every script is standalone-runnable.

## Environment

| var | meaning |
|---|---|
| `DEPLOYER_PRIVATE_KEY` | the broadcasting deployer (required) |
| `IS_TEST_DEPLOYMENT` | `true` selects the test salt namespace + single-admin roles (default: production) |
| `TEST_ADMIN` | overrides the single test admin (test deployments only) |
| `MARKET_NAME` | the market to deploy (`DeployMarket` only) |
| `TEMPLATE_ADDRESS` | the registered template (`DeployMarket` standalone runs) |

## Runbook

**1. Bootstrap the chain** (everything a chain needs before any market — core, periphery, roles, blacklist,
implementations, template, YDMs; safe to re-run):

```bash
forge script script/deploy/BootstrapChain.s.sol --rpc-url $RPC_URL --broadcast
```

Or run the components individually, in this order (the only two ordering constraints: periphery BEFORE the role
graph, and renounce LAST):
`core/DeployCore.s.sol` → `core/DeployPeriphery.s.sol` → `core/ApplyRoleGraph.s.sol` → `core/DeployBlacklist.s.sol`
→ `templates/royco-day-balancer-v3/DeployImplementations.s.sol` → `.../DeployTemplate.s.sol` (via bootstrap) →
`.../DeployYDMs.s.sol`.

**2. Deploy markets** (repeatable; permissionless once bootstrapped — the deployer must hold + the script approves
the genesis seed legs):

```bash
MARKET_NAME=<name> TEMPLATE_ADDRESS=<template> forge script script/deploy/templates/royco-day-balancer-v3/DeployMarket.s.sol --rpc-url $RPC_URL --broadcast
```

Market configs live one-per-file under `templates/royco-day-balancer-v3/markets/` as `DayMarketConfig` structs
shaped to mirror the template's own `MarketParams`. The struct shape is template-family-specific by design — a new
template family gets its own folder, market types, and scripts.

**3. Finalize** (the LAST admin-gated step; markets can still be added afterwards — `executeMarketDeployment` is
public and the oracle deployment is unpermissioned):

```bash
forge script script/deploy/core/RenounceDeployerRoles.s.sol --rpc-url $RPC_URL --broadcast
```

## Role distribution

The role graph mirrors the kerchkoffs four-multisig model (canonical spec: the kerchkoffs repo's
`docs/roles/assignments.md`); `script/deploy/config/RoleGraphConfig.sol` is the machine-readable form.

| Multisig | Duty |
|---|---|
| `FNDN` | Super-admin (ADMIN_ROLE at 72h, rarely transacts), unpauser, entry-point fee collection, guardian co-hold, emergency oracle co-hold (immediate) |
| `WAY` | Every parameter-update role, delayed (72h; entry-point config 24h); schedules all delayed ops; holds neither pauser nor guardian |
| `WAY_PAUSE` | Sole pauser, immediate (1-of-4 fast response) |
| `FNDN_VETO` | Guardian co-hold, immediate (1-of-4 fast response) — cancels any WAY-scheduled op |
| `AUTO` | LP-role admin co-hold, immediate (service provider granting LP roles) |

No party can both schedule and cancel: WAY proposes, FNDN/FNDN_VETO veto, WAY_PAUSE pauses, only FNDN unpauses.

## Invariants

- **Addresses are sacred.** Every salt preimage and prediction lives in `utils/RoycoDeterministic.sol` — the single
  source the deploy path, the config registries, and the guard tests all share. `Test_DeterministicAddresses` pins
  the derived addresses; if it trips, you moved every deployment.
- The template's CREATE2 salt hashes its FULL construction params (implementation set, blacklist, venue factories,
  SYSTEM policy) — changing any of them is a deliberate template redeploy.
- The market wiring transaction carries a 16.7M gas stipend, just under the EIP-7825 per-tx cap (16,777,216).
