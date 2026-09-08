// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Ownable } from "../../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { SafeCast } from "../../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { NAV_UNIT, toUint256 } from "../../../src/libraries/Units.sol";
import { ChainlinkPriceOracleBase } from "../../../src/oracle/base/ChainlinkPriceOracleBase.sol";
import { DiscretePriceOracleBase } from "../../../src/oracle/base/DiscretePriceOracleBase.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockDiscretePriceOracle } from "../../mocks/MockDiscretePriceOracle.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { MockValueSource } from "../../mocks/MockValueSource.sol";

/**
 * @title Test_DiscretePriceOracle
 * @notice Concrete vectors for the discrete composed oracle: the owner-driven checkpoint latch (activation from
 *         the zero checkpoint, two-step ownership over the lever, latch and stamp semantics, the fail-shut
 *         renounce) plus the composed surface (the checkpointed conversion hop with hand-derived floors, the
 *         oldest-hop report timestamp, and both staleness gates)
 * @dev The load-bearing property for the entry point's execution gate is that ONLY an owner checkpoint moves the
 *      conversion hop or its timestamp: between checkpoints intra-settlement drift never marks the market and no
 *      poke timing grants price selection power, and the owner's only authority is choosing when to sample, the
 *      price always comes from the live source read
 * @dev A halted or renounced owner fails shut: the checkpoint ages past its staleness threshold and every
 *      surface reverts, never serving a stale conversion price silently
 * @dev Every expected value is derived by hand from the composition definition, never captured from the oracle
 */
contract Test_DiscretePriceOracle is Test {
    /// @dev Base timestamp so poke and update timestamps assert against stable absolute values
    uint256 internal constant T0 = 1_700_000_000;

    /// @dev The per-hop staleness immutables the suite constructs with: the feed hop tight, the settlement hop
    ///      sized to a monthly epoch cadence plus slack, so the gates can be crossed independently
    uint32 internal constant FEED_STALENESS = 1 days;
    uint32 internal constant SETTLEMENT_STALENESS = 45 days;

    address internal owner;
    MockERC20C internal collateral;
    MockValueSource internal source;
    MockAggregatorV3 internal feed;
    MockDiscretePriceOracle internal oracle;

    function setUp() public {
        vm.warp(T0);
        owner = makeAddr("ORACLE_OWNER");
        // An epochic credit vault share whose WAD price the owner checkpoints at settlements, priced by an 8-decimal feed
        collateral = new MockERC20C("Pareto Credit Vault USDC", "cpUSDC", 18);
        source = new MockValueSource(1.01e18);
        feed = new MockAggregatorV3(8, 1e8);
        oracle = _deployOracle();
        // The owner's first checkpoint activates the oracle: the T0 baseline is (1.01e18, T0)
        _checkpoint(oracle);
    }

    function _deployOracle() internal returns (MockDiscretePriceOracle) {
        return new MockDiscretePriceOracle(owner, address(collateral), address(feed), address(source), FEED_STALENESS, SETTLEMENT_STALENESS);
    }

    /// @dev Restamps the feed at the current timestamp so checkpoint-mechanism vectors isolate the settlement hop:
    ///      the fresher feed leg never binds the oldest-hop report and never trips its own staleness gate
    function _freshenFeed() internal {
        feed.setUpdatedAt(block.timestamp);
    }

    /// @dev Latches the live source read through the owner's checkpointPrice, the only runtime update path
    function _checkpoint(MockDiscretePriceOracle _oracle) internal {
        vm.prank(owner);
        _oracle.checkpointPrice();
    }

    function _lastSourcePrice(MockDiscretePriceOracle _oracle) internal view returns (uint256) {
        (uint160 lastSourcePrice,) = _oracle.getDiscretePriceOracleState();
        return lastSourcePrice;
    }

    function _lastUpdatedAt(MockDiscretePriceOracle _oracle) internal view returns (uint32) {
        (, uint32 lastUpdatedAt) = _oracle.getDiscretePriceOracleState();
        return lastUpdatedAt;
    }

    /*----------------------------------------------------------------------
                        Construction and activation
    ----------------------------------------------------------------------*/

    /// Construction wires the identities, pins the immutable per-hop configuration, and rejects null or
    /// degenerate configuration, without ever reading the source
    function test_Discrete_constructionIdentityAndNullChecks() public {
        assertEq(oracle.owner(), owner, "the checkpoint lever is wired to the constructed owner");
        assertEq(oracle.COLLATERAL_ASSET(), address(collateral), "the collateral asset is wired");
        assertEq(address(oracle.ORACLE()), address(feed), "the feed is wired");
        assertEq(oracle.FEED_STALENESS_THRESHOLD_SECONDS(), FEED_STALENESS, "the feed hop's staleness threshold is a construction immutable");
        assertEq(
            oracle.SOURCE_PRICE_STALENESS_THRESHOLD_SECONDS(), SETTLEMENT_STALENESS, "the settlement hop's staleness threshold is a construction immutable"
        );
        assertEq(oracle.decimals(), 18, "prices are reported at WAD precision");
        assertEq(oracle.version(), 1, "version");
        assertEq(oracle.description(), string.concat("cpUSDC / ", feed.description()), "the description chains through the feed");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new MockDiscretePriceOracle(address(0), address(collateral), address(feed), address(source), FEED_STALENESS, SETTLEMENT_STALENESS);
        vm.expectRevert(ChainlinkPriceOracleBase.NULL_ADDRESS.selector);
        new MockDiscretePriceOracle(owner, address(0), address(feed), address(source), FEED_STALENESS, SETTLEMENT_STALENESS);
        vm.expectRevert(ChainlinkPriceOracleBase.NULL_ADDRESS.selector);
        new MockDiscretePriceOracle(owner, address(collateral), address(0), address(source), FEED_STALENESS, SETTLEMENT_STALENESS);
        // Both zero staleness thresholds are rejected per hop
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        new MockDiscretePriceOracle(owner, address(collateral), address(feed), address(source), 0, SETTLEMENT_STALENESS);
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        new MockDiscretePriceOracle(owner, address(collateral), address(feed), address(source), FEED_STALENESS, 0);
    }

    /// A fresh deployment carries the zero checkpoint: nothing latched, nothing stamped, and every surface fails
    /// shut under the source staleness gate until the owner's first checkpoint activates the oracle
    function test_Discrete_startsShutUntilTheFirstCheckpoint() public {
        MockDiscretePriceOracle unactivated = _deployOracle();
        (uint160 lastSourcePrice, uint32 lastUpdatedAt) = unactivated.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 0, "construction must never read or latch the source");
        assertEq(lastUpdatedAt, 0, "construction must never manufacture an update timestamp");
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        unactivated.getPrice();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        unactivated.poke();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        unactivated.previewPoke();

        // Time and drift alone never activate: only the owner's checkpoint can
        vm.warp(T0 + 30 days);
        _freshenFeed();
        source.setValue(2e18);
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        unactivated.poke();
        assertEq(_lastUpdatedAt(unactivated), 0, "an uncheckpointed oracle stays unstamped, however much time passes");

        // The first checkpoint latches the live read and opens every surface
        _checkpoint(unactivated);
        (NAV_UNIT price, uint256 updatedAt) = unactivated.getPrice();
        assertEq(toUint256(price), 2e18, "the first checkpoint prices the live read it latched");
        assertEq(updatedAt, T0 + 30 days, "the first checkpoint is the first stamped update");
    }

    /*----------------------------------------------------------------------
                        Ownership of the checkpoint lever
    ----------------------------------------------------------------------*/

    /// checkpointPrice is the owner's lever: any other caller is rejected before the source is even read
    function test_Discrete_RevertIf_CheckpointCallerNotOwner() public {
        address stranger = makeAddr("STRANGER");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        oracle.checkpointPrice();
        assertEq(_lastUpdatedAt(oracle), uint32(T0), "a rejected caller must not move the checkpoint");
    }

    /// Ownership hands over through the two-step transfer: the pending owner holds no authority until accepting,
    /// the incumbent keeps checkpointing until then, and after acceptance the lever swaps completely
    function test_Discrete_twoStepTransferHandsOverTheCheckpointLever() public {
        address newOwner = makeAddr("NEW_OWNER");
        vm.prank(owner);
        oracle.transferOwnership(newOwner);
        assertEq(oracle.owner(), owner, "the transfer must not hand over until accepted");
        assertEq(oracle.pendingOwner(), newOwner, "the pending owner is staged");

        // The pending owner cannot checkpoint before accepting
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        vm.prank(newOwner);
        oracle.checkpointPrice();

        // The incumbent still checkpoints while the transfer is pending
        vm.warp(T0 + 1 days);
        source.setValue(1.02e18);
        _checkpoint(oracle);
        assertEq(_lastSourcePrice(oracle), 1.02e18, "the incumbent keeps the lever until the handover completes");

        // Accepting completes the handover: the new owner checkpoints and the old owner is rejected
        vm.prank(newOwner);
        oracle.acceptOwnership();
        assertEq(oracle.owner(), newOwner, "acceptance completes the transfer");
        vm.warp(T0 + 2 days);
        source.setValue(1.03e18);
        vm.prank(newOwner);
        oracle.checkpointPrice();
        assertEq(_lastSourcePrice(oracle), 1.03e18, "the new owner holds the lever");
        assertEq(_lastUpdatedAt(oracle), uint32(T0 + 2 days), "the new owner's checkpoint stamps normally");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        oracle.checkpointPrice();
    }

    /// Renouncing ownership freezes the checkpoint permanently: pricing keeps serving it inside its staleness
    /// window and then fails shut forever, no lever exists to reopen it
    function test_Discrete_renounceFreezesCheckpointsIntoPermanentFailShut() public {
        vm.prank(owner);
        oracle.renounceOwnership();
        assertEq(oracle.owner(), address(0), "renouncing clears the owner");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        oracle.checkpointPrice();

        // The frozen checkpoint keeps pricing inside its window
        vm.warp(T0 + SETTLEMENT_STALENESS);
        _freshenFeed();
        (, uint256 updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0, "the frozen checkpoint keeps serving inside its window");

        // Past the window every surface fails shut permanently
        vm.warp(T0 + SETTLEMENT_STALENESS + 1);
        _freshenFeed();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.getPrice();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.poke();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.previewPoke();
    }

    /*----------------------------------------------------------------------
                        Checkpoint semantics
    ----------------------------------------------------------------------*/

    /// A checkpoint latches the live price with its own timestamp, and getPrice, poke, and previewPoke all
    /// advance to it identically
    function test_Discrete_checkpointLatchesThePriceAndAdvancesAllThreeSurfaces() public {
        vm.warp(T0 + 1 days);
        _freshenFeed();
        source.setValue(1.05e18);
        _checkpoint(oracle);
        (uint160 lastSourcePrice, uint32 lastUpdatedAt) = oracle.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 1.05e18, "the checkpoint must latch the live source price");
        assertEq(lastUpdatedAt, T0 + 1 days, "the checkpoint must stamp its own timestamp");
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 1.05e18, "the composed price consumes the fresh checkpoint");
        assertEq(updatedAt, T0 + 1 days, "getPrice reports the fresh checkpoint's stamp");
        assertEq(oracle.previewPoke(), T0 + 1 days, "previewPoke must agree with getPrice");
        assertEq(oracle.poke(), T0 + 1 days, "poke must agree with getPrice");
    }

    /**
     * THE property the latch exists for: mid-cycle price drift (eg. management fee accrual checkpointed into the
     * source on every request) never marks the market, and no poke timing grants price selection power, because
     * only the owner's checkpoint samples the source
     */
    function test_Discrete_driftBetweenCheckpointsNeverMovesThePriceOrClock() public {
        // Fee accrual steps the price down mid-epoch: noise, not information
        vm.warp(T0 + 1 hours);
        _freshenFeed();
        source.setValue(0.998e18);
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 1.01e18, "mid-cycle drift must never reach the composed price");
        assertEq(updatedAt, T0, "mid-cycle drift must never move the reported timestamp");
        assertEq(oracle.poke(), T0, "a poke on drift alone must never advance the gate");

        // The drift keeps moving and pokes keep landing at chosen times: the checkpoint still never moves
        vm.warp(T0 + 2 hours);
        _freshenFeed();
        source.setValue(1.4e18);
        vm.prank(makeAddr("ANYONE"));
        assertEq(oracle.poke(), T0, "an adversarially timed poke gains no price selection power");
        assertEq(oracle.previewPoke(), T0, "previewPoke agrees while no checkpoint lands");
        (price,) = oracle.getPrice();
        assertEq(toUint256(price), 1.01e18, "the checkpoint holds the last latched reading through any drift");
        assertEq(_lastSourcePrice(oracle), 1.01e18, "no poke may latch a mid-cycle price");
    }

    /// A distressed markdown with no settlement behind it checkpoints through at the owner's call, so the market
    /// reprices exactly when the owner books the loss
    function test_Discrete_markdownCheckpointsThroughAtTheOwnersCall() public {
        vm.warp(T0 + 1 days);
        _freshenFeed();
        source.setValue(0.9e18);
        assertEq(oracle.previewPoke(), T0, "the markdown must wait for the owner's checkpoint");
        _checkpoint(oracle);
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 0.9e18, "users must transact at the marked-down value once checkpointed");
        assertEq(updatedAt, T0 + 1 days, "the markdown checkpoint stamps and opens the gate");
        assertEq(_lastSourcePrice(oracle), 0.9e18, "the markdown must latch");
    }

    /// A zero read at a checkpoint fails shut like the feed leg's non-positive answer, and the failed call leaves
    /// the stored checkpoint untouched
    function test_Discrete_RevertIf_CheckpointReadIsZero() public {
        vm.warp(T0 + 1 days);
        _freshenFeed();
        source.setValue(0);
        vm.expectRevert(DiscretePriceOracleBase.INVALID_SOURCE_PRICE.selector);
        vm.prank(owner);
        oracle.checkpointPrice();
        assertEq(_lastSourcePrice(oracle), 1.01e18, "a wiped read must never latch");
        assertEq(_lastUpdatedAt(oracle), uint32(T0), "a failed checkpoint must not stamp");
        (NAV_UNIT price,) = oracle.getPrice();
        assertEq(toUint256(price), 1.01e18, "pricing keeps serving the last honest checkpoint");
    }

    /// The packed checkpoint stores the price in 160 bits: an unrealistically large read fails loudly through the
    /// SafeCast, never truncates, and the exact boundary still latches
    function test_Discrete_RevertIf_CheckpointPriceBeyondUint160() public {
        source.setValue(uint256(type(uint160).max) + 1);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 160, uint256(type(uint160).max) + 1));
        vm.prank(owner);
        oracle.checkpointPrice();
        assertEq(_lastSourcePrice(oracle), 1.01e18, "an overflowing read must never latch");

        source.setValue(type(uint160).max);
        _checkpoint(oracle);
        assertEq(_lastSourcePrice(oracle), uint256(type(uint160).max), "the exact boundary value still latches");
    }

    /// A broken source read blocks checkpoints loudly but never pricing: the composed surface consumes only the
    /// stored checkpoint, so a source outage degrades to the last honest price until the staleness gate fires
    function test_Discrete_brokenSourceBlocksCheckpointsNotPricing() public {
        source.setRevertMode(true);
        vm.expectRevert("MockValueSource: revert mode");
        vm.prank(owner);
        oracle.checkpointPrice();
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 1.01e18, "pricing must keep serving the stored checkpoint through a source outage");
        assertEq(updatedAt, T0, "the outage must not move the reported timestamp");
    }

    /*----------------------------------------------------------------------
                        Composed pricing
    ----------------------------------------------------------------------*/

    /**
     * The composed price is the checkpointed source price times the feed price in a single floored mulDiv
     * Derivation: checkpointed price 1.01e18 (1 share = 1.01 USDC) and feed 1.00005e8 (1 USDC = 1.00005 NAV
     * units at 8 decimals): price = floor(1.01e18 * 100005000 / 1e8) = 1.0100505e18 exact, at WAD decimals
     */
    function test_Discrete_composesCheckpointedPriceWithFeed() public {
        feed.setAnswer(1.00005e8);
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 1.0100505e18, "composed price must be the checkpointed price times the feed price");
        assertEq(updatedAt, T0, "both hops sit at T0 so the report is T0");
    }

    /**
     * The single-mulDiv composition floors exactly once
     * Derivation: checkpointed price 1e18+3 and feed 1.23456789e8: price = floor((1e18+3) * 123456789 / 1e8)
     * = 123456789e10 + floor(3 * 123456789 / 1e8) = 1234567890000000000 + 3 = 1234567890000000003
     */
    function test_Discrete_compositionFloorsOnce() public {
        source.setValue(1e18 + 3);
        _checkpoint(oracle);
        feed.setAnswer(1.23456789e8);
        (NAV_UNIT price,) = oracle.getPrice();
        assertEq(toUint256(price), 1_234_567_890_000_000_003, "the composition floors the full product once");
    }

    /**
     * THE property the composition exists for: the conversion hop consumes the CHECKPOINTED source price on
     * every path, so a drifted live read never reaches the composed price until the owner checkpoints it, and
     * the checkpoint flips the hop to exactly the read it latched (the feed sits at 1e8 so the composed price is
     * the consumed conversion price verbatim)
     */
    function test_Discrete_conversionConsumesTheCheckpointNotTheLiveRead() public {
        vm.warp(T0 + 1 hours);
        _freshenFeed();
        source.setValue(1.2e18);
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 1.01e18, "the drifted live read must never reach the composed price");
        assertEq(updatedAt, T0, "the checkpoint holds its stamp through the drift");

        // The owner's checkpoint flips the hop to the latched read and advances the report
        _checkpoint(oracle);
        (price, updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 1.2e18, "the checkpoint prices exactly the read it latched");
        assertEq(updatedAt, block.timestamp, "the fresh checkpoint stamps the current timestamp");
    }

    /**
     * A settled loss composes downward unfiltered, no monotonicity anywhere: the owner books the markdown and
     * users transact at it, a full wipe cannot latch, and the recovery checkpoints back up through the same
     * path, because the latch reports, it never editorializes
     * Derivation: settled price 0.62e18 and feed 1e8: price = floor(0.62e18 * 1e8 / 1e8) = 0.62e18
     */
    function test_Discrete_lossPassesThroughAtSettlement() public {
        vm.warp(T0 + 30 days);
        _freshenFeed();
        source.setValue(0.62e18);
        _checkpoint(oracle);
        (NAV_UNIT price,) = oracle.getPrice();
        assertEq(toUint256(price), 0.62e18, "the settled loss must pass through unfiltered");
        assertEq(oracle.poke(), T0 + 30 days, "the loss checkpoint opens the gate");

        // A full wipe to zero cannot latch: the checkpoint call fails shut and the last honest price keeps serving
        vm.warp(T0 + 31 days);
        _freshenFeed();
        source.setValue(0);
        vm.expectRevert(DiscretePriceOracleBase.INVALID_SOURCE_PRICE.selector);
        vm.prank(owner);
        oracle.checkpointPrice();
        assertEq(_lastSourcePrice(oracle), 0.62e18, "a wiped read must never latch");

        // The recovery checkpoints through the same owner path, so the fail-shut window self-heals
        vm.warp(T0 + 32 days);
        _freshenFeed();
        source.setValue(0.1e18);
        _checkpoint(oracle);
        assertEq(_lastSourcePrice(oracle), 0.1e18, "the recovery latches at the next checkpoint");
        (price,) = oracle.getPrice();
        assertEq(toUint256(price), 0.1e18, "the recovered checkpoint composes verbatim");
    }

    /*----------------------------------------------------------------------
                        Report timestamp (oldest hop)
    ----------------------------------------------------------------------*/

    /// The report's timestamp is the OLDER hop on all three surfaces: an older feed binds a fresher checkpoint
    /// and an older checkpoint binds a fresher feed, so NEITHER leg alone opens the execution gate
    function test_Discrete_updatedAtIsTheOlderHopOnAllThreeSurfaces() public {
        // The older feed binds the fresher checkpoint
        feed.setUpdatedAt(T0 - 10);
        (, uint256 updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0 - 10, "the older feed hop must bind the report");
        assertEq(oracle.previewPoke(), T0 - 10, "previewPoke must agree with getPrice");
        assertEq(oracle.poke(), T0 - 10, "poke must agree with getPrice");

        // The older checkpoint binds the fresher feed
        vm.warp(T0 + 100);
        feed.setUpdatedAt(T0 + 100);
        (, updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0, "the older checkpoint hop must bind the report");
        assertEq(oracle.previewPoke(), T0, "previewPoke must agree with getPrice");
        assertEq(oracle.poke(), T0, "poke must agree with getPrice");
    }

    /// A feed heartbeat alone never advances the gate: poke keeps reporting the stored checkpoint until the
    /// owner's checkpoint lands, which then stamps its own time
    function test_Discrete_feedHeartbeatAloneNeverAdvancesTheGate() public {
        vm.warp(T0 + 100);
        feed.setUpdatedAt(T0 + 100);
        assertEq(oracle.poke(), T0, "a feed heartbeat alone must never advance the gate");
        assertEq(oracle.previewPoke(), T0, "previewPoke agrees while no checkpoint lands");

        // The owner's checkpoint is the genuine update, even at an unchanged price: the gate opens on the
        // information that the owner sampled, not on a move
        _checkpoint(oracle);
        assertEq(oracle.poke(), T0 + 100, "the owner's checkpoint opens the gate at an unchanged price");
        assertEq(_lastSourcePrice(oracle), 1.01e18, "the unchanged reading re-commits as the fresh checkpoint");
    }

    /// A checkpoint commits behind an older feed: the commit stamps its own time while the older feed hop binds
    /// the report, so the gate opens only once BOTH hops have updated
    function test_Discrete_checkpointCommitsBehindAnOlderFeed() public {
        vm.warp(T0 + 100);
        feed.setUpdatedAt(T0 + 40);
        source.setValue(1.05e18);
        _checkpoint(oracle);
        (uint160 lastSourcePrice, uint32 lastUpdatedAt) = oracle.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 1.05e18, "the checkpoint must commit despite the older feed");
        assertEq(lastUpdatedAt, T0 + 100, "the commit stamps its own observation time");
        assertEq(oracle.poke(), T0 + 40, "the older feed hop binds the report");

        // Once the feed catches up the checkpoint's own stamp is the report
        feed.setUpdatedAt(T0 + 100);
        assertEq(oracle.poke(), T0 + 100, "the gate opens only after both hops have updated");
    }

    /*----------------------------------------------------------------------
                        Per-hop staleness (immutable thresholds)
    ----------------------------------------------------------------------*/

    /**
     * The settlement hop's staleness gate: pricing fails shut once the checkpoint is older than the threshold,
     * however fresh the feed is, the exact boundary age still prices, and a fresh checkpoint re-opens pricing
     */
    function test_Discrete_RevertIf_SourceCheckpointStale() public {
        // The exact boundary age still prices and binds the report's clock
        vm.warp(T0 + SETTLEMENT_STALENESS);
        _freshenFeed();
        (, uint256 updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0, "the boundary-age checkpoint still prices and binds the clock");

        // One second past the boundary fails shut on the settlement hop despite the fresh feed: this is how a
        // missed checkpoint or a halted owner fails pricing shut
        vm.warp(T0 + SETTLEMENT_STALENESS + 1);
        _freshenFeed();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.getPrice();

        // The owner's next checkpoint re-opens pricing at its own timestamp
        _checkpoint(oracle);
        (, updatedAt) = oracle.getPrice();
        assertEq(updatedAt, block.timestamp, "a fresh checkpoint re-opens pricing at the current timestamp");
    }

    /**
     * The per-hop property: the two hops cross their gates independently. A stale feed fails shut even while the
     * checkpoint is fresh, and a stale checkpoint fails shut even while the feed is fresh
     */
    function test_Discrete_hopsFailShutIndependently() public {
        // Fresh checkpoint, stale feed: the checkpoint lands but the feed's tight gate fires first
        vm.warp(T0 + FEED_STALENESS + 1);
        _checkpoint(oracle);
        vm.expectRevert(ChainlinkPriceOracleBase.STALE_FEED_PRICE.selector);
        oracle.getPrice();

        // Fresh feed, stale checkpoint: the checkpoint ages past the settlement gate with no owner call
        vm.warp(T0 + FEED_STALENESS + 1 + SETTLEMENT_STALENESS + 1);
        _freshenFeed();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.getPrice();
    }

    /*----------------------------------------------------------------------
                        Feed hop sanity
    ----------------------------------------------------------------------*/

    /// The feed hop fails shut at its own threshold
    function test_Discrete_RevertIf_FeedHopStale() public {
        vm.warp(T0 + FEED_STALENESS + 1); // the feed was stamped at T0 in setUp
        vm.expectRevert(ChainlinkPriceOracleBase.STALE_FEED_PRICE.selector);
        oracle.getPrice();
    }

    /// A non-positive feed price cannot compose into an honest collateral price
    function test_RevertIf_FeedAnswerNonPositive() public {
        feed.setAnswer(0);
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_PRICE.selector);
        oracle.getPrice();
        feed.setAnswer(-1);
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_PRICE.selector);
        oracle.getPrice();
    }

    /// answeredInRound is deprecated and OCR aggregators always answer in the reporting round, so a lagging value must not block pricing
    function test_Discrete_deprecatedAnsweredInRound_isIgnoredByPricing() public {
        (NAV_UNIT priceBefore,) = oracle.getPrice();
        feed.setAll(7, 1e8, T0 - 50, T0 - 10, 6);
        (NAV_UNIT priceAfter,) = oracle.getPrice();
        assertEq(toUint256(priceAfter), toUint256(priceBefore), "a lagging answeredInRound must not change or block pricing");
    }
}
