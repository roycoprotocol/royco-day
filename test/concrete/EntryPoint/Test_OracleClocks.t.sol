// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test, stdError } from "../../../lib/forge-std/src/Test.sol";
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
 *         clock's change-detection semantics (baseline recording, thresholds, the zero-value edge, and read-failure behavior)
 * @dev The load-bearing property for the entry point's execution gate is that a clock NEVER reports a timestamp without
 *      a genuine observed source update behind it — a manufactured timestamp would open the gate without new information,
 *      so initialization records the baseline value and stamps nothing
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

    function test_chainlinkClock_oversizedUpdatedAtFailsLoudly() public {
        // A garbage timestamp past uint32 must revert, never truncate: a truncated future time could masquerade
        // as a past one and slip the entry point's fail-shut future-timestamp check
        ChainlinkOracleClock clock = new ChainlinkOracleClock(address(feed));
        feed.setUpdatedAt(uint256(type(uint32).max) + 1 + block.timestamp);
        vm.expectRevert();
        clock.poke();
    }

    function test_chainlinkClock_describesViaTheUnderlyingFeed() public {
        ChainlinkOracleClock clock = new ChainlinkOracleClock(address(feed));
        assertEq(
            clock.description(),
            string(abi.encodePacked("Oracle clock reporting the update timestamps of the following feed: ", feed.description())),
            "the clock must compose its description over the underlying feed's"
        );
    }

    function test_chainlinkClock_constructionIsUncheckedPassthrough() public {
        // The clock is a stateless passthrough with no construction validation: a broken oracle fails loudly at
        // the first poke instead (the entry point pokes at configuration and request time), and a zero update
        // timestamp is reported as-is — the execution gate treats it as no-update-yet and conservatively holds shut
        ChainlinkOracleClock nullClock = new ChainlinkOracleClock(address(0));
        vm.expectRevert();
        nullClock.poke();

        MockAggregatorV3 deadFeed = new MockAggregatorV3(8, 1e8);
        deadFeed.setUpdatedAt(0);
        ChainlinkOracleClock deadClock = new ChainlinkOracleClock(address(deadFeed));
        assertEq(deadClock.poke(), 0, "a dead feed must read as no-update-yet, not revert");
    }

    // ---------------------------------------------------------------------
    // OracleCheckpointClockBase — initialization and administration
    // ---------------------------------------------------------------------

    function test_checkpointClock_initializeRecordsBaselineWithoutStamping() public {
        MockCheckpointClock clock = _deployCheckpointClock(0);
        assertEq(_lastValue(clock), 1e18, "initialization must record the source's current value as the baseline");
        assertEq(_lastUpdatedAt(clock), 0, "initialization must never manufacture an update timestamp");
        assertEq(clock.poke(), 0, "the clock must report no update until its first observed deviation");
    }

    function test_checkpointClock_notLiveUntilFirstDeviation_thenStampsHonestly() public {
        MockCheckpointClock clock = _deployCheckpointClock(0);

        // Time alone must never make the clock live: only an observed source update may produce a timestamp
        vm.warp(block.timestamp + 30 days);
        assertEq(clock.poke(), 0, "an unchanged source must leave the clock unstamped, however much time passes");

        // The first genuine deviation is the first checkpoint, stamped at its observation time
        source.setValue(2e18);
        assertEq(clock.poke(), uint32(block.timestamp), "the first observed deviation must be the first stamped update");
    }

    function test_checkpointClock_valueBeyondUint160FailsLoudly() public {
        // The packed checkpoint stores the value in 160 bits: an unrealistically large source must fail loudly, never truncate
        MockCheckpointClock clock = _deployCheckpointClock(0);
        source.setValue(uint256(type(uint160).max) + 1);
        vm.expectRevert();
        clock.poke();
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

        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18 - 0.5e18);
        assertEq(clock.poke(), 0, "a 50% move must not advance the clock under the maximal threshold");
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

        // A 1% move is sub-threshold under the deployed configuration
        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18 + 0.01e18);
        assertEq(clock.poke(), 0, "a sub-threshold move must not advance the clock");

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

        // Establish a live checkpoint, then hold the value still
        vm.warp(block.timestamp + 1 hours);
        source.setValue(2e18);
        uint32 checkpointedAt = clock.poke();
        assertEq(checkpointedAt, uint32(block.timestamp), "the fixture must establish a live checkpoint");

        vm.warp(block.timestamp + 30 days);
        assertEq(clock.poke(), checkpointedAt, "an unchanged value must never advance the clock, however much time passes");
        assertEq(_lastUpdatedAt(clock), checkpointedAt, "no checkpoint may be written for an unchanged value");
    }

    function test_checkpointClock_zeroThresholdCountsAnyChange() public {
        MockCheckpointClock clock = _deployCheckpointClock(0);

        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18 + 1);
        assertEq(clock.poke(), uint32(block.timestamp), "a one-wei change must checkpoint under a zero threshold");
        assertEq(_lastValue(clock), 1e18 + 1, "the checkpointed value must track the source");
    }

    function test_checkpointClock_thresholdGatesSubDeviationChanges() public {
        // 1% deviation threshold over a 1e18 checkpoint
        MockCheckpointClock clock = _deployCheckpointClock(0.01e18);

        // A 0.99% move must NOT checkpoint (drift stays the forfeiture mechanism's job)
        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18 + 0.0099e18);
        assertEq(clock.poke(), 0, "a sub-threshold move must not advance the clock");

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

    function test_checkpointClock_zeroCheckpointWithThreshold_failsShutOnEveryPoke() public {
        // A relative deviation from a zero checkpoint is undefined: under a nonzero threshold the deviation check
        // fails shut (division panic) on every poke, so a zero-baselined clock can never stamp a manufactured
        // timestamp — the tranche's queue reverts loudly until the clock is rotated
        source.setValue(0);
        MockCheckpointClock clock = _deployCheckpointClock(0.01e18);
        assertEq(clock.getOracleCheckpointClockState().lastUpdatedAt, 0, "a zero baseline must not stamp at initialization");

        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18);
        vm.expectRevert(stdError.divisionError);
        clock.poke();
    }

    function test_checkpointClock_zeroCheckpointWithZeroThreshold_stampsOnFirstNonZeroRead() public {
        // A zero threshold counts any change, so a zero baseline resolves on the first nonzero observation
        source.setValue(0);
        MockCheckpointClock clock = _deployCheckpointClock(0);

        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18);
        assertEq(clock.poke(), uint32(block.timestamp), "the first nonzero observation must checkpoint under a zero threshold");
    }

    function test_checkpointClock_midLifeZeroCrossing_dropCheckpointsThenFailsShut() public {
        // A mid-life wipeout checkpoints the drop to zero as a full deviation, but the zero checkpoint then makes
        // every further thresholded deviation check fail shut (division panic): the clock stays bricked — loudly —
        // until rotated, rather than ever stamping off an undefined relative base
        MockCheckpointClock clock = _deployCheckpointClock(0.01e18);

        vm.warp(block.timestamp + 1 hours);
        source.setValue(0);
        assertEq(clock.poke(), uint32(block.timestamp), "the drop to zero must checkpoint as a full deviation");
        assertEq(_lastValue(clock), 0, "the checkpoint must move to zero");

        source.setValue(1e18);
        vm.expectRevert(stdError.divisionError);
        clock.poke();
    }

    function test_checkpointClock_missedRoundTripStaysConservative() public {
        MockCheckpointClock clock = _deployCheckpointClock(0);

        // The value changes and reverts with nobody poking in between: the round trip is unobservable, and the
        // clock must NOT advance — the failure mode is conservative (the gate stays shut), never a false open
        vm.warp(block.timestamp + 1 hours);
        source.setValue(2e18);
        source.setValue(1e18);
        assertEq(clock.poke(), 0, "an unobserved round trip must not advance the clock");
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
