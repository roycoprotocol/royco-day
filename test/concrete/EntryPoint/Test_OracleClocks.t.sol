// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ChainlinkOracleClock } from "../../../src/entrypoint/clock/ChainlinkOracleClock.sol";
import { OracleCheckpointClockBase } from "../../../src/entrypoint/clock/base/OracleCheckpointClockBase.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
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
    AccessManager internal accessManager;
    MockAggregatorV3 internal feed;
    MockValueSource internal source;

    function setUp() public {
        vm.warp(1_000_000);
        accessManager = new AccessManager(address(this));
        feed = new MockAggregatorV3(8, 1e8);
        source = new MockValueSource(1e18);
    }

    /// @dev Deploys a checkpoint clock over the source behind an ERC1967 proxy, mirroring the production pattern
    function _deployCheckpointClock(uint256 _minDeviationWAD) internal returns (MockCheckpointClock) {
        address implementation = address(new MockCheckpointClock(address(source)));
        return MockCheckpointClock(
            address(new ERC1967Proxy(implementation, abi.encodeCall(MockCheckpointClock.initialize, (address(accessManager), _minDeviationWAD))))
        );
    }

    function _lastValue(MockCheckpointClock _clock) internal view returns (uint256) {
        return _clock.getOracleCheckpointClockState().lastValue;
    }

    function _lastUpdatedAt(MockCheckpointClock _clock) internal view returns (uint32) {
        return _clock.getOracleCheckpointClockState().lastUpdatedAt;
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

    function test_chainlinkClock_describesViaTheUnderlyingFeed() public {
        ChainlinkOracleClock clock = new ChainlinkOracleClock(address(feed));
        assertEq(
            clock.description(),
            string(abi.encodePacked("Oracle clock reporting the update timestamps of the following feed: ", feed.description())),
            "the clock must compose its description over the underlying feed's"
        );
    }

    function test_chainlinkClock_constructionRequiresALiveOracle() public {
        // The construction poke is the config validation: a null oracle fails the read outright
        vm.expectRevert();
        new ChainlinkOracleClock(address(0));

        // A feed reporting a zero update timestamp is not a valid clock source
        MockAggregatorV3 deadFeed = new MockAggregatorV3(8, 1e8);
        deadFeed.setUpdatedAt(0);
        vm.expectRevert(ChainlinkOracleClock.INVALID_ORACLE.selector);
        new ChainlinkOracleClock(address(deadFeed));
    }

    // ---------------------------------------------------------------------
    // OracleCheckpointClockBase — initialization and administration
    // ---------------------------------------------------------------------

    function test_checkpointClock_initializeSeedsFirstCheckpoint() public {
        MockCheckpointClock clock = _deployCheckpointClock(0);
        assertEq(_lastValue(clock), 1e18, "initialization must checkpoint the source's current value");
        assertEq(_lastUpdatedAt(clock), uint32(block.timestamp), "initialization must checkpoint the deployment time");
    }

    function test_checkpointClock_initializeFailsLoudlyOnBrokenSource() public {
        // The seed read is the config validation: a clock over a broken source must never deploy silently
        source.setRevertMode(true);
        address implementation = address(new MockCheckpointClock(address(source)));
        vm.expectRevert("MockValueSource: revert mode");
        new ERC1967Proxy(implementation, abi.encodeCall(MockCheckpointClock.initialize, (address(accessManager), 0)));
    }

    function test_checkpointClock_initializeRejectsFullDeviationThreshold() public {
        // A threshold at or above 100% would mute all downward updates (a downward deviation caps at exactly WAD)
        address implementation = address(new MockCheckpointClock(address(source)));
        vm.expectRevert(OracleCheckpointClockBase.INVALID_MIN_DEVIATION_WAD.selector);
        new ERC1967Proxy(implementation, abi.encodeCall(MockCheckpointClock.initialize, (address(accessManager), WAD)));
    }

    function test_checkpointClock_acceptsMaximalThreshold() public {
        // WAD - 1 is the maximal legal threshold: initialization must accept it, and a full downward move
        // (a 100% deviation, the largest possible) must still checkpoint under it
        MockCheckpointClock clock = _deployCheckpointClock(1e18 - 1);
        uint32 seededAt = _lastUpdatedAt(clock);

        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18 - 0.5e18);
        assertEq(clock.poke(), seededAt, "a 50% move must not advance the clock under the maximal threshold");
        source.setValue(0);
        assertEq(clock.poke(), uint32(block.timestamp), "a full downward move must advance the clock under the maximal threshold");
    }

    function test_checkpointClock_setMinDeviationWAD_isRestricted() public {
        MockCheckpointClock clock = _deployCheckpointClock(0);
        address anyone = makeAddr("ANYONE");
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, anyone));
        clock.setMinDeviationWAD(0.01e18);
    }

    function test_checkpointClock_setMinDeviationWAD_updatesGatingBehavior() public {
        MockCheckpointClock clock = _deployCheckpointClock(0.05e18);
        uint32 seededAt = _lastUpdatedAt(clock);

        // A 1% move is sub-threshold uMinDeviationUpdatednfiguration
        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18 + 0.01e18);
        assertEq(clock.poke(), seededAt, "a sub-threshold move must not advance the clock");

        // Tightening the threshold to 1% makes the same deviation count
        vm.expectEmit(address(clock));
        emit OracleCheckpointClockBase.MinDeviationUpdated(0.01e18);
        clock.setMinDeviationWAD(0.01e18);
        assertEq(clock.getOracleCheckpointClockState().minDeviationWAD, 0.01e18, "the threshold must be updated in storage");
        assertEq(clock.poke(), uint32(block.timestamp), "the same deviation must checkpoint under the tightened threshold");
    }

    // ---------------------------------------------------------------------
    // OracleCheckpointClockBase — change detection
    // ---------------------------------------------------------------------

    function test_checkpointClock_unchangedValueNeverAdvances() public {
        MockCheckpointClock clock = _deployCheckpointClock(0);
        uint32 seededAt = _lastUpdatedAt(clock);

        vm.warp(block.timestamp + 30 days);
        assertEq(clock.poke(), seededAt, "an unchanged value must never advance the clock, however much time passes");
        assertEq(_lastUpdatedAt(clock), seededAt, "no checkpoint may be written for an unchanged value");
    }

    function test_checkpointClock_zeroThresholdCountsAnyChange() public {
        MockCheckpointClock clock = _deployCheckpointClock(0);

        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18 + 1);
        vm.expectEmit(address(clock));
        emit OracleCheckpointClockBase.Checkpointed(1e18 + 1);
        assertEq(clock.poke(), uint32(block.timestamp), "a one-wei change must checkpoint under a zero threshold");
        assertEq(_lastValue(clock), 1e18 + 1, "the checkpointed value must track the source");
    }

    function test_checkpointClock_thresholdGatesSubDeviationChanges() public {
        // 1% deviation threshold over a 1e18 checkpoint
        MockCheckpointClock clock = _deployCheckpointClock(0.01e18);
        uint32 seededAt = _lastUpdatedAt(clock);

        // A 0.99% move must NOT checkpoint (drift stays the forfeiture mechanism's job)
        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18 + 0.0099e18);
        assertEq(clock.poke(), seededAt, "a sub-threshold move must not advance the clock");

        // A 1% move from the CHECKPOINT (not from the last observation) must checkpoint
        source.setValue(1e18 + 0.01e18);
        assertEq(clock.poke(), uint32(block.timestamp), "a threshold-exact move must advance the clock");
        assertEq(_lastValue(clock), 1e18 + 0.01e18, "the checkpoint must move to the deviated value");
    }

    function test_checkpointClock_downwardDeviationCountsSymmetrically() public {
        MockCheckpointClock clock = _deployCheckpointClock(0.01e18);

        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18 - 0.01e18);
        assertEq(clock.poke(), uint32(block.timestamp), "a downward deviation must count the same as an upward one");
    }

    function test_checkpointClock_initializeRejectsZeroValueSource() public {
        // A source reading zero cannot seed a live clock: initialization must fail loudly rather than deploy not-live
        source.setValue(0);
        address implementation = address(new MockCheckpointClock(address(source)));
        vm.expectRevert(OracleCheckpointClockBase.INVALID_ORACLE.selector);
        new ERC1967Proxy(implementation, abi.encodeCall(MockCheckpointClock.initialize, (address(accessManager), 0.01e18)));
    }

    function test_checkpointClock_changeFromZeroAlwaysCounts() public {
        // The source round-trips through zero mid-life: the drop checkpoints as a full deviation, and any change
        // from the zero checkpoint counts as a full deviation regardless of the threshold
        MockCheckpointClock clock = _deployCheckpointClock(0.01e18);

        vm.warp(block.timestamp + 1 hours);
        source.setValue(0);
        clock.poke();
        source.setValue(1);
        assertEq(clock.poke(), uint32(block.timestamp), "any change from a zero checkpoint must count as a full deviation");
        assertEq(_lastValue(clock), 1, "the checkpoint must move off zero");
    }

    function test_checkpointClock_missedRoundTripStaysConservative() public {
        MockCheckpointClock clock = _deployCheckpointClock(0);
        uint32 seededAt = _lastUpdatedAt(clock);

        // The value changes and reverts with nobody poking in between: the round trip is unobservable, and the
        // clock must NOT advance — the failure mode is conservative (the gate stays shut), never a false open
        vm.warp(block.timestamp + 1 hours);
        source.setValue(2e18);
        source.setValue(1e18);
        assertEq(clock.poke(), seededAt, "an unobserved round trip must not advance the clock");
    }

    function test_checkpointClock_pokeIsPermissionless() public {
        MockCheckpointClock clock = _deployCheckpointClock(0);

        vm.warp(block.timestamp + 1 hours);
        source.setValue(2e18);
        vm.prank(makeAddr("ANYONE"));
        assertEq(clock.poke(), uint32(block.timestamp), "any caller must be able to poke the clock");
    }

    function test_checkpointClock_pokeBubblesSourceFailure() public {
        MockCheckpointClock clock = _deployCheckpointClock(0);
        source.setRevertMode(true);
        vm.expectRevert("MockValueSource: revert mode");
        clock.poke();
    }
}
