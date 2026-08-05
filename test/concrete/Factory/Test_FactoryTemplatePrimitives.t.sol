// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { UpgradeableBeacon } from "../../../lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { ADMIN_FACTORY_ROLE, BURNER_ROLE, DEPLOYER_ROLE, SYNC_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { RoycoFactoryGatekeeper } from "../../../src/factory/RoycoFactoryGatekeeper.sol";
import { BaseDeploymentTemplate } from "../../../src/factory/templates/base/BaseDeploymentTemplate.sol";
import { IBaseTemplate } from "../../../src/interfaces/factory/IBaseTemplate.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { MockPrimitivesProbeTemplate } from "../../mocks/MockPrimitivesProbeTemplate.sol";
import { FactoryScaffold } from "../../utils/FactoryScaffold.sol";

/**
 * @title Test_FactoryTemplatePrimitives
 * @notice Drives the factory's template-callable primitives from INSIDE a real active-template window: CREATE3 proxy
 *         deployment (raw primitive and the base template's freshness-guarded helper), the base template's
 *         `_applyRoleBindings` batching loop, `executeAsFactory`'s forbidden-target rule, and the rejection of a
 *         registered-but-not-active peer template inside another template's window
 */
contract Test_FactoryTemplatePrimitives is Test {
    RoycoAccessManager internal am;
    RoycoFactoryGatekeeper internal gatekeeper;
    RoycoFactory internal factory;
    MockPrimitivesProbeTemplate internal probeTemplate;
    MockPrimitivesProbeTemplate internal peerTemplate;
    UpgradeableBeacon internal beacon;

    address internal DEPLOYER = makeAddr("DEPLOYER");

    function setUp() public {
        am = new RoycoAccessManager(address(this));
        (factory, gatekeeper,,) = FactoryScaffold.deployFactory(am, keccak256("FACTORY_PROXY"));

        am.grantRole(ADMIN_FACTORY_ROLE, address(this), 0);
        am.grantRole(DEPLOYER_ROLE, DEPLOYER, 0);

        probeTemplate = new MockPrimitivesProbeTemplate(IRoycoFactory(address(factory)));
        peerTemplate = new MockPrimitivesProbeTemplate(IRoycoFactory(address(factory)));
        factory.registerTemplate(address(probeTemplate));
        factory.registerTemplate(address(peerTemplate));
        probeTemplate.setDeploymentResult(_result());
        probeTemplate.setPeer(peerTemplate);

        // A real beacon over a trivial implementation, so deployed beacon proxies are live contracts
        beacon = new UpgradeableBeacon(address(new MockERC20C("Impl", "IMPL", 18)), address(this));
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

    function _deploy() internal {
        vm.prank(DEPLOYER);
        factory.executeMarketDeployment(address(probeTemplate), "");
    }

    // ---------------------------------------------------------------------
    // deployDeterministicProxyFromTemplate + the base template's _deployProxy helper
    // ---------------------------------------------------------------------

    /// @notice A proxy deployed inside the window lands exactly on the factory's predicted CREATE3 address
    function test_DeployProxy_LandsOnThePredictedCreate3Address() public {
        bytes32 componentSalt = keccak256("COMPONENT_SALT");
        address predicted = factory.predictDeterministicAddress(componentSalt);
        assertEq(predicted.code.length, 0, "the predicted address must start empty");

        probeTemplate.setAction(MockPrimitivesProbeTemplate.ProbeAction.DEPLOY_PROXY);
        probeTemplate.setProxyConfig(address(beacon), componentSalt);
        _deploy();

        assertEq(probeTemplate.lastDeployedProxy(), predicted, "the deployed proxy must occupy the predicted address");
        assertGt(predicted.code.length, 0, "the proxy must be a live contract");
    }

    /// @notice The raw primitive reports an existing proxy as (address, alreadyDeployed) instead of reverting, so a
    ///         template can decide the collision policy itself
    function test_DeployProxy_RawPrimitiveReportsAnExistingProxy() public {
        bytes32 componentSalt = keccak256("DIRECT_TWICE_SALT");
        probeTemplate.setAction(MockPrimitivesProbeTemplate.ProbeAction.DEPLOY_PROXY_DIRECT_TWICE);
        probeTemplate.setProxyConfig(address(beacon), componentSalt);
        _deploy();

        assertEq(probeTemplate.lastDeployedProxy(), factory.predictDeterministicAddress(componentSalt), "the second call must resolve the same address");
        assertTrue(probeTemplate.lastAlreadyDeployed(), "the second call must report the proxy as already deployed");
    }

    /// @notice The base template's helper enforces freshness: a second deployment under the same salt reverts, every
    ///         market proxy must be a fresh contract
    function test_RevertIf_DeployProxyHelperHitsAnOccupiedSalt() public {
        probeTemplate.setAction(MockPrimitivesProbeTemplate.ProbeAction.DEPLOY_PROXY_HELPER_TWICE);
        probeTemplate.setProxyConfig(address(beacon), keccak256("HELPER_TWICE_SALT"));
        vm.prank(DEPLOYER);
        vm.expectPartialRevert(BaseDeploymentTemplate.MARKET_COMPONENT_ALREADY_DEPLOYED.selector);
        factory.executeMarketDeployment(address(probeTemplate), "");
    }

    // ---------------------------------------------------------------------
    // _applyRoleBindings: the declarative batching loop over the factory's role primitives
    // ---------------------------------------------------------------------

    /// @notice One bindings array applies every per-target selector binding in one deployment, and an empty-selector
    ///         target is skipped without being configured
    function test_ApplyRoleBindings_BatchesBindings_SkippingEmptyTargets() public {
        address boundTarget = makeAddr("BOUND_TARGET");
        address skippedTarget = makeAddr("SKIPPED_TARGET");

        BaseDeploymentTemplate.TargetBinding[] memory bindings = new BaseDeploymentTemplate.TargetBinding[](2);
        bytes4[] memory selectors = new bytes4[](2);
        (selectors[0], selectors[1]) = (bytes4(0xaaaaaaaa), bytes4(0xbbbbbbbb));
        uint64[] memory roleIds = new uint64[](2);
        (roleIds[0], roleIds[1]) = (SYNC_ROLE, BURNER_ROLE);
        bindings[0] = BaseDeploymentTemplate.TargetBinding({ target: boundTarget, selectors: selectors, roleIds: roleIds });
        bindings[1] = BaseDeploymentTemplate.TargetBinding({ target: skippedTarget, selectors: new bytes4[](0), roleIds: new uint64[](0) });

        probeTemplate.setAction(MockPrimitivesProbeTemplate.ProbeAction.APPLY_ROLE_BINDINGS);
        probeTemplate.setEncodedRoleBindings(abi.encode(bindings));
        _deploy();

        assertEq(am.getTargetFunctionRole(boundTarget, bytes4(0xaaaaaaaa)), SYNC_ROLE, "the first selector must be bound");
        assertEq(am.getTargetFunctionRole(boundTarget, bytes4(0xbbbbbbbb)), BURNER_ROLE, "the second selector must be bound");
        assertTrue(am.wasEverConfigured(boundTarget), "the bound target must be recorded as configured");
        assertFalse(am.wasEverConfigured(skippedTarget), "an empty-selector target must be skipped entirely");
    }

    /// @notice A binding whose selector and role arrays disagree is rejected before any call reaches the factory
    function test_RevertIf_ApplyRoleBindingsSelectorAndRoleArraysDiffer() public {
        BaseDeploymentTemplate.TargetBinding[] memory bindings = new BaseDeploymentTemplate.TargetBinding[](1);
        bindings[0] = BaseDeploymentTemplate.TargetBinding({ target: makeAddr("TARGET"), selectors: new bytes4[](2), roleIds: new uint64[](1) });

        probeTemplate.setAction(MockPrimitivesProbeTemplate.ProbeAction.APPLY_ROLE_BINDINGS);
        probeTemplate.setEncodedRoleBindings(abi.encode(bindings));
        vm.prank(DEPLOYER);
        vm.expectRevert(IBaseTemplate.LENGTH_MISMATCH.selector);
        factory.executeMarketDeployment(address(probeTemplate), "");
    }

    // ---------------------------------------------------------------------
    // executeAsFactory: the forbidden-target rule inside a live window
    // ---------------------------------------------------------------------

    /// @notice Even the active template cannot point executeAsFactory at the access manager: an arbitrary call as the
    ///         factory into the authority would be a direct escalation surface
    function test_RevertIf_ActiveTemplateTargetsTheAccessManager() public {
        probeTemplate.setAction(MockPrimitivesProbeTemplate.ProbeAction.EXEC_AS_FACTORY);
        probeTemplate.setExecConfig(address(am), "");
        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.FACTORY_CALL_TARGET_FORBIDDEN.selector);
        factory.executeMarketDeployment(address(probeTemplate), "");
    }

    /// @notice Nor at the gatekeeper, which holds ADMIN_ROLE and is therefore the authority in blast-radius terms
    function test_RevertIf_ActiveTemplateTargetsTheGatekeeper() public {
        probeTemplate.setAction(MockPrimitivesProbeTemplate.ProbeAction.EXEC_AS_FACTORY);
        probeTemplate.setExecConfig(address(gatekeeper), "");
        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.FACTORY_CALL_TARGET_FORBIDDEN.selector);
        factory.executeMarketDeployment(address(probeTemplate), "");
    }

    // ---------------------------------------------------------------------
    // The window binds ONE template: a registered peer is rejected inside another template's window
    // ---------------------------------------------------------------------

    /// @notice Registration is not activation: a registered peer template calling a primitive during ANOTHER
    ///         template's window is rejected, the window authorizes exactly the template being deployed through
    function test_RevertIf_RegisteredPeerTemplateCallsPrimitivesDuringAnotherTemplatesWindow() public {
        probeTemplate.setAction(MockPrimitivesProbeTemplate.ProbeAction.CALL_PEER);
        probeTemplate.setExecConfig(makeAddr("ANY_TARGET"), "");
        vm.prank(DEPLOYER);
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.executeMarketDeployment(address(probeTemplate), "");
    }
}
