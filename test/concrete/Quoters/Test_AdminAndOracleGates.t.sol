// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import {
    IdenticalAssets_ST_JT_ChainlinkOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol";
import {
    IdenticalAssets_ST_JT_Oracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import { toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { defaultParams } from "../../utils/MarketParams.sol";
import { cellA } from "../../utils/TokenConfigs.sol";
import { DayMarketTestBase } from "../../utils/DayMarketTestBase.sol";

/**
 * @title Test_AdminAndOracleGates_STJTChainlinkQuoter
 * @notice Exercises the ST/JT quoter's admin surface (the stored conversion-rate override, the Chainlink oracle
 *         swap, the L2 sequencer-uptime wiring) and every oracle sanity gate (staleness, non-positive answer,
 *         incomplete round, sequencer down, grace period), including the exact-second boundaries of the staleness
 *         and grace windows and the attacker-side probes of every setter
 * @dev The quoter is the market's price backbone: a silently accepted bad price mismarks every tranche NAV in the
 *      same block, so each gate must reject its poisoned input and each setter must land exactly where it claims
 * @dev The market stays unseeded: conversion rates are independent of tranche NAVs, and the setters' internal
 *      accounting syncs pass trivially at zero NAVs, isolating the pricing math under test
 */
contract Test_AdminAndOracleGates_STJTChainlinkQuoter is DayMarketTestBase {
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
    }

    // =============================
    // Stored conversion-rate override (the admin price path)
    // =============================

    /**
     * @notice Setting a stored conversion rate overrides the oracle, and clearing it back to the sentinel resumes the oracle path
     * @dev With the shared 4626 vault at rate 1.0 and the feed at 1.0, the live rate is 1e18. A stored rate of 2e18 must
     *      make one whole 18-decimal share quote 1e18 x 2e18 / 1e18 = 2e18 NAV, and clearing it must return to 1e18
     */
    function test_SetConversionRate_OverridesOracleAndSentinelRestoresIt() public {
        vm.expectEmit(address(kernel));
        emit IdenticalAssets_ST_JT_Oracle_Quoter.ConversionRateUpdated(2e18);
        vm.prank(ORACLE_QUOTER_ADMIN);
        kernel.setConversionRate(2e18, true);

        assertEq(kernel.getStoredConversionRateWAD(), 2e18, "the stored conversion rate must land in quoter storage");
        assertEq(toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2e18, "one whole share must quote at the stored 2.0 rate");
        assertEq(toUint256(kernel.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 2e18, "the junior side shares the identical stored rate");
        // The inverse conversion divides by the same rate: 2e18 NAV / 2.0 = 1e18 shares
        assertEq(toUint256(kernel.stConvertNAVUnitsToTrancheUnits(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18)))), 1e18, "share -> NAV -> share must round-trip at the stored rate");

        // Clearing back to the sentinel (0) resumes the oracle-derived rate: vault 1.0 x feed 1.0 = 1e18
        vm.prank(ORACLE_QUOTER_ADMIN);
        kernel.setConversionRate(0, false);
        assertEq(toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1e18, "clearing the override must resume the oracle rate");
    }

    // =============================
    // Chainlink oracle swap
    // =============================

    /// @notice Swapping in a fresh feed at a different price and decimals re-prices conversions through the new feed exactly
    function test_SetChainlinkOracle_SwapsFeedAndRepricesConversions() public {
        // A 10-decimal feed at 3e10 is a 3.0 price: rate = vault 1.0 x (3e10 x 1e18 / 1e10) = 3e18
        MockAggregatorV3 newFeed = new MockAggregatorV3(10, 3e10);
        vm.expectEmit(address(kernel));
        emit IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.ChainlinkOracleUpdated(address(newFeed), 2 days);
        vm.prank(ORACLE_QUOTER_ADMIN);
        kernel.setChainlinkOracle(address(newFeed), 2 days, true);

        assertEq(toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 3e18, "one whole share must quote at the new feed's 3.0 price");
        IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState memory config = kernel.getChainlinkOracleConfiguration();
        assertEq(config.oracle, address(newFeed), "the new feed must land in quoter storage");
        assertEq(config.stalenessThresholdSeconds, 2 days, "the new staleness threshold must land in quoter storage");
    }

    /**
     * @notice A null oracle is a valid configuration only as a fallback behind a stored conversion rate
     * @dev The stored rate short-circuits the oracle query, so pricing keeps working with no feed wired at all
     */
    function test_SetChainlinkOracle_NullFeedWorksBehindStoredRate() public {
        vm.startPrank(ORACLE_QUOTER_ADMIN);
        kernel.setConversionRate(1.5e18, false);
        kernel.setChainlinkOracle(address(0), 1 days, false);
        vm.stopPrank();
        // vault 1.0 x stored 1.5 = 1.5e18, and the null feed is never consulted
        assertEq(toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1.5e18, "the stored rate must price with no oracle wired");
    }

    /// @notice A null oracle with a zero staleness threshold is now ACCEPTED (the fixed guard only requires a positive
    ///         staleness threshold when the oracle is set). With a stored admin rate as the price source, this is a
    ///         valid admin-fallback configuration.
    function test_ChainlinkOracleSetNullWithZeroStalenessThreshold_AcceptedWithStoredRate() public {
        vm.startPrank(ORACLE_QUOTER_ADMIN);
        kernel.setConversionRate(1.5e18, false); // admin rate as the price source
        kernel.setChainlinkOracle(address(0), 0, false); // no revert: oracle null, staleness irrelevant
        vm.stopPrank();
        assertEq(toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1.5e18, "the stored rate prices with a null oracle and zero staleness");
    }

    /**
     * @notice CURRENT BEHAVIOR (divergence): wiring a LIVE feed with a ZERO staleness threshold is accepted, even though that
     *         configuration can only ever price inside the exact second the feed updates in
     * @dev Expected from first principles: revert INVALID_STALENESS_THRESHOLD_SECONDS. A zero threshold is only harmless when no
     *      feed is consulted, so the guard should reject (live feed, zero threshold) and allow (null feed, zero threshold),
     *      which is exactly the sequencer twin's polarity (a null uptime feed disables the check, a live one demands a positive
     *      grace period). The guard at IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol:178 reads `_oracle != address(0) ||
     *      _stalenessThresholdSeconds > 0` while its own preceding comment and the sequencer guard at :195 use `== address(0) ||`,
     *      so the accepted and rejected configurations are swapped. The staleness gate is updatedAt + threshold >= now, so with
     *      threshold 0 a fresh answer (updatedAt == now) passes only until the next second ticks
     */
    function test_DIVERGENCE_19_SetChainlinkOracle_RejectsLiveFeedWithZeroStalenessThreshold() public {
        // Fixed: when the oracle is set (non-null), a zero staleness threshold is rejected — it would brick every
        // read (updatedAt + 0 >= now requires a same-second update). The guard now enforces staleness > 0 iff the
        // oracle is set.
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        kernel.setChainlinkOracle(address(priceFeed), 0, false);

        // A positive staleness threshold with a live feed is accepted.
        vm.prank(ORACLE_QUOTER_ADMIN);
        kernel.setChainlinkOracle(address(priceFeed), 1 days, false);
        IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState memory config = kernel.getChainlinkOracleConfiguration();
        assertEq(config.oracle, address(priceFeed), "the live feed must have landed in quoter storage");
        assertEq(config.stalenessThresholdSeconds, 1 days, "the positive staleness threshold must have landed in quoter storage");
    }

    // =============================
    // Composite conversion-rate floor
    // =============================

    /**
     * @notice A composite conversion rate of exactly 1 wei, the smallest nonzero rate, still prices both directions
     * @dev With the vault share worth 1 wei-WAD and the feed at 1.0, the composed rate is floor(1 x 1e18 / 1e18) = 1.
     *      Forward: one whole 18-decimal share is floor(1e18 x 1 / 1e18) = 1 wei of NAV. Backward: 1 wei of NAV is
     *      floor(1 x 1e18 / 1) = 1e18 tranche units. One wei is the exact boundary above the zero-rate failure mode
     *      (a zero rate cannot price the backward division at all), so neither direction may revert here
     */
    function test_OneWeiCompositeConversionRate_IsTheSmallestRateThatPricesBothDirections() public {
        // Crash the vault's share price to 1 wei-WAD while the feed stays at 1.0
        stJtVault.setRate(1);

        // Forward: floor(1e18 x 1 / 1e18) = 1 wei of NAV for one whole share
        assertEq(toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1, "one whole share must quote exactly 1 wei of NAV at the 1-wei composite rate");
        // Backward: floor(1 x 1e18 / 1) = 1e18 tranche units for 1 wei of NAV
        assertEq(toUint256(kernel.stConvertNAVUnitsToTrancheUnits(toNAVUnits(uint256(1)))), 1e18, "1 wei of NAV must convert back to exactly one whole share");
    }

    // =============================
    // Admin setters, attacker side
    // =============================

    /**
     * @notice An unprivileged attacker cannot inject a stored rate, swap in a hostile feed, or rewire the sequencer
     *         gate, and every failed attempt leaves the quoter configuration untouched
     * @dev Any one of these setters is a full market mispricing: a 2x stored rate would double every senior mark
     *      in the very next sync
     */
    function test_RevertIf_STJTQuoterSettersCalledByNonAdmin() public {
        address attacker = makeAddr("ATTACKER");
        MockAggregatorV3 hostileFeed = new MockAggregatorV3(8, 2e8);
        IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState memory configBefore =
            kernel.getChainlinkOracleConfiguration();

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        kernel.setConversionRate(2e18, false);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        kernel.setChainlinkOracle(address(hostileFeed), 365 days, false);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        kernel.setSequencerUptimeFeed(address(sequencerFeed), 1);
        vm.stopPrank();

        assertEq(kernel.getStoredConversionRateWAD(), 0, "the stored rate must remain the oracle-driven sentinel");
        IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.IdenticalAssets_ST_JT_ChainlinkOracle_QuoterState memory configAfter =
            kernel.getChainlinkOracleConfiguration();
        assertEq(configAfter.oracle, configBefore.oracle, "the feed must be untouched by the failed attempts");
        assertEq(configAfter.stalenessThresholdSeconds, configBefore.stalenessThresholdSeconds, "the staleness threshold must be untouched");
    }

    // =============================
    // Oracle sanity gates (each poisoned input must be rejected, not priced)
    // =============================

    /// @notice A feed answer older than the staleness threshold is rejected instead of pricing the market off history
    function test_RevertIf_OracleAnswerIsStale() public {
        // Warp one second past the 1-day staleness threshold without refreshing updatedAt
        setOracleMode(ORACLE_MODE_STALE);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.STALE_PRICE.selector);
        kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18));
    }

    /**
     * @notice The staleness window's exact boundary: an answer aged exactly the threshold still prices, one more
     *         second and it is rejected
     * @dev The gate is updatedAt + threshold >= now. An attacker wanting the market to price off history gets at
     *      most the configured window and not one second more, and an off-by-one toward strictness would brick
     *      pricing for feeds that update exactly on their heartbeat
     */
    function test_OracleStalenessGate_ExactThresholdBoundary() public {
        priceFeed.setUpdatedAt(block.timestamp);
        vm.warp(block.timestamp + ORACLE_STALENESS_THRESHOLD_SECONDS);
        // Age == threshold: updatedAt + threshold == now, still fresh
        assertEq(toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1e18, "an answer aged exactly the threshold must still price");

        vm.warp(block.timestamp + 1);
        // Age == threshold + 1: one second past the window is stale
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.STALE_PRICE.selector);
        kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18));
    }

    /// @notice A zero feed answer is rejected, zero is a broken feed rather than a real price
    function test_RevertIf_OracleAnswerIsZero() public {
        setOracleMode(ORACLE_MODE_ZERO);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_PRICE.selector);
        kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18));
    }

    /// @notice A negative feed answer is rejected, the int-shaped Chainlink answer must be strictly positive
    function test_RevertIf_OracleAnswerIsNegative() public {
        setOracleMode(ORACLE_MODE_NEGATIVE);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_PRICE.selector);
        kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18));
    }

    /// @notice An answer computed in an earlier round than the latest round is rejected as incomplete
    function test_RevertIf_OracleRoundIsIncomplete() public {
        // roundId stays 1 (the constructor's round) while answeredInRound drops to 0
        priceFeed.setAnsweredInRound(0);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INCOMPLETE_PRICE.selector);
        kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18));
    }

    /// @notice A reverting feed bubbles its revert instead of being swallowed into a default price
    function test_RevertIf_OracleFeedReverts() public {
        setOracleMode(ORACLE_MODE_REVERT);
        vm.expectRevert(MockAggregatorV3.ORACLE_REVERT_MODE.selector);
        kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18));
    }

    // =============================
    // L2 sequencer-uptime gating
    // =============================

    /// @notice Wiring a sequencer feed with a zero grace period is rejected, a restored sequencer needs a positive settling window
    function test_RevertIf_SequencerFeedSetWithZeroGracePeriod() public {
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_GRACE_PERIOD_SECONDS.selector);
        kernel.setSequencerUptimeFeed(address(sequencerFeed), 0);
    }

    /**
     * @notice The full sequencer lifecycle: down blocks pricing, freshly restored blocks pricing through the grace
     *         period, and pricing resumes only once the grace period has fully elapsed
     * @dev The fixture's spare sequencer feed reports answer 0 (up) with startedAt stamped at deployment
     */
    function test_SequencerGate_BlocksWhileDownOrInGraceAndThenResumes() public {
        vm.expectEmit(address(kernel));
        emit IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.SequencerUptimeFeedUpdated(address(sequencerFeed), 1 hours);
        vm.prank(ORACLE_QUOTER_ADMIN);
        kernel.setSequencerUptimeFeed(address(sequencerFeed), 1 hours);

        // Sequencer down (answer 1): pricing must halt outright
        sequencerFeed.setAnswer(1);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.SEQUENCER_DOWN.selector);
        kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18));

        // Sequencer restored this very second (startedAt == now): zero elapsed is not > 1 hour, still blocked
        sequencerFeed.setAnswer(0);
        sequencerFeed.setStartedAt(block.timestamp);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.GRACE_PERIOD_NOT_OVER.selector);
        kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18));

        // An uninitialized uptime feed (startedAt 0) is treated as not yet restored, still blocked
        sequencerFeed.setStartedAt(0);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.GRACE_PERIOD_NOT_OVER.selector);
        kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18));

        // One second past the grace period (with the price feed kept fresh) pricing resumes at the 1.0 rate
        sequencerFeed.setStartedAt(block.timestamp);
        _warpAndRefreshFeed(1 hours + 1);
        assertEq(toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1e18, "pricing must resume once the grace period elapses");

        // Unwiring the feed (null address, zero grace) disables the check entirely
        vm.prank(ORACLE_QUOTER_ADMIN);
        kernel.setSequencerUptimeFeed(address(0), 0);
        assertEq(toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1e18, "pricing must work with the sequencer check disabled");
    }

    /**
     * @notice The grace window's exact boundary: at exactly the grace second pricing is still blocked, one second
     *         later it resumes
     * @dev The gate is (now - startedAt) > gracePeriod, strictly greater. An attacker timing a trade to the first
     *      priceable second after an outage gets grace + 1 at the earliest, and the strictness direction is pinned
     *      so a regression to >= cannot shave the settling window by one second
     */
    function test_SequencerGate_ExactGraceSecondBoundary() public {
        // Headroom so a startedAt in the past cannot underflow the default genesis timestamp
        _warpAndRefreshFeed(30 days);
        vm.prank(ORACLE_QUOTER_ADMIN);
        kernel.setSequencerUptimeFeed(address(sequencerFeed), 1 hours);
        sequencerFeed.setAnswer(0);

        // Elapsed == grace exactly: 1 hours is not > 1 hours, still blocked
        sequencerFeed.setStartedAt(block.timestamp - 1 hours);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.GRACE_PERIOD_NOT_OVER.selector);
        kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18));

        // Elapsed == grace + 1: strictly past the window, pricing resumes at the 1.0 rate
        sequencerFeed.setStartedAt(block.timestamp - 1 hours - 1);
        assertEq(
            toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))),
            1e18,
            "pricing must resume exactly one second past the grace window"
        );
    }
}

/**
 * @title Test_ZeroStalenessGuard_STJTChainlinkQuoter
 * @notice A live feed paired with a zero staleness threshold is rejected at the setter, so the config that would
 *         brick every pricing view and sync one second later (a 1-second-old answer fails updatedAt + 0 >= now,
 *         a market-wide pricing and sync DoS until the feed pushes a new round) is unreachable from the admin surface
 * @dev The null-oracle arm stays settable with a zero threshold: upstream quoters may price from an admin-set
 *      stored rate with the chainlink oracle as an optional fallback, and no staleness gate runs without a feed
 */
contract Test_ZeroStalenessGuard_STJTChainlinkQuoter is DayMarketTestBase {
    function setUp() public {
        _deployMarket(cellA(), defaultParams());
        // A real market with senior and junior capital, so the survival assertions exercise the market, not a view
        _seedMarket(100e18, 50e18);
        // A fresh answer, so only the guard (never a stale price) can reject the sets below
        priceFeed.setUpdatedAt(block.timestamp);
    }

    /**
     * @notice Setting a live feed with a zero staleness threshold reverts through both setter arms, and the
     *         market still prices and syncs one second later under its untouched pre-existing config
     * @dev The guard sits in the shared internal setter, so the pre-update-sync arm cannot smuggle the pair in
     *      either: its pre-sync prices under the healthy old config and the guard still rejects before the write
     */
    function test_RevertIf_LiveFeedSetWithZeroStalenessThreshold() public {
        // Without the pre-update sync
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        kernel.setChainlinkOracle(address(priceFeed), 0, false);

        // With the pre-update sync
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        kernel.setChainlinkOracle(address(priceFeed), 0, true);

        // One second later the market is alive: the DoS the rejected pair would have caused cannot happen
        vm.warp(block.timestamp + 1);
        assertEq(
            toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))),
            1e18,
            "pricing must survive the second after the rejected set"
        );
        vm.prank(SYNC_OPERATOR);
        kernel.syncTrancheAccounting();
    }

    /**
     * @notice The null oracle stays settable with a zero staleness threshold once a stored conversion rate prices
     *         the market, because no staleness gate runs without a feed
     * @dev Pins the guard's exact shape (oracle == 0 || threshold > 0): the zero threshold is hazardous only
     *      when paired with a live feed, and rejecting it unconditionally would break the stored-rate-only config
     */
    function test_SetChainlinkOracle_NullOracleWithZeroThresholdRemainsSettable() public {
        // A stored conversion rate short-circuits the oracle query, so the setter's own post-update sync prices
        vm.prank(ORACLE_QUOTER_ADMIN);
        kernel.setConversionRate(1e18, false);

        vm.prank(ORACLE_QUOTER_ADMIN);
        kernel.setChainlinkOracle(address(0), 0, false);
        assertEq(kernel.getChainlinkOracleConfiguration().oracle, address(0), "the null oracle must land");
        assertEq(kernel.getChainlinkOracleConfiguration().stalenessThresholdSeconds, 0, "the zero threshold must land alongside the null oracle");

        // Pricing runs on the stored rate and never consults a feed, so the zero threshold is inert
        vm.warp(block.timestamp + 365 days);
        assertEq(toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1e18, "the stored rate must price with no feed set");
    }
}
