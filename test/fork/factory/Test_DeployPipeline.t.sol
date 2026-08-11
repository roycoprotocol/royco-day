// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Vm } from "../../../lib/forge-std/src/Vm.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { BootstrapChainComponent } from "../../../script/deploy/BootstrapChain.s.sol";
import { RenounceDeployerRolesComponent } from "../../../script/deploy/core/RenounceDeployerRoles.s.sol";
import { DayMarketRegistry } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketRegistry.sol";
import { DayMarketConfig } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketTypes.sol";
import { DeployMarketComponent } from "../../../script/deploy/templates/royco-day-balancer-v3/DeployMarket.s.sol";
import { RoycoBlacklist } from "../../../src/auth/RoycoBlacklist.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { ChainDeployment, DeploymentResult, MarketUpstream, TemplatePolicy } from "../../../script/config/DeploymentTypes.sol";

/// @title Test_DeployPipeline
/// @notice END-TO-END guard for the decomposed deployment pipeline: runs the REAL runbook — `BootstrapChainComponent`
///         (core -> periphery -> role graph -> blacklist -> implementations -> template -> YDMs) then
///         `DeployMarketComponent.deployMarket(struct)` then the renounce step — exactly as production would, and
///         asserts the market lands with every component wired. This is the composition the per-component scripts
///         must keep honoring: periphery-before-role-graph and renounce-last live HERE, not in any monolith.
/// @dev Requires a mainnet fork. FAILS (env not found) when `MAINNET_RPC_URL` is unset, instead of silently passing.
contract Test_DeployPipeline is Test {
    uint256 internal constant FORK_BLOCK = 25_400_000;

    /// @dev The local test-harness deployer — its predicted factory is pinned by Test_DeterministicAddresses
    address internal constant LOCAL_HARNESS_FACTORY = 0x7C2329FC234D01bF780d060120b7F0a028B604C6;

    Vm.Wallet internal DEPLOYER;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);
        DEPLOYER = vm.createWallet("DEPLOYER");
        vm.deal(DEPLOYER.addr, 100 ether);
    }

    function test_Runbook_BootstrapThenMarketThenRenounce() external {
        // 1. Bootstrap the chain through the orchestrator (production salts: the whole suite runs the prod config)
        BootstrapChainComponent bootstrap = new BootstrapChainComponent(false, address(0));
        ChainDeployment memory chain = bootstrap.bootstrap(DEPLOYER.privateKey);

        assertEq(chain.factory, LOCAL_HARNESS_FACTORY, "the pipeline must land the factory on the canary-pinned address");
        assertTrue(chain.amExisted == false, "fresh fork: the AccessManager must be newly deployed");
        assertTrue(RoycoFactory(chain.factory).isTemplateEnabled(chain.template), "the template must be registered");

        // 2. Deploy the snUSD market from its struct, exactly as the market script's CLI would
        DayMarketRegistry registry = new DayMarketRegistry();
        DayMarketConfig memory cfg = registry.getDayMarketConfig("snUSD");
        deal(cfg.pool.quoteAsset, DEPLOYER.addr, cfg.poolInitialization.quoteAmount);
        // The blacklist is per-market now: the deployer stands one up and threads it through the market config
        cfg.roycoBlacklist = address(new RoycoBlacklist(DEPLOYER.addr, address(0), new address[](0)));

        DeployMarketComponent market = new DeployMarketComponent(
            MarketUpstream({
                accessManager: chain.accessManager,
                factory: chain.factory,
                entryPoint: chain.entryPoint,
                marketSyncer: chain.marketSyncer,
                template: chain.template
            })
        );
        DeploymentResult memory r = market.deployMarket(cfg, registry.getMarketId("snUSD", chain.factory), DEPLOYER.privateKey);

        assertTrue(address(r.kernel) != address(0) && address(r.seniorTranche) != address(0), "market components must deploy");
        assertEq(r.kernel.collateralAsset(), cfg.collateralAsset, "kernel wired to the config's collateral");
        assertEq(r.kernel.quoteAsset(), cfg.pool.quoteAsset, "kernel wired to the config's quote leg");
        assertEq(r.roycoBlacklist, cfg.roycoBlacklist, "blacklist threaded through");

        // 3. Finalize: the explicit renounce step still works AFTER the market deployment
        RenounceDeployerRolesComponent renounce = new RenounceDeployerRolesComponent(chain.accessManager);
        renounce.execute(address(0xFAC7047ADdd111), !chain.amExisted, DEPLOYER.privateKey);
    }
}
