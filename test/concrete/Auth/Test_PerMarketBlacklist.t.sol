// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Ownable } from "../../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { RoycoBlacklist } from "../../../src/auth/RoycoBlacklist.sol";
import { IRoycoBlacklist } from "../../../src/interfaces/IRoycoBlacklist.sol";
import { MockSanctionsList } from "../../mocks/MockSanctionsList.sol";

/// @title Test_PerMarketBlacklist
/// @notice The per-market blacklist is a standalone, non-upgradeable `Ownable2Step` contract every market deployer
///         stands up and owns. This suite pins the two properties the design promises: (1) the owner can update the
///         blacklist's configuration (local blacklist + Chainalysis sanctions list) and every update takes effect on
///         the screening surface, gated to the owner; and (2) each market's blacklist is fully independent, so
///         updating one market's blacklist never leaks into another's.
contract Test_PerMarketBlacklist is Test {
    address internal OWNER = makeAddr("OWNER");
    address internal OWNER_TWO = makeAddr("OWNER_TWO");
    address internal STRANGER = makeAddr("STRANGER");
    address internal FLAGGED = makeAddr("FLAGGED");
    address internal SANCTIONED = makeAddr("SANCTIONED");
    address internal CLEAN = makeAddr("CLEAN");

    function _one(address _a) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = _a;
    }

    // ── Owner can update configuration, and every update is effective ──

    /// @notice The owner blacklists and unblacklists accounts, and every change is reflected by the screening surface
    function test_Owner_UpdatesLocalBlacklist_AndItIsEffective() external {
        RoycoBlacklist blacklist = new RoycoBlacklist(OWNER, address(0), new address[](0));

        assertFalse(blacklist.isBlacklisted(FLAGGED), "starts clean");

        // Owner blacklists FLAGGED — the update is effective on both the boolean view and the enforcing view
        vm.prank(OWNER);
        blacklist.blacklistAccounts(_one(FLAGGED));
        assertTrue(blacklist.isBlacklisted(FLAGGED), "blacklisted account reads as blacklisted");
        vm.expectRevert(abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, FLAGGED));
        blacklist.enforceNotBlacklisted(FLAGGED);
        assertFalse(blacklist.isBlacklisted(CLEAN), "an untouched account stays clean");

        // Owner unblacklists FLAGGED — the update is effective (the account clears)
        vm.prank(OWNER);
        blacklist.unblacklistAccounts(_one(FLAGGED));
        assertFalse(blacklist.isBlacklisted(FLAGGED), "unblacklisted account clears");
        blacklist.enforceNotBlacklisted(FLAGGED); // no longer reverts
    }

    /// @notice The owner points the blacklist at a Chainalysis sanctions list, and the screen honors it immediately;
    ///         clearing the list (setting it to the null address) disables sanctions screening again
    function test_Owner_UpdatesSanctionsList_AndItIsEffective() external {
        RoycoBlacklist blacklist = new RoycoBlacklist(OWNER, address(0), new address[](0));
        MockSanctionsList sanctions = new MockSanctionsList();
        sanctions.setSanctioned(SANCTIONED, true);

        assertEq(blacklist.getSanctionsList(), address(0), "no sanctions list configured at genesis");
        assertFalse(blacklist.isBlacklisted(SANCTIONED), "a sanctioned account is not screened until a list is wired");

        // Owner wires the sanctions list — screening picks it up immediately
        vm.prank(OWNER);
        blacklist.setSanctionsList(address(sanctions));
        assertEq(blacklist.getSanctionsList(), address(sanctions), "sanctions list update takes effect");
        assertTrue(blacklist.isBlacklisted(SANCTIONED), "a sanctioned account is now screened");
        assertFalse(blacklist.isBlacklisted(CLEAN), "an unsanctioned account stays clean");

        // Owner clears the sanctions list — screening stops honoring it
        vm.prank(OWNER);
        blacklist.setSanctionsList(address(0));
        assertEq(blacklist.getSanctionsList(), address(0), "sanctions list cleared");
        assertFalse(blacklist.isBlacklisted(SANCTIONED), "sanctions screening disabled once the list is cleared");
    }

    /// @notice Only the owner can update the blacklist's configuration — a stranger is rejected on every mutator
    function test_RevertIf_NonOwnerUpdatesConfiguration() external {
        RoycoBlacklist blacklist = new RoycoBlacklist(OWNER, address(0), new address[](0));

        vm.startPrank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        blacklist.blacklistAccounts(_one(FLAGGED));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        blacklist.unblacklistAccounts(_one(FLAGGED));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        blacklist.setSanctionsList(address(1));
        vm.stopPrank();
    }

    // ── Each market's blacklist is independent ──

    /// @notice Two markets deploy two independent blacklists (distinct owners). Updating one — local blacklist OR
    ///         sanctions list — has zero effect on the other, in either direction.
    function test_MultipleMarkets_HaveIndependentBlacklists() external {
        // Two markets each stand up their own blacklist under their own owner
        RoycoBlacklist marketABlacklist = new RoycoBlacklist(OWNER, address(0), new address[](0));
        RoycoBlacklist marketBBlacklist = new RoycoBlacklist(OWNER_TWO, address(0), new address[](0));
        assertTrue(address(marketABlacklist) != address(marketBBlacklist), "each market gets a distinct blacklist instance");

        // Market A blacklists FLAGGED — only A screens it; B is untouched
        vm.prank(OWNER);
        marketABlacklist.blacklistAccounts(_one(FLAGGED));
        assertTrue(marketABlacklist.isBlacklisted(FLAGGED), "market A screens its own blacklisted account");
        assertFalse(marketBBlacklist.isBlacklisted(FLAGGED), "market B is unaffected by market A's blacklist update");

        // Market B blacklists a different account — only B screens it; A is untouched
        vm.prank(OWNER_TWO);
        marketBBlacklist.blacklistAccounts(_one(CLEAN));
        assertTrue(marketBBlacklist.isBlacklisted(CLEAN), "market B screens its own blacklisted account");
        assertFalse(marketABlacklist.isBlacklisted(CLEAN), "market A is unaffected by market B's blacklist update");

        // Market A wires a sanctions list — market B's sanctions configuration is unchanged
        MockSanctionsList sanctions = new MockSanctionsList();
        sanctions.setSanctioned(SANCTIONED, true);
        vm.prank(OWNER);
        marketABlacklist.setSanctionsList(address(sanctions));
        assertEq(marketABlacklist.getSanctionsList(), address(sanctions), "market A wires its own sanctions list");
        assertEq(marketBBlacklist.getSanctionsList(), address(0), "market B's sanctions list is unaffected");
        assertTrue(marketABlacklist.isBlacklisted(SANCTIONED), "market A screens the sanctioned account");
        assertFalse(marketBBlacklist.isBlacklisted(SANCTIONED), "market B does not screen the sanctioned account");
    }

    /// @notice A market owner has no authority over another market's blacklist — ownership is per-instance
    function test_RevertIf_OneMarketOwnerUpdatesAnothersBlacklist() external {
        RoycoBlacklist marketABlacklist = new RoycoBlacklist(OWNER, address(0), new address[](0));
        RoycoBlacklist marketBBlacklist = new RoycoBlacklist(OWNER_TWO, address(0), new address[](0));

        // Market A's owner cannot mutate market B's blacklist
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        marketBBlacklist.blacklistAccounts(_one(FLAGGED));

        // ...and vice versa
        vm.prank(OWNER_TWO);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER_TWO));
        marketABlacklist.blacklistAccounts(_one(FLAGGED));
    }
}
