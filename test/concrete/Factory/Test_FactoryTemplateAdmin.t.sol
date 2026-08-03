// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Initializable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ADMIN_FACTORY_ROLE, ADMIN_UPGRADER_ROLE, DEPLOYER_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { RoycoFactoryGatekeeper } from "../../../src/factory/RoycoFactoryGatekeeper.sol";
import { RoycoUUPSBase } from "../../../src/base/RoycoUUPSBase.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { MockDeploymentTemplate } from "../../mocks/MockDeploymentTemplate.sol";
import { FactoryScaffold } from "../../utils/FactoryScaffold.sol";

/**
 * @title Test_FactoryTemplateAdmin
 * @notice Always-running (no-RPC) coverage for the factory's construction/initialization validations, the template
 *         registry lifecycle (register/disable/re-register with events and every rejection branch), the deployment
 *         entrypoint's auth + template-enablement gates, the completion event, and the UUPS upgrade gate. The fork
 *         suite exercises the same surface against the real Balancer template, this pins it for standard CI
 */
contract Test_FactoryTemplateAdmin is Test {
    RoycoAccessManager internal am;
    RoycoFactoryGatekeeper internal gatekeeper;
    IRoycoDayEntryPoint internal entryPoint;
    RoycoMarketSyncer internal syncer;
    RoycoFactory internal factory;
    MockDeploymentTemplate internal template;

    address internal FACTORY_ADMIN = makeAddr("FACTORY_ADMIN");
    address internal DEPLOYER = makeAddr("DEPLOYER");
    address internal UPGRADER = makeAddr("UPGRADER");
    address internal STRANGER = makeAddr("STRANGER");

    function setUp() public {
        am = new RoycoAccessManager(address(this));
        (factory, gatekeeper, entryPoint, syncer) = FactoryScaffold.deployFactory(am, keccak256("FACTORY_PROXY"));

        am.grantRole(ADMIN_FACTORY_ROLE, FACTORY_ADMIN, 0);
        am.grantRole(DEPLOYER_ROLE, DEPLOYER, 0);
        am.grantRole(ADMIN_UPGRADER_ROLE, UPGRADER, 0);

        template = new MockDeploymentTemplate(IRoycoFactory(address(factory)));
        template.setDeploymentResult(_result());
    }

    function _result() internal returns (IRoycoProtocolTemplate.DeploymentResult memory) {
        return IRoycoProtocolTemplate.DeploymentResult({
            seniorTranche: makeAddr("ST"),
            juniorTranche: makeAddr("JT"),
            liquidityProviderTranche: makeAddr("LPT"),
            kernel: makeAddr("KERNEL"),
            accountant: makeAddr("ACCOUNTANT"),
            ydm: makeAddr("YDM"),
            lptYdm: makeAddr("LPT_YDM"),
            extras: ""
        });
    }

    function _register() internal {
        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));
    }

    // ---------------------------------------------------------------------
    // Construction + initialization validations
    // ---------------------------------------------------------------------

    /// @notice A factory can never be constructed without a gatekeeper to route its configuration through
    function test_RevertIf_ConstructedWithoutAGatekeeper() public {
        vm.expectRevert(IRoycoFactory.FACTORY_GATEKEEPER_CANNOT_BE_ZERO_ADDRESS.selector);
        new RoycoFactory(address(0));
    }

    /// @notice A zero access manager is rejected at initialization
    function test_RevertIf_InitializedWithZeroAccessManager() public {
        RoycoFactory freshImpl = new RoycoFactory(address(gatekeeper));
        vm.expectRevert(IRoycoFactory.ACCESS_MANAGER_CANNOT_BE_ZERO_ADDRESS.selector);
        new ERC1967Proxy(address(freshImpl), abi.encodeCall(RoycoFactory.initialize, (address(0))));
    }

    /// @notice A codeless access manager is rejected: the factory refuses a dead authority
    function test_RevertIf_InitializedWithCodelessAccessManager() public {
        RoycoFactory freshImpl = new RoycoFactory(address(gatekeeper));
        vm.expectRevert(IRoycoFactory.ACCESS_MANAGER_HAS_NO_CODE.selector);
        new ERC1967Proxy(address(freshImpl), abi.encodeCall(RoycoFactory.initialize, (makeAddr("EOA_AUTHORITY"))));
    }

    /// @notice The gatekeeper must govern the exact access manager the factory initializes against, otherwise the
    ///         factory could never configure anything through it
    function test_RevertIf_InitializedAgainstAnAccessManagerItsGatekeeperDoesNotGovern() public {
        RoycoAccessManager otherAccessManager = new RoycoAccessManager(address(this));
        RoycoFactory freshImpl = new RoycoFactory(address(new RoycoFactoryGatekeeper(address(otherAccessManager), address(factory), address(entryPoint), address(syncer))));
        vm.expectRevert(IRoycoFactory.FACTORY_GATEKEEPER_MISMATCH.selector);
        new ERC1967Proxy(address(freshImpl), abi.encodeCall(RoycoFactory.initialize, (address(am))));
    }

    /// @notice The initializer is single-use
    function test_RevertIf_InitializedTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factory.initialize(address(am));
    }

    /// @notice The initialized factory exposes its authority through both getters
    function test_Initialize_WiresTheAuthority() public view {
        assertEq(factory.authority(), address(am), "authority");
        assertEq(factory.ROYCO_AUTHORITY(), address(am), "ROYCO_AUTHORITY mirror");
        assertEq(factory.ROYCO_FACTORY_GATEKEEPER(), address(gatekeeper), "gatekeeper immutable");
    }

    // ---------------------------------------------------------------------
    // Template registry lifecycle
    // ---------------------------------------------------------------------

    /// @notice Registration enables the template and emits TemplateRegistered
    function test_RegisterTemplate_EnablesTemplateWithEvent() public {
        assertFalse(factory.isTemplateEnabled(address(template)), "a fresh template must start disabled");
        vm.expectEmit(true, false, false, false, address(factory));
        emit IRoycoFactory.TemplateRegistered(address(template));
        _register();
        assertTrue(factory.isTemplateEnabled(address(template)), "registration must enable the template");
    }

    /// @notice The zero address names no template
    function test_RevertIf_ZeroAddressTemplateRegistered() public {
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(IRoycoFactory.TEMPLATE_CANNOT_BE_ZERO_ADDRESS.selector);
        factory.registerTemplate(address(0));
    }

    /// @notice A template cannot be registered twice
    function test_RevertIf_TemplateRegisteredTwice() public {
        _register();
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(IRoycoFactory.TEMPLATE_ALREADY_REGISTERED.selector);
        factory.registerTemplate(address(template));
    }

    /// @notice A template constructed against a different factory is rejected: its primitives would call the wrong
    ///         factory and its window could never open here
    function test_RevertIf_TemplateBoundToDifferentFactoryRegistered() public {
        (RoycoFactory foreignFactory,,,) = FactoryScaffold.deployFactory(am, keccak256("FOREIGN_FACTORY_PROXY"));
        MockDeploymentTemplate foreignTemplate = new MockDeploymentTemplate(IRoycoFactory(address(foreignFactory)));
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(IRoycoFactory.TEMPLATE_BOUND_TO_DIFFERENT_FACTORY.selector);
        factory.registerTemplate(address(foreignTemplate));
    }

    /// @notice Disabling emits TemplateDisabled and is reversible via re-registration
    function test_DisableTemplate_DisablesWithEvent_AndReRegisterWorks() public {
        _register();
        vm.expectEmit(true, false, false, false, address(factory));
        emit IRoycoFactory.TemplateDisabled(address(template));
        vm.prank(FACTORY_ADMIN);
        factory.disableTemplate(address(template));
        assertFalse(factory.isTemplateEnabled(address(template)), "disable must clear the enable flag");

        vm.prank(FACTORY_ADMIN);
        factory.registerTemplate(address(template));
        assertTrue(factory.isTemplateEnabled(address(template)), "a disabled template must be re-registrable");
    }

    /// @notice Only ADMIN_FACTORY_ROLE curates the registry, in both directions
    function test_RevertIf_NonFactoryAdminRegistersOrDisables() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.registerTemplate(address(template));

        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, DEPLOYER));
        factory.disableTemplate(address(template));
    }

    // ---------------------------------------------------------------------
    // Deployment entrypoint gating + completion event
    // ---------------------------------------------------------------------

    /// @notice Only DEPLOYER_ROLE may execute a deployment
    function test_RevertIf_NonDeployerExecutesMarketDeployment() public {
        _register();
        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, FACTORY_ADMIN));
        factory.executeMarketDeployment(address(template), "");
    }

    /// @notice A never-registered template cannot deploy
    function test_RevertIf_DeployingThroughUnregisteredTemplate() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.TEMPLATE_NOT_ENABLED.selector);
        factory.executeMarketDeployment(address(template), "");
    }

    /// @notice A disabled template cannot deploy, disabling takes effect immediately
    function test_RevertIf_DeployingThroughDisabledTemplate() public {
        _register();
        vm.prank(FACTORY_ADMIN);
        factory.disableTemplate(address(template));
        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.TEMPLATE_NOT_ENABLED.selector);
        factory.executeMarketDeployment(address(template), "");
    }

    /// @notice A completed deployment emits MarketDeploymentCompleted carrying (template, deployer) topics
    function test_ExecuteMarketDeployment_EmitsCompletionEvent() public {
        _register();
        vm.expectEmit(true, true, false, false, address(factory));
        emit IRoycoFactory.MarketDeploymentCompleted(address(template), DEPLOYER, _result());
        vm.prank(DEPLOYER);
        factory.executeMarketDeployment(address(template), "");
    }

    /// @notice Unknown tranches resolve to the zero market: the registry never fabricates a mapping
    function test_GetMarket_ZeroForUnknownTranche() public {
        assertEq(factory.trancheToKernel(makeAddr("UNKNOWN")), address(0), "unknown tranche -> zero kernel");
        (address st, address jt, address lt, address kernel, address accountant) = factory.getMarket(makeAddr("UNKNOWN"));
        assertEq(st, address(0), "unknown senior");
        assertEq(jt, address(0), "unknown junior");
        assertEq(lt, address(0), "unknown liquidity");
        assertEq(kernel, address(0), "unknown kernel");
        assertEq(accountant, address(0), "unknown accountant");
    }

    // ---------------------------------------------------------------------
    // UUPS upgrade gate
    // ---------------------------------------------------------------------

    /// @notice Only ADMIN_UPGRADER_ROLE may upgrade the factory proxy
    function test_RevertIf_NonUpgraderUpgradesFactory() public {
        address newImpl = address(new RoycoFactory(address(gatekeeper)));
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        factory.upgradeToAndCall(newImpl, "");
    }

    /// @notice A codeless implementation is rejected even for an authorized upgrader
    function test_RevertIf_UpgradedToCodelessImplementation() public {
        vm.prank(UPGRADER);
        vm.expectRevert(RoycoUUPSBase.INVALID_IMPLEMENTATION.selector);
        factory.upgradeToAndCall(makeAddr("CODELESS_IMPL"), "");
    }

    /// @notice The upgrader can upgrade and the authority survives the implementation swap
    function test_UpgradeToAndCall_SucceedsForUpgrader() public {
        address newImpl = address(new RoycoFactory(address(gatekeeper)));
        vm.prank(UPGRADER);
        factory.upgradeToAndCall(newImpl, "");
        assertEq(factory.authority(), address(am), "authority preserved across the upgrade");
    }
}
