// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ChainlinkOracleClock } from "../../../src/entrypoint/clock/ChainlinkOracleClock.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockCheckpointClock } from "../../mocks/MockCheckpointClock.sol";
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

    /// @dev Deploys a checkpoint clock over the specified source behind an ERC1967 proxy, mirroring the production pattern
    function _deployCheckpointClock(address _source, uint256 _minDeviationWAD) internal returns (MockCheckpointClock) {
        address implementation = address(new MockCheckpointClock(_source));
        return MockCheckpointClock(
            address(new ERC1967Proxy(implementation, abi.encodeCall(MockCheckpointClock.initialize, (address(accessManager), _minDeviationWAD))))
        );
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

    function test_request_stampsQueuedAtTimestamp() public {
        _setOracleClock(address(chainlinkClock));
        (uint256 depositNonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        assertEq(
            entryPoint.getDepositRequest(USER_A, depositNonce).baseRequest.queuedAtTimestamp,
            uint32(block.timestamp),
            "the deposit request must stamp its queueing time"
        );

        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 redemptionNonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        assertEq(
            entryPoint.getRedemptionRequest(USER_A, redemptionNonce).baseRequest.queuedAtTimestamp,
            uint32(block.timestamp),
            "the redemption request must stamp its queueing time"
        );
    }

    function test_request_withoutClock_stillStampsQueuedAtTimestamp() public {
        // The stamp carries no clock semantics of its own: it is always the queueing time, clock or no clock
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        assertEq(
            entryPoint.getDepositRequest(USER_A, nonce).baseRequest.queuedAtTimestamp, uint32(block.timestamp), "no clock must not skip the stamp"
        );
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
        MockCheckpointClock checkpointClock = _deployCheckpointClock(address(source), 0);
        _setOracleClock(address(checkpointClock));

        // The source changes BEFORE the request with nobody poking: that change is already priced into the
        // request-time mark and known to the requester, so it must NOT be able to satisfy the gate
        source.setValue(1.1e18);
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        assertEq(
            checkpointClock.getOracleCheckpointClockState().lastUpdatedAt,
            uint32(block.timestamp),
            "the request-time poke must checkpoint the pending change at the queueing time, not after it"
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

    function test_adminEnablingClockMidFlight_gatesPriorRequests() public {
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        _setOracleClock(address(chainlinkClock));

        // Configuring a clock expresses the intent to price pending information before execution: requests placed
        // before the clock hold to the same gate, since the queueing stamp carries no clock lineage
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.ORACLE_CLOCK_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        // A genuine post-request update opens the pre-clock request like any other
        priceFeed.setUpdatedAt(block.timestamp);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "a post-request update must open requests placed before the clock was set");
    }

    function test_modifyTrancheConfigs_rejectsFutureReportingClock() public {
        // A clock reporting a future update timestamp would satisfy the execution gate without a genuine update:
        // the configuration must fail shut on the one half of clock honesty that is checkable on-chain
        MockAggregatorV3 feed2 = new MockAggregatorV3(8, 1e8);
        address clock = address(new ChainlinkOracleClock(address(feed2)));
        feed2.setUpdatedAt(block.timestamp + 1 days);
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        for (uint256 i = 0; i < configs.length; ++i) {
            configs[i].oracleClock = clock;
        }
        vm.expectRevert(IRoycoDayEntryPoint.ORACLE_CLOCK_IN_THE_FUTURE.selector);
        vm.prank(ENTRY_POINT_ADMIN);
        entryPoint.modifyTrancheConfigs(tranches, configs);
    }

    function test_request_rejectsFutureReportingClock() public {
        // The clock turns future-reporting after configuration (e.g. an aggregator migration to a broken feed):
        // the request-time poke must fail shut rather than queue against a clock that can falsely open the gate
        MockAggregatorV3 feed2 = new MockAggregatorV3(8, 1e8);
        feed2.setUpdatedAt(block.timestamp);
        _setOracleClock(address(new ChainlinkOracleClock(address(feed2))));
        feed2.setUpdatedAt(block.timestamp + 1 days);

        vm.expectRevert(IRoycoDayEntryPoint.ORACLE_CLOCK_IN_THE_FUTURE.selector);
        vm.prank(USER_A);
        entryPoint.requestDeposit(address(juniorTranche), toTrancheUnits(10 * stUnit), USER_A, 0);
    }

    function test_deadClock_queuesFine_executionWaitsForRevival() public {
        // The clock's feed dies after configuration (a zero update timestamp): queueing stays open — a zero reading
        // cannot weaken the gate, it conservatively holds execution shut until the feed revives with a genuine update
        MockAggregatorV3 feed2 = new MockAggregatorV3(8, 1e8);
        feed2.setUpdatedAt(block.timestamp);
        _setOracleClock(address(new ChainlinkOracleClock(address(feed2))));
        feed2.setUpdatedAt(0);

        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.ORACLE_CLOCK_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        feed2.setUpdatedAt(block.timestamp);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "the feed's revival must reopen execution");
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

    function test_updateBeforeDelay_delayFloorStillBinds_redemption() public {
        _setOracleClock(address(chainlinkClock));
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);

        // The oracle updates immediately: the gate opens but the redemption delay floor must still hold
        vm.warp(block.timestamp + 10);
        priceFeed.setUpdatedAt(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.INVALID_REQUEST.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);
    }

    function test_requestRedemption_rejectsFutureReportingClock() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        MockAggregatorV3 feed2 = new MockAggregatorV3(8, 1e8);
        feed2.setUpdatedAt(block.timestamp);
        _setOracleClock(address(new ChainlinkOracleClock(address(feed2))));
        feed2.setUpdatedAt(block.timestamp + 1 days);

        vm.expectRevert(IRoycoDayEntryPoint.ORACLE_CLOCK_IN_THE_FUTURE.selector);
        vm.prank(USER_A);
        entryPoint.requestRedemption(address(juniorTranche), shares, USER_A, 0);
    }

    // ---------------------------------------------------------------------
    // The permissionless poke surface and its tick event
    // ---------------------------------------------------------------------

    function test_pokeOracleClock_isPermissionlessAndDrivesTheGate() public {
        // A checkpoint clock over a pull source: nobody pokes it organically, so a matured request stays blocked
        MockValueSource source = new MockValueSource(1e18);
        MockCheckpointClock checkpointClock = _deployCheckpointClock(address(source), 0);
        _setOracleClock(address(checkpointClock));
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        // A post-request change lands and ANYONE drives the clock through the entry point, emitting the tick
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        source.setValue(1.1e18);
        vm.expectEmit(address(entryPoint));
        emit IRoycoDayEntryPoint.OracleClockTick(address(juniorTranche), uint32(block.timestamp));
        vm.prank(makeAddr("ANYONE"));
        uint32 lastUpdatedAt = entryPoint.pokeOracleClock(address(juniorTranche));
        assertEq(lastUpdatedAt, uint32(block.timestamp), "the poke must report the freshly checkpointed update");

        // The externally driven checkpoint satisfies the gate: execution opens without any further source change
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "an externally poked checkpoint must open the gate");
    }

    function test_pokeOracleClock_clocklessTranche_isANoOpReportingZero() public {
        // Default configs carry no clock: the poke must not revert, must move nothing, and must emit nothing
        vm.recordLogs();
        assertEq(entryPoint.pokeOracleClock(address(juniorTranche)), 0, "a clockless tranche must report a zero timestamp");
        assertEq(vm.getRecordedLogs().length, 0, "a clockless poke must emit nothing");
    }

    function test_request_emitsOracleClockTickWithFoldedTimestamp() public {
        // The request-time poke folds a pending unobserved change and announces the tick it lands on
        MockValueSource source = new MockValueSource(1e18);
        MockCheckpointClock checkpointClock = _deployCheckpointClock(address(source), 0);
        _setOracleClock(address(checkpointClock));
        source.setValue(1.1e18);

        // Fund and approve first: the emit expectation must bind to the request call itself
        uint256 amount = 10 * stUnit;
        _fundTrancheAssets(USER_A, address(juniorTranche), amount);
        vm.startPrank(USER_A);
        stJtVault.approve(address(entryPoint), amount);
        vm.expectEmit(address(entryPoint));
        emit IRoycoDayEntryPoint.OracleClockTick(address(juniorTranche), uint32(block.timestamp));
        entryPoint.requestDeposit(address(juniorTranche), toTrancheUnits(amount), USER_A, 0);
        vm.stopPrank();
    }

    function test_execution_rejectsFutureReportingClock() public {
        // The execution-gate poke is where the future check is load-bearing: a future timestamp trivially
        // satisfies the strictly-after comparison, so it must fail shut before the gate ever reads it
        _setOracleClock(address(chainlinkClock));
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        priceFeed.setUpdatedAt(block.timestamp + 1 days);

        vm.expectRevert(IRoycoDayEntryPoint.ORACLE_CLOCK_IN_THE_FUTURE.selector);
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        // The standalone poke fails shut on the same clock
        vm.expectRevert(IRoycoDayEntryPoint.ORACLE_CLOCK_IN_THE_FUTURE.selector);
        entryPoint.pokeOracleClock(address(juniorTranche));

        // An honest update reopens execution
        priceFeed.setUpdatedAt(block.timestamp);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "an honest update must reopen execution");
    }

    function test_configAndExecutionPokes_emitOracleClockTick() public {
        // The config-time poke announces the tick for each tranche it validates
        (address[] memory tranches, IRoycoDayEntryPoint.TrancheConfig[] memory configs) = _defaultTrancheConfigs();
        for (uint256 i = 0; i < configs.length; ++i) {
            configs[i].oracleClock = address(chainlinkClock);
        }
        uint32 feedUpdatedAt = chainlinkClock.poke();
        vm.expectEmit(address(entryPoint));
        emit IRoycoDayEntryPoint.OracleClockTick(tranches[0], feedUpdatedAt);
        vm.prank(ENTRY_POINT_ADMIN);
        entryPoint.modifyTrancheConfigs(tranches, configs);

        // The execution-gate poke announces the tick it opened on
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        priceFeed.setUpdatedAt(block.timestamp);
        vm.expectEmit(address(entryPoint));
        emit IRoycoDayEntryPoint.OracleClockTick(address(juniorTranche), uint32(block.timestamp));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));
    }

    // ---------------------------------------------------------------------
    // Clock rotation: no pending request may open without a genuine update
    // ---------------------------------------------------------------------

    function test_rotationToVirginClock_cannotInstantOpenPendingQueue_thenAutoResumes() public {
        // A queue pending under one clock, rotated to a freshly initialized checkpoint clock: the virgin clock's
        // baseline recording carries no update timestamp, so the rotation cannot open a single pending request —
        // the queue pauses, then auto-resumes on the new source's first genuine deviation
        _setOracleClock(address(chainlinkClock));
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        MockValueSource source = new MockValueSource(1e18);
        MockCheckpointClock virginClock = _deployCheckpointClock(address(source), 0);
        assertEq(virginClock.getOracleCheckpointClockState().lastUpdatedAt, 0, "setup: the virgin clock must carry no update timestamp");
        _setOracleClock(address(virginClock));

        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.ORACLE_CLOCK_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        // The new source's first genuine deviation is a real post-request update: the queue resumes by itself
        source.setValue(1.1e18);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "the first genuine deviation of the new source must reopen the queue");
    }

    function test_rotationToWarmClock_opensOnPostRequestDeviation() public {
        // The rotated-in clock already checkpointed a deviation AFTER the request was queued: that is a genuine
        // post-request source update, so the pending request opens immediately — correct, not a hole
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        MockValueSource source = new MockValueSource(1e18);
        MockCheckpointClock warmClock = _deployCheckpointClock(address(source), 0);
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        source.setValue(1.1e18);
        warmClock.poke();
        assertGt(warmClock.getOracleCheckpointClockState().lastUpdatedAt, 0, "setup: the warm clock must carry a post-request checkpoint");

        _setOracleClock(address(warmClock));
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "a genuine post-request deviation on the rotated-in clock must open the request");
    }

    function test_sameSecondUpdate_staysBlocked_strictInequality() public {
        // An update stamped in the very second the request queued is not provably after it: the strict inequality
        // holds the gate shut until an update lands in a strictly later second
        _setOracleClock(address(chainlinkClock));
        priceFeed.setUpdatedAt(block.timestamp);
        (uint256 nonce,) = _requestDeposit(USER_A, address(juniorTranche), 10 * stUnit, USER_A, 0);

        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.ORACLE_CLOCK_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeDeposit(USER_A, nonce, toTrancheUnits(type(uint256).max));

        priceFeed.setUpdatedAt(block.timestamp);
        uint256 sharesMinted = _executeDepositMax(USER_A, USER_A, nonce);
        assertGt(sharesMinted, 0, "a strictly later update must open the gate");
    }

    function test_adminZeroingClock_degradesInFlightRedemptionsToPureDelay() public {
        _setOracleClock(address(chainlinkClock));
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        _setOracleClock(address(0));

        vm.warp(block.timestamp + DEFAULT_REDEMPTION_DELAY + 1);
        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);
        assertGt(toUint256(claims.nav), 0, "zeroing the clock must degrade in-flight redemptions to pure-delay gating");
    }

    function test_adminEnablingClockMidFlight_gatesPriorRedemptions() public {
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);
        _setOracleClock(address(chainlinkClock));

        vm.warp(block.timestamp + DEFAULT_REDEMPTION_DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.ORACLE_CLOCK_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeRedemption(USER_A, nonce, type(uint256).max);

        priceFeed.setUpdatedAt(block.timestamp);
        AssetClaims memory claims = _executeRedemptionMax(USER_A, USER_A, nonce);
        assertGt(toUint256(claims.nav), 0, "a post-request update must open redemptions placed before the clock was set");
    }

    function test_blockedRedemption_poisonsBatchLikeAnUnmaturedOne() public {
        _setOracleClock(address(chainlinkClock));
        uint256 shares = _acquireTrancheShares(USER_A, address(juniorTranche), 10 * stUnit);
        (uint256 nonce,) = _requestRedemption(USER_A, address(juniorTranche), shares, USER_A, 0);

        vm.warp(block.timestamp + DEFAULT_REDEMPTION_DELAY + 1);
        address[] memory users = new address[](1);
        users[0] = USER_A;
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = nonce;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;

        vm.expectRevert(abi.encodeWithSelector(IRoycoDayEntryPoint.ORACLE_CLOCK_NOT_ADVANCED.selector, nonce));
        vm.prank(USER_A);
        entryPoint.executeRedemptions(users, nonces, amounts);
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
