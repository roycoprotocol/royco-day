// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { DeployScript } from "../../../script/Deploy.s.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_BALANCER_POOL_MANAGER_ROLE,
    ADMIN_BLACKLIST_ROLE,
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE,
    ADMIN_KERNEL_ROLE,
    ADMIN_MARKET_OPS_ROLE,
    ADMIN_ORACLE_QUOTER_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    BURNER_ROLE,
    DEPLOYER_ROLE,
    DEPLOYER_ROLE_ADMIN_ROLE,
    GUARDIAN_ROLE,
    JT_LP_ROLE,
    LP_ROLE_ADMIN_ROLE,
    LT_LP_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE
} from "../../../src/factory/RolesConfiguration.sol";

/**
 * @title Test_DeployScriptConfig
 * @notice Pins the DeployScript pure configuration helpers that a mainnet deployment resolves before any state
 *         change: the generated role-assignment set, the per-role admin/guardian graph behind it, and the marketId
 *         derivation the CREATE2 component salts hang off
 * @dev These helpers are pure, so they are exercised on a plain instance with no fork. A hole here surfaces
 *      mid-broadcast on mainnet (an UNKNOWN_ROLE revert between role grants, or a salt collision between two
 *      markets), which is exactly the failure mode a deployment script must never discover live
 */
contract Test_DeployScriptConfig is Test {
    /// @dev Plain instance, its role and marketId helpers need no chain state
    DeployScript internal deployScript;

    /// @dev Mainnet USDC, the quote asset the script's constructor derives pool names from
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function setUp() public {
        // The script's constructor derives pool names by calling symbol() on the chain's USDC, so off-fork it needs
        // the mainnet chainid and token code at the mainnet USDC address. The helpers under test are pure and never
        // read that token, the etch only lets construction complete.
        vm.chainId(1);
        vm.etch(MAINNET_USDC, address(new MockERC20C("USD Coin", "USDC", 6)).code);
        deployScript = new DeployScript();
    }

    /**
     * @notice Every role emitted by generateRolesAssignments must resolve through getRoleConfig, and every resolved
     *         admin/guardian must itself be a role that exists in the graph. _applyRoleGraph grants all assignments in
     *         pass 1 and then re-resolves each role's config in pass 2 to re-point admins and guardians, so a single
     *         unmapped role (or an admin pointing at a role nobody administers) reverts UNKNOWN_ROLE mid-deployment,
     *         after grants have already landed. This test guarantees pass 2 can never hit that revert
     */
    function test_GetRoleConfig_ResolvesEveryGeneratedRoleAssignment() public view {
        // 17 distinct dummy addresses, one per RoleAssignmentAddresses field (the struct's full address surface).
        // The fee recipient deliberately carries three LP roles (ST/JT/LT) and market ops carries the blacklist
        // admin role alongside its own, which is how 17 addresses fan out to 20 assignments.
        DeployScript.RoleAssignmentAddresses memory addresses = DeployScript.RoleAssignmentAddresses({
            pauserAddress: address(0x1001),
            unpauserAddress: address(0x1002),
            upgraderAddress: address(0x1003),
            syncRoleAddress: address(0x1004),
            adminKernelAddress: address(0x1005),
            adminAccountantAddress: address(0x1006),
            adminProtocolFeeSetterAddress: address(0x1007),
            adminOracleQuoterAddress: address(0x1008),
            lpRoleAdminAddress: address(0x1009),
            guardianAddress: address(0x100A),
            deployerAddress: address(0x100B),
            deployerAdminAddress: address(0x100C),
            protocolFeeRecipientAddress: address(0x100D),
            balancerPoolManagerAddress: address(0x100E),
            marketOpsAddress: address(0x100F),
            adminEntryPointAddress: address(0x1010),
            entryPointFeeCollectorAddress: address(0x1011)
        });

        DeployScript.RoleAssignment[] memory assignments = deployScript.generateRolesAssignments(addresses);

        // Independently derived count: the address surface is 17 fields, of which the fee recipient maps to the
        // three LP roles, market ops maps to its own role plus the blacklist admin role, and the other 15 map
        // one-to-one, so 15 + 3 + 2 = 20 assignments.
        assertEq(assignments.length, 20, "one assignment per (role, assignee) pair: 15 one-to-one + 3 LP roles on the fee recipient + 2 on market ops");

        for (uint256 i; i < assignments.length; ++i) {
            uint64 role = assignments[i].role;

            // Pass 2 of _applyRoleGraph calls getRoleConfig(role) for every granted assignment. If any emitted
            // role were unmapped this call would revert UNKNOWN_ROLE and abort the deployment mid-broadcast.
            DeployScript.RoleConfig memory cfg = deployScript.getRoleConfig(role);

            // The admin re-pointing in pass 2 is only safe if every target admin role is itself rooted in the
            // graph: ADMIN_ROLE (held by the factory admin), or one of the two meta-admin roles that pass 1
            // granted to a concrete address (LP_ROLE_ADMIN_ROLE, DEPLOYER_ROLE_ADMIN_ROLE). Any other admin would
            // orphan the role: nobody could ever grant or revoke it after the deployer renounces.
            bool adminRooted = cfg.adminRole == ADMIN_ROLE || cfg.adminRole == LP_ROLE_ADMIN_ROLE || cfg.adminRole == DEPLOYER_ROLE_ADMIN_ROLE;
            assertTrue(adminRooted, "role admin must be ADMIN_ROLE or a granted meta-admin role");

            // Same closed-world requirement for guardians: GUARDIAN_ROLE for every role except GUARDIAN_ROLE
            // itself, which ADMIN_ROLE guards (a role cannot usefully guard itself).
            bool guardianRooted = cfg.guardianRole == GUARDIAN_ROLE || cfg.guardianRole == ADMIN_ROLE;
            assertTrue(guardianRooted, "role guardian must be GUARDIAN_ROLE or ADMIN_ROLE");

            // The assignment must carry the same admin the graph resolves, otherwise the struct consumers and
            // pass 2 disagree about who administers the role.
            assertEq(assignments[i].roleAdminRole, cfg.adminRole, "assignment admin must match the resolved role config");

            // Hand-derived admin per role: the three LP roles sit under LP_ROLE_ADMIN_ROLE, DEPLOYER_ROLE sits
            // under DEPLOYER_ROLE_ADMIN_ROLE, and every other role is administered by ADMIN_ROLE directly.
            uint64 expectedAdmin = ADMIN_ROLE;
            if (role == ST_LP_ROLE || role == JT_LP_ROLE || role == LT_LP_ROLE) expectedAdmin = LP_ROLE_ADMIN_ROLE;
            if (role == DEPLOYER_ROLE) expectedAdmin = DEPLOYER_ROLE_ADMIN_ROLE;
            assertEq(cfg.adminRole, expectedAdmin, "admin does not match the hand-derived role graph");

            // Hand-derived guardian per role: ADMIN_ROLE guards GUARDIAN_ROLE, GUARDIAN_ROLE guards the rest.
            uint64 expectedGuardian = role == GUARDIAN_ROLE ? ADMIN_ROLE : GUARDIAN_ROLE;
            assertEq(cfg.guardianRole, expectedGuardian, "guardian does not match the hand-derived role graph");
        }

        // The emitted role set itself, hand-listed from the deployment's operational surface (pause/unpause,
        // upgrade, sync, kernel/accountant/fee/quoter admin, LP admin + the three LP roles, guardian, deployer +
        // its admin, Balancer pool manager, market ops + blacklist admin, entry point config + fee collection).
        // Order-pinned so a silent drop or reorder is loud.
        uint64[20] memory expectedRoles = [
            ADMIN_PAUSER_ROLE,
            ADMIN_UPGRADER_ROLE,
            SYNC_ROLE,
            ADMIN_KERNEL_ROLE,
            ADMIN_ACCOUNTANT_ROLE,
            ADMIN_PROTOCOL_FEE_SETTER_ROLE,
            ADMIN_ORACLE_QUOTER_ROLE,
            LP_ROLE_ADMIN_ROLE,
            ST_LP_ROLE,
            JT_LP_ROLE,
            GUARDIAN_ROLE,
            DEPLOYER_ROLE,
            DEPLOYER_ROLE_ADMIN_ROLE,
            ADMIN_UNPAUSER_ROLE,
            LT_LP_ROLE,
            ADMIN_BALANCER_POOL_MANAGER_ROLE,
            ADMIN_MARKET_OPS_ROLE,
            ADMIN_BLACKLIST_ROLE,
            ADMIN_ENTRY_POINT_ROLE,
            ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE
        ];
        for (uint256 i; i < expectedRoles.length; ++i) {
            assertEq(assignments[i].role, expectedRoles[i], "generated role set diverged from the deployment role surface");
        }
    }

    /**
     * @notice getRoleConfig must revert UNKNOWN_ROLE, carrying the queried id, for protocol roles that exist as
     *         constants but have no admin/guardian mapping. BURNER_ROLE is a real role id (granted to each market's
     *         kernel by the template, never by this script), so a config that accidentally references it must fail
     *         loudly at resolution time instead of silently defaulting to some admin, which would hand role
     *         administration to an unintended party
     */
    function test_RevertIf_GetRoleConfigQueriedWithUnmappedRole() public {
        // The revert must carry the exact queried id so the operator can see WHICH role the config mis-references.
        vm.expectRevert(abi.encodeWithSelector(DeployScript.UNKNOWN_ROLE.selector, BURNER_ROLE));
        deployScript.getRoleConfig(BURNER_ROLE);
    }

    /**
     * @notice DeployScript.deploy derives the marketId as
     *         keccak256(abi.encode(seniorTrancheName, juniorTrancheName, block.timestamp, block.chainid)). abi.encode
     *         length-prefixes each dynamic string, so a shifted boundary between the two tranche names cannot alias two
     *         distinct configs to one id: ("Senior AB", "C-JT") and ("Senior A", "BC-JT") derive different ids. An
     *         identical config rerun in the same block still derives the same id (the derivation carries no caller
     *         nonce), but that is a loud foot-gun, not silent aliasing: the marketId seeds every CREATE2 component salt,
     *         so a colliding second deployment hits an already-deployed component address and reverts
     *         MARKET_COMPONENT_ALREADY_DEPLOYED atomically
     */
    function test_MarketIdDerivation_IsInjectiveAcrossShiftedNameBoundaries() public {
        // Fixed block context so the derivation below is fully determined: both derivations share the same
        // timestamp and chainid, isolating the string boundary as the only moving part.
        vm.warp(1_750_000_000);
        vm.chainId(1);

        // Two DIFFERENT market configs whose packed name bytes would coincide under encodePacked:
        //   "Senior AB" ++ "C-JT" and "Senior A" ++ "BC-JT" both pack to "Senior ABC-JT"
        // abi.encode length-prefixes each string, so the boundary survives and the two ids differ.
        bytes32 marketIdA = keccak256(abi.encode(string("Senior AB"), string("C-JT"), block.timestamp, block.chainid));
        bytes32 marketIdB = keccak256(abi.encode(string("Senior A"), string("BC-JT"), block.timestamp, block.chainid));
        assertNotEq(marketIdA, marketIdB, "abi.encode keeps shifted name boundaries distinct");

        // An identical config rerun in the same block still derives the same id (no nonce) — accepted, because the
        // colliding redeploy reverts MARKET_COMPONENT_ALREADY_DEPLOYED loudly rather than aliasing components.
        bytes32 rerunId = keccak256(abi.encode(string("Senior AB"), string("C-JT"), block.timestamp, block.chainid));
        assertEq(marketIdA, rerunId, "same names in the same block derive the same id, a loud redeploy revert not silent aliasing");

        // The replaced encodePacked derivation WOULD have aliased the shifted-boundary pair — shown for contrast.
        bytes32 packedA = keccak256(abi.encodePacked(string("Senior AB"), string("C-JT"), block.timestamp, block.chainid));
        bytes32 packedB = keccak256(abi.encodePacked(string("Senior A"), string("BC-JT"), block.timestamp, block.chainid));
        assertEq(packedA, packedB, "the replaced encodePacked derivation aliased shifted boundaries");
    }
}
