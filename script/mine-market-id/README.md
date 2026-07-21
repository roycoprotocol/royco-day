# mine-market-id

Mines a Royco Day `marketId` whose **senior-tranche CREATE3 proxy address sorts below the pool's quote asset**, so the
senior tranche is registered as pool **token0**.

## Why

Balancer V3 registers a pool's tokens in ascending address order. Rather than branch on that ordering at deploy time,
the deployment path pins the senior tranche as token0 and *asserts* it. That invariant holds only if the market's
senior-tranche proxy address sorts below the quote asset — and that address is a pure function of `(factory, marketId)`
(the proxy is deployed by the factory via solady CREATE3). So we mine a `marketId` that satisfies it, once, offline, and
bake it into the config keyed by factory.

## Usage

```
cargo run --release -- \
  --factory 0x76fF747399Ed12F0B631323d6d4c6E1b66cB7c89 \
  --quote   0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 \
  --name    snUSD
```

- `--factory` — the `RoycoFactory` proxy address the market deploys against (the CREATE3 deployer). Use the factory
  address already recorded in `MarketDeploymentConfig` (`_initializeMinedMarketIds`), or a factory from a deployment.
- `--quote` — the pool's quote asset (e.g. USDC), the address the senior tranche must sort below.
- `--name` — the market name (default `snUSD`); used as the marketId derivation seed.
- `--max-nonce` — search bound (default 10,000,000). Each nonce is a fair ~50/50 coin flip, so a hit is near-immediate.

It prints the `marketId` (and the nonce and predicted senior-tranche address). Paste the `marketId` into
`script/config/MarketDeploymentConfig.sol` for the matching factory.

## Derivation (kept identical to the on-chain miners)

- `marketId = keccak256(abi.encodePacked(bytes(name), uint64(nonce)))`
- `salt = keccak256("ROYCO_MARKET_" ++ marketId ++ bytes32("ST"))`
- `seniorTranche = CREATE3(deployer = factory, salt)` (solady `CREATE3.predictDeterministicAddress`)
- accept when `uint160(seniorTranche) < uint160(quoteAsset)`

The Solidity mirror is `test/concrete/Factory/Test_MineMarketId.t.sol`, which *guards* that the ids baked into
`MarketDeploymentConfig` still place the senior tranche as pool token0. A value produced here is cross-checkable
on-chain — e.g. verified against `cast`-computed CREATE3 for the snUSD mainnet factory.
