//! Vanity-mines the RoycoFactory proxy address: searches for the `bytes32` salt (the value passed to
//! `RoycoCreate3Deployer.deploy`) that maximizes the number of leading `a` nibbles in the resulting factory address
//! (e.g. `0xAAAA...`). Runs INDEFINITELY on every core, printing each new best as it is found — stop it with Ctrl-C
//! whenever the best-so-far is good enough.
//!
//! Derivation (mirrors `RoycoCreate3Deployer.predict` + solady CREATE3 exactly):
//!   namespacedSalt = keccak256(abi.encode(deployerEOA, salt))          // the deployer-namespaced salt
//!   proxy          = keccak256(0xff ++ create3Deployer ++ namespacedSalt ++ PROXY_INITCODE_HASH)[12..]
//!   factory        = keccak256(0xd6 ++ 0x94 ++ proxy ++ 0x01)[12..]    // RLP of [proxy, nonce 1]
//!
//! NOTE the pipeline currently derives the factory-proxy salt from the fixed string
//! `singletonSalt("ROYCO_FACTORY_PROXY")` (see `RoycoDeterministic.predictFactoryProxy`). To USE a mined salt, that
//! derivation must be swapped for the mined constant — which moves the factory and therefore EVERY downstream
//! prediction, market id, and address canary. Mine first, wire second, deliberately.
//!
//! Usage:
//!   cargo run --release -- \
//!     --create3-deployer 0x<the RoycoCreate3Deployer for the target env> \
//!     --deployer         0x<the EOA that will call deploy>
//!
//! The create3 deployer for an environment can be computed without a chain:
//!   cast create2 --deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C \
//!     --salt $(cast keccak "ROYCO_CREATE3_DEPLOYER_PROD_V1.0.2") \   // suffix = RoycoDeterministic.PROD_SALT_SUFFIX
//!     --init-code $(forge inspect src/factory/RoycoCreate3Deployer.sol:RoycoCreate3Deployer bytecode)

use std::process::exit;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
use tiny_keccak::{Hasher, Keccak};

/// solady `CREATE3.PROXY_INITCODE_HASH` (keccak256 of the CREATE3 proxy init code). See lib/solady/src/utils/CREATE3.sol.
const PROXY_INITCODE_HASH: [u8; 32] = [
    0x21, 0xc3, 0x5d, 0xbe, 0x1b, 0x34, 0x4a, 0x24, 0x88, 0xcf, 0x33, 0x21, 0xd6, 0xce, 0x54, 0x2f, 0x8e, 0x9f, 0x30,
    0x55, 0x44, 0xff, 0x09, 0xe4, 0x99, 0x3a, 0x62, 0x31, 0x9a, 0x49, 0x7c, 0x1f,
];

fn keccak256(parts: &[&[u8]]) -> [u8; 32] {
    let mut hasher = Keccak::v256();
    for part in parts {
        hasher.update(part);
    }
    let mut out = [0u8; 32];
    hasher.finalize(&mut out);
    out
}

/// `keccak256(abi.encode(deployer, salt))` — `RoycoCreate3Deployer._namespacedSalt`. abi.encode left-pads the
/// address to 32 bytes.
fn namespaced_salt(deployer: &[u8; 20], salt: &[u8; 32]) -> [u8; 32] {
    let padding = [0u8; 12];
    keccak256(&[&padding, deployer, salt])
}

/// solady CREATE3 deterministic address for `(create3Deployer, namespacedSalt)`.
fn create3_address(create3_deployer: &[u8; 20], salt: &[u8; 32]) -> [u8; 20] {
    let proxy_hash = keccak256(&[&[0xffu8], create3_deployer, salt, &PROXY_INITCODE_HASH]);
    let proxy: [u8; 20] = proxy_hash[12..32].try_into().unwrap();
    let deployed_hash = keccak256(&[&[0xd6u8, 0x94u8], &proxy, &[0x01u8]]);
    deployed_hash[12..32].try_into().unwrap()
}

/// The number of leading `0xa` nibbles in the address (case-insensitive "A"s at the start of the hex form).
fn leading_a_nibbles(addr: &[u8; 20]) -> u32 {
    let mut count = 0;
    for byte in addr {
        if byte >> 4 != 0xa {
            return count;
        }
        count += 1;
        if byte & 0x0f != 0xa {
            return count;
        }
        count += 1;
    }
    count
}

/// EIP-55 checksummed rendering, so the leading run prints as literal `A`s where the checksum capitalizes.
fn checksummed(addr: &[u8; 20]) -> String {
    let lower: String = addr.iter().map(|b| format!("{b:02x}")).collect();
    let hash = keccak256(&[lower.as_bytes()]);
    let mut out = String::from("0x");
    for (i, ch) in lower.chars().enumerate() {
        let hash_nibble = (hash[i / 2] >> (if i % 2 == 0 { 4 } else { 0 })) & 0x0f;
        if ch.is_ascii_alphabetic() && hash_nibble >= 8 {
            out.push(ch.to_ascii_uppercase());
        } else {
            out.push(ch);
        }
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

fn parse_bytes32(s: &str, flag: &str) -> [u8; 32] {
    let hex = s.strip_prefix("0x").unwrap_or(s);
    if hex.len() != 64 {
        eprintln!("error: {flag} must be a 32-byte hex value, got {s:?}");
        exit(2);
    }
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).unwrap_or_else(|_| {
            eprintln!("error: {flag} is not valid hex: {s:?}");
            exit(2);
        });
    }
    out
}

fn main() {
    let mut create3_deployer: Option<[u8; 20]> = None;
    let mut deployer: Option<[u8; 20]> = None;
    let mut check_salt: Option<[u8; 32]> = None;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--create3-deployer" => {
                create3_deployer = Some(parse_addr(&args.next().unwrap_or_default(), "--create3-deployer"))
            }
            "--deployer" => deployer = Some(parse_addr(&args.next().unwrap_or_default(), "--deployer")),
            "--check-salt" => check_salt = Some(parse_bytes32(&args.next().unwrap_or_default(), "--check-salt")),
            "-h" | "--help" => {
                eprintln!(
                    "usage: mine-factory-salt --create3-deployer <0x..20b> --deployer <0x..20b> [--check-salt <0x..32b>]\n\
                     --check-salt prints the factory address one salt resolves to and exits (derivation cross-check)"
                );
                exit(0);
            }
            other => {
                eprintln!("error: unknown argument {other:?} (see --help)");
                exit(2);
            }
        }
    }

    let create3_deployer = create3_deployer.unwrap_or_else(|| {
        eprintln!("error: --create3-deployer is required (the RoycoCreate3Deployer for the target environment)");
        exit(2);
    });
    let deployer = deployer.unwrap_or_else(|| {
        eprintln!("error: --deployer is required (the EOA that will call RoycoCreate3Deployer.deploy)");
        exit(2);
    });

    if let Some(salt) = check_salt {
        let factory = create3_address(&create3_deployer, &namespaced_salt(&deployer, &salt));
        println!("salt    {}", hex32(&salt));
        println!("factory {}", checksummed(&factory));
        return;
    }

    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
    // A per-run seed keeps restarts exploring fresh salt space instead of retreading the same counters.
    let run_seed = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() as u64;
    eprintln!("mining factory vanity salts on {threads} threads (run seed {run_seed}); Ctrl-C when satisfied");

    static BEST: AtomicU32 = AtomicU32::new(0);
    static TRIED: AtomicU64 = AtomicU64::new(0);
    static PRINT_LOCK: Mutex<()> = Mutex::new(());

    std::thread::scope(|scope| {
        for thread_id in 0..threads as u64 {
            let create3_deployer = &create3_deployer;
            let deployer = &deployer;
            scope.spawn(move || {
                // Disjoint salt space per thread: [run_seed ++ thread_id ++ counter ++ zeros]; the salt's literal
                // bytes are what gets passed to deploy, so no hashing is needed to generate candidates.
                let mut salt = [0u8; 32];
                salt[0..8].copy_from_slice(&run_seed.to_be_bytes());
                salt[8..16].copy_from_slice(&thread_id.to_be_bytes());
                let mut counter: u64 = 0;
                loop {
                    salt[16..24].copy_from_slice(&counter.to_be_bytes());
                    let factory = create3_address(create3_deployer, &namespaced_salt(deployer, &salt));
                    let count = leading_a_nibbles(&factory);
                    if count > BEST.load(Ordering::Relaxed)
                        && count > BEST.fetch_max(count, Ordering::Relaxed)
                    {
                        let _guard = PRINT_LOCK.lock().unwrap();
                        let tried = TRIED.load(Ordering::Relaxed) + counter;
                        println!("[{count:2} leading a] salt {}  factory {}  (~{tried} tried)", hex32(&salt), checksummed(&factory));
                    }
                    counter += 1;
                    if counter % (1 << 22) == 0 {
                        TRIED.fetch_add(1 << 22, Ordering::Relaxed);
                    }
                }
            });
        }
    });
}
