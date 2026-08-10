# mine-factory-salt

Vanity-mines the RoycoFactory proxy address: searches `bytes32` salts (the value passed to
`RoycoCreate3Deployer.deploy`) for the one whose CREATE3 factory address starts with the most `a` nibbles
(`0xAAAA...`). Runs **indefinitely** on every core and prints each new best as it is found — stop with Ctrl-C
whenever the best-so-far is good enough.

## Usage

```bash
# 1. The create3 deployer for the target environment (no chain needed — pure CREATE2 math):
C3=$(cast create2 --deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C \
  --salt $(cast keccak "ROYCO_CREATE3_DEPLOYER_PROD") \
  --init-code $(forge inspect src/factory/RoycoCreate3Deployer.sol:RoycoCreate3Deployer bytecode) | tail -1)

# 2. Mine (all cores, runs forever, prints improvements):
cargo run --release -- --create3-deployer $C3 --deployer <the EOA that will run the bootstrap>

# 3. Cross-check any salt's resulting address (also verifies the derivation — the current fixed salt
#    keccak("ROYCO_FACTORY_PROXY_PROD") reproduces the canary-pinned 0xa093c0Eb... factory exactly):
cargo run --release -- --create3-deployer $C3 --deployer <eoa> --check-salt <0x..32 bytes>
```

Expect roughly one extra leading nibble per 16x more work: ~seconds for 6–7 `a`s, ~hours for 9–10, and so on.

## Wiring a mined salt in

The pipeline currently derives the factory-proxy salt from the fixed string
`singletonSalt("ROYCO_FACTORY_PROXY")` (`RoycoDeterministic.predictFactoryProxy` + `DeployCore`). To use a mined
salt, that derivation must be replaced with the mined constant — which **moves the factory and every downstream
address** (periphery predictions, market-id seeds, the `Test_DeterministicAddresses` canaries). Mine first, wire
second, deliberately. The salt is deployer-namespaced on-chain (`keccak256(abi.encode(msg.sender, salt))`), so a
published salt cannot be front-run by another deployer.
