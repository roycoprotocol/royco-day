// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Initializable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoycoBlacklist } from "../../src/auth/RoycoBlacklist.sol";
import { IRoycoAuth } from "../../src/interfaces/IRoycoAuth.sol";
import { IRoycoBlacklist } from "../../src/interfaces/IRoycoBlacklist.sol";
import { ISanctionsList } from "../../src/interfaces/external/chainalysis/ISanctionsList.sol";

/// @notice Minimal settable Chainalysis-style sanctions oracle used to exercise the sanctions screening path.
contract MockSanctionsList is ISanctionsList {
    mapping(address => bool) public sanctioned;

    function setSanctioned(address _account, bool _isSanctioned) external {
        sanctioned[_account] = _isSanctioned;
    }

    function isSanctioned(address _account) external view override returns (bool) {
        return sanctioned[_account];
    }
}

/// @title RoycoBlacklistTest
/// @notice Unit tests for the chain-shared RoycoBlacklist contract: access control, local blacklist mutation,
///         Chainalysis sanctions screening, and the single/batch enforcement helpers.
contract RoycoBlacklistTest is Test {
    AccessManager internal authority;
    RoycoBlacklist internal blacklist;
    MockSanctionsList internal sanctions;

    address internal ADMIN = makeAddr("ADMIN");
    address internal AGENT = makeAddr("AGENT");
    address internal ALICE = makeAddr("ALICE");
    address internal BOB = makeAddr("BOB");
    address internal CAROL = makeAddr("CAROL");

    // An arbitrary application-defined role for the transfer agent
    uint64 internal constant AGENT_ROLE = 42;

    function setUp() public {
        // AccessManager with ADMIN holding the admin role (role 0)
        authority = new AccessManager(ADMIN);
        sanctions = new MockSanctionsList();

        // Deploy the blacklist proxy with no sanctions list and no seeded accounts
        blacklist = _deployBlacklist(address(authority), address(0), new address[](0));

        // Wire blacklistAccounts / unblacklistAccounts to AGENT_ROLE and grant it to AGENT.
        // setSanctionsList is left unconfigured, so it defaults to the admin role (ADMIN can call it).
        bytes4[] memory agentSelectors = new bytes4[](2);
        agentSelectors[0] = IRoycoBlacklist.blacklistAccounts.selector;
        agentSelectors[1] = IRoycoBlacklist.unblacklistAccounts.selector;
        vm.startPrank(ADMIN);
        authority.setTargetFunctionRole(address(blacklist), agentSelectors, AGENT_ROLE);
        authority.grantRole(AGENT_ROLE, AGENT, 0);
        vm.stopPrank();
    }

    function _deployBlacklist(address _authority, address _sanctions, address[] memory _seed) internal returns (RoycoBlacklist) {
        RoycoBlacklist impl = new RoycoBlacklist();
        bytes memory initData = abi.encodeCall(RoycoBlacklist.initialize, (_authority, _sanctions, _seed));
        return RoycoBlacklist(address(new ERC1967Proxy(address(impl), initData)));
    }

    function _arr(address _a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = _a;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Initialization
    // ─────────────────────────────────────────────────────────────────────────

    function test_initialize_setsSanctionsListAndSeedsAccounts() public {
        address[] memory seed = new address[](2);
        seed[0] = ALICE;
        seed[1] = BOB;
        RoycoBlacklist bl = _deployBlacklist(address(authority), address(sanctions), seed);

        assertEq(bl.getSanctionsList(), address(sanctions), "sanctions list not set");
        assertTrue(bl.isBlacklisted(ALICE), "ALICE should be seeded blacklisted");
        assertTrue(bl.isBlacklisted(BOB), "BOB should be seeded blacklisted");
        assertFalse(bl.isBlacklisted(CAROL), "CAROL should not be blacklisted");
    }

    function test_initialize_revertsOnNullSeedAccount() public {
        address[] memory seed = new address[](1);
        seed[0] = address(0);
        RoycoBlacklist impl = new RoycoBlacklist();
        bytes memory initData = abi.encodeCall(RoycoBlacklist.initialize, (address(authority), address(0), seed));
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        blacklist.initialize(address(authority), address(0), new address[](0));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Access control
    // ─────────────────────────────────────────────────────────────────────────

    function test_blacklistAccounts_revertsForUnauthorized() public {
        vm.prank(ALICE);
        vm.expectRevert();
        blacklist.blacklistAccounts(_arr(BOB));
    }

    function test_unblacklistAccounts_revertsForUnauthorized() public {
        vm.prank(AGENT);
        blacklist.blacklistAccounts(_arr(BOB));

        vm.prank(ALICE);
        vm.expectRevert();
        blacklist.unblacklistAccounts(_arr(BOB));
    }

    function test_setSanctionsList_revertsForUnauthorized() public {
        vm.prank(AGENT); // AGENT holds AGENT_ROLE but setSanctionsList defaults to the admin role
        vm.expectRevert();
        blacklist.setSanctionsList(address(sanctions));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Local blacklist mutation
    // ─────────────────────────────────────────────────────────────────────────

    function test_blacklistAccounts_setsAndEmits() public {
        vm.expectEmit(true, false, false, false, address(blacklist));
        emit IRoycoBlacklist.AccountBlacklisted(BOB);
        vm.prank(AGENT);
        blacklist.blacklistAccounts(_arr(BOB));
        assertTrue(blacklist.isBlacklisted(BOB));
    }

    function test_blacklistAccounts_revertsOnNullAddress() public {
        vm.prank(AGENT);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        blacklist.blacklistAccounts(_arr(address(0)));
    }

    function test_blacklistAccounts_isIdempotent() public {
        vm.startPrank(AGENT);
        blacklist.blacklistAccounts(_arr(BOB));
        // Blacklisting again must not revert
        blacklist.blacklistAccounts(_arr(BOB));
        vm.stopPrank();
        assertTrue(blacklist.isBlacklisted(BOB));
    }

    function test_unblacklistAccounts_clearsAndIsIdempotent() public {
        vm.startPrank(AGENT);
        blacklist.blacklistAccounts(_arr(BOB));
        blacklist.unblacklistAccounts(_arr(BOB));
        assertFalse(blacklist.isBlacklisted(BOB), "BOB should be cleared");
        // Unblacklisting a non-blacklisted account must not revert
        blacklist.unblacklistAccounts(_arr(CAROL));
        vm.stopPrank();
    }

    function test_blacklistAccounts_handlesMultiple() public {
        address[] memory accounts = new address[](2);
        accounts[0] = ALICE;
        accounts[1] = BOB;
        vm.prank(AGENT);
        blacklist.blacklistAccounts(accounts);
        assertTrue(blacklist.isBlacklisted(ALICE));
        assertTrue(blacklist.isBlacklisted(BOB));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Sanctions screening
    // ─────────────────────────────────────────────────────────────────────────

    function test_isBlacklisted_zeroAddressIsNeverBlacklisted() public view {
        assertFalse(blacklist.isBlacklisted(address(0)));
    }

    function test_isBlacklisted_reflectsSanctionsList() public {
        // Enable the sanctions oracle, then sanction CAROL
        vm.prank(ADMIN);
        blacklist.setSanctionsList(address(sanctions));

        assertFalse(blacklist.isBlacklisted(CAROL), "not sanctioned yet");
        sanctions.setSanctioned(CAROL, true);
        assertTrue(blacklist.isBlacklisted(CAROL), "sanctioned account should be blacklisted");
    }

    function test_isBlacklisted_localOrSanctions() public {
        vm.prank(ADMIN);
        blacklist.setSanctionsList(address(sanctions));

        // Locally blacklisted but not sanctioned
        vm.prank(AGENT);
        blacklist.blacklistAccounts(_arr(ALICE));
        assertTrue(blacklist.isBlacklisted(ALICE));

        // Sanctioned but not locally blacklisted
        sanctions.setSanctioned(BOB, true);
        assertTrue(blacklist.isBlacklisted(BOB));
    }

    function test_setSanctionsList_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(blacklist));
        emit IRoycoBlacklist.SanctionsListUpdated(address(sanctions));
        vm.prank(ADMIN);
        blacklist.setSanctionsList(address(sanctions));
        assertEq(blacklist.getSanctionsList(), address(sanctions));

        // Disabling screening by setting back to the null address
        vm.prank(ADMIN);
        blacklist.setSanctionsList(address(0));
        assertEq(blacklist.getSanctionsList(), address(0));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Enforcement helpers
    // ─────────────────────────────────────────────────────────────────────────

    function test_enforceNotBlacklisted_single() public {
        blacklist.enforceNotBlacklisted(ALICE); // clean account: no revert

        vm.prank(AGENT);
        blacklist.blacklistAccounts(_arr(ALICE));
        vm.expectRevert(abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, ALICE));
        blacklist.enforceNotBlacklisted(ALICE);
    }

    function test_enforceNotBlacklisted_batchSkipsZeroAndPassesClean() public view {
        address[] memory accounts = new address[](3);
        accounts[0] = ALICE;
        accounts[1] = address(0); // skipped
        accounts[2] = BOB;
        blacklist.enforceNotBlacklisted(accounts); // no revert
    }

    function test_enforceNotBlacklisted_batchRevertsOnAnyBlacklisted() public {
        vm.prank(AGENT);
        blacklist.blacklistAccounts(_arr(BOB));

        address[] memory accounts = new address[](3);
        accounts[0] = ALICE;
        accounts[1] = address(0);
        accounts[2] = BOB;
        vm.expectRevert(abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, BOB));
        blacklist.enforceNotBlacklisted(accounts);
    }
}
