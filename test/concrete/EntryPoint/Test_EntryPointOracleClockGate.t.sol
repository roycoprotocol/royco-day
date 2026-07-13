// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ChainlinkOracleClock } from "../../../src/entrypoint/clock/ChainlinkOracleClock.sol";
import { MockCheckpointClock } from "../../mocks/MockCheckpointClock.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockValueSource } from "../../mocks/MockValueSource.sol";
import { EntryPointTestBase } from "../../utils/EntryPointTestBase.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";

/**
 * @title Test_EntryPointOracleClockGate
 * @notice The oracle-clock execution gate: a request queued against a tranche with an oracle clock can only execute
 *         once the clock has observed at least one oracle update AFTER the request, on top of the minimum delay —
 *         so execution always happens at max(request + delay, first post-request update)
 * @dev The gate closes the one hole a pure time delay leaves: with deviation/heartbeat-driven oracles, a request can
 *      mature before the next update lands and execute at the same stale mark it was requested at, ahead of a
 *      predictable update. Requiring one observed update inside the request lifecycle puts that update inside the
 *      forfeiture window. The delay floor remains as the defense against induced updates
 */
contract Test_EntryPointOracleClockGate is EntryPointTestBase {
    uint256 internal stUnit;
    ChainlinkOracleClock internal chainlinkClock;

    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        stUnit = 10 ** uint256(cell.stAsset.decimals);
        _seedMarket(100 * stUnit, 50 * stUnit);
        _deployEntryPoint();
        // The market's Chainlink feed is the steppy pricing layer for every tranche in this kernel family
        chainlinkClock = new ChainlinkOracleClock(address(priceFeed));
    }

    /// @dev Rewrites all three tranche configs with the specified oracle clock (everything else unchanged)
    function _setOracleClock(address _clock) internal {
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        for (uint256 i = 0; i < configs.length; ++i) {
            configs[i].oracleClock = _clock;
        }
        vm.prank(ENTRY_POINT_ADMIN);
        entryPoint.modifyTrancheConfigs(tranches, configs);
    }

    // ---------------------------------------------------------------------
    // Request-time observation
    // ---------------------------------------------------------------------

    function test_request_snapshotsClockAtRequestTime() public {
        _setOracleClock(address(chainlinkClock));
        uint32 feedUpdatedAt = chainlinkClock.poke();
        assertGt(feedUpdatedAt, 0, "the fixture feed must carry a nonzero update timestamp");

        (uint256 depositNonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        assertEq(
            entryPoint.getDepositRequest(USER_A, depositNonce).baseRequest.oracleClockSnapshot,
            feedUpdatedAt,
            "the deposit request must snapshot the clock's request-time observation"
        );

        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 redemptionNonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        assertEq(
            entryPoint.getRedemptionRequest(USER_A, redemptionNonce).baseRequest.oracleClockSnapshot,
            feedUpdatedAt,
            "the redemption request must snapshot the clock's request-time observation"
        );
    }

    function test_request_withoutClock_snapshotsZero() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        assertEq(entryPoint.getDepositRequest(USER_A, nonce).baseRequest.oracleClockSnapshot, 0, "no clock must mean a zero snapshot");
    }

    // ---------------------------------------------------------------------
    // The gate: matured requests stay blocked until the oracle updates
    // ---------------------------------------------------------------------

    function test_maturedDepositRequest_blockedUntilOracleUpdates() public {
        _setOracleClock(address(chainlinkClock));
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        // The delay elapses but the oracle never pushes: the mark is the same one the request was placed at
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.ORACLE_CLOCK_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        // The oracle pushes: the post-request update is now priced into the mark, and execution opens
        priceFeed.setUpdatedAt(block.timestamp);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "execution must open once the oracle has updated");
    }

    function test_maturedRedemptionRequest_blockedUntilOracleUpdates() public {
        _setOracleClock(address(chainlinkClock));
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);

        vm.warp(block.timestamp + DEFAULT_REDEMPTION_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.ORACLE_CLOCK_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);

        priceFeed.setUpdatedAt(block.timestamp);
        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);
        assertGt(toUint256(claims.nav), 0, "execution must open once the oracle has updated");
    }

    function test_updateBeforeDelay_delayFloorStillBinds() public {
        _setOracleClock(address(chainlinkClock));
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        // The oracle updates immediately (or is induced to): the gate opens but the delay floor must still hold,
        // otherwise inducing an update would collapse the queue into a spot market
        vm.warp(block.timestamp + 10);
        priceFeed.setUpdatedAt(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.INVALID_REQUEST.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));
    }

    // ---------------------------------------------------------------------
    // Request-time poke correctness (the fold-in property)
    // ---------------------------------------------------------------------

    function test_requestTimePoke_foldsPendingUnobservedChangeIntoSnapshot() public {
        // A checkpoint clock over a pull source: changes are only observed when someone pokes
        MockValueSource source = new MockValueSource(1e18);
        MockCheckpointClock checkpointClock = new MockCheckpointClock(address(source), 0);
        _setOracleClock(address(checkpointClock));

        // The source changes BEFORE the request with nobody poking: that change is already priced into the
        // request-time mark and known to the requester, so it must NOT be able to satisfy the gate
        source.setValue(1.1e18);
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        assertEq(
            entryPoint.getDepositRequest(USER_A, nonce).baseRequest.oracleClockSnapshot,
            uint32(block.timestamp),
            "the request-time poke must fold the pending change into the snapshot"
        );

        // The delay elapses with no FURTHER change: still blocked — the pre-request change does not count
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.ORACLE_CLOCK_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        // A genuine post-request change opens the gate: the execution-time poke observes it in the same
        // transaction, and the fresh value is priced into the very mark the execution settles at
        source.setValue(1.2e18);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "a post-request change observed at execution time must open the gate");
    }

    // ---------------------------------------------------------------------
    // Configuration transitions and escapes
    // ---------------------------------------------------------------------

    function test_nullClock_isPureDelayMode() public {
        // Default configs carry no clock: the delay alone gates execution, with no oracle-update requirement
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "a clockless tranche must execute on the delay alone");
    }

    function test_adminZeroingClock_degradesInFlightRequestsToPureDelay() public {
        _setOracleClock(address(chainlinkClock));
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        _setOracleClock(address(0));

        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "zeroing the clock must degrade in-flight requests to pure-delay gating");
    }

    function test_adminEnablingClockMidFlight_doesNotGatePriorRequests() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        _setOracleClock(address(chainlinkClock));

        // The request predates the clock (zero snapshot): it cannot be held to an observation it never made
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "requests placed before the clock was set must stay delay-gated only");
    }

    function test_cancellation_isUngatedWhileExecutionIsBlocked() public {
        _setOracleClock(address(chainlinkClock));
        uint256 amount = 10 * stUnit;
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), amount, USER_A, 0);

        // Matured but gate-blocked: the escrow must still be recoverable — the gate guards entry, never exit
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        uint256 balanceBefore = stJtVault.balanceOf(USER_A);
        _cancelDeposit(USER_A, nonce, USER_A);
        assertEq(stJtVault.balanceOf(USER_A) - balanceBefore, amount, "cancellation must return the escrow while the gate is shut");
    }

    function test_blockedRequest_poisonsBatchLikeAnUnmaturedOne() public {
        _setOracleClock(address(chainlinkClock));
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        address[] memory users = new address[](1);
        users[0] = USER_A;
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = nonce;
        TRANCHE_UNIT[] memory amounts = new TRANCHE_UNIT[](1);
        amounts[0] = toTrancheUnits(type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.ORACLE_CLOCK_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposits(users, nonces, amounts);
    }
}
