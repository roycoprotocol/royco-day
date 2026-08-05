// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDeterministic } from "../utils/RoycoDeterministic.sol";

/**
 * @title EnvConfig
 * @notice The environment layer every deployment script shares: chain ids, the controlling multisig/EOA constants,
 *         and the test-vs-production flag that namespaces every deterministic salt.
 * @dev `isTestEnv` is resolved from env by the CLI entrypoints and flows into component scripts as CONSTRUCTOR DATA
 *      (inside each upstream struct), never as shared storage — that is what guarantees two scripts in one pipeline
 *      can never disagree on the salt namespace.
 */
abstract contract EnvConfig {
    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN IDs
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 internal constant MAINNET = 1;
    uint256 internal constant AVALANCHE = 43_114;
    uint256 internal constant ARBITRUM = 42_161;
    uint256 internal constant BASE = 8453;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONTROLLING MULTISIG / EOA ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    address internal constant EXECUTOR_MULTISIG = 0x84d37A25e46029CE161111420E07cEb78880119e;
    address internal constant ROOT_MULTISIG = 0x7c405bbD131e42af506d14e752f2e59B19D49997;
    address internal constant PROTOCOL_FEE_RECIPIENT = 0x05ea95aE815809D77153Ed3500Ad6d936712b639;

    // ═══════════════════════════════════════════════════════════════════════════
    // ENVIRONMENT (test vs production)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Selects the deployment environment. Production (false) is the DEFAULT, so the whole test suite exercises
    ///      the production config; the CLI entrypoints override it from the IS_TEST_DEPLOYMENT env var. Drives the
    ///      singleton salt suffix and which role holders the role-graph config resolves.
    bool internal isTestEnv;

    /// @dev The single admin every role resolves to for a test deployment. Overridable via the TEST_ADMIN env var.
    address internal testDeploymentAdmin = 0x77777Cc68b333a2256B436D675E8D257699Aa667;

    /// @dev CREATE2 salt for a protocol singleton, suffixed with the environment (via RoycoDeterministic)
    function _singletonSalt(string memory _seed) internal view returns (bytes32) {
        return RoycoDeterministic.singletonSalt(_seed, isTestEnv);
    }
}
