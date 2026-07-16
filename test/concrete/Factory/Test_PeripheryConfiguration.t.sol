// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { EntryPointConfigurer } from "../../../src/factory/templates/periphery/EntryPointConfigurer.sol";
import { MarketSyncerConfigurer } from "../../../src/factory/templates/periphery/MarketSyncerConfigurer.sol";
import { SYNC_ROLE } from "../../../src/factory/RolesConfiguration.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";

/**
 * @title PeripheryConfiguratorHarness
 * @notice A concrete host for the production EntryPointConfigurer + MarketSyncerConfigurer mixins, exposing their
 *         internal helpers so a test can drive the real periphery-configuration code off-fork (the production
 *         template that mixes these in can only be constructed against a live Balancer venue)
 */
contract PeripheryConfiguratorHarness is EntryPointConfigurer, MarketSyncerConfigurer {
    IRoycoFactory internal immutable FACTORY;

    constructor(
        address _entryPoint,
        address _syncer,
        IRoycoFactory _factory
    )
        EntryPointConfigurer(_entryPoint, _factory)
        MarketSyncerConfigurer(_syncer)
    {
        FACTORY = _factory;
    }

    function configureTranches(address[] memory _tranches, IRoycoDayEntryPoint.TrancheConfig[] memory _configs) external {
        _configureEntryPointTrancheConfigs(FACTORY, _tranches, _configs);
    }

    function registerKernel(address _kernel) external {
        _registerMarketKernelOnSyncer(FACTORY, _kernel);
    }
}

/**
 * @title Test_PeripheryConfiguration
 * @notice Always-running (no-RPC) coverage for the periphery-configuration mixins the deployment template drives
 *         through the factory: EntryPointConfigurer (per-tranche entry point configs, including the absent-tranche
 *         skip) and MarketSyncerConfigurer (kernel registration). These are otherwise only exercised on the
 *         RPC-gated fork factory suite, since the production template needs a live Balancer venue to construct
 * @dev The harness stands in for that template, hosting the real mixins over the fixture's real entry point, its
 *      registering MockRoycoFactory (which forwards executeAsFactory like the production factory), and a real
 *      RoycoMarketSyncer wired to the same access manager
 */
contract Test_PeripheryConfiguration is EntryPointTestBase {
    uint256 internal stUnit;

    RoycoMarketSyncer internal syncer;
    PeripheryConfiguratorHarness internal harness;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();

        // Deploy a real market syncer wired to the fixture's access manager, then bind its registration selector to
        // SYNC_ROLE and grant that role to the registering factory, mirroring the production deployment wiring
        RoycoMarketSyncer syncerImpl = new RoycoMarketSyncer();
        syncer = RoycoMarketSyncer(
            address(new ERC1967Proxy(address(syncerImpl), abi.encodeCall(RoycoMarketSyncer.initialize, (address(accessManager), new address[](0)))))
        );
        vm.label(address(syncer), "RoycoMarketSyncer");
        accessManager.setTargetFunctionRole(address(syncer), _sels(RoycoMarketSyncer.addMarketKernels.selector), SYNC_ROLE);
        accessManager.grantRole(SYNC_ROLE, address(entryPointFactory), 0);

        // The harness hosts the real mixins over the fixture's entry point and its registering factory
        harness = new PeripheryConfiguratorHarness(address(entryPoint), address(syncer), IRoycoFactory(address(entryPointFactory)));
    }

    /// @dev Builds a TrancheConfig with a marker deposit delay so a test can prove which tranche received which config
    function _markerConfig(uint24 _depositDelay) internal pure returns (IRoycoDayEntryPoint.TrancheConfig memory) {
        return IRoycoDayEntryPoint.TrancheConfig({ enabled: true, depositDelaySeconds: _depositDelay, redemptionDelaySeconds: 1 hours, oracleClock: address(0) });
    }

    // ---------------------------------------------------------------------
    // EntryPointConfigurer + MarketSyncerConfigurer: the full three-tranche path
    // ---------------------------------------------------------------------

    function test_ConfigureAllThreeTranches_appliesConfigsAndRegistersKernel() public {
        address[] memory tranches = new address[](3);
        (tranches[0], tranches[1], tranches[2]) = (address(seniorTranche), address(juniorTranche), address(liquidityTranche));
        IRoycoDayEntryPoint.TrancheConfig[] memory configs = new IRoycoDayEntryPoint.TrancheConfig[](3);
        (configs[0], configs[1], configs[2]) = (_markerConfig(111), _markerConfig(222), _markerConfig(333));

        harness.configureTranches(tranches, configs);

        // Each present tranche received its own index-aligned config and resolved to the market's kernel
        assertEq(entryPoint.getTrancheConfig(address(seniorTranche)).baseConfig.depositDelaySeconds, 111, "ST config applied");
        assertEq(entryPoint.getTrancheConfig(address(juniorTranche)).baseConfig.depositDelaySeconds, 222, "JT config applied");
        assertEq(entryPoint.getTrancheConfig(address(liquidityTranche)).baseConfig.depositDelaySeconds, 333, "LT config applied");
        assertEq(entryPoint.getTrancheConfig(address(seniorTranche)).kernel, address(kernel), "ST resolved to the market kernel");

        // The kernel registers on the syncer through the factory-forwarded, SYNC_ROLE-gated call
        assertFalse(syncer.isMarketKernelRegistered(address(kernel)), "kernel must be unregistered before the call");
        harness.registerKernel(address(kernel));
        assertTrue(syncer.isMarketKernelRegistered(address(kernel)), "kernel must be registered after the call");
    }

    // ---------------------------------------------------------------------
    // EntryPointConfigurer: an absent (zero-address) tranche is dropped, its paired config never applied
    // ---------------------------------------------------------------------

    function test_ConfigureSkipsAbsentTranche_pairingPreserved() public {
        // The fixture configured all three tranches with the default deposit delay during _deployEntryPoint
        uint24 defaultDelay = entryPoint.getTrancheConfig(address(juniorTranche)).baseConfig.depositDelaySeconds;
        assertEq(defaultDelay, DEFAULT_DEPOSIT_DELAY, "the junior tranche starts at the fixture's default delay");

        // Present ST and LT, absent JT (zero address) with a distinct config in its slot
        address[] memory tranches = new address[](3);
        (tranches[0], tranches[1], tranches[2]) = (address(seniorTranche), address(0), address(liquidityTranche));
        IRoycoDayEntryPoint.TrancheConfig[] memory configs = new IRoycoDayEntryPoint.TrancheConfig[](3);
        (configs[0], configs[1], configs[2]) = (_markerConfig(111), _markerConfig(999), _markerConfig(333));

        // The absent tranche is dropped so the entry point never sees a zero address (it would revert NULL_ADDRESS)
        harness.configureTranches(tranches, configs);

        // ST and LT took their own index-aligned configs, proving the paired config survives the skip
        assertEq(entryPoint.getTrancheConfig(address(seniorTranche)).baseConfig.depositDelaySeconds, 111, "ST took its paired config");
        assertEq(entryPoint.getTrancheConfig(address(liquidityTranche)).baseConfig.depositDelaySeconds, 333, "LT took its paired config");
        // The skipped slot's config (999) was never applied to the junior tranche, its delay is untouched
        assertEq(entryPoint.getTrancheConfig(address(juniorTranche)).baseConfig.depositDelaySeconds, defaultDelay, "the absent tranche's config was never applied");
    }
}
