// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { RoycoFactoryGatekeeper } from "../../../src/factory/RoycoFactoryGatekeeper.sol";
import { ADMIN_ENTRY_POINT_ROLE } from "../../../src/factory/Roles.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IBaseTemplate } from "../../../src/interfaces/factory/IBaseTemplate.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoFactoryGatekeeper } from "../../../src/interfaces/factory/IRoycoFactoryGatekeeper.sol";
import { IRoycoProtocolTemplate } from "../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { MockMarketRegistrationTemplate } from "../../mocks/MockMarketRegistrationTemplate.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { FactoryScaffold } from "../../utils/FactoryScaffold.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_PeripheryConfiguration
 * @notice Always-running (no-RPC) coverage for the periphery configuration a market deployment drives: the template's
 *         post-registration hook calls the factory, the factory forwards into the gatekeeper, and the gatekeeper —
 *         which alone holds `ADMIN_ENTRY_POINT_ROLE` — applies the tranche configs and registers the
 *         kernel, but only for tranches and a kernel that carry no configuration yet
 * @dev Every test drives a SECOND, independent factory/gatekeeper/periphery set over the fixture's market components.
 *      The shared fixture already consumes its one-shot configuration during `_deployEntryPoint`, and the whole point
 *      of the freshness rule is that it cannot be consumed twice, so these need a clean periphery of their own
 */
contract Test_PeripheryConfiguration is EntryPointTestBase {
    RoycoFactory internal freshFactory;
    RoycoFactoryGatekeeper internal freshGatekeeper;
    IRoycoDayEntryPoint internal freshEntryPoint;
    RoycoMarketSyncer internal freshSyncer;
    MockMarketRegistrationTemplate internal freshTemplate;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        _seedMarket(100 * 10 ** uint256(cell.collateralAsset.decimals), 50 * 10 ** uint256(cell.collateralAsset.decimals));
        _deployEntryPoint();

        // A clean factory + gatekeeper + periphery, so each test starts against an unconfigured entry point and syncer
        (freshFactory, freshGatekeeper, freshEntryPoint, freshSyncer) =
            FactoryScaffold.deployFactory(RoycoAccessManager(address(accessManager)), keccak256("PERIPHERY_TEST_FACTORY"));
        accessManager.setTargetFunctionRole(address(freshEntryPoint), _sels(IRoycoDayEntryPoint.modifyTrancheConfigs.selector), ADMIN_ENTRY_POINT_ROLE);
        accessManager.setTargetFunctionRole(address(freshSyncer), _sels(RoycoMarketSyncer.addMarketKernels.selector), ADMIN_ENTRY_POINT_ROLE);

        freshTemplate = new MockMarketRegistrationTemplate(IRoycoFactory(address(freshFactory)));
        freshFactory.registerTemplate(address(freshTemplate));
        freshTemplate.setDeploymentResult(
            IRoycoProtocolTemplate.DeploymentResult({
                seniorTranche: address(seniorTranche),
                juniorTranche: address(juniorTranche),
                liquidityProviderTranche: address(liquidityProviderTranche),
                kernel: address(kernel),
                accountant: address(accountant),
                ydm: address(jtYdm),
                lptYdm: address(lptYdm),
                extras: ""
            })
        );
    }

    /// @dev Builds a TrancheConfig with a marker deposit delay so a test can prove which tranche received which config
    function _markerConfig(uint24 _depositDelay) internal pure returns (IRoycoDayEntryPoint.TrancheConfig memory) {
        return IRoycoDayEntryPoint.TrancheConfig({
            enabled: true,
            depositDelaySeconds: _depositDelay,
            depositExpirySeconds: 0,
            redemptionDelaySeconds: 1 hours,
            redemptionExpirySeconds: 0,
            gateByOracleUpdate: false
        });
    }

    /// @dev Queues the configs and runs a real deployment through the fresh factory, exactly as production does
    function _configureThroughFreshFactory(address[] memory _tranches, IRoycoDayEntryPoint.TrancheConfig[] memory _configs) internal {
        freshTemplate.queueTrancheConfigs(_tranches, _configs);
        freshTemplate.queueKernelRegistrationOnSyncer();
        freshFactory.executeMarketDeployment(address(freshTemplate), "");
    }

    // ---------------------------------------------------------------------
    // The full three-tranche path
    // ---------------------------------------------------------------------

    function test_ConfigureAllThreeTranches_appliesConfigsAndRegistersKernel() public {
        address[] memory tranches = new address[](3);
        (tranches[0], tranches[1], tranches[2]) = (address(seniorTranche), address(juniorTranche), address(liquidityProviderTranche));
        IRoycoDayEntryPoint.TrancheConfig[] memory configs = new IRoycoDayEntryPoint.TrancheConfig[](3);
        (configs[0], configs[1], configs[2]) = (_markerConfig(111), _markerConfig(222), _markerConfig(333));

        assertFalse(freshSyncer.isMarketKernelRegistered(address(kernel)), "kernel must be unregistered before the deployment");
        _configureThroughFreshFactory(tranches, configs);

        // Each present tranche received its own index-aligned config and resolved to the market's kernel
        assertEq(freshEntryPoint.getTrancheConfig(address(seniorTranche)).baseConfig.depositDelaySeconds, 111, "ST config applied");
        assertEq(freshEntryPoint.getTrancheConfig(address(juniorTranche)).baseConfig.depositDelaySeconds, 222, "JT config applied");
        assertEq(freshEntryPoint.getTrancheConfig(address(liquidityProviderTranche)).baseConfig.depositDelaySeconds, 333, "LPT config applied");
        assertEq(freshEntryPoint.getTrancheConfig(address(seniorTranche)).kernel, address(kernel), "ST resolved to the market kernel");
        assertTrue(freshSyncer.isMarketKernelRegistered(address(kernel)), "kernel must be registered after the deployment");
    }

    // ---------------------------------------------------------------------
    // An absent (zero-address) tranche is dropped, its paired config never applied
    // ---------------------------------------------------------------------


    // ---------------------------------------------------------------------
    // Freshness: a deployment configures a tranche and a kernel exactly once
    // ---------------------------------------------------------------------

    /**
     * @notice A market deployment may never re-point a tranche that already carries an entry point configuration.
     *         Tranches are CREATE3-deployed per market, so a repeat here means a `marketId` reuse that would
     *         otherwise silently overwrite a live market's request-lifecycle policy
     */
    function test_RevertIf_TrancheIsAlreadyConfigured() public {
        address[] memory tranches = new address[](1);
        tranches[0] = address(seniorTranche);
        IRoycoDayEntryPoint.TrancheConfig[] memory configs = new IRoycoDayEntryPoint.TrancheConfig[](1);
        configs[0] = _markerConfig(111);
        _configureThroughFreshFactory(tranches, configs);

        freshTemplate.queueTrancheConfigs(tranches, configs);
        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.TRANCHE_ALREADY_CONFIGURED.selector, address(seniorTranche)));
        freshFactory.executeMarketDeployment(address(freshTemplate), "");

        // The first deployment's config survives the rejected second one
        assertEq(freshEntryPoint.getTrancheConfig(address(seniorTranche)).baseConfig.depositDelaySeconds, 111, "the original config must stand");
    }

    /// @notice The same rule covers the syncer: a kernel is registered by exactly one deployment
    function test_RevertIf_KernelIsAlreadyRegistered() public {
        address[] memory tranches = new address[](1);
        tranches[0] = address(seniorTranche);
        IRoycoDayEntryPoint.TrancheConfig[] memory configs = new IRoycoDayEntryPoint.TrancheConfig[](1);
        configs[0] = _markerConfig(111);
        _configureThroughFreshFactory(tranches, configs);

        // Re-run with a tranche that is still fresh, so only the kernel registration can fail
        address[] memory secondTranches = new address[](1);
        secondTranches[0] = address(juniorTranche);
        freshTemplate.queueTrancheConfigs(secondTranches, configs);
        freshTemplate.queueKernelRegistrationOnSyncer();
        vm.expectRevert(abi.encodeWithSelector(IRoycoFactoryGatekeeper.KERNEL_ALREADY_REGISTERED.selector, address(kernel)));
        freshFactory.executeMarketDeployment(address(freshTemplate), "");
    }

    // ---------------------------------------------------------------------
    // Caller gating and constructor validations
    // ---------------------------------------------------------------------

    /// @notice Only the factory may drive the gatekeeper's periphery configuration
    function test_RevertIf_ConfigureMarketPeripheryCalledDirectly() public {
        address[] memory tranches = new address[](1);
        tranches[0] = address(seniorTranche);
        IRoycoDayEntryPoint.TrancheConfig[] memory configs = new IRoycoDayEntryPoint.TrancheConfig[](1);
        configs[0] = _markerConfig(111);

        vm.expectRevert(IRoycoFactoryGatekeeper.ONLY_FACTORY.selector);
        freshGatekeeper.configureMarketPeriphery(tranches, configs, address(kernel));
    }

    /// @notice A template can never be constructed against a zero factory
    function test_RevertIf_TemplateConstructedWithZeroFactory() public {
        vm.expectRevert(IBaseTemplate.ROYCO_FACTORY_CANNOT_BE_ZERO_ADDRESS.selector);
        new MockMarketRegistrationTemplate(IRoycoFactory(address(0)));
    }

    /// @notice A zero periphery address is rejected: the gatekeeper pins live singletons, not placeholders
    function test_RevertIf_GatekeeperConstructedWithZeroEntryPoint() public {
        vm.expectRevert(IRoycoFactoryGatekeeper.NULL_ADDRESS.selector);
        new RoycoFactoryGatekeeper(address(accessManager), address(freshFactory), address(0), address(freshSyncer));
    }

    /// @notice A zero market syncer is rejected for the same reason
    function test_RevertIf_GatekeeperConstructedWithZeroSyncer() public {
        vm.expectRevert(IRoycoFactoryGatekeeper.NULL_ADDRESS.selector);
        new RoycoFactoryGatekeeper(address(accessManager), address(freshFactory), address(freshEntryPoint), address(0));
    }

}
