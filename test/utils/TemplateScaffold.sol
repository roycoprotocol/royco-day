// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DayMarketRegistry } from "../../script/deploy/templates/royco-day-balancer-v3/DayMarketRegistry.sol";
import { DeployImplementationsComponent } from "../../script/deploy/templates/royco-day-balancer-v3/DeployImplementations.s.sol";
import { DeployMarketComponent } from "../../script/deploy/templates/royco-day-balancer-v3/DeployMarket.s.sol";
import { DeployTemplateComponent } from "../../script/deploy/templates/royco-day-balancer-v3/DeployTemplate.s.sol";
import { DeployYDMsComponent } from "../../script/deploy/templates/royco-day-balancer-v3/DeployYDMs.s.sol";
import { ImplementationSet, MarketUpstream, TemplateUpstream } from "../../script/config/DeploymentTypes.sol";
import { RoycoAccessManager } from "../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";

/**
 * @title TemplateScaffold
 * @notice Stands up the Day template family for the direct-template fork suites — the suites that hand-build a
 *         factory via `FactoryScaffold` and then drive `executeMarketDeployment` themselves. Composes the REAL
 *         per-component deploy scripts (implementations -> template -> YDM registry -> market param builder) against
 *         the caller's scaffolded factory, replacing the old monolith's `deployTemplateForTest` /
 *         `registerYieldDistributionModelsForTest` / `buildMarketParams` surface.
 * @dev `standUp` does NOT register the YDM models: the caller binds `setYieldDistributionModels` to DEPLOYER_ROLE,
 *      grants that role to `result.ydms`, and calls `result.ydms.registerModels()` — mirroring the auth choreography
 *      these suites assert on. Everything deployed here is CREATE2/CREATE3-idempotent per (chain, factory).
 */
library TemplateScaffold {
    struct Result {
        DayMarketRegistry registry;
        ImplementationSet impls;
        RoycoDayBalancerV3MarketDeploymentTemplate template;
        DeployYDMsComponent ydms;
        DeployMarketComponent market;
    }

    /// @notice Deploys the implementation set + template for `_factory` and returns the family's component handles
    function standUp(RoycoAccessManager _am, RoycoFactory _factory, address _roycoBlacklist) internal returns (Result memory r) {
        r.registry = new DayMarketRegistry();

        DeployImplementationsComponent implsComponent = new DeployImplementationsComponent(false, address(_am));
        r.impls = implsComponent.deployImplementationSet();

        r.template = RoycoDayBalancerV3MarketDeploymentTemplate(deployTemplateFor(_am, _factory, _roycoBlacklist, r.impls));
        r.ydms = new DeployYDMsComponent(address(r.template));

        // The market component here is only the param builder + oracle deployer for these suites — they execute the
        // factory call themselves, so the periphery upstream legs are deliberately unset
        r.market = new DeployMarketComponent(
            MarketUpstream({
                accessManager: address(_am),
                factory: address(_factory),
                entryPoint: address(0),
                marketSyncer: address(0),
                roycoBlacklist: _roycoBlacklist,
                template: address(r.template)
            })
        );
    }

    /// @notice Deploys (or reuses) the family template against `_factory` — the seam for suites standing up a second
    ///         factory (the template's CREATE2 salt hashes its construction params, so each factory gets its own)
    function deployTemplateFor(
        RoycoAccessManager _am,
        RoycoFactory _factory,
        address _roycoBlacklist,
        ImplementationSet memory _impls
    )
        internal
        returns (address template)
    {
        DeployTemplateComponent templateComponent = new DeployTemplateComponent(
            false,
            TemplateUpstream({ accessManager: address(_am), factory: address(_factory), roycoBlacklist: _roycoBlacklist, impls: _impls })
        );
        (template,) = templateComponent.deployTemplate();
    }
}
