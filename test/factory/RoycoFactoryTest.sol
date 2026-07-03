// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Initializable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ADMIN_ENTRY_POINT_ROLE, ADMIN_FACTORY_ROLE, ADMIN_ROLE, ADMIN_UPGRADER_ROLE, DEPLOYER_ROLE } from "../../src/factory/RolesConfiguration.sol";
import { RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { IRoycoFactory } from "../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { CallRecorder, Dummy, MockDeploymentTemplate } from "./mocks/MockDeploymentTemplate.sol";

/// @title RoycoFactoryTest
/// @notice Unit tests for `RoycoFactory` in isolation from any real market recipe, driven by a configurable
///         `MockDeploymentTemplate`. Covers: initialization + role wiring, template registration/disabling,
///         the deployment entrypoint (mapping storage, event emission, verify-revert propagation, reentrancy),
///         the active-template-gated primitives (both in and out of a deployment window), pausability, and the
///         UUPS upgrade gate.
contract RoycoFactoryTest is Test {
    AccessManager internal am;
    RoycoFactory internal factory;
    MockDeploymentTemplate internal template;

    address internal FACTORY_ADMIN = makeAddr("FACTORY_ADMIN");
    address internal DEPLOYER = makeAddr("DEPLOYER");
    address internal UPGRADER = makeAddr("UPGRADER");
    address internal STRANGER = makeAddr("STRANGER");

    // Mirrors of the factory's events, for `vm.expectEmit`.
    event TemplateRegistered(address indexed template);
    event TemplateDisabled(address indexed template);
    event MarketDeploymentStarted(address indexed template, address indexed deployer);
    event MarketDeploymentCompleted(address indexed template, IRoycoProtocolTemplate.DeploymentResult result);

    function setUp() public {
        // This test contract is the AccessManager admin (ADMIN_ROLE).
        am = new AccessManager(address(this));

        // OZ mandates init data in the ERC1967Proxy constructor, and `initialize` requires the factory to
        // already hold ADMIN_ROLE on the AM. So predict the proxy's CREATE address, grant it ADMIN_ROLE, then
        // construct the proxy with real init data (mirrors DeployScript's predicted-factory grant).
        RoycoFactory impl = new RoycoFactory();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        am.grantRole(ADMIN_ROLE, predicted, 0);
        factory = RoycoFactory(address(new ERC1967Proxy(address(impl), abi.encodeCall(RoycoFactory.initialize, (address(am))))));
        require(address(factory) == predicted, "proxy address prediction failed");

        // Grant the factory-facing roles the initialize() call bound to selectors.
        am.grantRole(ADMIN_FACTORY_ROLE, FACTORY_ADMIN, 0);
        am.grantRole(DEPLOYER_ROLE, DEPLOYER, 0);
        am.grantRole(ADMIN_UPGRADER_ROLE, UPGRADER, 0);

        template = new MockDeploymentTemplate(factory);
    }

    // ─── helpers ───

    function _register(address _template) internal {
        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(_template, new bytes32[](0), new bytes[](0));
    }

    function _deploy() internal returns (IRoycoProtocolTemplate.DeploymentResult memory) {
        vm.prank(DEPLOYER);
        return factory.executeMarketDeployment(address(template), "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_initialize_wiresAuthorityAndRoles() external view {
        assertEq(factory.authority(), address(am), "authority");
        assertEq(factory.ROYCO_AUTHORITY(), address(am), "ROYCO_AUTHORITY");

        // Factory holds ADMIN_ENTRY_POINT_ROLE on the AM.
        (bool hasEntryPoint,) = am.hasRole(ADMIN_ENTRY_POINT_ROLE, address(factory));
        assertTrue(hasEntryPoint, "factory should hold ADMIN_ENTRY_POINT_ROLE");

        // Selector→role bindings from initialize().
        assertEq(am.getTargetFunctionRole(address(factory), IRoycoFactory.executeMarketDeployment.selector), DEPLOYER_ROLE, "deploy role");
        assertEq(am.getTargetFunctionRole(address(factory), IRoycoFactory.registerTemplate.selector), ADMIN_FACTORY_ROLE, "register role");
        assertEq(am.getTargetFunctionRole(address(factory), IRoycoFactory.disableTemplate.selector), ADMIN_FACTORY_ROLE, "disable role");
        assertEq(am.getTargetFunctionRole(address(factory), UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE, "upgrade role");
    }

    function test_initialize_revertsOnZeroAccessManager() external {
        // initialize runs inside the proxy constructor, so the construction call reverts.
        RoycoFactory freshImpl = new RoycoFactory();
        vm.expectRevert(IRoycoFactory.ACCESS_MANAGER_CANNOT_BE_ZERO_ADDRESS.selector);
        new ERC1967Proxy(address(freshImpl), abi.encodeCall(RoycoFactory.initialize, (address(0))));
    }

    function test_initialize_revertsWhenAccessManagerHasNoCode() external {
        address eoa = makeAddr("EOA_NO_CODE");
        RoycoFactory freshImpl = new RoycoFactory();
        vm.expectRevert(IRoycoFactory.ACCESS_MANAGER_HAS_NO_CODE.selector);
        new ERC1967Proxy(address(freshImpl), abi.encodeCall(RoycoFactory.initialize, (eoa)));
    }

    function test_initialize_revertsWhenFactoryNotAdminOnAM() external {
        // The proxy's predicted address is never granted ADMIN_ROLE on `am`, so initialize rejects it.
        RoycoFactory freshImpl = new RoycoFactory();
        vm.expectRevert(IRoycoFactory.FACTORY_NOT_ADMIN_ON_ACCESS_MANAGER.selector);
        new ERC1967Proxy(address(freshImpl), abi.encodeCall(RoycoFactory.initialize, (address(am))));
    }

    function test_initialize_revertsOnSecondCall() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factory.initialize(address(am));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // registerTemplate
    // ═══════════════════════════════════════════════════════════════════════════

    function test_registerTemplate_succeeds() external {
        assertFalse(factory.isTemplateEnabled(address(template)), "not enabled pre");

        vm.expectEmit(true, false, false, false, address(factory));
        emit TemplateRegistered(address(template));

        _register(address(template));

        assertTrue(factory.isTemplateEnabled(address(template)), "enabled post");
        assertTrue(template.initialized(), "template.initialize called");
        assertEq(template.initializeCallCount(), 1, "initialize called once");
    }

    function test_registerTemplate_revertsForNonAdmin() external {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.registerTemplate(address(template), new bytes32[](0), new bytes[](0));
    }

    function test_registerTemplate_revertsOnZeroAddress() external {
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(IRoycoFactory.TEMPLATE_CANNOT_BE_ZERO_ADDRESS.selector);
        factory.registerTemplate(address(0), new bytes32[](0), new bytes[](0));
    }

    function test_registerTemplate_revertsOnDoubleRegister() external {
        _register(address(template));
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(IRoycoFactory.TEMPLATE_ALREADY_REGISTERED.selector);
        factory.registerTemplate(address(template), new bytes32[](0), new bytes[](0));
    }

    function test_registerTemplate_revertsForForeignFactory() external {
        // A template bound to a different factory address must be rejected.
        MockDeploymentTemplate foreign = new MockDeploymentTemplate(IRoycoFactory(makeAddr("OTHER_FACTORY")));
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(IRoycoFactory.TEMPLATE_BOUND_TO_DIFFERENT_FACTORY.selector);
        factory.registerTemplate(address(foreign), new bytes32[](0), new bytes[](0));
    }

    function test_registerTemplate_revertsWhenPaused() external {
        factory.pause(); // this == AM admin, pause defaults to ADMIN_ROLE
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.registerTemplate(address(template), new bytes32[](0), new bytes[](0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // disableTemplate
    // ═══════════════════════════════════════════════════════════════════════════

    function test_disableTemplate_succeeds() external {
        _register(address(template));

        vm.expectEmit(true, false, false, false, address(factory));
        emit TemplateDisabled(address(template));

        vm.prank(FACTORY_ADMIN);
        factory.disableTemplate(address(template));

        assertFalse(factory.isTemplateEnabled(address(template)), "disabled");
    }

    function test_disableTemplate_revertsForNonAdmin() external {
        _register(address(template));
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.disableTemplate(address(template));
    }

    function test_disableTemplate_thenDeployReverts() external {
        _register(address(template));
        vm.prank(FACTORY_ADMIN);
        factory.disableTemplate(address(template));

        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.TEMPLATE_NOT_ENABLED.selector);
        factory.executeMarketDeployment(address(template), "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // executeMarketDeployment
    // ═══════════════════════════════════════════════════════════════════════════

    function test_execute_storesMappingsAndEmits() external {
        _register(address(template));

        address senior = makeAddr("SENIOR");
        address junior = makeAddr("JUNIOR");
        address liquidity = makeAddr("LIQUIDITY");
        template.setDeployResult(senior, junior, liquidity);

        // Both lifecycle events fire (do not match the full result struct data; just topics + emitter).
        vm.expectEmit(true, true, false, false, address(factory));
        emit MarketDeploymentStarted(address(template), DEPLOYER);
        vm.expectEmit(true, false, false, false, address(factory));
        emit MarketDeploymentCompleted(address(template), _emptyResult());

        IRoycoProtocolTemplate.DeploymentResult memory result = _deploy();

        assertEq(result.seniorTranche, senior, "result senior");
        assertEq(result.juniorTranche, junior, "result junior");
        assertEq(result.liquidityTranche, liquidity, "result liquidity");

        assertEq(factory.seniorTrancheToJuniorTranche(senior), junior, "s->j mapping");
        assertEq(factory.juniorTrancheToSeniorTranche(junior), senior, "j->s mapping");
    }

    function test_execute_revertsForNonDeployer() external {
        _register(address(template));
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.executeMarketDeployment(address(template), "");
    }

    function test_execute_revertsWhenTemplateNotEnabled() external {
        // Never registered.
        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.TEMPLATE_NOT_ENABLED.selector);
        factory.executeMarketDeployment(address(template), "");
    }

    function test_execute_revertsWhenPaused() external {
        _register(address(template));
        factory.pause();
        vm.prank(DEPLOYER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.executeMarketDeployment(address(template), "");
    }

    function test_execute_propagatesDeployRevert() external {
        _register(address(template));
        template.setRevertOnDeploy(true);
        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoProtocolTemplate.INVALID_PARAMS.selector);
        factory.executeMarketDeployment(address(template), "");
    }

    function test_execute_propagatesVerifyRevertAndRollsBack() external {
        _register(address(template));
        address senior = makeAddr("SENIOR");
        address junior = makeAddr("JUNIOR");
        template.setDeployResult(senior, junior, address(0));
        template.setRevertOnVerify(true);

        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoProtocolTemplate.INVALID_PARAMS.selector);
        factory.executeMarketDeployment(address(template), "");

        // The revert must roll back the mapping writes.
        assertEq(factory.seniorTrancheToJuniorTranche(senior), address(0), "s->j not stored on revert");
        assertEq(factory.juniorTrancheToSeniorTranche(junior), address(0), "j->s not stored on revert");
    }

    function test_execute_clearsActiveTemplate_allowsSequentialDeploys() external {
        _register(address(template));

        template.setDeployResult(makeAddr("S1"), makeAddr("J1"), address(0));
        _deploy();

        // A second deployment succeeding proves the transient active-template binding was cleared.
        template.setDeployResult(makeAddr("S2"), makeAddr("J2"), address(0));
        IRoycoProtocolTemplate.DeploymentResult memory r2 = _deploy();
        assertEq(r2.seniorTranche, makeAddr("S2"), "second deploy senior");
        assertEq(factory.seniorTrancheToJuniorTranche(makeAddr("S2")), makeAddr("J2"), "second mapping");
    }

    function test_execute_reentrancyReverts() external {
        _register(address(template));
        // Give the template DEPLOYER_ROLE so its re-entrant call clears the `restricted` gate and reaches
        // the `_activeTemplate == 0` guard, which must reject the nested deployment.
        am.grantRole(DEPLOYER_ROLE, address(template), 0);
        template.setPrimitive(MockDeploymentTemplate.Primitive.ReenterExecuteMarketDeployment, bytes32(0));

        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.NO_ACTIVE_TEMPLATE.selector);
        factory.executeMarketDeployment(address(template), "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEMPLATE-CALLABLE PRIMITIVES — inside an active deployment window
    // ═══════════════════════════════════════════════════════════════════════════

    function test_primitive_deployContract_duringWindow() external {
        _register(address(template));
        bytes32 salt = keccak256("dummy-salt");
        template.setPrimitive(MockDeploymentTemplate.Primitive.DeployContract, salt);

        _deploy();

        address deployed = template.lastDeployedContract();
        assertEq(deployed, factory.predictDeterministicAddress(salt), "deployed == predicted");
        assertGt(deployed.code.length, 0, "deployed has code");
        assertFalse(template.lastAlreadyDeployed(), "fresh deploy");
    }

    function test_primitive_deployContract_idempotentForSameSalt() external {
        _register(address(template));
        bytes32 salt = keccak256("dup-salt");
        template.setPrimitive(MockDeploymentTemplate.Primitive.DeployContractTwiceSameSalt, salt);

        _deploy();

        assertTrue(template.lastAlreadyDeployed(), "second call reports alreadyDeployed");
        assertEq(template.lastDeployedContract(), factory.predictDeterministicAddress(salt), "stable address");
    }

    function test_primitive_deployProxy_duringWindow() external {
        _register(address(template));
        bytes32 salt = keccak256("proxy-salt");
        template.setPrimitive(MockDeploymentTemplate.Primitive.DeployProxy, salt);

        _deploy();

        address proxy = template.lastDeployedProxy();
        assertEq(proxy, factory.predictDeterministicAddress(salt), "proxy == predicted");
        assertGt(proxy.code.length, 0, "proxy has code");
    }

    function test_primitive_setTargetFunctionRole_duringWindow() external {
        _register(address(template));
        address target = makeAddr("SOME_TARGET");
        bytes4 selector = bytes4(keccak256("someFn()"));
        uint64 someRole = 777;
        template.setPrimitive(MockDeploymentTemplate.Primitive.SetTargetFunctionRole, bytes32(0));
        template.setRoleWiring(target, selector, someRole, address(0));

        _deploy();

        assertEq(am.getTargetFunctionRole(target, selector), someRole, "target function role bound");
    }

    function test_primitive_grantRole_duringWindow() external {
        _register(address(template));
        address account = makeAddr("GRANTEE");
        uint64 someRole = 888;
        template.setPrimitive(MockDeploymentTemplate.Primitive.GrantRole, bytes32(0));
        template.setRoleWiring(address(0), bytes4(0), someRole, account);

        _deploy();

        (bool has,) = am.hasRole(someRole, account);
        assertTrue(has, "role granted to account");
    }

    function test_primitive_executeAsFactory_forwardsAsFactory() external {
        _register(address(template));
        CallRecorder recorder = new CallRecorder();
        template.setPrimitive(MockDeploymentTemplate.Primitive.ExecuteAsFactory, bytes32(0));
        template.setRoleWiring(address(recorder), CallRecorder.ping.selector, 0, address(0));

        _deploy();

        assertEq(recorder.lastCaller(), address(factory), "call arrived as the factory");
        assertEq(recorder.pings(), 1, "recorder pinged once");
        assertEq(abi.decode(template.lastExecuteAsFactoryReturn(), (uint256)), 1, "forwarded return value");
    }

    function test_primitive_executeAsFactory_propagatesFailure() external {
        _register(address(template));
        CallRecorder recorder = new CallRecorder();
        template.setPrimitive(MockDeploymentTemplate.Primitive.ExecuteAsFactory, bytes32(0));
        template.setRoleWiring(address(recorder), CallRecorder.boom.selector, 0, address(0));

        vm.prank(DEPLOYER);
        vm.expectPartialRevert(IRoycoFactory.FACTORY_CALL_FAILED.selector);
        factory.executeMarketDeployment(address(template), "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEMPLATE-CALLABLE PRIMITIVES — rejected outside an active deployment window
    // ═══════════════════════════════════════════════════════════════════════════

    function test_primitives_revertWithoutActiveTemplate() external {
        // Called directly (no deployment in progress): `_activeTemplate == 0`, so every primitive rejects.
        vm.startPrank(STRANGER);

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.deployDeterministicContract(type(Dummy).creationCode, keccak256("x"));

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.deployDeterministicProxy(address(this), "", keccak256("y"));

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.setMarketTargetFunctionRole(address(this), bytes4(0), 0);

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.grantMarketRole(0, address(this), 0);

        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.executeAsFactory(address(this), "");

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GETTERS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getters_zeroForUnknownTranche() external {
        assertEq(factory.seniorTrancheToJuniorTranche(makeAddr("UNKNOWN_S")), address(0), "unknown s->j");
        assertEq(factory.juniorTrancheToSeniorTranche(makeAddr("UNKNOWN_J")), address(0), "unknown j->s");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UPGRADE GATE
    // ═══════════════════════════════════════════════════════════════════════════

    function test_upgrade_revertsForNonUpgrader() external {
        address newImpl = address(new RoycoFactory());
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.upgradeToAndCall(newImpl, "");
    }

    function test_upgrade_succeedsForUpgrader() external {
        address newImpl = address(new RoycoFactory());
        vm.prank(UPGRADER);
        factory.upgradeToAndCall(newImpl, "");
        // Still governed by the same AM after upgrade.
        assertEq(factory.authority(), address(am), "authority preserved");
    }

    // ─── internal ───

    function _emptyResult() internal pure returns (IRoycoProtocolTemplate.DeploymentResult memory r) {
        r; // zero-initialized; only used for event topic matching (data not checked)
    }
}
