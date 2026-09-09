// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
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
 * @notice Concrete vectors for the permissionless discrete composed oracle: the construction seed through the
 *         shared commit path, the ID-and-distress checkpoint predicate (an ID change is a settlement and always
 *         commits, even at an unchanged price, while the force signal admits price moves the ID cannot see),
 *         pending observations reading poke-consistently, plus the composed surface (the checkpointed conversion
 *         hop with hand-derived floors, the oldest-hop report timestamp, and both staleness gates)
 * @dev The load-bearing properties for the entry point's execution gate: an unchanged-price settlement must
 *      still stamp and open the gate (the ID clause), price drift with an unchanged ID and no force signal must
 *      never move anything (no poke timing grants price selection power), and the force signal alone at an
 *      unchanged price must manufacture no updates
 * @dev A silent settlement signal fails shut: the checkpoint ages past its staleness threshold and every
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

    MockERC20C internal collateral;
    MockValueSource internal source;
    MockAggregatorV3 internal feed;
    MockDiscretePriceOracle internal oracle;

    function setUp() public {
        vm.warp(T0);
        // An epoch-settled credit vault share whose WAD price latches at settlements, priced by an 8-decimal feed
        collateral = new MockERC20C("Pareto Credit Vault USDC", "cpUSDC", 18);
        source = new MockValueSource(1.01e18);
        feed = new MockAggregatorV3(8, 1e8);
        // Construction seeds the baseline from the live reads: the T0 checkpoint triple is (1.01e18, T0, ID 0)
        oracle = _deployOracle();
    }

    /// @dev Deploys the discrete oracle over the suite's fixtures, seeding the baseline triple from the live reads
    function _deployOracle() internal returns (MockDiscretePriceOracle) {
        return new MockDiscretePriceOracle(address(collateral), address(feed), address(source), FEED_STALENESS, SETTLEMENT_STALENESS);
    }

    /// @dev Restamps the feed at the current timestamp so checkpoint-mechanism vectors isolate the settlement hop:
    ///      the fresher feed leg never binds the oldest-hop report and never trips its own staleness gate
    function _freshenFeed() internal {
        feed.setUpdatedAt(block.timestamp);
    }

    /// @dev Reads the price leg of the committed checkpoint triple
    function _lastSourcePrice(MockDiscretePriceOracle _oracle) internal view returns (uint256) {
        (uint160 lastSourcePrice,,) = _oracle.getDiscretePriceOracleState();
        return lastSourcePrice;
    }

    /// @dev Reads the timestamp leg of the committed checkpoint triple
    function _lastUpdatedAt(MockDiscretePriceOracle _oracle) internal view returns (uint32) {
        (, uint32 lastUpdatedAt,) = _oracle.getDiscretePriceOracleState();
        return lastUpdatedAt;
    }

    /// @dev Reads the ID leg of the committed checkpoint triple
    function _lastCheckpointId(MockDiscretePriceOracle _oracle) internal view returns (uint256) {
        (,, uint256 lastCheckpointId) = _oracle.getDiscretePriceOracleState();
        return lastCheckpointId;
    }

    /*----------------------------------------------------------------------
                        Construction and seeding
    ----------------------------------------------------------------------*/

    /// Construction wires the identities, pins the immutable per-hop configuration, and rejects null or
    /// degenerate configuration
    function test_Discrete_constructionIdentityAndNullChecks() public {
        assertEq(oracle.COLLATERAL_ASSET(), address(collateral), "the collateral asset is wired");
        assertEq(address(oracle.ORACLE()), address(feed), "the feed is wired");
        assertEq(oracle.FEED_STALENESS_THRESHOLD_SECONDS(), FEED_STALENESS, "the feed hop's staleness threshold is a construction immutable");
        assertEq(
            oracle.SOURCE_PRICE_STALENESS_THRESHOLD_SECONDS(), SETTLEMENT_STALENESS, "the settlement hop's staleness threshold is a construction immutable"
        );
        assertEq(oracle.decimals(), 18, "prices are reported at WAD precision");
        assertEq(oracle.version(), 1, "version");
        assertEq(oracle.description(), string.concat("cpUSDC / ", feed.description()), "the description chains through the feed");
        assertEq(oracle.checkpointId(), 0, "the mock's checkpoint ID rests at zero, no settlement observed yet");
        assertFalse(oracle.forceCheckpoint(), "the mock's force signal rests clear, no distress observed yet");
        vm.expectRevert(ChainlinkPriceOracleBase.NULL_ADDRESS.selector);
        new MockDiscretePriceOracle(address(0), address(feed), address(source), FEED_STALENESS, SETTLEMENT_STALENESS);
        vm.expectRevert(ChainlinkPriceOracleBase.NULL_ADDRESS.selector);
        new MockDiscretePriceOracle(address(collateral), address(0), address(source), FEED_STALENESS, SETTLEMENT_STALENESS);
        // Both zero staleness thresholds are rejected per hop
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        new MockDiscretePriceOracle(address(collateral), address(feed), address(source), 0, SETTLEMENT_STALENESS);
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        new MockDiscretePriceOracle(address(collateral), address(feed), address(source), FEED_STALENESS, 0);
    }

    /**
     * Construction seeds the baseline through the same commit path pokes use: a fresh deployment latches the
     * live (price, timestamp, ID) triple and every surface prices from it immediately, a zero seed is REPORTED
     * rather than reverted (rejecting a zero price is the kernel's own guard), and a reverting seed read fails
     * the deployment loudly
     */
    function test_Discrete_constructionSeedsTheBaseline() public {
        (uint160 lastSourcePrice, uint32 lastUpdatedAt, uint256 lastCheckpointId) = oracle.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 1.01e18, "construction must latch the live source read as the baseline");
        assertEq(lastUpdatedAt, uint32(T0), "construction must stamp the seed at its own timestamp");
        assertEq(lastCheckpointId, 0, "construction must latch the live checkpoint ID");
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 1.01e18, "a fresh deployment prices its construction read");
        assertEq(updatedAt, T0, "the seed's stamp is the first reported update");
        assertEq(oracle.previewPoke(), T0, "previewPoke must agree with getPrice");
        assertEq(oracle.poke(), T0, "poke must agree with getPrice");

        // A zero seed latches and composes honestly like every source hop in the oracle family: rejecting a
        // zero price is the kernel's own guard (INVALID_PRICE at the price-cache fill), never the oracle's
        source.setValue(0);
        MockDiscretePriceOracle zeroSeeded = _deployOracle();
        (lastSourcePrice, lastUpdatedAt, lastCheckpointId) = zeroSeeded.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 0, "a zero seed latches as the baseline");
        assertEq(lastUpdatedAt, uint32(T0), "a zero seed stamps its own timestamp");
        assertEq(lastCheckpointId, 0, "a zero seed latches the live ID like any other");
        (price, updatedAt) = zeroSeeded.getPrice();
        assertEq(toUint256(price), 0, "the zero seed composes to zero and is reported as such");
        assertEq(updatedAt, T0, "the zero seed's stamp binds the report normally");

        // A reverting seed read bubbles verbatim, failing the deployment loudly
        source.setRevertMode(true);
        vm.expectRevert("MockValueSource: revert mode");
        _deployOracle();
    }

    /*----------------------------------------------------------------------
                        Drift muting (unchanged ID, no force signal)
    ----------------------------------------------------------------------*/

    /**
     * THE muting property the latch exists for: with the ID unchanged and no force signal, price drift in either
     * direction never moves the composed price, the checkpoint, or any of the three surfaces, and no poke timing
     * grants price selection power, because the predicate observes nothing to latch
     */
    function test_Discrete_driftWithUnchangedIdNeverMovesThePriceOrTheGate() public {
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
        assertEq(oracle.previewPoke(), T0, "previewPoke agrees while the ID holds and no force signal pends");
        (price,) = oracle.getPrice();
        assertEq(toUint256(price), 1.01e18, "the checkpoint holds the seeded reading through any drift");
        assertEq(_lastSourcePrice(oracle), 1.01e18, "no poke may latch a drifting price");
        assertEq(_lastUpdatedAt(oracle), uint32(T0), "no poke may stamp a drifting observation");
    }

    /*----------------------------------------------------------------------
                        The ID clause (settlements)
    ----------------------------------------------------------------------*/

    /**
     * THE headline property of the ID clause: a settlement at an UNCHANGED price still commits, stamps, and
     * opens all three surfaces, then self-resets. Without it an unchanged-price settlement would never advance
     * the reported timestamp and the entry point's execution gate would stay shut through a genuine update
     */
    function test_Discrete_idBumpAtUnchangedPriceCommitsStampsAndOpensTheGate() public {
        vm.warp(T0 + 1 days);
        _freshenFeed();
        oracle.setCheckpointId(1);

        // The pending settlement reads poke-consistently on every surface at the unchanged price
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 1.01e18, "the unchanged price keeps composing through the pending settlement");
        assertEq(updatedAt, T0 + 1 days, "the pending settlement reports the current timestamp before any commit");
        assertEq(oracle.previewPoke(), T0 + 1 days, "previewPoke must agree with getPrice on the pending settlement");
        assertEq(_lastUpdatedAt(oracle), uint32(T0), "the views must never commit the settlement");

        // The poke commits: the unchanged price re-latches with a fresh stamp and the observed ID
        assertEq(oracle.poke(), T0 + 1 days, "the unchanged-price settlement stamps and opens the gate");
        (uint160 lastSourcePrice, uint32 lastUpdatedAt, uint256 lastCheckpointId) = oracle.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 1.01e18, "the unchanged price re-commits as the fresh checkpoint");
        assertEq(lastUpdatedAt, uint32(T0 + 1 days), "the commit stamps its observation time");
        assertEq(lastCheckpointId, 1, "the commit latches the observed ID");

        // The commit self-resets the predicate: further pokes are no-ops until the next settlement
        vm.warp(T0 + 2 days);
        _freshenFeed();
        assertEq(oracle.poke(), T0 + 1 days, "the latched ID makes further pokes no-ops");
        assertEq(_lastUpdatedAt(oracle), uint32(T0 + 1 days), "a no-op poke must not restamp");
    }

    /// A settlement with a moved price latches the new price with its stamp and ID, exactly what the views
    /// reported while it pended
    function test_Discrete_idBumpWithMovedPriceLatchesTheNewPrice() public {
        vm.warp(T0 + 1 days);
        _freshenFeed();
        source.setValue(1.05e18);
        oracle.setCheckpointId(1);
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 1.05e18, "the pending settlement prices the live read before any commit");
        assertEq(updatedAt, T0 + 1 days, "the pending settlement reports the current timestamp");
        assertEq(oracle.poke(), T0 + 1 days, "the poke commits and reports the pending pair");
        (uint160 lastSourcePrice, uint32 lastUpdatedAt, uint256 lastCheckpointId) = oracle.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 1.05e18, "the settlement latches the live read");
        assertEq(lastUpdatedAt, uint32(T0 + 1 days), "the commit stamps its observation time");
        assertEq(lastCheckpointId, 1, "the commit latches the observed ID");
    }

    /// ANY ID difference counts, not just a monotonic advance: a rewound ID (a source-side reset or upgrade)
    /// still registers as a settlement and commits
    function test_Discrete_idRewindStillCommits() public {
        oracle.setCheckpointId(5);
        assertEq(oracle.poke(), T0, "the ID advance commits at the construction stamp's clock");
        assertEq(_lastCheckpointId(oracle), 5, "the advanced ID latches");

        // The rewind is just another difference from the stored ID: it commits and stamps
        vm.warp(T0 + 1 days);
        _freshenFeed();
        oracle.setCheckpointId(2);
        assertEq(oracle.poke(), T0 + 1 days, "the rewound ID still commits and stamps");
        (uint160 lastSourcePrice, uint32 lastUpdatedAt, uint256 lastCheckpointId) = oracle.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 1.01e18, "the unchanged price re-latches through the rewind");
        assertEq(lastUpdatedAt, uint32(T0 + 1 days), "the rewind commit stamps its observation time");
        assertEq(lastCheckpointId, 2, "the rewound ID latches verbatim");
    }

    /// Several settlements elapsing between pokes collapse into ONE commit capturing the latest state, the only
    /// one still priced into the source
    function test_Discrete_multipleIdBumpsBetweenPokesCommitOnce() public {
        oracle.setCheckpointId(1);
        vm.warp(T0 + 1 days);
        source.setValue(1.02e18);
        oracle.setCheckpointId(2);
        vm.warp(T0 + 2 days);
        source.setValue(1.03e18);
        oracle.setCheckpointId(3);
        _freshenFeed();

        // The first poke after the gap commits the latest (price, now, ID) in a single latch
        assertEq(oracle.poke(), T0 + 2 days, "the catch-up commit stamps the poke's own time");
        (uint160 lastSourcePrice, uint32 lastUpdatedAt, uint256 lastCheckpointId) = oracle.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 1.03e18, "the single commit captures the latest settled price");
        assertEq(lastUpdatedAt, uint32(T0 + 2 days), "the single commit carries one stamp");
        assertEq(lastCheckpointId, 3, "the single commit latches the latest ID");

        // Everything is caught up: the next poke is a no-op
        vm.warp(T0 + 3 days);
        _freshenFeed();
        assertEq(oracle.poke(), T0 + 2 days, "the caught-up predicate makes the next poke a no-op");
    }

    /*----------------------------------------------------------------------
                        The force clause (distress repricings)
    ----------------------------------------------------------------------*/

    /// The force signal alone never commits: however long it holds, an unchanged price manufactures no updates,
    /// so a permanently defaulted source cannot fabricate freshness
    function test_Discrete_forceSignalAloneNeverCommits() public {
        oracle.setForceCheckpoint(true);
        vm.warp(T0 + 1 days);
        _freshenFeed();
        assertEq(oracle.poke(), T0, "the force signal alone must never advance the gate");
        assertEq(oracle.previewPoke(), T0, "previewPoke agrees at the unchanged price");
        vm.warp(T0 + 10 days);
        _freshenFeed();
        assertEq(oracle.poke(), T0, "however long the signal holds, no update is manufactured");
        assertEq(_lastUpdatedAt(oracle), uint32(T0), "the checkpoint never restamps under the bare signal");
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 1.01e18, "the stored checkpoint keeps serving");
        assertEq(updatedAt, T0, "the stored stamp keeps binding");
    }

    /**
     * A forced repricing reads as (live price, now) on all three surfaces BEFORE any commit, poke commits
     * exactly that pair, the commit self-resets, and successive markdowns and recoveries all track through the
     * same clause, because the latch reports, it never editorializes
     * Derivation: each leg composes at the unit feed, so the composed price is the latched read verbatim
     */
    function test_Discrete_forcedPriceMoveReadsLiveCommitsAndTracksMarkdownsAndRecoveries() public {
        vm.warp(T0 + 30 days);
        _freshenFeed();
        oracle.setForceCheckpoint(true);
        source.setValue(0.62e18);

        // The views report the pair a poke would commit, with nothing committed yet
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 0.62e18, "the pending markdown prices the live read before any commit");
        assertEq(updatedAt, T0 + 30 days, "the pending markdown reports the current timestamp");
        assertEq(oracle.previewPoke(), T0 + 30 days, "previewPoke must agree with getPrice on the pending pair");
        assertEq(_lastSourcePrice(oracle), 1.01e18, "the views must never commit the markdown");

        // The poke commits the markdown and self-resets: the ID never moved, only the force clause fired
        assertEq(oracle.poke(), T0 + 30 days, "the markdown latches at the first poke that observes it");
        assertEq(_lastSourcePrice(oracle), 0.62e18, "the markdown commits verbatim");
        assertEq(_lastCheckpointId(oracle), 0, "the force clause commits without an ID change");
        assertEq(oracle.poke(), T0 + 30 days, "the latched markdown makes further pokes no-ops");

        // A deeper markdown tracks through the same clause
        vm.warp(T0 + 31 days);
        _freshenFeed();
        source.setValue(0.4e18);
        assertEq(oracle.poke(), T0 + 31 days, "the deeper markdown latches at the next poke");
        assertEq(_lastSourcePrice(oracle), 0.4e18, "the deeper markdown commits verbatim");

        // The partial recovery latches back up unfiltered, no monotonicity anywhere
        vm.warp(T0 + 32 days);
        _freshenFeed();
        source.setValue(0.7e18);
        assertEq(oracle.poke(), T0 + 32 days, "the recovery latches at the next poke");
        assertEq(_lastSourcePrice(oracle), 0.7e18, "the recovery commits verbatim");
        (price,) = oracle.getPrice();
        assertEq(toUint256(price), 0.7e18, "the recovered checkpoint composes verbatim");
    }

    /**
     * A forced wipe to zero is a pending observation like any other: all three surfaces report the zero
     * composition at the current timestamp and poke commits (0, now), because the oracle reports honestly and
     * rejecting a zero price is the kernel's own guard
     */
    function test_Discrete_pendingZeroReadComposesToZeroAndCommits() public {
        vm.warp(T0 + 1 days);
        _freshenFeed();
        oracle.setForceCheckpoint(true);
        source.setValue(0);
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 0, "the pending zero read composes to zero and is reported as such");
        assertEq(updatedAt, T0 + 1 days, "the pending zero observation reports the current timestamp");
        assertEq(oracle.previewPoke(), T0 + 1 days, "previewPoke must agree with getPrice on the pending zero pair");
        assertEq(_lastSourcePrice(oracle), 1.01e18, "the views must never commit the observation");

        // The poke commits the zero observation through the same path as any value
        assertEq(oracle.poke(), T0 + 1 days, "the poke commits and reports the pending zero pair");
        (uint160 lastSourcePrice, uint32 lastUpdatedAt,) = oracle.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 0, "the zero read latches");
        assertEq(lastUpdatedAt, uint32(T0 + 1 days), "the zero commit stamps its observation time");

        // The commit self-resets the predicate: pricing serves the committed zero from the stored triple
        (price, updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 0, "the committed zero composes from the stored checkpoint");
        assertEq(updatedAt, T0 + 1 days, "the stored zero checkpoint's stamp binds the report");
    }

    /// The packed checkpoint stores the price in 160 bits: an unrealistically large pending read fails the poke
    /// loudly through the SafeCast, never truncates, and the exact boundary still latches
    function test_Discrete_RevertIf_PendingPriceBeyondUint160() public {
        oracle.setForceCheckpoint(true);
        source.setValue(uint256(type(uint160).max) + 1);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 160, uint256(type(uint160).max) + 1));
        oracle.poke();
        assertEq(_lastSourcePrice(oracle), 1.01e18, "an overflowing read must never latch");

        source.setValue(type(uint160).max);
        oracle.poke();
        assertEq(_lastSourcePrice(oracle), uint256(type(uint160).max), "the exact boundary value still latches");
    }

    /*----------------------------------------------------------------------
                        Source lifecycle states
    ----------------------------------------------------------------------*/

    /**
     * The pool-closure state: wind-down delivers one final settlement (the closing ID bump commits), then the
     * source falls silent forever with the ID frozen, so the market has exactly one staleness window to migrate
     * before every surface bricks shut permanently, and nothing ever reopens them
     */
    function test_Discrete_windDownFinalSettlementThenPermanentBrick() public {
        // The closing settlement commits like any other
        vm.warp(T0 + 1 days);
        _freshenFeed();
        source.setValue(1.02e18);
        oracle.setCheckpointId(1);
        assertEq(oracle.poke(), T0 + 1 days, "the closing settlement commits and stamps");
        (uint160 lastSourcePrice, uint32 lastUpdatedAt, uint256 lastCheckpointId) = oracle.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 1.02e18, "the closing settlement latches the final price");
        assertEq(lastUpdatedAt, uint32(T0 + 1 days), "the closing settlement stamps its observation time");
        assertEq(lastCheckpointId, 1, "the closing settlement latches the final ID");

        // The migration window: the boundary age still prices at the final checkpoint
        vm.warp(T0 + 1 days + SETTLEMENT_STALENESS);
        _freshenFeed();
        (, uint256 updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0 + 1 days, "the final checkpoint keeps pricing through the migration window");

        // One second past the window every surface bricks shut
        vm.warp(T0 + 1 days + SETTLEMENT_STALENESS + 1);
        _freshenFeed();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.getPrice();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.previewPoke();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.poke();

        // The brick is permanent: with the ID frozen and no force signal, further warps and drift reopen nothing
        vm.warp(T0 + 300 days);
        _freshenFeed();
        source.setValue(0.9e18);
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.getPrice();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.previewPoke();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.poke();
        assertEq(_lastUpdatedAt(oracle), uint32(T0 + 1 days), "nothing ever moves the bricked checkpoint");
    }

    /**
     * The counter-decoupling hazard the concrete's NOTE documents (behavior, not a bug): with the source price
     * FROZEN, a counter that keeps ticking re-stamps the unchanged price on every poke, so a total span far past
     * SETTLEMENT_STALENESS never trips the gate. The staleness gate presumes the counter belongs to the priced
     * source, so a counter decoupled from it (eg. an upstream strategy repoint) requires an oracle redeploy
     */
    function test_Discrete_liveCounterDefeatsTheStalenessGateByDesign() public {
        // Four 20-day strides re-stamp the frozen price across 80 days, far past the 45-day threshold
        for (uint256 i = 1; i <= 4; i++) {
            vm.warp(T0 + i * 20 days);
            _freshenFeed();
            oracle.setCheckpointId(i);
            assertEq(oracle.poke(), T0 + i * 20 days, "each counter tick re-stamps the frozen price");
        }
        (uint160 lastSourcePrice, uint32 lastUpdatedAt, uint256 lastCheckpointId) = oracle.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 1.01e18, "the price never moved across the whole span");
        assertEq(lastUpdatedAt, uint32(T0 + 80 days), "the last tick's stamp is current");
        assertEq(lastCheckpointId, 4, "the last tick's ID is stored");

        // 80 days after construction the oracle still prices: the live counter defeated the staleness gate
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 1.01e18, "a live counter keeps the frozen price priced by design");
        assertEq(updatedAt, T0 + 80 days, "the re-stamped checkpoint binds the report as fresh");
    }

    /**
     * The stopEpoch-catch default class: the defaulting transaction itself accrues fees, so the price dips a few
     * wei in the same stage the force signal flips, and the first poke commits immediately at the dipped price
     * (the gate opens at the default). Contrast: a force flip at an EXACTLY unchanged price commits nothing
     * until the first later move
     */
    function test_Discrete_forceFlipWithSameStageDustDipCommitsImmediately() public {
        // The default flips the signal and dips the price by dust in one stage: the first poke commits it
        vm.warp(T0 + 1 days);
        _freshenFeed();
        oracle.setForceCheckpoint(true);
        source.setValue(1.01e18 - 3);
        assertEq(oracle.poke(), T0 + 1 days, "the dust-dipped default commits at the first poke");
        (uint160 lastSourcePrice, uint32 lastUpdatedAt,) = oracle.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 1.01e18 - 3, "the dipped price latches verbatim");
        assertEq(lastUpdatedAt, uint32(T0 + 1 days), "the gate opens at the default");

        // The contrast: a second oracle whose force flip lands at an EXACTLY unchanged price
        source.setValue(1.005e18);
        MockDiscretePriceOracle exact = _deployOracle();
        exact.setForceCheckpoint(true);
        vm.warp(T0 + 2 days);
        _freshenFeed();
        assertEq(exact.poke(), T0 + 1 days, "an exactly unchanged price under the flipped signal commits nothing");
        assertEq(_lastUpdatedAt(exact), uint32(T0 + 1 days), "the seed's stamp holds until a move lands");

        // The first later move commits through the force clause
        source.setValue(1.005e18 - 1);
        assertEq(exact.poke(), T0 + 2 days, "the first later move commits");
        assertEq(_lastSourcePrice(exact), 1.005e18 - 1, "the first later move latches verbatim");
    }

    /**
     * The distressed-pre-markdown deployment precondition: between a default and its first markdown the source
     * still reads the pre-loss price, so a fresh oracle constructed in that window seeds the pre-loss price
     * live-and-fresh, and the markdown re-latches at the next poke once it lands
     */
    function test_Discrete_constructionWhileDistressedSeedsThePreLossPrice() public {
        // The source is already defaulted but the loss is not yet marked down: construction seeds the pre-loss read
        vm.warp(T0 + 1 days);
        _freshenFeed();
        MockDiscretePriceOracle distressed = _deployOracle();
        distressed.setForceCheckpoint(true);
        (NAV_UNIT price, uint256 updatedAt) = distressed.getPrice();
        assertEq(toUint256(price), 1.01e18, "the distressed deployment seeds and prices the pre-loss read");
        assertEq(updatedAt, T0 + 1 days, "the pre-loss seed is live and fresh from construction");

        // The markdown lands and the next poke re-latches it through the force clause
        vm.warp(T0 + 2 days);
        _freshenFeed();
        source.setValue(0.7e18);
        assertEq(distressed.poke(), T0 + 2 days, "the markdown re-latches at the next poke");
        (uint160 lastSourcePrice, uint32 lastUpdatedAt,) = distressed.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 0.7e18, "the markdown commits verbatim");
        assertEq(lastUpdatedAt, uint32(T0 + 2 days), "the markdown commit stamps its observation time");
    }

    /**
     * The keyless-loss family the predicate cannot see (an owner recall, a junior-wipe class event): with the ID
     * frozen and no force signal, a 12% markdown never reaches any surface, the checkpoint keeps serving, and
     * the oracle's endgame is unpriced-then-fail-shut, never a live misprice through its own surfaces
     * Derivation: 12% off the 1.01e18 checkpoint is 1.01e18 * 88 / 100 = 0.8888e18
     */
    function test_Discrete_mutedMarkdownFailsShutRatherThanMisprices() public {
        vm.warp(T0 + 1 days);
        _freshenFeed();
        source.setValue(0.8888e18);
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 1.01e18, "the muted markdown never reaches the composed price");
        assertEq(updatedAt, T0, "the muted markdown never moves the reported timestamp");
        assertEq(oracle.previewPoke(), T0, "previewPoke keeps serving the checkpoint");
        assertEq(oracle.poke(), T0, "poke keeps serving the checkpoint and commits nothing");
        assertEq(_lastSourcePrice(oracle), 1.01e18, "the loss the predicate cannot see never latches");

        // The endgame: the checkpoint ages out and pricing fails shut instead of ever serving the stale value
        vm.warp(T0 + SETTLEMENT_STALENESS + 1);
        _freshenFeed();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.getPrice();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.previewPoke();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.poke();
    }

    /**
     * The force-held staleness round trip: the force signal with a frozen price cannot keep the checkpoint
     * fresh, so pricing bricks past the staleness window, and the first later move (a single wei at day 46)
     * un-bricks every surface with a pending observation reading (live, now) that the poke then commits
     */
    function test_Discrete_forceHeldStalenessRoundTrip() public {
        // The signal holds but the price never moves: the checkpoint ages out and every surface bricks
        oracle.setForceCheckpoint(true);
        vm.warp(T0 + SETTLEMENT_STALENESS + 1);
        _freshenFeed();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.getPrice();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.previewPoke();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.poke();

        // A single wei of movement at day 46 un-bricks: the pending observation reads (live, now) and commits
        vm.warp(T0 + 46 days);
        _freshenFeed();
        source.setValue(1.01e18 + 1);
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), 1.01e18 + 1, "the pending observation prices the live read past the stale window");
        assertEq(updatedAt, T0 + 46 days, "the pending observation reports the current timestamp");
        assertEq(oracle.previewPoke(), T0 + 46 days, "previewPoke must agree with getPrice");
        assertEq(oracle.poke(), T0 + 46 days, "the poke commits the un-bricking observation");
        (uint160 lastSourcePrice, uint32 lastUpdatedAt,) = oracle.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 1.01e18 + 1, "the single-wei move latches verbatim");
        assertEq(lastUpdatedAt, uint32(T0 + 46 days), "the un-bricking commit stamps its observation time");
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
     * The single-mulDiv composition floors exactly once at the checkpointed price
     * Derivation: checkpointed price 1e18+3 and feed 1.23456789e8: price = floor((1e18+3) * 123456789 / 1e8)
     * = 123456789e10 + floor(3 * 123456789 / 1e8) = 1234567890000000000 + 3 = 1234567890000000003
     */
    function test_Discrete_compositionFloorsOnce() public {
        // The checkpointed price under test lands through the construction seed, the same commit path pokes use
        source.setValue(1e18 + 3);
        MockDiscretePriceOracle seeded = _deployOracle();
        feed.setAnswer(1.23456789e8);
        (NAV_UNIT price,) = seeded.getPrice();
        assertEq(toUint256(price), 1_234_567_890_000_000_003, "the composition floors the full product once");
    }

    /*----------------------------------------------------------------------
                        Report timestamp (oldest hop)
    ----------------------------------------------------------------------*/

    /**
     * The report's timestamp is the OLDER hop on all three surfaces: an older feed binds a fresher checkpoint,
     * and an aged checkpoint binds a fresher feed once time passes with no settlement, so NEITHER leg alone
     * opens the execution gate
     */
    function test_Discrete_updatedAtIsTheOlderHopOnAllThreeSurfaces() public {
        // The older feed binds the fresher checkpoint
        feed.setUpdatedAt(T0 - 10);
        (, uint256 updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0 - 10, "the older feed hop must bind the report");
        assertEq(oracle.previewPoke(), T0 - 10, "previewPoke must agree with getPrice");
        assertEq(oracle.poke(), T0 - 10, "poke must agree with getPrice");

        // The checkpoint ages behind the settlement-free warp and binds the fresher feed
        vm.warp(T0 + 100);
        feed.setUpdatedAt(T0 + 100);
        (, updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0, "the older checkpoint hop must bind the report");
        assertEq(oracle.previewPoke(), T0, "previewPoke must agree with getPrice");
        assertEq(oracle.poke(), T0, "poke must agree with getPrice");
    }

    /// A feed heartbeat alone never advances the gate: poke keeps reporting the stored checkpoint until a
    /// settlement lands, which then stamps its own time even at an unchanged price
    function test_Discrete_feedHeartbeatAloneNeverAdvancesTheGate() public {
        vm.warp(T0 + 100);
        feed.setUpdatedAt(T0 + 100);
        assertEq(oracle.poke(), T0, "a feed heartbeat alone must never advance the gate");
        assertEq(oracle.previewPoke(), T0, "previewPoke agrees while no settlement pends");

        // The settlement is the genuine update, even at an unchanged price: the gate opens on the information
        // that the source settled, not on a move
        oracle.setCheckpointId(1);
        assertEq(oracle.poke(), T0 + 100, "the settlement opens the gate at an unchanged price");
        assertEq(_lastSourcePrice(oracle), 1.01e18, "the unchanged reading re-commits as the fresh checkpoint");
    }

    /// A settlement commits behind an older feed: the commit stamps its own time while the older feed hop binds
    /// the report, so the gate opens only once BOTH hops have updated
    function test_Discrete_settlementCommitsBehindAnOlderFeed() public {
        vm.warp(T0 + 100);
        feed.setUpdatedAt(T0 + 40);
        source.setValue(1.05e18);
        oracle.setCheckpointId(1);
        assertEq(oracle.poke(), T0 + 40, "the older feed hop binds the report");
        (uint160 lastSourcePrice, uint32 lastUpdatedAt, uint256 lastCheckpointId) = oracle.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, 1.05e18, "the settlement must commit despite the older feed");
        assertEq(lastUpdatedAt, uint32(T0 + 100), "the commit stamps its own observation time");
        assertEq(lastCheckpointId, 1, "the commit latches the observed ID");

        // Once the feed catches up the checkpoint's own stamp is the report
        feed.setUpdatedAt(T0 + 100);
        assertEq(oracle.poke(), T0 + 100, "the gate opens only after both hops have updated");
    }

    /*----------------------------------------------------------------------
                        Per-hop staleness (immutable thresholds)
    ----------------------------------------------------------------------*/

    /**
     * The settlement hop's staleness gate: pricing fails shut once the checkpoint is older than the threshold,
     * however fresh the feed is, the exact boundary age still prices, and the next settlement re-opens pricing
     * through the predicate
     */
    function test_Discrete_RevertIf_SourceCheckpointStale() public {
        // The exact boundary age still prices and binds the report's clock
        vm.warp(T0 + SETTLEMENT_STALENESS);
        _freshenFeed();
        (, uint256 updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0, "the boundary-age checkpoint still prices and binds the clock");

        // One second past the boundary fails shut on the settlement hop despite the fresh feed: this is how a
        // missed settlement or a silently frozen source fails pricing shut
        vm.warp(T0 + SETTLEMENT_STALENESS + 1);
        _freshenFeed();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.getPrice();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.poke();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.previewPoke();

        // The next settlement re-opens pricing at its own timestamp
        oracle.setCheckpointId(1);
        (, updatedAt) = oracle.getPrice();
        assertEq(updatedAt, block.timestamp, "a pending settlement re-opens pricing at the current timestamp");
        assertEq(oracle.poke(), block.timestamp, "the commit re-opens pricing through the same pair");
    }

    /**
     * The per-hop property: the two hops cross their gates independently. A stale feed fails shut even while the
     * source leg previews as current, and a stale checkpoint fails shut even while the feed is fresh
     */
    function test_Discrete_hopsFailShutIndependently() public {
        // Pending-fresh source leg, stale feed: the settlement previews as current but the feed's tight gate fires
        vm.warp(T0 + FEED_STALENESS + 1);
        oracle.setCheckpointId(1);
        vm.expectRevert(ChainlinkPriceOracleBase.STALE_FEED_PRICE.selector);
        oracle.getPrice();

        // Fresh feed, stale checkpoint: with the ID back at the stored value the checkpoint ages past the gate
        oracle.setCheckpointId(0);
        vm.warp(T0 + SETTLEMENT_STALENESS + 1);
        _freshenFeed();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.getPrice();
    }

    /// A seeded oracle under a never-stale threshold keeps pricing its construction read indefinitely, however
    /// far the settlement signal falls silent
    function test_Discrete_neverStaleThresholdStillPricesWhenSeeded() public {
        MockDiscretePriceOracle neverStale = new MockDiscretePriceOracle(address(collateral), address(feed), address(source), FEED_STALENESS, type(uint32).max);
        vm.warp(T0 + 400 days);
        _freshenFeed();
        (NAV_UNIT price, uint256 updatedAt) = neverStale.getPrice();
        assertEq(toUint256(price), 1.01e18, "the seeded checkpoint keeps pricing under a never-stale threshold");
        assertEq(updatedAt, T0, "the aged seed still binds the report's clock");
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
    function test_Discrete_RevertIf_FeedAnswerNonPositive() public {
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
