// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../../lib/forge-std/src/Test.sol";
import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IIdleCDO } from "../../../../src/interfaces/external/idle-finance/IIdleCDO.sol";
import { IIdleCreditVault } from "../../../../src/interfaces/external/idle-finance/IIdleCreditVault.sol";
import { NAV_UNIT, toUint256 } from "../../../../src/libraries/Units.sol";
import { DiscreteIdleCDOTranchePriceOracle } from "../../../../src/oracle/DiscreteIdleCDOTranchePriceOracle.sol";
import { DiscretePriceOracleBase } from "../../../../src/oracle/base/DiscretePriceOracleBase.sol";

/**
 * @title Test_DiscreteIdleCDO_FalconXFork
 * @notice Oracle-level fork vectors for the discrete Idle CDO tranche oracle against the REAL Pareto FalconX
 *         USDC credit vault on mainnet: the construction seed latching the live (virtualPrice, now, epochNumber)
 *         triple, the composed price hand-derived from the same live reads, real tranche membership on both the
 *         AA and BB legs, and the checkpoint predicate driven off real state wherever real state can express it
 * @dev vm.mockCall stands in only where real state cannot be driven from a test: settlements (epochNumber bumps),
 *      the borrower default flag, and virtualPrice moves, each mock self-seeded from the live reads captured in
 *      setUp so every vector starts at reality
 * @dev The live vault premises the vectors rest on, asserted in setUp so a changed reality fails loudly: the
 *      vault is undefaulted and the USDC/USD feed is fresh within its 24h heartbeat at the forked block
 * @dev Every expected value is derived by hand from the live reads captured in setUp, never from the oracle
 */
contract Test_DiscreteIdleCDO_FalconXFork is Test {
    /// @dev The REAL Pareto FalconX USDC Idle CDO (a proxy) and its tranche and feed periphery on mainnet
    address internal constant PARETO_FALCONX_CDO = 0x433D5B175148dA32Ffe1e1A37a939E1b7e79be4d;
    address internal constant AA_TRANCHE_TOKEN = 0xC26A6Fa2C37b38E549a4a1807543801Db684f99C;
    address internal constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev The per-hop staleness immutables under test: the Chainlink leg at its doubled 24h heartbeat, the
    ///      virtual-price checkpoint sized to the CDO's monthly epoch cadence plus slack
    uint32 internal constant FEED_STALENESS = 48 hours;
    uint32 internal constant SOURCE_STALENESS = 45 days;

    /// @dev USDC carries 6 decimals so the oracle lifts virtualPrice to WAD with exactly this multiplier
    uint256 internal constant VIRTUAL_PRICE_LIFT = 1e12;

    DiscreteIdleCDOTranchePriceOracle internal oracle;

    // Live reads captured once in setUp: every expected value below derives from these, never from the oracle
    uint256 internal liveVirtualPrice;
    address internal liveStrategy;
    uint256 internal liveEpochNumber;
    int256 internal liveFeedAnswer;
    uint256 internal liveFeedUpdatedAt;
    uint256 internal liveFeedPrecision;
    uint256 internal seedTimestamp;

    /**
     * @dev Forks mainnet at the LATEST block, a recent-state fork a pruned or non-archive RPC can serve
     *      (CI can pin a fork block here once an archive RPC is guaranteed), skipping the whole suite when
     *      MAINNET_RPC_URL is unset to match the config-driven kernel fork suites
     */
    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        // Capture the live reads every expected value derives from, before the oracle exists
        liveVirtualPrice = IIdleCDO(PARETO_FALCONX_CDO).virtualPrice(AA_TRANCHE_TOKEN);
        liveStrategy = IIdleCDO(PARETO_FALCONX_CDO).strategy();
        liveEpochNumber = IIdleCreditVault(liveStrategy).epochNumber();
        (, liveFeedAnswer,, liveFeedUpdatedAt,) = AggregatorV3Interface(USDC_USD_FEED).latestRoundData();
        liveFeedPrecision = 10 ** AggregatorV3Interface(USDC_USD_FEED).decimals();
        seedTimestamp = block.timestamp;

        // The premises the vectors rest on: an undefaulted vault and a heartbeat-fresh feed at the forked block
        assertFalse(IIdleCDO(PARETO_FALCONX_CDO).defaulted(), "the vectors assume the live vault is undefaulted, re-derive them from reality if this trips");
        assertLe(block.timestamp - liveFeedUpdatedAt, FEED_STALENESS, "the vectors assume the live feed is fresh at the forked block");

        oracle = new DiscreteIdleCDOTranchePriceOracle(PARETO_FALCONX_CDO, AA_TRANCHE_TOKEN, USDC_USD_FEED, FEED_STALENESS, SOURCE_STALENESS);
    }

    /*----------------------------------------------------------------------
                        Derivation and mock helpers
    ----------------------------------------------------------------------*/

    /// @dev The composition definition by hand: the WAD-lifted virtual price times the feed answer, floored once
    function _composedPrice(uint256 _virtualPrice) internal view returns (uint256) {
        return (_virtualPrice * VIRTUAL_PRICE_LIFT * uint256(liveFeedAnswer)) / liveFeedPrecision;
    }

    /// @dev Mocks the REAL CDO's virtualPrice for the AA tranche, always seeded relative to the live read
    function _mockVirtualPrice(uint256 _virtualPrice) internal {
        vm.mockCall(PARETO_FALCONX_CDO, abi.encodeWithSelector(IIdleCDO.virtualPrice.selector, AA_TRANCHE_TOKEN), abi.encode(_virtualPrice));
    }

    /// @dev Mocks the REAL strategy's settlement counter, always offset from the live epoch number
    function _mockEpochNumber(uint256 _epochNumber) internal {
        vm.mockCall(liveStrategy, abi.encodeWithSelector(IIdleCreditVault.epochNumber.selector), abi.encode(_epochNumber));
    }

    /// @dev Mocks the REAL CDO's permanent default flag, the oracle's force-checkpoint signal
    function _mockDefaulted(bool _defaulted) internal {
        vm.mockCall(PARETO_FALCONX_CDO, abi.encodeWithSelector(IIdleCDO.defaulted.selector), abi.encode(_defaulted));
    }

    /// @dev Re-stamps the feed at the current timestamp holding the live answer, so post-warp vectors isolate
    ///      the checkpoint hop (mirroring the kernel suite's post-warp feed refresh)
    function _restampFeedMock() internal {
        vm.mockCall(
            USDC_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), liveFeedAnswer, block.timestamp, block.timestamp, uint80(1))
        );
    }

    /// @dev Asserts the view surfaces report the hand-derived pair and previewPoke agrees with getPrice, the
    ///      poke-consistency invariant checked at every stage without committing anything
    function _assertViewSurfaces(uint256 _expectedPriceWAD, uint256 _expectedUpdatedAt, string memory _context) internal view {
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), _expectedPriceWAD, string.concat(_context, ": getPrice price"));
        assertEq(updatedAt, _expectedUpdatedAt, string.concat(_context, ": getPrice updatedAt"));
        assertEq(oracle.previewPoke(), _expectedUpdatedAt, string.concat(_context, ": previewPoke must agree with getPrice"));
    }

    function _checkpointTriple() internal view returns (uint160 lastSourcePrice, uint32 lastUpdatedAt, uint256 lastCheckpointId) {
        return oracle.getDiscretePriceOracleState();
    }

    /*----------------------------------------------------------------------
                        Construction against the live vault
    ----------------------------------------------------------------------*/

    /**
     * Construction seeds the baseline from the live vault through the same commit path pokes use: the checkpoint
     * triple is the live virtualPrice lifted to WAD, the deployment timestamp, and the live settlement counter,
     * with every identity wired to the real periphery
     * Derivation: the live AA virtualPrice is read in USDC's 6 decimals so the lift is exactly 1e12, and the
     * description chains the real tranche symbol through the real feed description, "AA_FalconXUSDC / USDC / USD"
     * on the live vault
     */
    function test_Fork_constructionSeedsFromTheLiveVault() public view {
        (uint160 lastSourcePrice, uint32 lastUpdatedAt, uint256 lastCheckpointId) = _checkpointTriple();
        assertEq(lastSourcePrice, liveVirtualPrice * VIRTUAL_PRICE_LIFT, "construction must latch the live virtualPrice lifted to WAD");
        assertEq(lastUpdatedAt, uint32(seedTimestamp), "construction must stamp the seed at its own timestamp");
        assertEq(lastCheckpointId, liveEpochNumber, "construction must latch the live epoch number as the checkpoint ID");

        assertEq(oracle.IDLE_CDO(), PARETO_FALCONX_CDO, "the real CDO is wired");
        assertEq(oracle.CREDIT_VAULT_STRATEGY(), liveStrategy, "the strategy pointer is cached from the real CDO at construction");
        assertEq(oracle.COLLATERAL_ASSET(), AA_TRANCHE_TOKEN, "the real AA tranche is the collateral asset");
        assertEq(address(oracle.ORACLE()), USDC_USD_FEED, "the real feed is wired");
        assertEq(oracle.FEED_STALENESS_THRESHOLD_SECONDS(), FEED_STALENESS, "the feed hop's staleness threshold is a construction immutable");
        assertEq(oracle.SOURCE_PRICE_STALENESS_THRESHOLD_SECONDS(), SOURCE_STALENESS, "the checkpoint hop's staleness threshold is a construction immutable");
        assertEq(oracle.decimals(), 18, "prices are reported at WAD precision");
        assertEq(
            oracle.description(),
            string.concat(IERC20Metadata(AA_TRANCHE_TOKEN).symbol(), " / ", AggregatorV3Interface(USDC_USD_FEED).description()),
            "the description chains the real tranche symbol through the real feed"
        );
        assertEq(oracle.description(), "AA_FalconXUSDC / USDC / USD", "the live symbols compose the documented pair chain");
    }

    /*----------------------------------------------------------------------
                        Real composition
    ----------------------------------------------------------------------*/

    /**
     * The composed price against pure live state: the WAD-lifted live virtualPrice times the live feed answer in
     * a single floored mulDiv, reported at the older hop
     * Derivation: price = floor(liveVirtualPrice * 1e12 * liveFeedAnswer / 1e8) and updatedAt is the older of the
     * feed's live stamp and the seed timestamp, all from the setUp captures
     */
    function test_Fork_composesTheLiveVirtualPriceWithTheLiveFeed() public {
        uint256 expectedPrice = _composedPrice(liveVirtualPrice);
        uint256 expectedUpdatedAt = ((liveFeedUpdatedAt < seedTimestamp) ? liveFeedUpdatedAt : seedTimestamp);
        _assertViewSurfaces(expectedPrice, expectedUpdatedAt, "live composition");
        assertEq(oracle.poke(), expectedUpdatedAt, "live composition: poke must agree with getPrice");
    }

    /**
     * The BB leg against pure live state: an oracle deployed for the real BB tranche seeds and composes from the
     * BB tranche's OWN live virtualPrice, which differs from the AA leg's on the live vault (the live BB supply
     * is zero, so its virtual price reads the empty-tranche one-token branch while AA carries the accrued interest)
     */
    function test_Fork_bbTrancheSeedsAndPricesFromItsOwnLiveRead() public {
        address bbTranche = IIdleCDO(PARETO_FALCONX_CDO).BBTranche();
        uint256 bbVirtualPrice = IIdleCDO(PARETO_FALCONX_CDO).virtualPrice(bbTranche);
        assertNotEq(bbVirtualPrice, liveVirtualPrice, "the live BB virtualPrice must differ from the AA leg's");

        DiscreteIdleCDOTranchePriceOracle bbOracle =
            new DiscreteIdleCDOTranchePriceOracle(PARETO_FALCONX_CDO, bbTranche, USDC_USD_FEED, FEED_STALENESS, SOURCE_STALENESS);
        (uint160 lastSourcePrice,, uint256 lastCheckpointId) = bbOracle.getDiscretePriceOracleState();
        assertEq(lastSourcePrice, bbVirtualPrice * VIRTUAL_PRICE_LIFT, "the BB oracle must seed from the BB tranche's own live read");
        assertEq(lastCheckpointId, liveEpochNumber, "both tranches share the strategy's settlement counter");

        (NAV_UNIT price,) = bbOracle.getPrice();
        assertEq(toUint256(price), (bbVirtualPrice * VIRTUAL_PRICE_LIFT * uint256(liveFeedAnswer)) / liveFeedPrecision, "the BB composition prices its own leg");
        assertEq(
            bbOracle.description(),
            string.concat(IERC20Metadata(bbTranche).symbol(), " / ", AggregatorV3Interface(USDC_USD_FEED).description()),
            "the BB description chains the real junior symbol through the real feed"
        );
    }

    /// virtualPrice treats any unknown address as the BB tranche, so construction against the real CDO must
    /// reject a collateral asset that is neither of its tranche tokens
    function test_Fork_RevertIf_CollateralIsNotACDOTranche() public {
        address notATranche = makeAddr("NOT_A_TRANCHE");
        vm.expectRevert(DiscreteIdleCDOTranchePriceOracle.COLLATERAL_ASSET_MUST_BE_CDO_TRANCHE.selector);
        new DiscreteIdleCDOTranchePriceOracle(PARETO_FALCONX_CDO, notATranche, USDC_USD_FEED, FEED_STALENESS, SOURCE_STALENESS);
    }

    /*----------------------------------------------------------------------
                        Drift muting on the real vault
    ----------------------------------------------------------------------*/

    /**
     * Fee drift against the real predicate legs: with the REAL epoch number unchanged and the REAL default flag
     * false, a realistic fee-accrual dip in virtualPrice never moves the composed price, the reported timestamp,
     * or the checkpoint on any of the three surfaces
     * Derivation: the seeded composition and the older-hop report from setUp's captures stand unchanged
     */
    function test_Fork_feeDriftAtTheLiveEpochNeverMovesThePriceOrClock() public {
        uint256 expectedPrice = _composedPrice(liveVirtualPrice);
        uint256 expectedUpdatedAt = ((liveFeedUpdatedAt < seedTimestamp) ? liveFeedUpdatedAt : seedTimestamp);

        // Fees accrue against the vault mid-epoch, dipping the live reading a few underlying units
        _mockVirtualPrice(liveVirtualPrice - 3);
        _assertViewSurfaces(expectedPrice, expectedUpdatedAt, "fee drift");
        assertEq(oracle.poke(), expectedUpdatedAt, "a poke on drift alone must never advance the gate");
        (uint160 lastSourcePrice, uint32 lastUpdatedAt, uint256 lastCheckpointId) = _checkpointTriple();
        assertEq(lastSourcePrice, liveVirtualPrice * VIRTUAL_PRICE_LIFT, "no poke may latch a drifting price");
        assertEq(lastUpdatedAt, uint32(seedTimestamp), "no poke may stamp a drifting observation");
        assertEq(lastCheckpointId, liveEpochNumber, "the real settlement counter still binds the checkpoint ID");
    }

    /*----------------------------------------------------------------------
                        Settlements (the ID clause)
    ----------------------------------------------------------------------*/

    /**
     * A settlement on the real strategy's counter: the epoch bump with a raised virtualPrice reads as the pending
     * pair on every surface, poke latches the new price, stamps its own time, and stores the new ID, then a
     * second bump at an UNCHANGED price still stamps and opens the gate
     * Derivation: each commit's report is its own poke time because the feed is re-stamped at now, so the
     * checkpoint hop is the older leg's equal
     */
    function test_Fork_settlementLatchesAndAnUnchangedPriceSettlementStillStamps() public {
        uint256 raisedVirtualPrice = liveVirtualPrice + 500;
        uint256 t1 = seedTimestamp + 1 days;
        vm.warp(t1);
        _restampFeedMock();
        _mockVirtualPrice(raisedVirtualPrice);
        _mockEpochNumber(liveEpochNumber + 1);

        // The pending settlement reads poke-consistently before any commit
        _assertViewSurfaces(_composedPrice(raisedVirtualPrice), t1, "pending settlement");
        (, uint32 lastUpdatedAt,) = _checkpointTriple();
        assertEq(lastUpdatedAt, uint32(seedTimestamp), "the views must never commit the settlement");

        // The poke latches the raised price, stamps now, and stores the new ID
        assertEq(oracle.poke(), t1, "the settlement stamps and opens the gate");
        (uint160 lastSourcePrice, uint32 committedAt, uint256 lastCheckpointId) = _checkpointTriple();
        assertEq(lastSourcePrice, raisedVirtualPrice * VIRTUAL_PRICE_LIFT, "the settlement latches the raised price");
        assertEq(committedAt, uint32(t1), "the commit stamps its observation time");
        assertEq(lastCheckpointId, liveEpochNumber + 1, "the commit stores the bumped epoch number");

        // The next settlement lands at an UNCHANGED price: it still stamps and opens the gate
        uint256 t2 = seedTimestamp + 2 days;
        vm.warp(t2);
        _restampFeedMock();
        _mockEpochNumber(liveEpochNumber + 2);
        _assertViewSurfaces(_composedPrice(raisedVirtualPrice), t2, "unchanged-price settlement");
        assertEq(oracle.poke(), t2, "the unchanged-price settlement stamps and opens the gate");
        (lastSourcePrice, committedAt, lastCheckpointId) = _checkpointTriple();
        assertEq(lastSourcePrice, raisedVirtualPrice * VIRTUAL_PRICE_LIFT, "the unchanged price re-commits as the fresh checkpoint");
        assertEq(committedAt, uint32(t2), "the unchanged-price commit still stamps its observation time");
        assertEq(lastCheckpointId, liveEpochNumber + 2, "the commit stores the second bumped epoch number");
    }

    /*----------------------------------------------------------------------
                        Default markdown (the force clause)
    ----------------------------------------------------------------------*/

    /**
     * A borrower default on the real vault: with the default flag raised and the REAL epoch number frozen at the
     * live value, a 12% markdown reads as (marked-down, now) before any commit, poke commits it with the ID
     * unchanged (only the force clause fired), a partial recovery re-latches through the same clause, and once
     * the flag clears drift is muted again
     * Derivation: each composed expectation is the mocked virtualPrice through the hand composition, and the
     * post-clear report keeps serving the recovery checkpoint's pair
     */
    function test_Fork_defaultMarkdownAndRecoveryTrackThroughTheForceClause() public {
        uint256 markdownVirtualPrice = (liveVirtualPrice * 88) / 100;
        uint256 t1 = seedTimestamp + 1 days;
        vm.warp(t1);
        _restampFeedMock();
        _mockDefaulted(true);
        _mockVirtualPrice(markdownVirtualPrice);

        // The pending markdown reads poke-consistently before any commit
        _assertViewSurfaces(_composedPrice(markdownVirtualPrice), t1, "pending markdown");
        (uint160 lastSourcePrice,,) = _checkpointTriple();
        assertEq(lastSourcePrice, liveVirtualPrice * VIRTUAL_PRICE_LIFT, "the views must never commit the markdown");

        // The poke commits the markdown without an ID change: only the force clause fired
        assertEq(oracle.poke(), t1, "the markdown latches at the first poke that observes it");
        uint32 committedAt;
        uint256 lastCheckpointId;
        (lastSourcePrice, committedAt, lastCheckpointId) = _checkpointTriple();
        assertEq(lastSourcePrice, markdownVirtualPrice * VIRTUAL_PRICE_LIFT, "the markdown commits verbatim");
        assertEq(committedAt, uint32(t1), "the markdown commit stamps its observation time");
        assertEq(lastCheckpointId, liveEpochNumber, "the force clause commits with the real epoch number frozen");

        // The partial recovery re-latches through the same clause, no monotonicity anywhere
        uint256 recoveryVirtualPrice = (liveVirtualPrice * 95) / 100;
        uint256 t2 = seedTimestamp + 2 days;
        vm.warp(t2);
        _restampFeedMock();
        _mockVirtualPrice(recoveryVirtualPrice);
        _assertViewSurfaces(_composedPrice(recoveryVirtualPrice), t2, "pending recovery");
        assertEq(oracle.poke(), t2, "the recovery latches at the next poke");
        (lastSourcePrice, committedAt, lastCheckpointId) = _checkpointTriple();
        assertEq(lastSourcePrice, recoveryVirtualPrice * VIRTUAL_PRICE_LIFT, "the recovery commits verbatim");
        assertEq(committedAt, uint32(t2), "the recovery commit stamps its observation time");

        // Clearing the default mock restores the REAL flag (false): drift is muted again
        vm.clearMockedCalls();
        _mockVirtualPrice(recoveryVirtualPrice - 4);
        vm.warp(seedTimestamp + 3 days);
        _restampFeedMock();
        _assertViewSurfaces(_composedPrice(recoveryVirtualPrice), t2, "post-default drift");
        assertEq(oracle.poke(), t2, "with the real flag clear, drift alone must never advance the gate");
        (lastSourcePrice,,) = _checkpointTriple();
        assertEq(lastSourcePrice, recoveryVirtualPrice * VIRTUAL_PRICE_LIFT, "the recovery checkpoint keeps serving through post-default drift");
    }

    /**
     * The stopEpoch-catch default class on the real vault: the defaulting transaction itself accrues fees, so
     * virtualPrice dips a few underlying units in the same stage the default flag flips, and the first poke
     * commits immediately at the dipped price with the real epoch number frozen (the gate opens at the default)
     * Derivation: the dipped composition is the hand composition over liveVirtualPrice - 2, stamped at the
     * poke's own time under the re-stamped feed
     */
    function test_Fork_defaultWithSameStageFeeDipCommitsAtTheFirstPoke() public {
        uint256 dippedVirtualPrice = liveVirtualPrice - 2;
        uint256 t1 = seedTimestamp + 1 days;
        vm.warp(t1);
        _restampFeedMock();
        _mockDefaulted(true);
        _mockVirtualPrice(dippedVirtualPrice);

        // The first poke commits the dust-dipped default immediately
        _assertViewSurfaces(_composedPrice(dippedVirtualPrice), t1, "same-stage dust dip");
        assertEq(oracle.poke(), t1, "the dust-dipped default commits at the first poke");
        (uint160 lastSourcePrice, uint32 committedAt, uint256 lastCheckpointId) = _checkpointTriple();
        assertEq(lastSourcePrice, dippedVirtualPrice * VIRTUAL_PRICE_LIFT, "the dipped price latches verbatim");
        assertEq(committedAt, uint32(t1), "the gate opens at the default");
        assertEq(lastCheckpointId, liveEpochNumber, "the force clause commits with the real epoch number frozen");
    }

    /*----------------------------------------------------------------------
                        Checkpoint staleness
    ----------------------------------------------------------------------*/

    /**
     * The checkpoint hop's staleness gate against the real vault falling silent: with the real epoch number
     * unchanged and no default, the boundary age still prices at the seed's stamp and one second past it every
     * surface fails shut on STALE_SOURCE_PRICE, the feed hop held fresh so the checkpoint hop's gate is isolated
     */
    function test_Fork_RevertIf_CheckpointAgesPastTheSourceStalenessThreshold() public {
        // The exact boundary age still prices and the aged seed binds the report's clock
        vm.warp(seedTimestamp + SOURCE_STALENESS);
        _restampFeedMock();
        _assertViewSurfaces(_composedPrice(liveVirtualPrice), seedTimestamp, "boundary age");

        // One second past the boundary fails shut on all three surfaces despite the fresh feed
        vm.warp(seedTimestamp + SOURCE_STALENESS + 1);
        _restampFeedMock();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.getPrice();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.previewPoke();
        vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
        oracle.poke();
    }
}
