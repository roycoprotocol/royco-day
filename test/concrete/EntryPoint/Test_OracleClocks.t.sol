// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { ChainlinkOracleClock } from "../../../src/entrypoint/clock/ChainlinkOracleClock.sol";
import { OracleCheckpointClockBase } from "../../../src/entrypoint/clock/base/OracleCheckpointClockBase.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockCheckpointClock } from "../../mocks/MockCheckpointClock.sol";
import { MockValueSource } from "../../mocks/MockValueSource.sol";

/**
 * @title Test_OracleClocks
 * @notice Unit-pins both oracle clock implementations: the Chainlink (compatible) passthrough clock and the checkpoint
 *         clock's change-detection semantics (seeding, thresholds, the zero-value edge, and read-failure behavior)
 * @dev The load-bearing property for the entry point's execution gate is that a clock NEVER advances without an
 *      observed source update — a falsely advancing clock would open the gate without new information
 */
contract Test_OracleClocks is Test {
    MockAggregatorV3 internal feed;
    MockValueSource internal source;

    function setUp() public {
        vm.warp(1_000_000);
        feed = new MockAggregatorV3(8, 1e8);
        source = new MockValueSource(1e18);
    }

    // ---------------------------------------------------------------------
    // ChainlinkOracleClock
    // ---------------------------------------------------------------------

    function test_chainlinkClock_passesThroughFeedUpdatedAt() public {
        ChainlinkOracleClock clock = new ChainlinkOracleClock(address(feed));
        feed.setUpdatedAt(123_456);
        assertEq(clock.poke(), 123_456, "the clock must report the feed's own update timestamp");

        // The oracle network timestamps its own updates: a new push moves the clock, nothing else does
        feed.setUpdatedAt(123_999);
        assertEq(clock.poke(), 123_999, "a feed push must advance the clock");
    }

    function test_chainlinkClock_revertsOnNullOracle() public {
        vm.expectRevert(ChainlinkOracleClock.NULL_ADDRESS.selector);
        new ChainlinkOracleClock(address(0));
    }

    // ---------------------------------------------------------------------
    // OracleCheckpointClockBase — construction
    // ---------------------------------------------------------------------

    function test_checkpointClock_constructorSeedsFirstCheckpoint() public {
        MockCheckpointClock clock = new MockCheckpointClock(address(source), 0);
        assertEq(clock.lastValue(), 1e18, "the constructor must checkpoint the source's current value");
        assertEq(clock.lastUpdatedAt(), uint32(block.timestamp), "the constructor must checkpoint the deployment time");
    }

    function test_checkpointClock_constructionFailsLoudlyOnBrokenSource() public {
        // The seed read is the config validation: a clock over a broken source must never deploy silently
        source.setRevertMode(true);
        vm.expectRevert("MockValueSource: revert mode");
        new MockCheckpointClock(address(source), 0);
    }

    // ---------------------------------------------------------------------
    // OracleCheckpointClockBase — change detection
    // ---------------------------------------------------------------------

    function test_checkpointClock_unchangedValueNeverAdvances() public {
        MockCheckpointClock clock = new MockCheckpointClock(address(source), 0);
        uint32 seededAt = clock.lastUpdatedAt();

        vm.warp(block.timestamp + 30 days);
        assertEq(clock.poke(), seededAt, "an unchanged value must never advance the clock, however much time passes");
        assertEq(clock.lastUpdatedAt(), seededAt, "no checkpoint may be written for an unchanged value");
    }

    function test_checkpointClock_zeroThresholdCountsAnyChange() public {
        MockCheckpointClock clock = new MockCheckpointClock(address(source), 0);

        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18 + 1);
        vm.expectEmit(address(clock));
        emit OracleCheckpointClockBase.Checkpointed(1e18 + 1, uint32(block.timestamp));
        assertEq(clock.poke(), uint32(block.timestamp), "a one-wei change must checkpoint under a zero threshold");
        assertEq(clock.lastValue(), 1e18 + 1, "the checkpointed value must track the source");
    }

    function test_checkpointClock_thresholdGatesSubDeviationChanges() public {
        // 1% deviation threshold over a 1e18 checkpoint
        MockCheckpointClock clock = new MockCheckpointClock(address(source), 0.01e18);
        uint32 seededAt = clock.lastUpdatedAt();

        // A 0.99% move must NOT checkpoint (drift stays the forfeiture mechanism's job)
        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18 + 0.0099e18);
        assertEq(clock.poke(), seededAt, "a sub-threshold move must not advance the clock");

        // A 1% move from the CHECKPOINT (not from the last observation) must checkpoint
        source.setValue(1e18 + 0.01e18);
        assertEq(clock.poke(), uint32(block.timestamp), "a threshold-exact move must advance the clock");
        assertEq(clock.lastValue(), 1e18 + 0.01e18, "the checkpoint must move to the deviated value");
    }

    function test_checkpointClock_downwardDeviationCountsSymmetrically() public {
        MockCheckpointClock clock = new MockCheckpointClock(address(source), 0.01e18);

        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18 - 0.01e18);
        assertEq(clock.poke(), uint32(block.timestamp), "a downward deviation must count the same as an upward one");
    }

    function test_checkpointClock_changeFromZeroAlwaysCounts() public {
        source.setValue(0);
        MockCheckpointClock clock = new MockCheckpointClock(address(source), 0.01e18);

        vm.warp(block.timestamp + 1 hours);
        source.setValue(1);
        assertEq(clock.poke(), uint32(block.timestamp), "any change from a zero checkpoint must count as a full deviation");
    }

    function test_checkpointClock_missedRoundTripStaysConservative() public {
        MockCheckpointClock clock = new MockCheckpointClock(address(source), 0);
        uint32 seededAt = clock.lastUpdatedAt();

        // The value changes and reverts with nobody poking in between: the round trip is unobservable, and the
        // clock must NOT advance — the failure mode is conservative (the gate stays shut), never a false open
        vm.warp(block.timestamp + 1 hours);
        source.setValue(2e18);
        source.setValue(1e18);
        assertEq(clock.poke(), seededAt, "an unobserved round trip must not advance the clock");
    }

    function test_checkpointClock_pokeIsPermissionless() public {
        MockCheckpointClock clock = new MockCheckpointClock(address(source), 0);

        vm.warp(block.timestamp + 1 hours);
        source.setValue(2e18);
        vm.prank(makeAddr("ANYONE"));
        assertEq(clock.poke(), uint32(block.timestamp), "any caller must be able to poke the clock");
    }

    function test_checkpointClock_pokeBubblesSourceFailure() public {
        MockCheckpointClock clock = new MockCheckpointClock(address(source), 0);
        source.setRevertMode(true);
        vm.expectRevert("MockValueSource: revert mode");
        clock.poke();
    }
}
