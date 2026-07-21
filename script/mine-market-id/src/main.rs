//! Mines a Royco Day `marketId` such that the market's senior-tranche CREATE3 proxy address sorts *below* the pool's
//! quote asset. Balancer V3 registers a pool's tokens in ascending address order, so this pins the senior tranche as
//! pool token0 — the deployment path asserts that invariant instead of sorting at runtime.
//!
//! The senior-tranche proxy is deployed by the factory via solady CREATE3, so its address is a pure function of
//! `(factory, salt)` where `salt = keccak256("ROYCO_MARKET_" ++ marketId ++ "ST")`. That makes the search a cheap
//! offline loop: pick a `marketId`, predict the ST address, keep it if it sorts below the quote asset.
//!
//! The derived `marketId` is `keccak256(marketName_utf8 ++ big_endian_u64(nonce))`. The CREATE3 address math matches
//! the on-chain guard in `test/concrete/Factory/Test_MineMarketId.t.sol`, so a value produced here can be cross-checked
//! on-chain (and was verified against `cast`-computed CREATE3 for the snUSD mainnet factory).
//!
//! Usage:
//!   cargo run --release -- \
//!     --factory 0x8a49E091fc78Ec84f8c75DB9508891F3Ea69f29A \
//!     --quote   0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 \
//!     --name    snUSD
//!
//! Paste the printed marketId into `script/config/MarketDeploymentConfig.sol` for the matching factory.

use std::process::exit;
use tiny_keccak::{Hasher, Keccak};

/// solady `CREATE3.PROXY_INITCODE_HASH` (keccak256 of the CREATE3 proxy init code). See lib/solady/src/utils/CREATE3.sol.
const PROXY_INITCODE_HASH: [u8; 32] = [
    0x21, 0xc3, 0x5d, 0xbe, 0x1b, 0x34, 0x4a, 0x24, 0x88, 0xcf, 0x33, 0x21, 0xd6, 0xce, 0x54, 0x2f, 0x8e, 0x9f, 0x30,
    0x55, 0x44, 0xff, 0x09, 0xe4, 0x99, 0x3a, 0x62, 0x31, 0x9a, 0x49, 0x7c, 0x1f,
];

/// The salt-tag for the senior-tranche proxy: Solidity `bytes32("ST")` (left-aligned, zero-padded).
fn st_proxy_tag() -> [u8; 32] {
    let mut tag = [0u8; 32];
    tag[0] = b'S';
    tag[1] = b'T';
    tag
}

fn keccak256(parts: &[&[u8]]) -> [u8; 32] {
    let mut hasher = Keccak::v256();
    for part in parts {
        hasher.update(part);
    }
    let mut out = [0u8; 32];
    hasher.finalize(&mut out);
    out
}

/// `keccak256(abi.encodePacked(bytes(name), uint64(nonce)))` — the marketId derivation the on-chain miners use.
fn market_id(name: &str, nonce: u64) -> [u8; 32] {
    keccak256(&[name.as_bytes(), &nonce.to_be_bytes()])
}

/// The template's per-market component salt: `keccak256("ROYCO_MARKET_" ++ marketId ++ componentTag)`.
fn component_salt(market_id: &[u8; 32], tag: &[u8; 32]) -> [u8; 32] {
    keccak256(&[b"ROYCO_MARKET_", market_id, tag])
}

/// solady CREATE3 deterministic address for `(deployer, salt)`.
///   proxy    = keccak256(0xff ++ deployer ++ salt ++ PROXY_INITCODE_HASH)[12..]
///   deployed = keccak256(0xd6 ++ 0x94 ++ proxy ++ 0x01)[12..]
fn create3_address(deployer: &[u8; 20], salt: &[u8; 32]) -> [u8; 20] {
    let proxy_hash = keccak256(&[&[0xffu8], deployer, salt, &PROXY_INITCODE_HASH]);
    let proxy: [u8; 20] = proxy_hash[12..32].try_into().unwrap();
    let deployed_hash = keccak256(&[&[0xd6u8, 0x94u8], &proxy, &[0x01u8]]);
    deployed_hash[12..32].try_into().unwrap()
}

/// Compares two 20-byte addresses as Solidity does `uint160(a) < uint160(b)` (big-endian byte order).
fn addr_lt(a: &[u8; 20], b: &[u8; 20]) -> bool {
    a.as_slice() < b.as_slice()
}

fn parse_addr(s: &str, flag: &str) -> [u8; 20] {
    let hex = s.strip_prefix("0x").unwrap_or(s);
    if hex.len() != 40 {
        eprintln!("error: {flag} must be a 20-byte hex address, got {s:?}");
        exit(2);
    }
    let mut out = [0u8; 20];
    for i in 0..20 {
        out[i] = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).unwrap_or_else(|_| {
            eprintln!("error: {flag} is not valid hex: {s:?}");
            exit(2);
        });
    }
    out
}

fn hex32(b: &[u8; 32]) -> String {
    let mut s = String::from("0x");
    for byte in b {
        s.push_str(&format!("{byte:02x}"));
    }
    s
}

fn hex20(b: &[u8; 20]) -> String {
    let mut s = String::from("0x");
    for byte in b {
        s.push_str(&format!("{byte:02x}"));
    }
    s
}

fn main() {
    let mut factory: Option<[u8; 20]> = None;
    let mut quote: Option<[u8; 20]> = None;
    let mut name = String::from("snUSD");
    let mut max_nonce: u64 = 10_000_000;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--factory" => factory = Some(parse_addr(&args.next().unwrap_or_default(), "--factory")),
            "--quote" => quote = Some(parse_addr(&args.next().unwrap_or_default(), "--quote")),
            "--name" => name = args.next().unwrap_or_default(),
            "--max-nonce" => max_nonce = args.next().and_then(|v| v.parse().ok()).unwrap_or(max_nonce),
            "-h" | "--help" => {
                eprintln!(
                    "usage: mine-market-id --factory <0x..20b> --quote <0x..20b> [--name <marketName>] [--max-nonce <n>]"
                );
                exit(0);
            }
            other => {
                eprintln!("error: unknown argument {other:?} (see --help)");
                exit(2);
            }
        }
    }

    let factory = factory.unwrap_or_else(|| {
        eprintln!("error: --factory is required (the RoycoFactory proxy address)");
        exit(2);
    });
    let quote = quote.unwrap_or_else(|| {
        eprintln!("error: --quote is required (the pool's quote asset address)");
        exit(2);
    });

    let tag = st_proxy_tag();
    for nonce in 0..max_nonce {
        let id = market_id(&name, nonce);
        let st = create3_address(&factory, &component_salt(&id, &tag));
        if addr_lt(&st, &quote) {
            println!("marketName    {name}");
            println!("factory       {}", hex20(&factory));
            println!("quoteAsset    {}", hex20(&quote));
            println!("nonce         {nonce}");
            println!("marketId      {}", hex32(&id));
            println!("seniorTranche {}  (< quoteAsset, so ST is pool token0)", hex20(&st));
            return;
        }
    }

    eprintln!("error: no marketId placed the senior tranche below the quote asset within {max_nonce} nonces");
    exit(1);
}
