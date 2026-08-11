// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { RoleAssignment, RoleAssignmentAddresses, RoleConfig } from "../../../script/config/DeploymentTypes.sol";
import { RoleGraphConfig } from "../../../script/deploy/config/RoleGraphConfig.sol";
import { ApplyRoleGraphComponent } from "../../../script/deploy/core/ApplyRoleGraph.s.sol";
import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_BALANCER_POOL_MANAGER_ROLE,
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE,
    ADMIN_KERNEL_ROLE,
    ADMIN_MARKET_OPS_ROLE,
    ADMIN_ORACLE_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    BURNER_ROLE,
    GUARDIAN_ROLE,
    JT_LP_ROLE,
    LPT_LP_ROLE,
    LP_ROLE_ADMIN_ROLE,
    ST_LP_ROLE
} from "../../../src/factory/Roles.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";

/**
 * @title Test_DeployScriptConfig
 * @notice Pins the role-graph component's pure configuration helpers that a mainnet deployment resolves before any state
 *         change: the generated role-assignment set, the per-role admin/guardian graph behind it, and the marketId
 *         derivation the CREATE2 component salts hang off
 * @dev These helpers are pure, so they are exercised on a plain instance with no fork. A hole here surfaces
 *      mid-broadcast on mainnet (an UNKNOWN_ROLE revert between role grants, or a salt collision between two
 *      markets), which is exactly the failure mode a deployment script must never discover live
 */
contract Test_DeployScriptConfig is Test {
    /// @dev Plain instance, its role and marketId helpers need no chain state
    ApplyRoleGraphComponent internal deployScript;

    /// @dev Mainnet USDC, the quote asset the script's constructor derives pool names from
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function setUp() public {
        // The script's constructor derives pool names by calling symbol() on the chain's USDC, so off-fork it needs
        // the mainnet chainid and token code at the mainnet USDC address. The helpers under test are pure and never
        // read that token, the etch only lets construction complete.
        vm.chainId(1);
        vm.etch(MAINNET_USDC, address(new MockERC20C("USD Coin", "USDC", 6)).code);
        deployScript = new ApplyRoleGraphComponent(address(0));
    }

    /**
     * @notice Every role emitted by generateRolesAssignments must resolve through getRoleConfig, and every resolved
     *         admin/guardian must itself be a role that exists in the graph. _applyRoleGraph grants all assignments in
     *         pass 1 and then re-resolves each role's config in pass 2 to re-point admins and guardians, so a single
     *         unmapped role (or an admin pointing at a role nobody administers) reverts UNKNOWN_ROLE mid-deployment,
     *         after grants have already landed. This test guarantees pass 2 can never hit that revert
     */
    function test_GetRoleConfig_ResolvesEveryGeneratedRoleAssignment() public view {
        // 18 distinct dummy addresses, one per RoleAssignmentAddresses field (the struct's full address surface).
        // The LP-role holder deliberately carries three LP roles (ST/JT/LPT), market ops carries its own role, and
        // the three co-hold fields (guardian veto, emergency oracle admin, LP operator) each add a second holder to
        // an already-emitted role — the address surface fans out to 19 assignments.
        RoleAssignmentAddresses memory addresses = RoleAssignmentAddresses({
            pauserAddress: address(0x1001),
            unpauserAddress: address(0x1002),
            upgraderAddress: address(0x1003),
            syncRoleAddress: address(0x1004),
            adminKernelAddress: address(0x1005),
            adminAccountantAddress: address(0x1006),
            adminProtocolFeeSetterAddress: address(0x1007),
            adminOracleAddress: address(0x1008),
            adminOracleEmergencyAddress: address(0x1013),
            lpRoleAdminAddress: address(0x1009),
            lpRoleAdminOperatorAddress: address(0x1014),
            guardianAddress: address(0x100A),
            guardianVetoAddress: address(0x1015),
            lpRoleHolderAddress: address(0x100D),
            balancerPoolManagerAddress: address(0x100E),
            marketOpsAddress: address(0x100F),
            adminEntryPointAddress: address(0x1010),
            entryPointFeeCollectorAddress: address(0x1011)
        });

        RoleAssignment[] memory assignments = deployScript.generateRolesAssignments(addresses);

        // Independently derived count: the address surface is 18 fields, of which the LP-role holder maps to the
        // three LP roles, the three co-hold fields append one entry each, and the other 12 map one-to-one, so
        // 12 + 3 + 1 + 3 = 19 assignments (market ops now maps to its own role only).
        assertEq(assignments.length, 19, "one assignment per (role, assignee) pair: 12 one-to-one + 3 LP roles on the holder + market ops + 3 co-holds");

        for (uint256 i; i < assignments.length; ++i) {
            uint64 role = assignments[i].role;

            // Pass 2 of _applyRoleGraph calls getRoleConfig(role) for every granted assignment. If any emitted
            // role were unmapped this call would revert UNKNOWN_ROLE and abort the deployment mid-broadcast.
            RoleConfig memory cfg = deployScript.getRoleConfig(role);

            // The admin re-pointing in pass 2 is only safe if every target admin role is itself rooted in the
            // graph: ADMIN_ROLE (held by the factory admin), or the meta-admin role that pass 1 granted to a
            // concrete address (LP_ROLE_ADMIN_ROLE). Any other admin would orphan the role: nobody could ever
            // grant or revoke it after the deployer renounces.
            bool adminRooted = cfg.adminRole == ADMIN_ROLE || cfg.adminRole == LP_ROLE_ADMIN_ROLE;
            assertTrue(adminRooted, "role admin must be ADMIN_ROLE or a granted meta-admin role");

            // Same closed-world requirement for guardians: GUARDIAN_ROLE for every role except GUARDIAN_ROLE
            // itself, which ADMIN_ROLE guards (a role cannot usefully guard itself).
            bool guardianRooted = cfg.guardianRole == GUARDIAN_ROLE || cfg.guardianRole == ADMIN_ROLE;
            assertTrue(guardianRooted, "role guardian must be GUARDIAN_ROLE or ADMIN_ROLE");

            // The assignment must carry the same admin the graph resolves, otherwise the struct consumers and
            // pass 2 disagree about who administers the role.
            assertEq(assignments[i].roleAdminRole, cfg.adminRole, "assignment admin must match the resolved role config");

            // Every assignment carries the role table's delay, except the emergency oracle co-hold (index 17),
            // which is deliberately IMMEDIATE while WAY's parameter path stays at the table's 72h.
            uint32 expectedDelay = i == 17 ? 0 : cfg.executionDelay;
            assertEq(assignments[i].executionDelay, expectedDelay, "assignment delay must match the role table (or the co-hold exception)");

            // Hand-derived admin per role: the three LP roles sit under LP_ROLE_ADMIN_ROLE, and every other role
            // is administered by ADMIN_ROLE directly.
            uint64 expectedAdmin = ADMIN_ROLE;
            if (role == ST_LP_ROLE || role == JT_LP_ROLE || role == LPT_LP_ROLE) expectedAdmin = LP_ROLE_ADMIN_ROLE;
            assertEq(cfg.adminRole, expectedAdmin, "admin does not match the hand-derived role graph");

            // Hand-derived guardian per role: ADMIN_ROLE guards GUARDIAN_ROLE, GUARDIAN_ROLE guards the rest.
            uint64 expectedGuardian = role == GUARDIAN_ROLE ? ADMIN_ROLE : GUARDIAN_ROLE;
            assertEq(cfg.guardianRole, expectedGuardian, "guardian does not match the hand-derived role graph");
        }

        // The emitted role set itself, hand-listed from the deployment's operational surface (pause/unpause,
        // upgrade, kernel/accountant/fee/venue admin, LP admin + the three LP roles, guardian, Balancer
        // pool manager, market ops, entry point config + fee collection, liquidity-premium
        // reinvestment, plus the three kerchkoffs co-holds). Market deployment is PUBLIC, so no deployer role
        // appears. Order-pinned so a silent drop or reorder is loud.
        uint64[19] memory expectedRoles = [
            ADMIN_PAUSER_ROLE,
            ADMIN_UPGRADER_ROLE,
            ADMIN_KERNEL_ROLE,
            ADMIN_ACCOUNTANT_ROLE,
            ADMIN_PROTOCOL_FEE_SETTER_ROLE,
            ADMIN_ORACLE_ROLE,
            LP_ROLE_ADMIN_ROLE,
            ST_LP_ROLE,
            JT_LP_ROLE,
            GUARDIAN_ROLE,
            ADMIN_UNPAUSER_ROLE,
            LPT_LP_ROLE,
            ADMIN_BALANCER_POOL_MANAGER_ROLE,
            ADMIN_MARKET_OPS_ROLE,
            ADMIN_ENTRY_POINT_ROLE,
            ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE,
                    // The kerchkoffs co-holds, appended at the tail: a second guardian (the veto multisig), the immediate
            // emergency oracle admin, and the LP-role operator
            GUARDIAN_ROLE,
            ADMIN_ORACLE_ROLE,
            LP_ROLE_ADMIN_ROLE
        ];
        for (uint256 i; i < expectedRoles.length; ++i) {
            assertEq(assignments[i].role, expectedRoles[i], "generated role set diverged from the deployment role surface");
        }
    }

    /**
     * @notice Pins the kerchkoffs four-multisig separation on the PRODUCTION address resolution: WAY (the proposer,
     *         which schedules every delayed parameter op) holds neither the pause lever nor either guardian seat —
     *         no party may both schedule and cancel — and the pauser is a dedicated fast-response multisig holding
     *         nothing else. Also pins the kerchkoffs delay tiers and the ADMIN_ROLE lockdown
     */
    function test_ProductionRoleDistribution_MatchesKerchkoffsModel() public view {
        RoleAssignmentAddresses memory a = deployScript.roleAssignmentAddresses(false);

        // WAY is the proposer: one address holds the entire parameter-update surface
        address way = a.adminKernelAddress;
        assertEq(a.upgraderAddress, way, "upgrader must be the proposer");
        assertEq(a.adminAccountantAddress, way, "accountant admin must be the proposer");
        assertEq(a.adminProtocolFeeSetterAddress, way, "fee setter must be the proposer");
        assertEq(a.adminOracleAddress, way, "oracle admin (delayed path) must be the proposer");
        assertEq(a.lpRoleAdminAddress, way, "LP role admin must be the proposer");
        assertEq(a.adminEntryPointAddress, way, "entry point admin must be the proposer");
        assertEq(a.balancerPoolManagerAddress, way, "balancer pool manager must be the proposer");
        assertEq(a.marketOpsAddress, way, "market ops must be the proposer");
        assertEq(a.syncRoleAddress, way, "sync must be the proposer");

        // ...but the proposer holds neither the pause lever nor either guardian seat
        assertTrue(a.pauserAddress != way, "the pauser must not be the proposer");
        assertTrue(a.guardianAddress != way && a.guardianVetoAddress != way, "no party may both schedule and cancel");
        // The dedicated fast-response seats are distinct from each other and from FNDN's seats
        assertTrue(a.pauserAddress != a.unpauserAddress, "pause and unpause must be split (only FNDN clears a pause)");
        assertTrue(a.guardianVetoAddress != a.guardianAddress, "the veto multisig must be a second, distinct guardian");
        // FNDN keeps the unwind surface: unpause, fee collection, the emergency oracle co-hold, and the three
        // LP-role grants made at bootstrap
        assertEq(a.unpauserAddress, a.entryPointFeeCollectorAddress, "FNDN holds unpause and fee collection");
        assertEq(a.adminOracleEmergencyAddress, a.guardianAddress, "FNDN co-holds the emergency oracle seat");
        assertEq(a.lpRoleHolderAddress, a.guardianAddress, "FNDN holds the three LP roles granted at bootstrap");

        // Kerchkoffs delay tiers: entry point config on the SHORT tier, fee claim and LP-role admin immediate
        assertEq(deployScript.getRoleConfig(ADMIN_ENTRY_POINT_ROLE).executionDelay, 24 hours, "entry point admin must ride the 24h tier");
        assertEq(deployScript.getRoleConfig(ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE).executionDelay, 0, "fee claim must be immediate");
        assertEq(deployScript.getRoleConfig(LP_ROLE_ADMIN_ROLE).executionDelay, 0, "LP-role admin must be immediate (operational granting)");

        // The ADMIN_ROLE lockdown: FNDN's admin ops run at 72h in production; fixtures stay synchronous
        assertEq(deployScript.factoryAdminExecutionDelay(false), 72 hours, "production admin ops must ride the 72h lockdown");
        assertEq(deployScript.factoryAdminExecutionDelay(true), 0, "test deployments must stay synchronous");
    }

    /**
     * @notice getRoleConfig must revert UNKNOWN_ROLE, carrying the queried id, for protocol roles that exist as
     *         constants but have no admin/guardian mapping. BURNER_ROLE is a real role id (granted to each market's
     *         kernel by the gatekeeper, never by this script), so a config that accidentally references it must fail
     *         loudly at resolution time instead of silently defaulting to some admin, which would hand role
     *         administration to an unintended party
     */
    function test_RevertIf_GetRoleConfigQueriedWithUnmappedRole() public {
        // The revert must carry the exact queried id so the operator can see WHICH role the config mis-references.
        vm.expectRevert(abi.encodeWithSelector(RoleGraphConfig.UnknownRole.selector, BURNER_ROLE));
        deployScript.getRoleConfig(BURNER_ROLE);
    }
}
