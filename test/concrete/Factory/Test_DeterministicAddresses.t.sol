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

    // Recaptured 2026-08-10: the factory-proxy salt became the vanity-mined `RoycoDeterministic.FACTORY_PROXY_SALT`
    // (leading-`a` prod factory), which moved every factory prediction and the entry point (its impl embeds the
    // factory). The AccessManager and market syncer derive without the factory, so they did not move.
    // (TEST_SALT_SUFFIX = "_TEST_3243241421")
    address internal constant PROD_FACTORY = 0xaaaaaAAAb6550bdC14C45B40cF37dd29E75691E2;
    address internal constant LOCAL_HARNESS_FACTORY = 0x612D1aa4a6156C7735B1A219BbCEA9417Db8d316;
    address internal constant TEST_ENV_FACTORY = 0x751156E1522D8F1f61A31aA43aE3Dac842B1c688;
    address internal constant PROD_ACCESS_MANAGER = 0xeF31d0A3a178f575380bA2e72494a41A9B44a0F4;
    address internal constant PROD_ENTRY_POINT = 0x74Af69cbB2Aa3aD942AeCa9D42487E6A09a5248d;
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
