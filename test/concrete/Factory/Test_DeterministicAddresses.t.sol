// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { RoycoDeterministic } from "../../../script/deploy/utils/RoycoDeterministic.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";

/// @title Test_DeterministicAddresses
/// @notice ADDRESS CANARY for the deployment-script decomposition: every deterministic address the deploy path
///         derives — the factory proxies per (deployer, environment) and the prod periphery pair — is pinned here as
///         a hardcoded constant captured from the monolithic script BEFORE the split, now asserted against the shared library. Any refactor that changes a
///         salt preimage, a creation-code hash boundary, or a prediction derivation trips this suite instead of
///         silently moving every deployed address.
/// @dev If a trip is INTENTIONAL (a deliberate salt bump or contract change), recapture the constants in one commit
///      that says so. The mined prod snUSD market id in the config registry is a second, independent canary: it is
///      only valid against the prod factory address pinned here.
contract Test_DeterministicAddresses is Test {
    // The deployer EOAs the captured predictions derive from. These live HERE, not in the script configs: the
    // deploy pipeline itself has no dependency on any particular deployer address — every prediction derives from
    // the broadcasting key at run time. The canary pins the historical (deployer -> address) captures only.
    address internal constant DEPLOYER = 0x35518D5E1fD8105FC325c5c171c329c3B10b254c;
    /// @dev The test harness deployer, `vm.createWallet("DEPLOYER")` (private key keccak256("DEPLOYER")).
    address internal constant TEST_HARNESS_DEPLOYER = 0x3A383B39c10856a75B9E3f6eda6fCC8fC3334050;

    // Captured 2026-08-06 from the pre-split monolith (TEST_SALT_SUFFIX = "_TEST_3243241421")
    address internal constant PROD_FACTORY = 0xa093c0EbD81d1350a8bb8cD11d273A38cF45f390;
    address internal constant LOCAL_HARNESS_FACTORY = 0xDed778B5bB6B3a3bA77F93220188d660D711Bf65;
    address internal constant TEST_ENV_FACTORY = 0xD1FC1d1502f4ad42f0E7a508485C04e91a1bF76c;
    address internal constant PROD_ACCESS_MANAGER = 0xeF31d0A3a178f575380bA2e72494a41A9B44a0F4;
    address internal constant PROD_ENTRY_POINT = 0x4E29Cf4C21503D54BA271Dc016d63f2954800B49;
    address internal constant PROD_MARKET_SYNCER = 0x538f9993F8719BfaF3c1bc2351c209b99f2319A2;

    function test_Canary_FactoryPredictionsUnchanged() public view {
        assertEq(RoycoDeterministic.predictFactoryProxy(DEPLOYER, false), PROD_FACTORY, "prod factory prediction drifted");
        assertEq(RoycoDeterministic.predictFactoryProxy(TEST_HARNESS_DEPLOYER, false), LOCAL_HARNESS_FACTORY, "local harness factory prediction drifted");
        assertEq(RoycoDeterministic.predictFactoryProxy(DEPLOYER, true), TEST_ENV_FACTORY, "test-env factory prediction drifted");
    }

    function test_Canary_ProdPeripheryPredictionsUnchanged() public view {
        address am = RoycoDeterministic.create2Address(
            RoycoDeterministic.singletonSalt("ROYCO_ACCESS_MANAGER", false),
            keccak256(abi.encodePacked(type(RoycoAccessManager).creationCode, abi.encode(DEPLOYER)))
        );
        assertEq(am, PROD_ACCESS_MANAGER, "prod AccessManager prediction drifted");
        (address ep, address syncer) = RoycoDeterministic.predictPeripherySingletons(am, PROD_FACTORY, false);
        assertEq(ep, PROD_ENTRY_POINT, "prod entry point prediction drifted");
        assertEq(syncer, PROD_MARKET_SYNCER, "prod market syncer prediction drifted");
    }
}
