# Solace Security Review - Royco Day

## Scope

Repo   : https://github.com/roycoprotocol/royco-day

Commit : 9764c9e20c8e8af7df1358f228c4be83b78be97f

Scope  : src/*.sol plus relevant scripts

## Findings Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 8 |
| Informational | 4 |

## Findings

### [L-1] `RoycoDayAccountant::setDustTolerance` has no upper bound

**Triage:** Valid privileged-configuration hardening issue. An authorized operator can set an unreasonable value; this is not an external attack path.

**Description**

`setDustTolerance` stores any `NAV_UNIT` value without a range check. In contrast, the other accountant setters bound coverage, liquidity, fees, and combined yield shares. `withSyncedAccounting` does not constrain dust tolerance because it only compares coverage/liquidity utilization.

Crucially, `stGain > dustTolerance` controls `premiumsPaid` but not the premium calculation itself. An oversized tolerance can pay the JT/LPT premiums while leaving their accumulated time-weighted window and `lastPremiumPaymentTimestamp` unconsumed, allowing that prior window to be included again on a later gain. The value also affects the maximum-deposit/withdrawal calculations, fee gates, and the fixed-term impermanent-loss resolution condition.

**Impact**

An excessive authorized value can cause repeated premium payments for an already accrued window, reduce senior deposit capacity and junior/LPT withdrawal capacity to zero, suppress protocol fees, and erase an outstanding junior impermanent-loss claim on the next sync. Recovery requires another authorized parameter update.

**Recommendation**

Enforce a protocol-defined maximum small enough to cover rounding artifacts without suppressing a meaningful gain or premium-window reset, both at initialization and in `setDustTolerance`.

### [L-2] Disabling fixed term omits `FixedTermEnded`

**Triage:** Valid observability issue only.

**Description**

`setFixedTermDuration(0)` resets `lastMarketState` to `PERPETUAL`, clears junior impermanent loss, and deletes `fixedTermEndTimestamp`. The ordinary accounting-sync transition from `FIXED_TERM` to `PERPETUAL` emits `FixedTermEnded`, but the setter emits only `JuniorTrancheImpermanentLossReset` and `FixedTermDurationUpdated`.

**Impact**

An indexer or monitoring system that derives fixed-term state from `FixedTermEnded` can retain stale state after an authorized duration-zero update. On-chain accounting and execution remain correct.

**Recommendation**

When the duration-zero branch is entered from `FIXED_TERM`, emit `FixedTermEnded` before clearing the end timestamp.

### [L-3] YDM replacement after a failed best-effort sync retroactively applies the new rate

**Triage:** Valid low-severity recovery-path accounting issue. It needs both a failed sync and an authorized YDM replacement.

**Description**

`setJuniorTrancheYDM` and `setLiquidityProviderTrancheYDM` first attempt `syncTrancheAccountingFromAccountant` through `_tryExecute`, then proceed even if that call fails. This behavior is intentional so a sync-bricking YDM can be replaced.

If that best-effort sync fails, the time-weighted premium accumulators, `lastYieldShareAccrualTimestamp`, `lastPremiumPaymentTimestamp`, and NAV checkpoints remain unchanged. On the next successful sync, `_accruePremiumYieldShares` uses the elapsed time since the stale timestamp but calls the newly installed YDM. Consequently, the new yield-share rate is applied to time that preceded its installation. This differs from `setMaxYieldShares`, which deliberately syncs and preserves the already accrued window under the old parameters before changing the cap.

**Impact**

The first successful post-replacement sync can over- or underpay the JT or LPT premium relative to the outgoing model. The effect is bounded by the configured maximum yield shares and the senior gain, but is not reversible after that sync.

**Recommendation**

If the pre-replacement sync fails, reset the affected premium accumulators and timestamps before installing the new YDM, or otherwise settle the old model's accrued period before starting a fresh window under the replacement.

### [L-4] Runtime dependency setters accept nonzero codeless addresses

**Triage:** Valid administrative misconfiguration hardening issue. It has no untrusted attacker path.

**Description**

Several mutable dependency pointers accept a nonzero address without checking `.code.length`:

- `RoycoDayKernel.setRoycoBlacklist` stores the supplied address verbatim. `isBlacklisted` reads revert while decoding empty return data, and the void enforcement overloads revert on Solidity's external-contract existence check.
- `RoycoDayKernel.setSequencerUptimeFeed` validates only the grace period. A codeless nonzero feed makes `latestRoundData()` fail when the kernel prices collateral.
- `RoycoDayAccountant.setJuniorTrancheYDM` and `setLiquidityProviderTrancheYDM` can persist a codeless YDM when initialization data is empty. A later `yieldShare` call then prevents syncing.
- `RoycoBlacklist.setSanctionsList` can store a codeless nonzero sanctions-list address, causing later `isSanctioned` reads to fail.

The deployment validation path already applies the recommended optional-dependency pattern to the initial sequencer uptime feed (`address == address(0) || address.code.length > 0`), so the missing runtime check is inconsistent with the deployment-time policy.

**Impact**

The effects depend on the pointer. A codeless kernel blacklist, or a codeless sanctions list behind a configured `RoycoBlacklist`, reverts every screen, freezing mint, burn, and transfer across all three tranches; it also makes ERC-4626-style maximum views revert rather than report capacity. Codeless sequencer and YDM dependencies break pricing and accounting syncs. The null address remains a deliberately supported way to disable optional blacklist, sanctions, or sequencer checks; this finding concerns nonzero codeless values only.

**Recommendation**

Require `address == address(0) || address.code.length > 0` for optional external dependencies and `ydm.code.length > 0` for YDM replacements.

### [L-5] Factory-upgrade tooling conflates the Factory with the AccessManager

**Triage:** Valid low-severity operational tooling defect.

**Description**

The current deployment architecture deploys `RoycoAccessManager` and `RoycoFactory` as separate contracts. `ParameterUpdateBase` misleadingly calls its AccessManager address `ROYCO_FACTORY`, but an operator can configure that constant with the AccessManager, so this naming error alone does not make every parameter-update batch fail.

The same `UpgradeConfig._factories[chainId]` slot is consumed as the AccessManager by `UpgradeBase` and as the Factory proxy by `UpgradeFactoryModule`; its “Factory (AccessManager)” comment documents this conflation. The AccessManager is the one correct value for every consumer except `UpgradeFactoryModule`, making the Factory-upgrade path unsatisfiable by construction. With the real Factory address, `IAccessManager.expiration()` reverts. With the AccessManager address, `_readImplementation` silently reads zero from its non-proxy implementation slot and deployment of the new `RoycoFactory` implementation reverts because its required gatekeeper constructor argument is omitted. Even if implementation deployment were corrected, the generated `upgradeToAndCall` would target the non-upgradeable AccessManager.

**Impact**

The Factory-upgrade workflow cannot create a usable batch. Recovery is a tooling correction and regenerated Safe transactions; no deployed market funds are directly exposed.

**Recommendation**

Track the Factory and AccessManager separately, send all `IAccessManager` calls to the latter, and make the Factory module read the Factory proxy while constructing its implementation with the live gatekeeper address.

### [L-6] Governance scripts and runbooks use a 48-hour wait for 72-hour roles

**Triage:** Valid low-severity operational tooling defect.

**Description**

The current production role graph assigns a 72-hour execution delay to the root admin membership and to roles including `ADMIN_UPGRADER_ROLE`, `ADMIN_KERNEL_ROLE`, `ADMIN_ACCOUNTANT_ROLE`, `ADMIN_PROTOCOL_FEE_SETTER_ROLE`, `ADMIN_FACTORY_ROLE`, and `ADMIN_MARKET_OPS_ROLE`. In contrast, `ParameterUpdateBase` and `UpgradeBase` simulate only `2 days + 1`, and their runbooks describe a two-day wait.

The scripts therefore simulate and instruct operators to execute roughly one day before the AccessManager will authorize the operation. `ParameterUpdateBase` swallows that execution failure, labels it likely oracle staleness, skips verification, and still writes the Safe JSON. The entry-point updater also assumes the immediate WCE role, while the canonical graph assigns `ADMIN_ENTRY_POINT_ROLE` to WAY with a 24-hour delay.

**Impact**

Safe execute batches generated or submitted after the documented two-day delay revert until the actual delay has elapsed. This delays governance operations but does not affect user balances or accounting.

**Recommendation**

Derive the simulation wait and operator documentation from the canonical deployment `RoleGraphConfig`, or query the live AccessManager role-member delay before generating batches. Route entry-point changes through schedule/execute when its membership delay is nonzero.

### [L-7] Upgrade verification snapshots the beacon instead of its representative proxy

**Triage:** Valid low-severity operational tooling defect.

**Description**

`PreparedUpgrade.beacon` overloads two meanings: a component beacon for market components and the proxy itself for self-upgrading singletons. `UpgradeBase::_executeAndVerifyOne` passes that field to `snapshotState` and `verify`. For beacon-based tranche and accountant upgrades, it is an `UpgradeableBeacon`, not a live tranche or accountant proxy.

The verifier modules snapshot proxy-specific state—for example, `UpgradeTrancheModule` calls `name`, `totalSupply`, `asset`, `kernel`, and `totalAssets`. Those selectors are not implemented by the beacon, so a simulated or executed beacon upgrade reverts before it can be verified. The kernel base module has the same proxy-versus-beacon mismatch.

**Impact**

Simulation reverts before the script writes any Safe JSON, so it cannot produce a tranche or accountant upgrade batch. This can delay a needed implementation rollout until operators correct the tooling; it does not directly alter live market balances.

**Recommendation**

Store a representative initialized proxy separately in `PreparedUpgrade` and pass that proxy—not the beacon—to `snapshotState` and `verify`. Keep the beacon only as the target of `upgradeTo`.

### [L-8] The upgrade batch cannot prepare kernel upgrades

**Triage:** Valid low-severity operational tooling defect.

**Description**

`UpgradeBatch::_pushMarketUpgrades` accepts a `kernelKind` and enqueues it as part of every full-market upgrade. However, `UpgradeKind` contains only `TRANCHE`, `ACCOUNTANT`, and `FACTORY`, and `_moduleFor` has no kernel branch. Although an abstract `UpgradeKernelBaseModule` exists, no concrete kernel module is instantiated or dispatchable by the batch.

There is therefore no valid `kernelKind` a caller can supply. Supplying `ACCOUNTANT` is particularly dangerous because its `abi.encode(marketName)` payload is accepted and silently adds a duplicate accountant upgrade with no kernel upgrade; `TRANCHE` instead reverts while decoding the missing tranche type. The enum's own comment says to add `KERNEL_*` values, confirming the intended but unfinished dispatch path.

**Impact**

The batch system cannot produce or simulate a kernel upgrade, even though the helper advertises a complete market upgrade path. Governance must bypass the workflow and its continuity checks, or first repair the tooling, which can delay an emergency kernel remediation.

**Recommendation**

Add explicit kernel upgrade kinds and concrete modules for each deployed kernel family, instantiate them in `UpgradeBatch`, and cover a full ST/JT/LPT/kernel/accountant upgrade in an end-to-end script test.

### [I-1] Deployment and upgrade scripts read the deployer private key from an environment variable

**Triage:** Valid operational-security finding, not an on-chain protocol vulnerability.

**Description**

The deployment and upgrade scripts read `DEPLOYER_PRIVATE_KEY` through `vm.envUint(...)` and pass the raw value to `vm.startBroadcast(...) ` / `vm.addr(...)`. The pattern appears across core deployment, template deployment, market deployment, bootstrap, role-renouncement, and upgrade scripts.

The example environment file is gitignored and warns against committing a real key, but environment variables and plaintext deployment files still risk exposure through developer machines, CI configuration, process inspection, command history, or logging. During bootstrap, compromise of the deployer key can carry substantial authority before the script renounces bootstrap roles.

**Impact**

This requires an off-chain key-exposure event; it is not exploitable through the deployed contracts. The impact depends on the deployment stage and whether bootstrap privileges have already been renounced.

**Recommendation**

Use Foundry's encrypted keystore or a hardware-/remote-signer workflow for production broadcasts. Avoid storing the key in plaintext environment files and ensure CI secret redaction is enabled.

### [I-2] `getRate` NatSpec misstates the nonzero rate floor

**Triage:** Valid documentation-only finding.

**Description**

The NatSpec above `BalancerV3LiquidityVenue::getRate` says the senior-share rate is floored at `1 WAD`. The implementation and adjacent inline comment correctly floor only a zero rate to `1`, i.e. one wei of the WAD-scaled rate.

**Impact**

The contradictory documentation overstates the rate floor by 18 decimal places and can mislead integrators or reviewers. Runtime behavior is correct.

**Recommendation**

Change the NatSpec to say the rate is floored to `1 wei`.

### [I-3] EntryPoint NatSpec overstates request-time screening and oracle-update gating

**Triage:** Valid documentation-only finding. Unrelated editorial observations from the source report are intentionally excluded.

**Description**

The `requestRedemption` interface documentation says both the caller and the requested receiver are screened at request time. The implementation escrows shares with a transfer from the caller to the EntryPoint, so that transfer screens the caller and the EntryPoint; it does not screen the redemption receiver until execution or cancellation.

The request-validation documentation also describes a collateral-oracle update after queueing as a universal execution requirement. In implementation, that check is conditional on `gateByOracleUpdate`; the canonical market configuration sets that flag to `false`.

**Impact**

Integrators can incorrectly assume a redemption receiver was screened when a request was queued, or incorrectly require an oracle update before attempting an execution on a tranche that has the optional gate disabled. Runtime behavior remains correct.

**Recommendation**

Update the request and validation NatSpec to identify the actual request-time participants and to state that the post-queue oracle-update requirement applies only when `gateByOracleUpdate` is enabled.

### [I-4] `StaticCurveYDM` insufficiently validates curve parameters

**Triage:** Valid informational deployment-time configuration-validation issue. It has no live-market or untrusted-attacker path.

**Description**

`StaticCurveYDM` inherits BaseYDM's family-wide `(0, WAD]` target range but cannot honor its 100% endpoint. `TARGET_UTILIZATION_WAD == WAD` makes the above-target interval zero, so `_computeSlope` divides by zero. For a nonzero interval, a substantial rise over a narrow range can produce a WAD-scaled slope greater than `type(uint64).max`, causing `SafeCast.toUint64` to revert during `initializeYDMForMarket`.

The canonical model deployment uses a 90% target, and no current production market configuration selects `StaticCurveYDM`. The StaticCurve fuzz tests restrict curves to the representable domain. The constructor does not exclude the unusable 100% target, while the initializer relies on `SafeCast` rather than explicitly documenting and validating the slope-representability constraint with a protocol-specific error. Adaptive models deliberately support the inherited 100% endpoint, so the target constraint must remain StaticCurve-specific.

**Impact**

An authorized deployment configuration can create an unusable StaticCurve instance or fail to initialize its market. No corrupt state is stored, and the failure is recoverable by selecting valid parameters or a different YDM implementation.

**Recommendation**

In `StaticCurveYDM`'s constructor, require `TARGET_UTILIZATION_WAD < WAD` without changing BaseYDM's shared range. Additionally, validate each computed slope against `type(uint64).max` with a protocol-specific error before storing it.
