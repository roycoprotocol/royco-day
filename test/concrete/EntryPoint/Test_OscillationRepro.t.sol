// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { MockCheckpointClock } from "../../mocks/MockCheckpointClock.sol";
import { MockValueSource } from "../../mocks/MockValueSource.sol";

contract Test_OscillationRepro is Test {
    MockValueSource internal source;

    function setUp() public {
        source = new MockValueSource(1e18);
    }

    /// Repro of the reported scenario: 1% threshold, source oscillates 1.00e18 <-> 1.01e18,
    /// every leg observed by a poke. Does the clock tick once then stall forever?
    function test_repro_observedOscillationAtThresholdAmplitude() public {
        MockCheckpointClock clock = new MockCheckpointClock(address(source), 0.01e18);
        uint32 seededAt = clock.lastUpdatedAt();

        // Leg 1: 1.00e18 -> 1.01e18, observed. 1% relative to checkpoint 1.00e18 => ticks.
        vm.warp(block.timestamp + 1 hours);
        source.setValue(1.01e18);
        uint32 firstTick = clock.poke();
        assertEq(firstTick, uint32(block.timestamp), "first upward leg must tick");
        assertGt(firstTick, seededAt, "sanity");
        assertEq(clock.lastValue(), 1.01e18);

        // Now oscillate for 20 legs, poking on EVERY leg (every change observed).
        uint32 last = firstTick;
        for (uint256 i = 0; i < 20; i++) {
            vm.warp(block.timestamp + 1 hours);
            source.setValue(i % 2 == 0 ? 1e18 : 1.01e18);
            last = clock.poke();
            assertEq(last, firstTick, "clock advanced during oscillation - finding refuted");
        }

        // Breakout: from checkpoint 1.01e18 a move to 1.0201e18 (exactly +1%) ticks again.
        vm.warp(block.timestamp + 1 hours);
        source.setValue(1.0201e18);
        assertEq(clock.poke(), uint32(block.timestamp), "breakout must tick");

        // And confirm the down-leg math precisely: relative deviation of the return leg
        // is 0.01e18 * 1e18 / 1.01e18 = 9900990099009900 < 1e16.
        assertLt(uint256(1e18) * 0.01e18 / 1.01e18, 0.01e18);
    }

    /// Wider amplitude escapes: oscillation 1.00e18 <-> 1.02e18 keeps ticking both ways.
    function test_repro_widerAmplitudeKeepsTicking() public {
        MockCheckpointClock clock = new MockCheckpointClock(address(source), 0.01e18);

        vm.warp(block.timestamp + 1 hours);
        source.setValue(1.02e18);
        assertEq(clock.poke(), uint32(block.timestamp), "up leg ticks");

        // down leg: delta 0.02e18 rel to 1.02e18 = 1.9607...% >= 1% => ticks
        vm.warp(block.timestamp + 1 hours);
        source.setValue(1e18);
        assertEq(clock.poke(), uint32(block.timestamp), "down leg ticks");
    }
}
