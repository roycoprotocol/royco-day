// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { OracleClockBase } from "../../../src/oracle/base/clock/OracleClockBase.sol";
import { MockCheckpointClock } from "../../mocks/MockCheckpointClock.sol";
import { MockValueSource } from "../../mocks/MockValueSource.sol";

/**
 * @title Test_OracleClocks
 * @notice Unit-pins the checkpoint clock's change-detection semantics (baseline recording, thresholds, the
 *         zero-value edge, and read-failure behavior); the Chainlink passthrough clock shape is pinned on the
 *         collateral oracles that carry it
 * @dev The load-bearing property for the entry point's execution gate is that a clock NEVER reports a timestamp without
 *      a genuine observed source update behind it, a manufactured timestamp would open the gate without new information,
 *      so construction records the baseline value and stamps nothing beyond the deployer-attested checkpoint
 * @dev The clock is fully immutable and admin-free: the threshold and attested checkpoint are constructor arguments,
 *      the removed tick was a freshness-fabrication lever (it could stamp now with no genuine source update), and
 *      reconfiguration is a redeploy plus a kernel oracle repoint
 */
contract Test_OracleClocks is Test {
    MockValueSource internal source;

    function setUp() public {
        vm.warp(1_000_000);
        source = new MockValueSource(1e18);
    }

    /// @dev Deploys a checkpoint clock over the source with no attested checkpoint, mirroring the production pattern
    function _deployCheckpointClock(uint256 _minDeviationWAD) internal returns (MockCheckpointClock) {
        return new MockCheckpointClock(address(source), 0, _minDeviationWAD);
    }

    function _lastValue(MockCheckpointClock _clock) internal view returns (uint256) {
        (uint160 lastValue,) = _clock.getOracleClockState();
        return lastValue;
    }

    function _lastUpdatedAt(MockCheckpointClock _clock) internal view returns (uint32) {
        (, uint32 lastUpdatedAt) = _clock.getOracleClockState();
        return lastUpdatedAt;
    }

    // ---------------------------------------------------------------------
    // OracleClockBase: construction
    // ---------------------------------------------------------------------

    function test_checkpointClock_constructionRecordsBaselineWithoutStamping() public {
        MockCheckpointClock clock = _deployCheckpointClock(0);
        assertEq(_lastValue(clock), 1e18, "construction must record the source's current value as the baseline");
        assertEq(_lastUpdatedAt(clock), 0, "construction must never manufacture an update timestamp");
        assertEq(clock.poke(), 0, "a zero attested checkpoint fails shut: no update is reported until the first observed deviation");
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

    function test_checkpointClock_constructionFailsLoudlyOnBrokenSource() public {
        // The baseline read is the config validation: a clock over a broken source must never deploy silently
        source.setRevertMode(true);
        vm.expectRevert("MockValueSource: revert mode");
        new MockCheckpointClock(address(source), 0, 0);
    }

    function test_checkpointClock_constructionRejectsFullDeviationThreshold() public {
        // A threshold at or above 100% would mute all downward updates (a downward deviation caps at exactly WAD),
        // and the threshold is a construction immutable, so WAD is the fail-fast boundary
        vm.expectRevert(OracleClockBase.INVALID_MIN_DEVIATION_WAD.selector);
        new MockCheckpointClock(address(source), 0, WAD);
    }

    function test_checkpointClock_constructionWithAttestedCheckpointStampsIt() public {
        // An attested past update seeds the clock at construction: rotation to a fresh clock need not re-block
        // a queue when the deployer can attest to the source's true last update
        MockCheckpointClock clock = new MockCheckpointClock(address(source), uint32(block.timestamp - 100), 0);
        assertEq(clock.poke(), block.timestamp - 100, "the attested checkpoint must seed the clock");
        assertEq(_lastValue(clock), 1e18, "the baseline value must still be the source's current reading");

        // The current timestamp is the boundary: an attestation at exactly now is a genuine (freshest possible) claim
        MockCheckpointClock fresh = new MockCheckpointClock(address(source), uint32(block.timestamp), 0);
        assertEq(fresh.poke(), block.timestamp, "an attestation at exactly now must be accepted");
    }

    function test_checkpointClock_constructionRejectsFutureCheckpoint() public {
        // A future checkpoint would satisfy the execution gate without a genuine update: fail shut at construction
        vm.expectRevert(OracleClockBase.INVALID_LAST_UPDATE_TIMESTAMP.selector);
        new MockCheckpointClock(address(source), uint32(block.timestamp + 1), 0);
    }

    function test_checkpointClock_acceptsMaximalThreshold() public {
        // WAD - 1 is the maximal legal threshold: construction must accept it, and a full downward move
        // (a 100% deviation, the largest possible) must still checkpoint under it
        MockCheckpointClock clock = _deployCheckpointClock(1e18 - 1);
        assertEq(clock.MIN_DEVIATION_WAD(), 1e18 - 1, "the maximal threshold must be pinned as the immutable");

        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18 - 0.5e18);
        assertEq(clock.poke(), 0, "a 50% move must not advance the clock under the maximal threshold");
        source.setValue(0);
        assertEq(clock.poke(), uint32(block.timestamp), "a full downward move must advance the clock under the maximal threshold");
    }

    // ---------------------------------------------------------------------
    // OracleClockBase: no admin surface
    // ---------------------------------------------------------------------

    function test_checkpointClock_hasNoAdminSurface() public {
        // The clock carries no authority and no fallback, so the removed admin selectors hit nothing and revert.
        // tick was a freshness-fabrication lever (it could stamp now with no genuine source update) and
        // setMinDeviationWAD was a live gating-policy lever, both are gone by construction, not by role
        MockCheckpointClock clock = _deployCheckpointClock(0);
        (bool tickOk,) = address(clock).call(abi.encodeWithSignature("tick()"));
        assertFalse(tickOk, "the removed tick selector must not be callable");
        (bool setOk,) = address(clock).call(abi.encodeWithSignature("setMinDeviationWAD(uint256)", 0.01e18));
        assertFalse(setOk, "the removed setMinDeviationWAD selector must not be callable");
        (bool initOk,) = address(clock).call(abi.encodeWithSignature("initialize(address,uint256,uint32)", address(0), uint256(0), uint32(0)));
        assertFalse(initOk, "the clock is not a proxy and exposes no initializer");
    }

    /**
     * The deviation blind spot fails shut: a source that genuinely republishes at an identical or sub-threshold
     * value never advances the clock, so the entry point's execution gate stays conservatively shut until the
     * next observable deviation. With the forced tick removed there is no lever to stamp the blind spot, which
     * is the hardening: a shut gate delays execution, a fabricated timestamp would open it on stale information
     */
    function test_checkpointClock_blindSpotFailsShutUntilObservableDeviation() public {
        MockCheckpointClock clock = _deployCheckpointClock(0.01e18);

        // A republish at the unchanged construction baseline is invisible to deviation checkpointing
        vm.warp(block.timestamp + 1 hours);
        assertEq(clock.poke(), 0, "an unchanged republish must not advance the clock");
        assertEq(_lastUpdatedAt(clock), 0, "no checkpoint may be written for the blind spot");

        // A sub-threshold republish is equally invisible: 0.99% over the 1e18 baseline stays below the 1% threshold
        vm.warp(block.timestamp + 1 hours);
        source.setValue(1.0099e18);
        assertEq(clock.poke(), 0, "a sub-threshold republish must hold the gate shut");
        assertEq(_lastUpdatedAt(clock), 0, "the shut gate is the conservative failure mode, never a false open");

        // The next observable deviation opens the gate: 1% from the construction baseline (not the muted reading)
        source.setValue(1.01e18);
        assertEq(clock.poke(), uint32(block.timestamp), "the next threshold deviation must open the gate");
        assertEq(_lastValue(clock), 1.01e18, "the checkpoint must move to the deviated value");
    }

    /**
     * The threshold is a construction immutable, so a muted move can never be made to count later, and
     * reconfiguration is a redeploy (plus a kernel oracle repoint in production)
     * Derivation: 1.01e18 is a 1% move over the 1e18 baseline (muted under 5%), the redeploy baselines at the
     * live 1.01e18 reading, and 1.0201e18 is exactly 1% over it (floor(1e18 * 0.0101e18 / 1.01e18) = 1e16)
     */
    function test_checkpointClock_thresholdIsImmutable_redeployIsTheReconfiguration() public {
        MockCheckpointClock clock = _deployCheckpointClock(0.05e18);
        assertEq(clock.MIN_DEVIATION_WAD(), 0.05e18, "the threshold must be pinned at construction");

        // A 1% move is sub-threshold under the deployed configuration and stays muted for the clock's whole life
        vm.warp(block.timestamp + 1 hours);
        source.setValue(1.01e18);
        assertEq(clock.poke(), 0, "a sub-threshold move must not advance the clock");
        vm.warp(block.timestamp + 30 days);
        assertEq(clock.poke(), 0, "no lever exists to make the muted move count later");

        // The redeploy pins the tighter threshold and baselines at the live reading without stamping
        MockCheckpointClock redeployed = new MockCheckpointClock(address(source), 0, 0.01e18);
        assertEq(redeployed.MIN_DEVIATION_WAD(), 0.01e18, "the redeploy must pin the new threshold");
        assertEq(_lastValue(redeployed), 1.01e18, "the redeploy must baseline at the live reading");
        assertEq(_lastUpdatedAt(redeployed), 0, "the redeploy must not manufacture an update timestamp");

        // A 1% move from the redeploy's baseline checkpoints on the new clock while the old one stays muted
        source.setValue(1.0201e18);
        assertEq(redeployed.poke(), uint32(block.timestamp), "the tighter threshold must count the move on the new clock");
        assertEq(clock.poke(), 0, "the old clock must stay muted under its immutable threshold");
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

    function test_checkpointClock_zeroCheckpointWithThreshold_resolvesOnFirstNonZeroRead() public {
        // A RELATIVE deviation from a zero checkpoint has no scale to measure against, so the threshold cannot be
        // applied and any nonzero observation counts as a full deviation. The alternative (dividing by the zero
        // baseline) bricks the clock permanently, holding the tranche's execution gate shut until the clock is
        // rotated, which is a far worse outcome than resolving off the first real observation
        source.setValue(0);
        MockCheckpointClock clock = _deployCheckpointClock(0.01e18);
        assertEq(_lastUpdatedAt(clock), 0, "a zero baseline must not stamp at construction");

        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18);
        uint256 resolvedAt = clock.poke();
        assertEq(resolvedAt, uint32(block.timestamp), "the first nonzero observation must checkpoint off a zero baseline");
        assertEq(_lastValue(clock), 1e18, "the checkpoint must move to the observed value");

        // Once the baseline is nonzero the threshold applies again: a sub-threshold move leaves the checkpoint where
        // it is, so poke keeps reporting the earlier stamp rather than advancing to now
        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18 + 0.0099e18);
        assertEq(clock.poke(), resolvedAt, "the threshold must resume governing once a real baseline exists");
    }

    function test_checkpointClock_zeroCheckpointWithZeroThreshold_stampsOnFirstNonZeroRead() public {
        // A zero threshold counts any change, so a zero baseline resolves on the first nonzero observation
        source.setValue(0);
        MockCheckpointClock clock = _deployCheckpointClock(0);

        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18);
        assertEq(clock.poke(), uint32(block.timestamp), "the first nonzero observation must checkpoint under a zero threshold");
    }

    function test_checkpointClock_midLifeZeroCrossing_checkpointsBothTheDropAndTheRecovery() public {
        // A mid-life wipeout checkpoints the drop to zero as a full deviation, and the recovery off that zero
        // checkpoint is a full deviation too, for the same reason: there is no relative scale to apply a threshold
        // against. The clock passes THROUGH zero rather than being stranded at it
        MockCheckpointClock clock = _deployCheckpointClock(0.01e18);

        vm.warp(block.timestamp + 1 hours);
        source.setValue(0);
        assertEq(clock.poke(), uint32(block.timestamp), "the drop to zero must checkpoint as a full deviation");
        assertEq(_lastValue(clock), 0, "the checkpoint must move to zero");

        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18);
        assertEq(clock.poke(), uint32(block.timestamp), "the recovery off a zero checkpoint must checkpoint too");
        assertEq(_lastValue(clock), 1e18, "the checkpoint must move to the recovered value");

        // A zero source that STAYS zero is not a deviation, so a wiped-out source cannot stamp the clock repeatedly:
        // the checkpoint holds at the drop's timestamp instead of advancing on every poke
        vm.warp(block.timestamp + 1 hours);
        source.setValue(0);
        uint256 droppedAt = clock.poke();
        assertEq(droppedAt, uint32(block.timestamp), "the second drop to zero checkpoints");
        vm.warp(block.timestamp + 1 hours);
        assertEq(clock.poke(), droppedAt, "an unchanged zero source must not advance the clock");
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
