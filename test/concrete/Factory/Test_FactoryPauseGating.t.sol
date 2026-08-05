// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ADMIN_FACTORY_ROLE, ADMIN_PAUSER_ROLE, ADMIN_UNPAUSER_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { RoycoFactoryGatekeeper } from "../../../src/factory/RoycoFactoryGatekeeper.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { MockDeploymentTemplate } from "../../mocks/MockDeploymentTemplate.sol";
import { FactoryScaffold } from "../../utils/FactoryScaffold.sol";

/**
 * @title Test_FactoryPauseGating
 * @notice Pins the factory's pause matrix: which entrypoints an emergency pause freezes (deployments, registration,
 *         and the whenNotPaused-first template primitives), which stay live by design (disableTemplate, so a bad
 *         template can be cut during the emergency, and every read), and who may flip the switch
 * @dev Primitive expectations follow each function's declared modifier ORDER: deployDeterministicProxyFromTemplate
 *      checks onlyActiveTemplate before whenNotPaused, the other three primitives check whenNotPaused first
 */
contract Test_FactoryPauseGating is Test {
    RoycoAccessManager internal am;
    RoycoFactoryGatekeeper internal gatekeeper;
    RoycoFactory internal factory;
    MockDeploymentTemplate internal template;

    address internal DEPLOYER = makeAddr("DEPLOYER");
    address internal STRANGER = makeAddr("STRANGER");

    function setUp() public {
        am = new RoycoAccessManager(address(this));
        (factory, gatekeeper,,) = FactoryScaffold.deployFactory(am, keccak256("FACTORY_PROXY"));

        am.grantRole(ADMIN_FACTORY_ROLE, address(this), 0);
        am.grantRole(ADMIN_PAUSER_ROLE, address(this), 0);
        am.grantRole(ADMIN_UNPAUSER_ROLE, address(this), 0);

        template = new MockDeploymentTemplate(IRoycoFactory(address(factory)));
        factory.registerTemplate(address(template));
        template.setDeploymentResult(
            IRoycoProtocolTemplate.DeploymentResult({
                seniorTranche: makeAddr("ST"),
                juniorTranche: makeAddr("JT"),
                liquidityProviderTranche: makeAddr("LPT"),
                kernel: makeAddr("KERNEL"),
                accountant: makeAddr("ACCOUNTANT"),
                ydm: makeAddr("YDM"),
                lptYdm: makeAddr("LPT_YDM"),
                extras: ""
            })
        );
    }

    function _pause() internal {
        IRoycoAuth(address(factory)).pause();
    }

    /// @notice A paused factory deploys nothing: the deployment entrypoint is frozen before any template runs
    function test_RevertIf_MarketDeploymentExecutedWhilePaused() public {
        _pause();
        vm.prank(DEPLOYER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.executeMarketDeployment(address(template), "");
    }

    /// @notice A paused factory admits no new templates
    function test_RevertIf_TemplateRegisteredWhilePaused() public {
        MockDeploymentTemplate freshTemplate = new MockDeploymentTemplate(IRoycoFactory(address(factory)));
        _pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.registerTemplate(address(freshTemplate));
    }

    /// @notice The three whenNotPaused-first primitives freeze with the factory, so a pause also closes the wiring
    ///         surface a hypothetical in-flight window would use
    function test_PausedPrimitives_RejectWithEnforcedPauseWhereWhenNotPausedIsFirst() public {
        _pause();

        bytes4[] memory selectors = new bytes4[](1);
        uint64[] memory roleIds = new uint64[](1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.setMarketTargetFunctionRole(makeAddr("TARGET"), selectors, roleIds);

        address[] memory tranches = new address[](1);
        IRoycoDayEntryPoint.TrancheConfig[] memory configs = new IRoycoDayEntryPoint.TrancheConfig[](1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.configureMarketPeriphery(tranches, configs, makeAddr("KERNEL"));

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.executeAsFactory(makeAddr("TARGET"), "");
    }

    /// @notice deployDeterministicProxyFromTemplate declares onlyActiveTemplate BEFORE whenNotPaused, so outside a
    ///         window the caller check fires first even while paused
    function test_PausedProxyPrimitive_RejectsOnTheCallerCheckFirst() public {
        _pause();
        vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
        factory.deployDeterministicProxyFromTemplate(makeAddr("BEACON"), "", keccak256("SALT"));
    }

    /// @notice disableTemplate deliberately carries no pause gate: an emergency pause must still allow cutting a bad
    ///         template out of the registry
    function test_DisableTemplate_WorksWhilePaused() public {
        _pause();
        factory.disableTemplate(address(template));
        assertFalse(factory.isTemplateEnabled(address(template)), "the template must be disabled during the pause");
    }

    /// @notice Reads stay live during a pause
    function test_Views_StayLiveWhilePaused() public {
        _pause();
        assertEq(factory.marketDeployer(), address(0), "marketDeployer must stay readable");
        assertEq(factory.trancheToKernel(makeAddr("ANY")), address(0), "trancheToKernel must stay readable");
        assertTrue(factory.isTemplateEnabled(address(template)), "isTemplateEnabled must stay readable");
    }

    /// @notice Unpausing restores the deployment entrypoint
    function test_Unpause_RestoresDeployments() public {
        _pause();
        IRoycoAuth(address(factory)).unpause();
        vm.prank(DEPLOYER);
        factory.executeMarketDeployment(address(template), "");
        assertEq(factory.trancheToKernel(makeAddr("ST")), makeAddr("KERNEL"), "the post-unpause deployment must register the market");
    }

    /// @notice Only the pauser and unpauser roles may flip the switch
    function test_RevertIf_StrangerPausesOrUnpauses() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        IRoycoAuth(address(factory)).pause();

        _pause();
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        IRoycoAuth(address(factory)).unpause();
    }
}
