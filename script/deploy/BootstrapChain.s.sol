// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ChainDeployment, CoreDeployment, ImplementationSet, PeripheryUpstream, TemplateUpstream } from "../config/DeploymentTypes.sol";
import { RoleGraphConfig } from "./config/RoleGraphConfig.sol";
import { TemplateConfig } from "./config/TemplateConfig.sol";
import { ApplyRoleGraphComponent } from "./core/ApplyRoleGraph.s.sol";
import { DeployBlacklistComponent } from "./core/DeployBlacklist.s.sol";
import { DeployCoreComponent } from "./core/DeployCore.s.sol";
import { DeployPeripheryComponent } from "./core/DeployPeriphery.s.sol";
import { DeployScriptBase } from "./core/DeployScriptBase.sol";
import { DeployImplementationsComponent } from "./templates/royco-day-balancer-v3/DeployImplementations.s.sol";
import { DeployTemplateComponent } from "./templates/royco-day-balancer-v3/DeployTemplate.s.sol";

/**
 * @title BootstrapChainComponent
 * @notice THE chain-bootstrap orchestrator: composes the per-component deployment scripts, in dependency order, to
 *         stand up everything a chain needs BEFORE any market exists — the auth + factory core, the periphery
 *         singletons, the role graph, the shared blacklist, and (per template family) the implementation set, the
 *         template, and the yield distribution models.
 * @dev Composition only: each component broadcasts ITS OWN transactions, the orchestrator never does (nested
 *      broadcasts revert). Ordering encodes the two cross-component constraints: periphery runs BEFORE the role
 *      graph's second pass (its LP-role grants need the default role admins), and the deployer's roles are NOT
 *      renounced here — markets may still be added, and `RenounceDeployerRoles` is the runbook's explicit final
 *      step. Every component is idempotent, so re-running the bootstrap against a live chain reuses what exists.
 * @dev As new template families ship, this grows one composition block per family.
 */
contract BootstrapChainComponent is DeployScriptBase, RoleGraphConfig, TemplateConfig {
    constructor(bool _isTestEnv, address _testDeploymentAdmin) {
        isTestEnv = _isTestEnv;
        testDeploymentAdmin = _testDeploymentAdmin;
    }

    /// @notice Bootstraps the chain end-to-end, returning every address downstream market deployments consume
    function bootstrap(uint256 _deployerPrivateKey) public returns (ChainDeployment memory chain) {
        // 1. Auth + factory core (root of the DAG)
        DeployCoreComponent core = new DeployCoreComponent(isTestEnv);
        core.enableLogging();
        CoreDeployment memory c = core.execute(_deployerPrivateKey);
        chain.accessManager = c.accessManager;
        chain.gatekeeper = c.gatekeeper;
        chain.factory = c.factory;
        chain.amExisted = c.amExisted;

        // 2. Periphery singletons — MUST precede the role graph (LP-role grants need default role admins)
        DeployPeripheryComponent periphery = new DeployPeripheryComponent(isTestEnv, PeripheryUpstream({ accessManager: c.accessManager, factory: c.factory }));
        periphery.enableLogging();
        (chain.entryPoint, chain.marketSyncer) = periphery.execute(_deployerPrivateKey);

        // 3. Role graph (grants pass, then admin/guardian re-pointing) — only on a fresh AccessManager
        ApplyRoleGraphComponent roleGraph = new ApplyRoleGraphComponent(c.accessManager);
        roleGraph.applyRoleGraph(
            generateRolesAssignments(roleAssignmentAddresses(isTestEnv)),
            factoryAdmin(isTestEnv),
            factoryAdminExecutionDelay(isTestEnv),
            !c.amExisted,
            _deployerPrivateKey
        );

        // 4. The chain's shared blacklist
        DeployBlacklistComponent blacklist = new DeployBlacklistComponent(isTestEnv, c.accessManager);
        blacklist.enableLogging();
        chain.roycoBlacklist = blacklist.execute(_deployerPrivateKey);

        // 5. Royco Day Balancer V3 template family: implementation set -> template
        DeployImplementationsComponent impls = new DeployImplementationsComponent(isTestEnv, c.accessManager);
        impls.enableLogging();
        chain.impls = impls.execute(_deployerPrivateKey);

        DeployTemplateComponent template = new DeployTemplateComponent(
            isTestEnv, TemplateUpstream({ accessManager: c.accessManager, factory: c.factory, roycoBlacklist: chain.roycoBlacklist, impls: chain.impls })
        );
        template.enableLogging();
        // Forward THIS instance's resolved policy (canonical or test-pinned), so the component and the orchestrator
        // can never disagree on the template's construction params — and therefore its address
        template.overrideTemplatePolicyForTest(templatePolicy(isTestEnv));
        chain.template = template.execute(_deployerPrivateKey);
    }
}

/// @notice CLI entrypoint: `forge script script/deploy/BootstrapChain.s.sol` — bootstraps the env's chain end-to-end
contract BootstrapChain is BootstrapChainComponent {
    constructor() BootstrapChainComponent(vm.envOr("IS_TEST_DEPLOYMENT", false), vm.envOr("TEST_ADMIN", 0x77777Cc68b333a2256B436D675E8D257699Aa667)) { }

    function run() external {
        enableLogging();
        bootstrap(vm.envUint("DEPLOYER_PRIVATE_KEY"));
    }
}
