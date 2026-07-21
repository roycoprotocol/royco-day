// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ADMIN_PAUSER_ROLE, ADMIN_ROLE, DEPLOYER_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { UninitializedERC1967Proxy } from "../../mocks/UninitializedERC1967Proxy.sol";

/// @notice A trivial implementation with code for a proxy to point at. The hardened ERC1967Proxy rejects EMPTY init
///         data (ERC1967ProxyUninitialized), so proxies are deployed with a non-empty no-op that delegatecalls into
///         this fallback; the impl only needs to be a contract with code.
contract MockProxyImpl {
    function ping() external pure returns (uint256) {
        return 42;
    }

    fallback() external { }
}

/**
 * @title Test_FactoryDeployProxy
 * @notice Always-running (no-RPC) coverage for `RoycoFactory.deployDeterministicProxy` — the DEPLOYER_ROLE-gated CREATE3
 *         ERC1967-proxy primitive callable OUTSIDE a template deployment window: its success path (returned code,
 *         implementation provenance, event), its access-control gate, its salt-reuse revert, and its pause gate.
 */
contract Test_FactoryDeployProxy is Test {
    AccessManager internal am;
    RoycoFactory internal factory;
    MockProxyImpl internal impl;

    /// @notice Mirrors IRoycoFactory.ProxyDeployed for expectEmit
    event ProxyDeployed(address indexed proxy, address indexed implementation, bytes32 salt);

    function setUp() public {
        // This test contract is the AccessManager admin (ADMIN_ROLE).
        am = new AccessManager(address(this));

        // `initialize` requires the factory to already hold ADMIN_ROLE on the AM, so deploy the proxy uninitialized,
        // grant its (now known) address ADMIN_ROLE, then initialize.
        RoycoFactory factoryImpl = new RoycoFactory();
        factory = RoycoFactory(address(new UninitializedERC1967Proxy(address(factoryImpl))));
        am.grantRole(ADMIN_ROLE, address(factory), 0);
        factory.initialize(address(am));

        // This contract drives deployDeterministicProxy (DEPLOYER_ROLE) and pause (ADMIN_PAUSER_ROLE) directly.
        am.grantRole(DEPLOYER_ROLE, address(this), 0);
        am.grantRole(ADMIN_PAUSER_ROLE, address(this), 0);

        // A simple implementation with code for the deployed proxies to point at.
        impl = new MockProxyImpl();
    }

    // ---------------------------------------------------------------------
    // Success: a DEPLOYER_ROLE-holder deploys a proxy outside any template window
    // ---------------------------------------------------------------------

    /// @dev The deployed address matches the CREATE3 prediction and carries proxy code.
    function test_DeployProxy_DeploysProxyWithCodeAtPredictedAddress() public {
        bytes32 salt = keccak256("proxy-with-code");
        address predicted = factory.predictDeterministicAddress(salt);

        address deployed = factory.deployDeterministicProxy(address(impl), bytes("no-op"), salt);

        assertEq(deployed, predicted, "the deployed address must match the CREATE3 prediction");
        assertGt(deployed.code.length, 0, "the deployed proxy must have code");
    }

    /// @dev The deployed proxy delegates to the implementation it was deployed against.
    function test_DeployProxy_ProxyDelegatesToImplementation() public {
        bytes32 salt = keccak256("proxy-delegation");

        address deployed = factory.deployDeterministicProxy(address(impl), bytes("no-op"), salt);

        assertEq(MockProxyImpl(deployed).ping(), 42, "proxy must delegate to its implementation");
    }

    /// @dev The ProxyDeployed event carries the deployed proxy, its implementation, and the salt.
    function test_DeployProxy_EmitsProxyDeployed() public {
        bytes32 salt = keccak256("proxy-event");
        address predicted = factory.predictDeterministicAddress(salt);

        vm.expectEmit(true, true, true, true, address(factory));
        emit ProxyDeployed(predicted, address(impl), salt);
        factory.deployDeterministicProxy(address(impl), bytes("no-op"), salt);
    }

    // ---------------------------------------------------------------------
    // Access control: only DEPLOYER_ROLE may deploy
    // ---------------------------------------------------------------------

    /// @dev A caller without DEPLOYER_ROLE is rejected by the `restricted` gate.
    function test_DeployProxy_RevertIf_CallerNotDeployer() public {
        address stranger = makeAddr("STRANGER");
        bytes32 salt = keccak256("proxy-unauthorized");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        factory.deployDeterministicProxy(address(impl), bytes("no-op"), salt);
    }

    // ---------------------------------------------------------------------
    // Salt reuse: a second deployment at the same salt is rejected
    // ---------------------------------------------------------------------

    /// @dev The CREATE3 address is occupied after the first deployment, so a same-salt redeploy reverts.
    function test_DeployProxy_RevertIf_SaltAlreadyDeployed() public {
        bytes32 salt = keccak256("proxy-salt-reuse");

        address deployed = factory.deployDeterministicProxy(address(impl), bytes("no-op"), salt);

        vm.expectRevert(abi.encodeWithSelector(IRoycoFactory.PROXY_ALREADY_DEPLOYED.selector, deployed, salt));
        factory.deployDeterministicProxy(address(impl), bytes("no-op"), salt);
    }

    // ---------------------------------------------------------------------
    // Pause: deployDeterministicProxy is gated by whenNotPaused
    // ---------------------------------------------------------------------

    /// @dev A paused factory rejects deployDeterministicProxy on the `whenNotPaused` gate.
    function test_DeployProxy_RevertIf_Paused() public {
        factory.pause(); // this == ADMIN_PAUSER_ROLE holder

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.deployDeterministicProxy(address(impl), bytes("no-op"), keccak256("proxy-while-paused"));
    }
}
