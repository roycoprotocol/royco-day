// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test, stdError } from "../../../lib/forge-std/src/Test.sol";
import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { OracleClockBase } from "../../../src/oracle/base/clock/OracleClockBase.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockCheckpointClock } from "../../mocks/MockCheckpointClock.sol";
import { MockValueSource } from "../../mocks/MockValueSource.sol";

/**
 * @title Test_OracleClocks
 * @notice Unit-pins the checkpoint clock's change-detection semantics (baseline recording, thresholds, the
 *         zero-value edge, and read-failure behavior); the Chainlink passthrough clock shape is pinned on the
 *         collateral oracles that carry it
 * @dev The load-bearing property for the entry point's execution gate is that a clock NEVER reports a timestamp without
 *      a genuine observed source update behind it, a manufactured timestamp would open the gate without new information,
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
            address(new ERC1967Proxy(implementation, abi.encodeCall(MockCheckpointClock.initialize, (address(accessManager), _minDeviationWAD, 0))))
        );
    }

    function _lastValue(MockCheckpointClock _clock) internal view returns (uint256) {
        return _clock.getOracleClockState().lastValue;
    }

    function _lastUpdatedAt(MockCheckpointClock _clock) internal view returns (uint32) {
        return _clock.getOracleClockState().lastUpdatedAt;
    }

    // ---------------------------------------------------------------------
    // OracleClockBase: initialization and administration
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
        new ERC1967Proxy(implementation, abi.encodeCall(MockCheckpointClock.initialize, (address(accessManager), 0, 0)));
    }

    function test_checkpointClock_initializeRejectsFullDeviationThreshold() public {
        // A threshold at or above 100% would mute all downward updates (a downward deviation caps at exactly WAD)
        address implementation = address(new MockCheckpointClock(address(source)));
        vm.expectRevert(OracleClockBase.INVALID_MIN_DEVIATION_WAD.selector);
        new ERC1967Proxy(implementation, abi.encodeCall(MockCheckpointClock.initialize, (address(accessManager), WAD, 0)));
    }

    function test_checkpointClock_initializeWithAttestedCheckpointStampsIt() public {
        // An attested past update seeds the clock at initialization: rotation to a fresh clock need not re-block
        // a queue when the operator can attest to the source's true last update
        address implementation = address(new MockCheckpointClock(address(source)));
        MockCheckpointClock clock = MockCheckpointClock(
            address(
                new ERC1967Proxy(implementation, abi.encodeCall(MockCheckpointClock.initialize, (address(accessManager), 0, uint32(block.timestamp - 100))))
            )
        );
        assertEq(clock.poke(), block.timestamp - 100, "the attested checkpoint must seed the clock");
        assertEq(_lastValue(clock), 1e18, "the baseline value must still be the source's current reading");
    }

    function test_checkpointClock_initializeRejectsFutureCheckpoint() public {
        // A future checkpoint would satisfy the execution gate without a genuine update: fail shut at initialization
        address implementation = address(new MockCheckpointClock(address(source)));
        vm.expectRevert(OracleClockBase.INVALID_LAST_UPDATE_TIMESTAMP.selector);
        new ERC1967Proxy(implementation, abi.encodeCall(MockCheckpointClock.initialize, (address(accessManager), 0, uint32(block.timestamp + 1))));
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

    function test_checkpointClock_tick_isRestricted() public {
        MockCheckpointClock clock = _deployCheckpointClock(0);
        address anyone = makeAddr("ANYONE");
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, anyone));
        clock.tick();
    }

    /**
     * The deviation blind spot: a source that genuinely republishes at an unchanged value never advances the
     * clock, so the gate would stay shut forever. A forced tick stamps the admin-attested update
     */
    function test_checkpointClock_tickStampsTheBlindSpot() public {
        MockCheckpointClock clock = _deployCheckpointClock(0);

        // The source republishes at the unchanged baseline value: poke can never observe it
        vm.warp(block.timestamp + 1 hours);
        assertEq(clock.poke(), 0, "an unchanged republish is invisible to deviation checkpointing");

        // The forced tick stamps the attested update and the clock reports it from then on
        vm.expectEmit(address(clock));
        emit OracleClockBase.ClockTicked(1e18);
        clock.tick();
        assertEq(clock.poke(), uint32(block.timestamp), "the forced tick stamps the attested update");
        assertEq(_lastUpdatedAt(clock), uint32(block.timestamp), "the checkpoint carries the forced timestamp");
    }

    /**
     * A forced tick re-baselines the checkpointed value, so subsequent deviations measure from the current
     * reading rather than the pre-tick checkpoint
     * Derivation (1% threshold over the 1e18 baseline): a 0.99% move is sub-threshold, the forced tick adopts
     * 1.0099e18 as the new baseline, and a further 0.99% move from the OLD baseline (1.0198e18) is only ~0.98%
     * from the new one, so it stays muted until the cumulative move from the forced baseline reaches 1%
     */
    function test_checkpointClock_tickRebaselinesTheCheckpoint() public {
        MockCheckpointClock clock = _deployCheckpointClock(0.01e18);

        // A sub-threshold move never checkpoints on its own
        vm.warp(block.timestamp + 1 hours);
        source.setValue(1.0099e18);
        assertEq(clock.poke(), 0, "a sub-threshold move must not advance the clock");

        // The forced tick adopts the current reading as the new baseline
        clock.tick();
        uint32 forcedAt = uint32(block.timestamp);
        assertEq(_lastValue(clock), 1.0099e18, "the forced tick re-baselines to the current reading");

        // A move that would have cleared the threshold from the OLD baseline stays muted from the new one
        vm.warp(block.timestamp + 1 hours);
        source.setValue(1.0198e18);
        assertEq(clock.poke(), forcedAt, "deviation measures from the forced baseline, not the pre-tick checkpoint");

        // Clearing the threshold from the forced baseline checkpoints organically again
        source.setValue(1.020099e18);
        assertEq(clock.poke(), uint32(block.timestamp), "a threshold move from the forced baseline checkpoints");
    }

    function test_checkpointClock_setMinDeviationWAD_updatesGatingBehavior() public {
        MockCheckpointClock clock = _deployCheckpointClock(0.05e18);

        // A 1% move is sub-threshold under the deployed configuration
        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18 + 0.01e18);
        assertEq(clock.poke(), 0, "a sub-threshold move must not advance the clock");

        // Tightening the threshold to 1% makes the same deviation count
        vm.expectEmit(address(clock));
        emit OracleClockBase.MinDeviationUpdated(0.01e18);
        clock.setMinDeviationWAD(0.01e18);
        assertEq(clock.getOracleClockState().minDeviationWAD, 0.01e18, "the threshold must be updated in storage");
        assertEq(clock.poke(), uint32(block.timestamp), "the same deviation must checkpoint under the tightened threshold");
    }

    // ---------------------------------------------------------------------
    // OracleClockBase: change detection
    // ---------------------------------------------------------------------

    function test_checkpointClock_unchangedValueNeverAdvances() public {
        MockCheckpointClock clock = _deployCheckpointClock(0);

        // Establish a live checkpoint, then hold the value still
        vm.warp(block.timestamp + 1 hours);
        source.setValue(2e18);
        uint256 checkpointedAt = clock.poke();
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
        // timestamp, the tranche's queue reverts loudly until the clock is rotated
        source.setValue(0);
        MockCheckpointClock clock = _deployCheckpointClock(0.01e18);
        assertEq(clock.getOracleClockState().lastUpdatedAt, 0, "a zero baseline must not stamp at initialization");

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
        // every further thresholded deviation check fail shut (division panic): the clock stays bricked, loudly,
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
        // clock must NOT advance, the failure mode is conservative (the gate stays shut), never a false open
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
