// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactoryGatekeeper } from "../../../src/factory/RoycoFactoryGatekeeper.sol";
import { FactoryScaffold } from "../../utils/FactoryScaffold.sol";
import {
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_FACTORY_ROLE,
    ADMIN_ROLE,
    ADMIN_UPGRADER_ROLE,
    BURNER_ROLE,
    DEPLOYER_ROLE,
    SYNC_ROLE
} from "../../../src/factory/Roles.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoFactoryGatekeeper } from "../../../src/interfaces/factory/IRoycoFactoryGatekeeper.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { MockWiringTemplate } from "../../mocks/MockWiringTemplate.sol";
import { UninitializedERC1967Proxy } from "../../mocks/UninitializedERC1967Proxy.sol";

/**
 * @title Test_FactoryDeploymentWiring
 * @notice Always-running (no-RPC) coverage for the factory's active-template role-wiring primitives and its
 *         previously fork-only revert branches: the `onlyActiveTemplate` guard (ONLY_ACTIVE_TEMPLATE), the
 *         `executeAsFactory` failure path (a verbatim-bubbled target revert), and the `executeMarketDeployment` reentrancy
 *         guard (NO_ACTIVE_TEMPLATE). The production template exercises these only on a mainnet fork.
 */
contract Test_FactoryDeploymentWiring is Test {
    RoycoAccessManager internal am;
    RoycoFactoryGatekeeper internal gatekeeper;
    RoycoFactory internal factory;
    MockWiringTemplate internal template;

    bytes4 internal constant WIRE_SELECTOR = 0x12345678;
    address internal WIRE_TARGET;
    address internal WIRE_ACCOUNT;

    function setUp() public {
        WIRE_TARGET = makeAddr("WIRE_TARGET");
        WIRE_ACCOUNT = makeAddr("WIRE_ACCOUNT");
        am = new RoycoAccessManager(address(this));

        // The gatekeeper holds ADMIN_ROLE on the factory's behalf; the scaffold stands both up and wires the
        // factory's own selectors and roles
        (factory, gatekeeper) = FactoryScaffold.deployFactory(am, keccak256("FACTORY_PROXY"));

        am.grantRole(ADMIN_FACTORY_ROLE, address(this), 0);
        am.grantRole(DEPLOYER_ROLE, address(this), 0);

        template = new MockWiringTemplate(IRoycoFactory(address(factory)));
        factory.registerTemplate(address(template));

        // A canned non-zero result so the registry write is clean (avoids the zero-tranche registry skip).
        template.setDeploymentResult(
            IRoycoProtocolTemplate.DeploymentResult({
                seniorTranche: makeAddr("ST"),
                juniorTranche: makeAddr("JT"),
                liquidityProviderTranche: makeAddr("LPT"),
                kernel: makeAddr("KERNEL"),
                accountant: makeAddr("ACCOUNTANT"),
                ydm: makeAddr("YDM"),
                lptYdm: makeAddr("LPTYDM"),
                extras: ""
            })
        );
    }

    // ---------------------------------------------------------------------
    // The factory's standing role set: narrow, and specifically not ADMIN_ROLE
    // ---------------------------------------------------------------------

    /// @dev The factory no longer configures itself during `initialize` (it cannot, having no ADMIN_ROLE): the
    ///      deployment script grants these, which the scaffold mirrors. The periphery configuration hook drives
    ///      modifyTrancheConfigs (ADMIN_ENTRY_POINT_ROLE) and addMarketKernels (SYNC_ROLE) as the factory
    function test_FactoryHoldsEntryPointAndSyncRolesButNotAdmin() public view {
        (bool holdsEntryPointRole,) = am.hasRole(ADMIN_ENTRY_POINT_ROLE, address(factory));
        assertTrue(holdsEntryPointRole, "the factory must hold ADMIN_ENTRY_POINT_ROLE");
        (bool holdsSyncRole,) = am.hasRole(SYNC_ROLE, address(factory));
        assertTrue(holdsSyncRole, "the factory must hold SYNC_ROLE");

        // The containment property: ADMIN_ROLE sits on the gatekeeper, never on the factory
        (bool holdsAdmin,) = am.hasRole(ADMIN_ROLE, address(factory));
        assertFalse(holdsAdmin, "the factory must NOT hold ADMIN_ROLE");
        (bool gatekeeperHoldsAdmin,) = am.hasRole(ADMIN_ROLE, address(gatekeeper));
        assertTrue(gatekeeperHoldsAdmin, "the gatekeeper must hold ADMIN_ROLE instead");
    }

    // ---------------------------------------------------------------------
    // ONLY_ACTIVE_TEMPLATE: the three primitives reject any caller outside an active-template window
    // ---------------------------------------------------------------------

    function test_ONLY_ACTIVE_TEMPLATE_guardsSetTargetFunctionRole() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = WIRE_SELECTOR;
        uint64[] memory roleIds = new uint64[](1);
        roleIds[0] = SYNC_ROLE;
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.setMarketTargetFunctionRole(WIRE_TARGET, selectors, roleIds);
    }

    function test_ONLY_ACTIVE_TEMPLATE_guardsGrantMarketRole() public {
        uint64[] memory roleIds = new uint64[](1);
        roleIds[0] = SYNC_ROLE;
        address[] memory accounts = new address[](1);
        accounts[0] = WIRE_ACCOUNT;
        uint32[] memory delays = new uint32[](1);
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.grantMarketRole(roleIds, accounts, delays);
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
        assertEq(factory.trancheToKernel(makeAddr("LPT")), makeAddr("KERNEL"), "LPT -> kernel registry write");
    }

    // ---------------------------------------------------------------------
    // grantMarketRole: the constant allowlist of roles a deployment may grant
    // ---------------------------------------------------------------------

    /// @notice `BURNER_ROLE` is the second of the two roles a market deployment legitimately grants (to its kernel)
    function test_grantMarketRole_allowsBurnerRole() public {
        template.setMode(template.MODE_WIRE());
        template.setWireConfig(WIRE_TARGET, WIRE_SELECTOR, BURNER_ROLE, WIRE_ACCOUNT);

        factory.executeMarketDeployment(address(template), "");

        (bool member,) = am.hasRole(BURNER_ROLE, WIRE_ACCOUNT);
        assertTrue(member, "the account must have been granted BURNER_ROLE");
    }

    /**
     * @notice Every other role is refused, including ones the factory might otherwise be able to grant
     * @dev The allowlist is a constant on the gatekeeper, which is non-upgradeable, so widening what a deployment can
     *      mint requires deploying a new gatekeeper and moving `ADMIN_ROLE` to it
     */
    function test_RevertIf_grantMarketRoleGrantsAnythingOutsideTheAllowlist() public {
        template.setMode(template.MODE_WIRE());
        template.setWireConfig(WIRE_TARGET, WIRE_SELECTOR, ADMIN_UPGRADER_ROLE, WIRE_ACCOUNT);

        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.ROLE_FORBIDDEN.selector, ADMIN_UPGRADER_ROLE));
        factory.executeMarketDeployment(address(template), "");
    }

    /// @notice Including the access manager's root-admin role, the escalation the allowlist most directly denies
    function test_RevertIf_grantMarketRoleGrantsAdminRole() public {
        template.setMode(template.MODE_WIRE());
        template.setWireConfig(WIRE_TARGET, WIRE_SELECTOR, ADMIN_ROLE, WIRE_ACCOUNT);

        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.ROLE_FORBIDDEN.selector, ADMIN_ROLE));
        factory.executeMarketDeployment(address(template), "");
    }

    // ---------------------------------------------------------------------
    // postMarketRegistration: the active-template window spans the post-registration hook
    // ---------------------------------------------------------------------

    function test_Hook_wiringPrimitivesWorkInpostMarketRegistration_afterRegistryWrite() public {
        template.setMode(template.MODE_WIRE_IN_HOOK());
        template.setWireConfig(WIRE_TARGET, WIRE_SELECTOR, SYNC_ROLE, WIRE_ACCOUNT);

        factory.executeMarketDeployment(address(template), "");

        // The hook ran with the window still open (the primitives succeeded) ...
        assertEq(am.getTargetFunctionRole(WIRE_TARGET, WIRE_SELECTOR), SYNC_ROLE, "the hook must be able to bind selectors through the factory");
        (bool member,) = am.hasRole(SYNC_ROLE, WIRE_ACCOUNT);
        assertTrue(member, "the hook must be able to grant roles through the factory");
        // ... and after the registry write, so hook-phase periphery config can validate tranche provenance.
        assertEq(factory.trancheToKernel(makeAddr("ST")), makeAddr("KERNEL"), "the registry write must precede the hook");

        // The window is closed once executeMarketDeployment returns.
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.executeAsFactory(WIRE_TARGET, hex"deadbeef");
    }

    function test_Hook_directCallRejectedForNonFactoryCaller() public {
        IRoycoProtocolTemplate.DeploymentResult memory result;
        vm.expectRevert(abi.encodeWithSignature("ONLY_ROYCO_FACTORY()"));
        template.postMarketRegistration(result, "");
    }

    function test_Hook_revertUnwindsRegistryWritesAtomically() public {
        template.setMode(template.MODE_EXEC_FAIL_IN_HOOK());
        // The mock's deadbeef target has no fallback, so the dispatch bubbles its empty revert data verbatim
        vm.expectRevert(bytes(""));
        factory.executeMarketDeployment(address(template), "");

        // The registry writes that preceded the failing hook were unwound with the whole deployment.
        assertEq(factory.trancheToKernel(makeAddr("ST")), address(0), "a hook revert must unwind the registry writes");
    }

    // ---------------------------------------------------------------------
    // executeAsFactory failure: a reverting target bubbles its revert data verbatim
    // ---------------------------------------------------------------------

    function test_ExecuteAsFactory_bubblesTargetRevertVerbatim() public {
        template.setMode(template.MODE_EXEC_FAIL());
        // The mock's deadbeef target has no fallback, so the dispatch bubbles its empty revert data verbatim
        vm.expectRevert(bytes(""));
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
