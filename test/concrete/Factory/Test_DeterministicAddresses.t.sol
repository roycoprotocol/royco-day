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

    // Recaptured 2026-08-14: the prod namespace bumped to PROD_SALT_SUFFIX = "_PROD_V1.0.2" (fresh deployments) AND
    // the factory-proxy salt was re-mined to the vanity `RoycoDeterministic.FACTORY_PROXY_SALT` (9-leading-`a` prod
    // factory). The suffix bump moves the AccessManager/create3-deployer/periphery too, so every prod address is fresh.
    // (TEST_SALT_SUFFIX = "_TEST_3243241421")
    address internal constant PROD_FACTORY = 0xaAAaaAAAaE46cA12Bf3810DF8C13c5E8A4400812;
    address internal constant LOCAL_HARNESS_FACTORY = 0xf03E361DEdaC92b2fbA45189FEbeB286b1149aEd;
    address internal constant TEST_ENV_FACTORY = 0x6da9980875dCB6Bd9faBae0D743Ab8b9160F25Dc;
    address internal constant PROD_ACCESS_MANAGER = 0x82EecE4a736db0767370d2DfFdE9BDF6e38AaeB8;
    address internal constant PROD_ENTRY_POINT = 0xaF55a0c251690d9322b5F94b7e50EE895750262c;
    address internal constant PROD_MARKET_SYNCER = 0x387e025306cb1C41fe7AB752D9C04607E03Bb8CE;

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
