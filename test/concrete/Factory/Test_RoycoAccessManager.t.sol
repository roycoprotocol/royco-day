// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test, Vm } from "../../../lib/forge-std/src/Test.sol";
import { ADMIN_ROLE, ADMIN_ORACLE_ROLE } from "../../../src/factory/Roles.sol";
import { RoycoAccessManager } from "../../../src/factory/RoycoAccessManager.sol";
import { IRoycoAccessManager } from "../../../src/interfaces/factory/IRoycoAccessManager.sol";

/**
 * @title Test_RoycoAccessManager
 * @notice The access manager's one addition over OpenZeppelin: a permanent record of every target it has ever
 *         configured, which is what lets the factory's gatekeeper tell a contract the protocol just created apart from
 *         one that already existed
 * @dev The record must be complete across EVERY target-scoped write, whoever the caller is. If any path could configure
 *      a target without recording it, that target would still read as fresh and remain open to a market deployment
 */
contract Test_RoycoAccessManager is Test {
    RoycoAccessManager internal am;

    address internal TARGET = makeAddr("TARGET");
    address internal STRANGER = makeAddr("STRANGER");

    bytes4 internal constant SELECTOR = 0xaaaaaaaa;

    function setUp() public {
        am = new RoycoAccessManager(address(this));
    }

    function _selectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = SELECTOR;
    }

    // ---------------------------------------------------------------------
    // Every target-scoped write records the target
    // ---------------------------------------------------------------------

    function test_wasEverConfigured_startsFalseForEveryAddress() public view {
        assertFalse(am.wasEverConfigured(TARGET), "an untouched target must read as never configured");
        assertFalse(am.wasEverConfigured(address(am)), "the access manager holds no self target-function configuration");
        assertFalse(am.wasEverConfigured(address(0)), "the zero address must read as never configured");
    }

    function test_setTargetFunctionRole_recordsTheTarget() public {
        am.setTargetFunctionRole(TARGET, _selectors(), ADMIN_ORACLE_ROLE);
        assertTrue(am.wasEverConfigured(TARGET), "binding a selector must record the target");
    }

    /// @dev A target carrying an admin delay is configured even though no selector has been bound
    function test_setTargetAdminDelay_recordsTheTarget() public {
        am.setTargetAdminDelay(TARGET, 1 days);
        assertTrue(am.wasEverConfigured(TARGET), "setting an admin delay must record the target");
    }

    /// @dev Likewise for opening or closing a target
    function test_setTargetClosed_recordsTheTarget() public {
        am.setTargetClosed(TARGET, true);
        assertTrue(am.wasEverConfigured(TARGET), "closing a target must record the target");
    }

    /// @notice The record announces only the FIRST touch, so the event marks the transition rather than every write
    function test_setTargetFunctionRole_emitsOnlyOnTheFirstConfiguration() public {
        vm.expectEmit(true, false, false, false, address(am));
        emit IRoycoAccessManager.TargetConfiguredAtGenesis(TARGET);
        am.setTargetFunctionRole(TARGET, _selectors(), ADMIN_ORACLE_ROLE);

        // A second write must not re-announce it (getRecordedLogs drains the buffer, so read it exactly once)
        vm.recordLogs();
        am.setTargetFunctionRole(TARGET, _selectors(), ADMIN_ROLE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IRoycoAccessManager.TargetConfiguredAtGenesis.selector, "the first-configuration event must not fire twice for one target"
            );
        }
    }

    /**
     * @notice The record is monotonic: there is no path back to unconfigured
     * @dev Deliberate. A clearing function would hand back exactly the capability the record exists to remove, since
     *      anyone able to clear it could re-open an existing contract to a market deployment
     */
    function test_wasEverConfigured_isMonotonicAcrossEveryWrite() public {
        am.setTargetFunctionRole(TARGET, _selectors(), ADMIN_ORACLE_ROLE);
        assertTrue(am.wasEverConfigured(TARGET), "recorded on the first write");

        // Unbinding the selector (rebinding to ADMIN_ROLE), closing, then re-opening the target all leave it recorded
        am.setTargetFunctionRole(TARGET, _selectors(), ADMIN_ROLE);
        am.setTargetClosed(TARGET, true);
        am.setTargetClosed(TARGET, false);
        am.setTargetAdminDelay(TARGET, 0);
        assertTrue(am.wasEverConfigured(TARGET), "no sequence of writes may return a target to unconfigured");
    }
}
