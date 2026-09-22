// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { NAV_UNIT, toUint256 } from "../../src/libraries/Units.sol";
import { ChainlinkPriceOracleBase } from "../../src/oracle/base/ChainlinkPriceOracleBase.sol";
import { DiscretePriceOracleBase } from "../../src/oracle/base/DiscretePriceOracleBase.sol";
import { MockAggregatorV3 } from "../mocks/MockAggregatorV3.sol";
import { MockDiscretePriceOracle } from "../mocks/MockDiscretePriceOracle.sol";
import { MockERC20C } from "../mocks/MockERC20C.sol";
import { MockValueSource } from "../mocks/MockValueSource.sol";

/**
 * @title DiscreteOracleHandler
 * @notice Drives one discrete composed oracle through random source moves, feed moves, warps, checkpoint ID
 *         bumps, force-signal toggles, pokes, and reads while maintaining an INDEPENDENT mirror of the oracle's
 *         specified state transition, so any divergence between the implementation and the specification
 *         surfaces as a flag regardless of the sequence that produced it
 * @dev The mirror re-implements the spec from its definition (construction-seeded checkpoint triple, the
 *      ID-or-forced-move predicate, poke-consistent pending observations, feed-first staleness gates,
 *      single-floor composition, oldest-hop stamp), never reading the oracle's own state to form an expectation
 */
contract DiscreteOracleHandler is Test {
    /// @dev Generous per-hop staleness thresholds: ops mostly stay live under bounded warps, but a few unrefreshed
    ///      warps or a deep feed restamp genuinely cross either gate, so the stale regimes stay reachable
    uint32 public constant FEED_STALENESS = 45 days;
    uint32 public constant SOURCE_STALENESS = 60 days;

    /// @dev The mock feed reports at 8 decimals, locked at the oracle's construction
    uint256 internal constant FEED_PRECISION = 1e8;

    MockValueSource public source;
    MockAggregatorV3 public feed;
    MockDiscretePriceOracle public oracle;

    /// @dev The live inputs the handler drives, shadowed here so expectations never read the oracle's state
    uint256 public liveId;
    bool public liveForce;

    /// @dev The mirror of the specified oracle state: the checkpoint triple
    uint256 public mirror_sourcePrice;
    uint256 public mirror_lastUpdatedAt;
    uint256 public mirror_checkpointId;

    /// @dev Sticky divergence flags, asserted by the invariants
    bool public ghost_everMismatched;
    string public ghost_mismatch;

    constructor() {
        source = new MockValueSource(1.01e18);
        feed = new MockAggregatorV3(8, 1e8);
        oracle = new MockDiscretePriceOracle(
            address(new MockERC20C("Pareto Credit Vault USDC", "cpUSDC", 18)), address(feed), address(source), FEED_STALENESS, SOURCE_STALENESS
        );
        // Construction seeds through the same commit path pokes use, so the mirror seeds the identical triple
        // (the initial source value, the construction timestamp, the resting zero ID) with the force signal clear
        mirror_sourcePrice = 1.01e18;
        mirror_lastUpdatedAt = block.timestamp;
        mirror_checkpointId = 0;
    }

    /// @dev The specified checkpoint predicate: an ID change always counts, and a price move counts under force
    function _pending(uint256 _live) internal view returns (bool) {
        return liveId != mirror_checkpointId || (liveForce && _live != mirror_sourcePrice);
    }

    /**
     * @dev The specification's composed report, re-derived from its definition in the implementation's
     *      feed-first order: the feed gate fires first, then the poke-consistent pair (a pending observation
     *      reads as the live price at now, zero included, else the mirror's checkpoint) crosses the source
     *      staleness gate, composes through a single floored mulDiv, and the older hop stamps the report
     */
    function _specReport() internal view returns (bytes4 expectedError, uint256 expectedPrice, uint256 expectedUpdatedAt) {
        (, int256 answer,, uint256 feedUpdatedAt,) = feed.latestRoundData();
        uint256 live = source.value();
        bool pending = _pending(live);
        if (feedUpdatedAt + FEED_STALENESS < block.timestamp) return (ChainlinkPriceOracleBase.STALE_FEED_PRICE.selector, 0, 0);
        (uint256 sourcePrice, uint256 sourceUpdatedAt) = (pending ? (live, block.timestamp) : (mirror_sourcePrice, mirror_lastUpdatedAt));
        if (sourceUpdatedAt + SOURCE_STALENESS < block.timestamp) return (DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector, 0, 0);
        expectedPrice = Math.mulDiv(sourcePrice, uint256(answer), FEED_PRECISION);
        expectedUpdatedAt = Math.min(feedUpdatedAt, sourceUpdatedAt);
    }

    /**
     * @dev The specification's poke transition: a pending observation commits (latching the mirror triple with
     *      any value, zero included) and then reports its own fresh stamp against the feed, no pending
     *      observation means the poke reports exactly like the views, and only the feed and staleness gates
     *      ever revert
     */
    function _specPoke() internal view returns (bytes4 expectedError, uint256 expectedUpdatedAt, bool expectedCommit, uint256 live) {
        live = source.value();
        bool pending = _pending(live);
        (,,, uint256 feedUpdatedAt,) = feed.latestRoundData();
        if (feedUpdatedAt + FEED_STALENESS < block.timestamp) return (ChainlinkPriceOracleBase.STALE_FEED_PRICE.selector, 0, false, live);
        uint256 sourceUpdatedAt = (pending ? block.timestamp : mirror_lastUpdatedAt);
        if (sourceUpdatedAt + SOURCE_STALENESS < block.timestamp) return (DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector, 0, false, live);
        expectedCommit = pending;
        expectedUpdatedAt = Math.min(feedUpdatedAt, sourceUpdatedAt);
    }

    /// @dev Records a divergence without reverting, so the sequence that produced it is preserved
    function _flag(bool _condition, string memory _what) internal {
        if (!_condition) {
            ghost_everMismatched = true;
            if (bytes(ghost_mismatch).length == 0) ghost_mismatch = _what;
        }
    }

    /// @dev The committed checkpoint triple must equal the mirror exactly after every op
    function _checkCommittedTriple() internal {
        (uint160 lastSourcePrice, uint32 lastUpdatedAt, uint256 lastCheckpointId) = oracle.getDiscretePriceOracleState();
        _flag(uint256(lastSourcePrice) == mirror_sourcePrice, "the committed checkpoint price diverged from the mirror");
        _flag(uint256(lastUpdatedAt) == mirror_lastUpdatedAt, "the committed checkpoint timestamp diverged from the mirror");
        _flag(lastCheckpointId == mirror_checkpointId, "the committed checkpoint ID diverged from the mirror");
    }

    /// @notice Moves the source value anywhere in the checkpoint's representable range, zero included
    function op_setSource(uint256 _price) external {
        source.setValue(bound(_price, 0, type(uint160).max));
    }

    /// @notice Moves the feed's answer (always positive) and restamps it anywhere from deep-stale to now
    function op_setFeed(uint256 _answer, uint256 _updatedAt) external {
        feed.setAnswer(int256(bound(_answer, 1, 1e12)));
        feed.setUpdatedAt(bound(_updatedAt, block.timestamp - 2 * uint256(FEED_STALENESS), block.timestamp));
    }

    /// @notice Advances time by a bounded step
    function op_warp(uint256 _dt) external {
        vm.warp(block.timestamp + bound(_dt, 1, 30 days));
    }

    /// @notice Sets the live checkpoint ID from a small pool, so ID changes and ID no-ops both stay exercised,
    ///         mirroring nothing until a poke commits the observation
    function op_bumpId(uint256 _id) external {
        liveId = bound(_id, 0, 7);
        oracle.setCheckpointId(liveId);
        _flag(oracle.checkpointId() == liveId, "the live checkpoint ID diverged from the shadow");
        _checkCommittedTriple();
    }

    /// @notice Flips the force-checkpoint flag and shadows the bit, so both distress regimes stay exercised
    function op_toggleForce() external {
        liveForce = !liveForce;
        oracle.setForceCheckpoint(liveForce);
        _flag(oracle.forceCheckpoint() == liveForce, "the force flag diverged from the shadow");
        _checkCommittedTriple();
    }

    /// @notice Pokes the oracle and steps the mirror through the specified transition: a pending observation
    ///         commits (the mirror latches the live triple, zero included) and any other poke is a stateless report
    function op_poke() external {
        (bytes4 expectedError, uint256 expectedUpdatedAt, bool expectedCommit, uint256 live) = _specPoke();
        try oracle.poke() returns (uint256 updatedAt) {
            _flag(expectedError == bytes4(0), "poke reported where the specification fails shut");
            _flag(updatedAt == expectedUpdatedAt, "poke diverged from the specified oldest-hop stamp");
            if (expectedCommit) {
                mirror_sourcePrice = live;
                mirror_lastUpdatedAt = block.timestamp;
                mirror_checkpointId = liveId;
            }
        } catch (bytes memory err) {
            _flag(expectedError != bytes4(0), "poke failed shut where the specification reports");
            _flag(expectedError == bytes4(0) || bytes4(err) == expectedError, "poke failed shut with the wrong gate");
        }
        // A reverted poke rolls its commit back, so either way the committed triple must equal the mirror
        _checkCommittedTriple();
    }

    /// @notice Reads the composed price and checks the report against the specification
    function op_getPrice() external {
        (bytes4 expectedError, uint256 expectedPrice, uint256 expectedUpdatedAt) = _specReport();
        try oracle.getPrice() returns (NAV_UNIT price, uint256 updatedAt) {
            _flag(expectedError == bytes4(0), "getPrice priced where the specification fails shut");
            _flag(toUint256(price) == expectedPrice, "getPrice diverged from the specified composed price");
            _flag(updatedAt == expectedUpdatedAt, "getPrice diverged from the specified oldest-hop stamp");
        } catch (bytes memory err) {
            _flag(expectedError != bytes4(0), "getPrice failed shut where the specification prices");
            _flag(expectedError == bytes4(0) || bytes4(err) == expectedError, "getPrice failed shut with the wrong gate");
        }
        // A view must never commit a pending observation
        _checkCommittedTriple();
    }

    /// @notice Previews the oracle and checks the report against the specification WITHOUT committing
    function op_previewPoke() external {
        (bytes4 expectedError,, uint256 expectedUpdatedAt) = _specReport();
        try oracle.previewPoke() returns (uint256 updatedAt) {
            _flag(expectedError == bytes4(0), "previewPoke reported where the specification fails shut");
            _flag(updatedAt == expectedUpdatedAt, "previewPoke diverged from the specified oldest-hop stamp");
        } catch (bytes memory err) {
            _flag(expectedError != bytes4(0), "previewPoke failed shut where the specification reports");
            _flag(expectedError == bytes4(0) || bytes4(err) == expectedError, "previewPoke failed shut with the wrong gate");
        }
        // The preview must never commit the observation it reports
        _checkCommittedTriple();
    }
}

/**
 * @title Invariant_DiscreteOracle
 * @notice Differential invariant campaign for the permissionless discrete composed oracle: across arbitrary
 *         sequences of source moves, feed moves, time warps, checkpoint ID bumps, force-signal toggles, pokes,
 *         and reads, the oracle must match an independent mirror of its specification exactly (which entails
 *         that the checkpoint only ever moves on a predicate commit the mirror recorded) and never time-travel
 */
contract Invariant_DiscreteOracle is Test {
    uint256 internal constant T0 = 1_700_000_000;

    DiscreteOracleHandler internal h;

    /// @dev The committed checkpoint timestamp the previous invariant round observed, for the monotonicity check
    uint32 internal ghost_lastSeenUpdatedAt;

    function setUp() public {
        vm.warp(T0);
        h = new DiscreteOracleHandler();
        targetContract(address(h));
    }

    /// The oracle's every output matched the independent specification mirror across the whole sequence, and
    /// the committed triple equals the mirror's, so the checkpoint only ever moved on a recorded predicate commit
    function invariant_oracleMatchesTheSpecificationMirror() public view {
        assertFalse(h.ghost_everMismatched(), h.ghost_mismatch());
        (uint160 lastSourcePrice, uint32 lastUpdatedAt, uint256 lastCheckpointId) = h.oracle().getDiscretePriceOracleState();
        assertEq(uint256(lastSourcePrice), h.mirror_sourcePrice(), "the committed checkpoint price must equal the specified one");
        assertEq(uint256(lastUpdatedAt), h.mirror_lastUpdatedAt(), "the committed checkpoint timestamp must equal the specified one");
        assertEq(lastCheckpointId, h.mirror_checkpointId(), "the committed checkpoint ID must equal the specified one");
    }

    /// The committed checkpoint timestamp never exceeds the present and never steps backwards
    function invariant_checkpointNeverTimeTravels() public {
        (, uint32 lastUpdatedAt,) = h.oracle().getDiscretePriceOracleState();
        assertLe(uint256(lastUpdatedAt), block.timestamp, "a checkpoint in the future would open the execution gate without an update");
        assertGe(lastUpdatedAt, ghost_lastSeenUpdatedAt, "the checkpoint timestamp must be monotonically nondecreasing");
        ghost_lastSeenUpdatedAt = lastUpdatedAt;
    }
}
