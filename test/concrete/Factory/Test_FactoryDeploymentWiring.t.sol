// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ADMIN_ROLE, ADMIN_FACTORY_ROLE, DEPLOYER_ROLE, SYNC_ROLE } from "../../../src/factory/RolesConfiguration.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { MockWiringTemplate } from "../../mocks/MockWiringTemplate.sol";
import { UninitializedERC1967Proxy } from "../../mocks/UninitializedERC1967Proxy.sol";

/**
 * @title Test_FactoryDeploymentWiring
 * @notice Always-running (no-RPC) coverage for the factory's active-template role-wiring primitives and its
 *         previously fork-only revert branches: the `onlyActiveTemplate` guard (ONLY_ACTIVE_TEMPLATE), the
 *         `executeAsFactory` failure path (FACTORY_CALL_FAILED), and the `executeMarketDeployment` reentrancy
 *         guard (NO_ACTIVE_TEMPLATE). The production template exercises these only on a mainnet fork.
 */
contract Test_FactoryDeploymentWiring is Test {
    AccessManager internal am;
    RoycoFactory internal factory;
    MockWiringTemplate internal template;

    bytes4 internal constant WIRE_SELECTOR = 0x12345678;
    address internal WIRE_TARGET;
    address internal WIRE_ACCOUNT;

    function setUp() public {
        WIRE_TARGET = makeAddr("WIRE_TARGET");
        WIRE_ACCOUNT = makeAddr("WIRE_ACCOUNT");
        am = new AccessManager(address(this));

        RoycoFactory impl = new RoycoFactory();
        factory = RoycoFactory(address(new UninitializedERC1967Proxy(address(impl))));
        am.grantRole(ADMIN_ROLE, address(factory), 0);
        factory.initialize(address(am));

        am.grantRole(ADMIN_FACTORY_ROLE, address(this), 0);
        am.grantRole(DEPLOYER_ROLE, address(this), 0);

        template = new MockWiringTemplate(IRoycoFactory(address(factory)));
        // Empty init arrays count as initialized, which satisfies registerTemplate's isInitialized gate.
        template.initialize(new bytes32[](0), new bytes[](0));
        factory.registerTemplate(address(template));

        // A canned non-zero result so the registry write is clean (avoids the zero-tranche registry skip).
        template.setDeploymentResult(
            IRoycoProtocolTemplate.DeploymentResult({
                seniorTranche: makeAddr("ST"),
                juniorTranche: makeAddr("JT"),
                liquidityTranche: makeAddr("LT"),
                kernel: makeAddr("KERNEL"),
                accountant: makeAddr("ACCOUNTANT"),
                ydm: makeAddr("YDM"),
                ltYdm: makeAddr("LTYDM"),
                extras: ""
            })
        );
    }

    // ---------------------------------------------------------------------
    // ONLY_ACTIVE_TEMPLATE: the three primitives reject any caller outside an active-template window
    // ---------------------------------------------------------------------

    function test_ONLY_ACTIVE_TEMPLATE_guardsSetTargetFunctionRole() public {
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.setMarketTargetFunctionRole(WIRE_TARGET, WIRE_SELECTOR, SYNC_ROLE);
    }

    function test_ONLY_ACTIVE_TEMPLATE_guardsGrantMarketRole() public {
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.grantMarketRole(SYNC_ROLE, WIRE_ACCOUNT, 0);
    }

    function test_ONLY_ACTIVE_TEMPLATE_guardsExecuteAsFactory() public {
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.executeAsFactory(WIRE_TARGET, hex"deadbeef");
    }

    // ---------------------------------------------------------------------
    // Success: the wiring primitives install the selector->role binding and the grant
    // ---------------------------------------------------------------------

    function test_WiringPrimitives_installBindingAndGrantThroughActiveTemplate() public {
        template.setMode(template.MODE_WIRE());
        template.setWireConfig(WIRE_TARGET, WIRE_SELECTOR, SYNC_ROLE, WIRE_ACCOUNT);

        factory.executeMarketDeployment(address(template), "");

        assertEq(am.getTargetFunctionRole(WIRE_TARGET, WIRE_SELECTOR), SYNC_ROLE, "the selector must be bound to SYNC_ROLE");
        (bool member,) = am.hasRole(SYNC_ROLE, WIRE_ACCOUNT);
        assertTrue(member, "the account must have been granted SYNC_ROLE");

        // The registry write landed for all three tranches.
        assertEq(factory.trancheToKernel(makeAddr("ST")), makeAddr("KERNEL"), "ST -> kernel registry write");
        assertEq(factory.trancheToKernel(makeAddr("LT")), makeAddr("KERNEL"), "LT -> kernel registry write");
    }

    // ---------------------------------------------------------------------
    // FACTORY_CALL_FAILED: a reverting executeAsFactory target bubbles the named error
    // ---------------------------------------------------------------------

    function test_FACTORY_CALL_FAILED_onRevertingExecuteAsFactoryTarget() public {
        template.setMode(template.MODE_EXEC_FAIL());
        vm.expectPartialRevert(IRoycoFactory.FACTORY_CALL_FAILED.selector);
        factory.executeMarketDeployment(address(template), "");
    }

    // ---------------------------------------------------------------------
    // NO_ACTIVE_TEMPLATE: a reentrant executeMarketDeployment trips the singleton guard
    // ---------------------------------------------------------------------

    function test_NO_ACTIVE_TEMPLATE_onReentrantExecuteMarketDeployment() public {
        // The reentrant call must pass the `restricted` (DEPLOYER_ROLE) gate to reach the singleton guard.
        am.grantRole(DEPLOYER_ROLE, address(template), 0);
        template.setMode(template.MODE_REENTER());
        vm.expectRevert(IRoycoFactory.NO_ACTIVE_TEMPLATE.selector);
        factory.executeMarketDeployment(address(template), "");
    }
}
