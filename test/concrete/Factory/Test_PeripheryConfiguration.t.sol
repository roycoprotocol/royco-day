// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDayEntryPoint } from "../../../src/entrypoint/RoycoDayEntryPoint.sol";
import { EntryPointConfigurer } from "../../../src/factory/templates/periphery/EntryPointConfigurer.sol";
import { MarketSyncerConfigurer } from "../../../src/factory/templates/periphery/MarketSyncerConfigurer.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IBaseTemplate } from "../../../src/interfaces/factory/IBaseTemplate.sol";
import { IRoycoFactory } from "../../../src/interfaces/factory/IRoycoFactory.sol";
import { MockMarketRegistrationTemplate } from "../../mocks/MockMarketRegistrationTemplate.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_PeripheryConfiguration
 * @notice Always-running (no-RPC) coverage for the periphery-configuration mixins a deployment template drives
 *         through the factory: EntryPointConfigurer (per-tranche entry point configs, including the absent-tranche
 *         skip) and MarketSyncerConfigurer (kernel registration), plus both mixins' constructor validations
 * @dev The fixture's registration template hosts the REAL mixins over the REAL factory, entry point, and market
 *      syncer, and every configuration call rides a real executeMarketDeployment window, so this is the production
 *      periphery path minus only the Balancer-venue market construction the full template needs a fork for
 */
contract Test_PeripheryConfiguration is EntryPointTestBase {
    uint256 internal collateralUnit;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        collateralUnit = 10 ** uint256(cell.collateralAsset.decimals);
        _seedMarket(100 * collateralUnit, 50 * collateralUnit);
        _deployEntryPoint();
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

    // ---------------------------------------------------------------------
    // EntryPointConfigurer + MarketSyncerConfigurer: the full three-tranche path
    // ---------------------------------------------------------------------

    function test_ConfigureAllThreeTranches_appliesConfigsAndRegistersKernel() public {
        address[] memory tranches = new address[](3);
        (tranches[0], tranches[1], tranches[2]) = (address(seniorTranche), address(juniorTranche), address(liquidityProviderTranche));
        IRoycoDayEntryPoint.TrancheConfig[] memory configs = new IRoycoDayEntryPoint.TrancheConfig[](3);
        (configs[0], configs[1], configs[2]) = (_markerConfig(111), _markerConfig(222), _markerConfig(333));

        // The kernel registers on the syncer through the factory-forwarded, SYNC_ROLE-gated call in the same hook
        assertFalse(marketSyncer.isMarketKernelRegistered(address(kernel)), "kernel must be unregistered before the deployment");
        registrationTemplate.queueKernelRegistrationOnSyncer();
        _applyTrancheConfigsThroughFactory(tranches, configs);

        // Each present tranche received its own index-aligned config and resolved to the market's kernel
        assertEq(entryPoint.getTrancheConfig(address(seniorTranche)).baseConfig.depositDelaySeconds, 111, "ST config applied");
        assertEq(entryPoint.getTrancheConfig(address(juniorTranche)).baseConfig.depositDelaySeconds, 222, "JT config applied");
        assertEq(entryPoint.getTrancheConfig(address(liquidityProviderTranche)).baseConfig.depositDelaySeconds, 333, "LPT config applied");
        assertEq(entryPoint.getTrancheConfig(address(seniorTranche)).kernel, address(kernel), "ST resolved to the market kernel");
        assertTrue(marketSyncer.isMarketKernelRegistered(address(kernel)), "kernel must be registered after the deployment");
    }

    // ---------------------------------------------------------------------
    // EntryPointConfigurer: an absent (zero-address) tranche is dropped, its paired config never applied
    // ---------------------------------------------------------------------

    function test_ConfigureSkipsAbsentTranche_pairingPreserved() public {
        // The fixture configured all three tranches with the default deposit delay during _deployEntryPoint
        uint24 defaultDelay = entryPoint.getTrancheConfig(address(juniorTranche)).baseConfig.depositDelaySeconds;
        assertEq(defaultDelay, DEFAULT_DEPOSIT_DELAY, "the junior tranche starts at the fixture's default delay");

        // Present ST and LPT, absent JT (zero address) with a distinct config in its slot
        address[] memory tranches = new address[](3);
        (tranches[0], tranches[1], tranches[2]) = (address(seniorTranche), address(0), address(liquidityProviderTranche));
        IRoycoDayEntryPoint.TrancheConfig[] memory configs = new IRoycoDayEntryPoint.TrancheConfig[](3);
        (configs[0], configs[1], configs[2]) = (_markerConfig(111), _markerConfig(999), _markerConfig(333));

        // The absent tranche is dropped so the entry point never sees a zero address (it would revert NULL_ADDRESS)
        _applyTrancheConfigsThroughFactory(tranches, configs);

        // ST and LPT took their own index-aligned configs, proving the paired config survives the skip
        assertEq(entryPoint.getTrancheConfig(address(seniorTranche)).baseConfig.depositDelaySeconds, 111, "ST took its paired config");
        assertEq(entryPoint.getTrancheConfig(address(liquidityProviderTranche)).baseConfig.depositDelaySeconds, 333, "LPT took its paired config");
        // The skipped slot's config (999) was never applied to the junior tranche, its delay is untouched
        assertEq(
            entryPoint.getTrancheConfig(address(juniorTranche)).baseConfig.depositDelaySeconds, defaultDelay, "the absent tranche's config was never applied"
        );
    }

    // ---------------------------------------------------------------------
    // Mixin constructor validations
    // ---------------------------------------------------------------------

    /// @notice A template can never be constructed against a zero factory, the base rejects it before either mixin runs
    function test_RevertIf_TemplateConstructedWithZeroFactory() public {
        vm.expectRevert(IBaseTemplate.ROYCO_FACTORY_CANNOT_BE_ZERO_ADDRESS.selector);
        new MockMarketRegistrationTemplate(IRoycoFactory(address(0)), address(entryPoint), address(marketSyncer));
    }

    /// @notice A zero entry point is rejected: the mixin pins a live singleton, not a placeholder
    function test_RevertIf_TemplateConstructedWithZeroEntryPoint() public {
        vm.expectRevert(EntryPointConfigurer.ENTRY_POINT_CANNOT_BE_ZERO_ADDRESS.selector);
        new MockMarketRegistrationTemplate(IRoycoFactory(address(entryPointFactory)), address(0), address(marketSyncer));
    }

    /// @notice An entry point bound to a different factory is rejected: its provenance reads would miss every market
    ///         this template's factory registers
    function test_RevertIf_TemplateConstructedWithEntryPointBoundToDifferentFactory() public {
        RoycoDayEntryPoint foreignEntryPoint = new RoycoDayEntryPoint(makeAddr("OTHER_FACTORY"));
        vm.expectRevert(EntryPointConfigurer.ENTRY_POINT_BOUND_TO_DIFFERENT_FACTORY.selector);
        new MockMarketRegistrationTemplate(IRoycoFactory(address(entryPointFactory)), address(foreignEntryPoint), address(marketSyncer));
    }

    /// @notice A zero market syncer is rejected: the mixin pins a live singleton, not a placeholder
    function test_RevertIf_TemplateConstructedWithZeroSyncer() public {
        vm.expectRevert(MarketSyncerConfigurer.SYNCER_CANNOT_BE_ZERO_ADDRESS.selector);
        new MockMarketRegistrationTemplate(IRoycoFactory(address(entryPointFactory)), address(entryPoint), address(0));
    }
}
