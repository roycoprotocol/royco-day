// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_BALANCER_POOL_MANAGER_ROLE,
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE,
    ADMIN_FACTORY_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_MARKET_OPS_ROLE,
    ADMIN_ORACLE_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    BURNER_ROLE,
    DEPLOYER_ROLE,
    DEPLOYER_ROLE_ADMIN_ROLE,
    GUARDIAN_ROLE,
    JT_LP_ROLE,
    LP_ROLE_ADMIN_ROLE,
    LPT_LP_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE
} from "../../../src/factory/Roles.sol";

/**
 * @notice Local single-function redeclaration of Balancer v3's two-argument withdrawPoolCreatorFees overload,
 *         withdrawPoolCreatorFees(address pool, address recipient), so the compiler derives its selector for us.
 *         Balancer's real IProtocolFeeController also declares a one-argument overload, which is why the factory
 *         template cannot use .selector and must hand-hash the signature string, the thing under test here
 */
interface IWithdrawPoolCreatorFeesTwoArgOverload {
    function withdrawPoolCreatorFees(address pool, address recipient) external;
}

/**
 * @title Test_Roles
 * @notice Pins the role-id registry: every hashed role id must derive from its own "ROYCO_<NAME>" string, all ids
 *         must be pairwise distinct, and none may collide with AccessManager's reserved ADMIN_ROLE (0) or
 *         PUBLIC_ROLE (type(uint64).max). Also pins the hand-hashed withdrawPoolCreatorFees selector the factory
 *         template binds a role to, against the compiler-derived selector of the real two-argument overload
 */
contract Test_Roles is Test {
    /**
     * A colliding or reserved-value role id silently merges two permission sets: AccessManager keys permissions by
     * the uint64 id alone, so two roles hashing to the same id would grant each other's targets, an id of 0 would
     * grant full admin (ADMIN_ROLE), and an id of type(uint64).max would open the function to everyone
     * (PUBLIC_ROLE). Each id is recomputed here from its role-name string via the documented derivation
     * uint64(uint256(keccak256(abi.encode("ROYCO_<NAME>")))) — the expected values come from that formula applied
     * to the strings written in this test, never read back from the constants being checked — then all ids are
     * swept pairwise for distinctness and against the two reserved AccessManager values
     */
    function test_RoleIds_PairwiseDistinct_AndReservedAdminPublicValuesAvoided() public pure {
        // parallel arrays: the role-name string each id must hash from, and the imported constant under test
        string[21] memory names = [
            string("ROYCO_ADMIN_PAUSER_ROLE"),
            "ROYCO_ADMIN_UNPAUSER_ROLE",
            "ROYCO_ADMIN_UPGRADER_ROLE",
            "ROYCO_ST_LP_ROLE",
            "ROYCO_JT_LP_ROLE",
            "ROYCO_LPT_LP_ROLE",
            "ROYCO_BURNER_ROLE",
            "ROYCO_SYNC_ROLE",
            "ROYCO_ADMIN_KERNEL_ROLE",
            "ROYCO_ADMIN_MARKET_OPS_ROLE",
            "ROYCO_ADMIN_ACCOUNTANT_ROLE",
            "ROYCO_ADMIN_PROTOCOL_FEE_SETTER_ROLE",
            "ROYCO_ADMIN_ORACLE_ROLE",
            "ROYCO_ADMIN_ENTRY_POINT_ROLE",
            "ROYCO_ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE",
            "ROYCO_ADMIN_BALANCER_POOL_MANAGER_ROLE",
            "ROYCO_ADMIN_FACTORY_ROLE",
            "ROYCO_DEPLOYER_ROLE",
            "ROYCO_DEPLOYER_ROLE_ADMIN_ROLE",
            "ROYCO_LP_ROLE_ADMIN_ROLE",
            "ROYCO_GUARDIAN_ROLE"
        ];
        uint64[21] memory ids = [
            ADMIN_PAUSER_ROLE,
            ADMIN_UNPAUSER_ROLE,
            ADMIN_UPGRADER_ROLE,
            ST_LP_ROLE,
            JT_LP_ROLE,
            LPT_LP_ROLE,
            BURNER_ROLE,
            SYNC_ROLE,
            ADMIN_KERNEL_ROLE,
            ADMIN_MARKET_OPS_ROLE,
            ADMIN_ACCOUNTANT_ROLE,
            ADMIN_PROTOCOL_FEE_SETTER_ROLE,
            ADMIN_ORACLE_ROLE,
            ADMIN_ENTRY_POINT_ROLE,
            ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE,
            ADMIN_BALANCER_POOL_MANAGER_ROLE,
            ADMIN_FACTORY_ROLE,
            DEPLOYER_ROLE,
            DEPLOYER_ROLE_ADMIN_ROLE,
            LP_ROLE_ADMIN_ROLE,
            GUARDIAN_ROLE
        ];

        // hand-derived spot anchors computed offline with cast, tying the derivation formula itself to fixed
        // literals so a silent change to the formula (or to abi.encode's string layout) cannot slip past:
        //   keccak256(abi.encode("ROYCO_ST_LP_ROLE"))    = 0xe9b5...411ba2c3, low 64 bits = 0x858ca8ea411ba2c3
        //   keccak256(abi.encode("ROYCO_GUARDIAN_ROLE")) = 0x4b86...29f38eba, low 64 bits = 0x2bc4420d29f38eba
        assertEq(ST_LP_ROLE, 0x858ca8ea411ba2c3, "ST_LP_ROLE hand-derived anchor");
        assertEq(GUARDIAN_ROLE, 0x2bc4420d29f38eba, "GUARDIAN_ROLE hand-derived anchor");

        for (uint256 i = 0; i < 21; ++i) {
            // each id must equal the derivation formula applied to its own role-name string, so a role whose
            // constant was copy-pasted with the wrong string (hashing to another role's id) fails by name here
            assertEq(ids[i], uint64(uint256(keccak256(abi.encode(names[i])))), names[i]);
            // 0 is AccessManager's ADMIN_ROLE: a role hashing to 0 would silently be the super-admin
            assertNotEq(ids[i], 0, names[i]);
            // type(uint64).max is AccessManager's PUBLIC_ROLE: a role hashing to it would open its targets to all
            assertNotEq(ids[i], type(uint64).max, names[i]);
            // pairwise distinctness: any two roles sharing an id would each inherit the other's permissions
            for (uint256 j = i + 1; j < 21; ++j) {
                assertNotEq(ids[i], ids[j], string.concat(names[i], " collides with ", names[j]));
            }
        }
    }

    /**
     * The factory template binds ADMIN_BALANCER_POOL_MANAGER_ROLE to the two-argument
     * withdrawPoolCreatorFees(address,address) overload. Because Balancer's IProtocolFeeController overloads the name
     * (it also declares a one-argument version), IProtocolFeeController.withdrawPoolCreatorFees.selector is ambiguous
     * and non-compiling, so the template derives the selector from a local single-function interface declaring only the
     * two-argument overload. This test pins that compiler-derived selector to the offline-derived literal 0xf7061445 so
     * a future edit to the interface signature (wrong parameter list, stray space, wrong casing) that would silently
     * bind fee withdrawal to a dead selector is caught here
     */
    function test_WithdrawPoolCreatorFeesSelector_MatchesOverloadedInterfaceSignature() public pure {
        // compiler-derived selector of the unambiguous local redeclaration of the two-argument overload
        assertEq(
            IWithdrawPoolCreatorFeesTwoArgOverload.withdrawPoolCreatorFees.selector,
            bytes4(0xf7061445),
            "overload selector != offline-derived selector literal"
        );
        // sanity: the raw keccak of the canonical signature agrees with the compiler-derived selector
        assertEq(
            IWithdrawPoolCreatorFeesTwoArgOverload.withdrawPoolCreatorFees.selector,
            bytes4(keccak256("withdrawPoolCreatorFees(address,address)")),
            "overload selector != keccak of canonical signature"
        );
    }
}
