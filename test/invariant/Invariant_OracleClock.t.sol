// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { MockCheckpointClock } from "../mocks/MockCheckpointClock.sol";
import { MockValueSource } from "../mocks/MockValueSource.sol";

/**
 * @title OracleClockHandler
 * @notice Drives one checkpoint clock through random source moves, warps, pokes, and previews while maintaining
 *         an INDEPENDENT mirror of the clock's specified state transition, so any divergence between the
 *         implementation and the specification surfaces as a flag regardless of the sequence that produced it
 * @dev The mirror re-implements the spec from its definition (checkpoint pair, deviation predicate, stamp rule),
 *      never reading the clock's own state to form an expectation
 */
contract OracleClockHandler is Test {
    MockValueSource public source;
    MockCheckpointClock public clock;
    uint256 public thresholdWAD;

    /// @dev The mirror of the specified clock state
    uint256 public mirror_checkpointPrice;
    uint256 public mirror_lastUpdatedAt;

    /// @dev Sticky divergence flags, asserted by the invariants
    bool public ghost_everMismatched;
    string public ghost_mismatch;

    constructor(uint256 _thresholdWAD, uint32 _attestedLastUpdate, uint256 _initialPrice) {
        thresholdWAD = _thresholdWAD;
        source = new MockValueSource(_initialPrice);
        clock = new MockCheckpointClock(address(source), _attestedLastUpdate, _thresholdWAD);
        mirror_checkpointPrice = _initialPrice;
        mirror_lastUpdatedAt = _attestedLastUpdate;
    }

    /// @dev The specification's deviation predicate, re-derived from its definition
    function _specDeviated(uint256 _price) internal view returns (bool) {
        if (_price == mirror_checkpointPrice) return false;
        if (thresholdWAD == 0) return true;
        if (mirror_checkpointPrice == 0) return true;
        uint256 delta = _price > mirror_checkpointPrice ? _price - mirror_checkpointPrice : mirror_checkpointPrice - _price;
        return Math.mulDiv(WAD, delta, mirror_checkpointPrice) >= thresholdWAD;
    }

    /// @dev Records a divergence without reverting, so the sequence that produced it is preserved
    function _flag(bool _condition, string memory _what) internal {
        if (!_condition) {
            ghost_everMismatched = true;
            if (bytes(ghost_mismatch).length == 0) ghost_mismatch = _what;
        }
    }

    /// @notice Moves the source price anywhere in the clock's representable range
    function op_setSource(uint256 _price) external {
        source.setValue(bound(_price, 0, type(uint160).max));
    }

    /// @notice Nudges the source by a bounded relative step, densely sampling the threshold boundary
    function op_nudgeSource(uint256 _stepWAD, bool _up) external {
        uint256 current = source.getValue();
        uint256 stepWAD = bound(_stepWAD, 0, 0.2e18);
        uint256 delta = Math.mulDiv(current, stepWAD, WAD);
        uint256 next = _up ? current + delta : current - Math.min(delta, current);
        source.setValue(bound(next, 0, type(uint160).max));
    }

    /// @notice Advances time by a bounded step
    function op_warp(uint256 _dt) external {
        vm.warp(block.timestamp + bound(_dt, 1, 30 days));
    }

    /// @notice Previews the clock and checks the report against the specification WITHOUT committing
    function op_previewPoke() external {
        uint256 reported = clock.previewPoke();
        uint256 expected = _specDeviated(source.getValue()) ? block.timestamp : mirror_lastUpdatedAt;
        _flag(reported == expected, "previewPoke diverged from the specified report");
    }

    /// @notice Pokes the clock and steps the mirror through the specified transition, checking every output
    function op_poke() external {
        uint256 price = source.getValue();
        bool deviated = _specDeviated(price);
        uint256 reported = clock.poke();

        // Step the mirror through the specified transition
        if (deviated) {
            mirror_checkpointPrice = price;
            mirror_lastUpdatedAt = block.timestamp;
        }
        _flag(reported == mirror_lastUpdatedAt, "poke diverged from the specified stamp");

        // The committed checkpoint pair must equal the mirror exactly
        (uint160 lastPrice, uint32 lastAt) = clock.getOracleClockState();
        _flag(uint256(lastPrice) == mirror_checkpointPrice, "the committed checkpoint price diverged from the mirror");
        _flag(uint256(lastAt) == mirror_lastUpdatedAt, "the committed checkpoint timestamp diverged from the mirror");
    }
}

/**
 * @title Invariant_OracleClock
 * @notice Differential invariant campaign for the oracle deviation clock: across arbitrary sequences of source
 *         moves, time warps, pokes, and previews, the clock must match an independent mirror of its specification
 *         exactly, never time-travel, and never stamp without a genuinely observed deviation
 */
contract Invariant_OracleClock is Test {
    uint256 internal constant T0 = 1_700_000_000;

    OracleClockHandler internal h;

    function setUp() public virtual {
        vm.warp(T0);
        h = new OracleClockHandler(0, uint32(T0), 1e18);
        targetContract(address(h));
    }

    /// The clock's every output matched the independent specification mirror across the whole sequence
    function invariant_clockMatchesTheSpecificationMirror() public view {
        assertFalse(h.ghost_everMismatched(), h.ghost_mismatch());
    }

    /// The committed checkpoint timestamp never exceeds the present and never precedes the mirror's record
    function invariant_checkpointNeverTimeTravels() public view {
        (, uint32 lastAt) = h.clock().getOracleClockState();
        assertLe(uint256(lastAt), block.timestamp, "a checkpoint in the future would open the execution gate without an update");
        assertEq(uint256(lastAt), h.mirror_lastUpdatedAt(), "the committed timestamp must equal the specified one");
    }
}

/// @notice The same differential campaign under a live 1% deviation threshold, where sub-threshold noise must be muted
contract Invariant_OracleClock_Thresholded is Invariant_OracleClock {
    function setUp() public override {
        vm.warp(T0);
        h = new OracleClockHandler(0.01e18, uint32(T0), 1e18);
        targetContract(address(h));
    }
}

/// @notice The same differential campaign from an unattested zero checkpoint, covering the fail-shut genesis regime
contract Invariant_OracleClock_Unattested is Invariant_OracleClock {
    function setUp() public override {
        vm.warp(T0);
        h = new OracleClockHandler(0.001e18, 0, 1e18);
        targetContract(address(h));
    }
}
