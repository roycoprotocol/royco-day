// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import {
    IdenticalAssets_ST_JT_ChainlinkOracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.sol";
import {
    IdenticalAssets_ST_JT_Oracle_Quoter
} from "../../../src/kernels/base/quoter/identical-st-jt/base/IdenticalAssets_ST_JT_Oracle_Quoter.sol";
import {
    BalancerV3_LT_BPTOracle_Quoter
} from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockBPT } from "../../mocks/MockBPT.sol";
import { MockBPTOracle } from "../../mocks/MockBPTOracle.sol";
import { defaultParams } from "../../base/fixtures/MarketParams.sol";
import { cellA } from "../../base/fixtures/TokenConfigs.sol";
import { TrancheFixture } from "../../base/fixtures/TrancheFixture.sol";

/**
 * @title QuoterAdminAndOracleGatesTest
 * @notice Exercises the ST/JT quoter's admin surface (the stored conversion-rate override, the Chainlink oracle
 *         swap, the L2 sequencer-uptime wiring) and every oracle sanity gate (staleness, non-positive answer,
 *         incomplete round, sequencer down, grace period), plus the LT quoter's admin surface (the BPT oracle
 *         swap and the reinvestment slippage bound)
 * @dev The quoter is the market's price backbone: a silently accepted bad price mismarks every tranche NAV in the
 *      same block, so each gate must reject its poisoned input and each setter must land exactly where it claims
 * @dev The market stays unseeded: conversion rates are independent of tranche NAVs, and the setters' internal
 *      accounting syncs pass trivially at zero NAVs, isolating the pricing math under test
 */
contract QuoterAdminAndOracleGatesTest is TrancheFixture {
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
    function test_SetConversionRate_overridesOracleAndSentinelRestoresIt() public {
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
    function test_SetChainlinkOracle_swapsFeedAndRepricesConversions() public {
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
    function test_SetChainlinkOracle_nullFeedWorksBehindStoredRate() public {
        vm.startPrank(ORACLE_QUOTER_ADMIN);
        kernel.setConversionRate(1.5e18, false);
        kernel.setChainlinkOracle(address(0), 1 days, false);
        vm.stopPrank();
        // vault 1.0 x stored 1.5 = 1.5e18, and the null feed is never consulted
        assertEq(toUint256(kernel.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18))), 1.5e18, "the stored rate must price with no oracle wired");
    }

    /// @notice Wiring a null oracle with a zero staleness threshold is rejected, that configuration could never price anything
    function test_RevertIf_ChainlinkOracleSetNullWithZeroStalenessThreshold() public {
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(IdenticalAssets_ST_JT_ChainlinkOracle_Quoter.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        kernel.setChainlinkOracle(address(0), 0, false);
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
    function test_SequencerGate_blocksWhileDownOrInGraceAndThenResumes() public {
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

    // =============================
    // LT quoter admin surface
    // =============================

    /// @notice Swapping the BPT oracle to another instance priced over the same pool lands in storage with its event, on both sync-flag paths
    function test_SetBPTOracle_swapsOracleOnBothSyncFlagPaths() public {
        MockBPTOracle replacementOracle = new MockBPTOracle(balancerVault, address(bpt));
        vm.expectEmit(address(kernel));
        emit BalancerV3_LT_BPTOracle_Quoter.BPTOracleUpdated(address(replacementOracle));
        vm.prank(ORACLE_QUOTER_ADMIN);
        kernel.setBPTOracle(address(replacementOracle), true);
        assertEq(kernel.getBalancerV3QuoterState().bptOracle, address(replacementOracle), "the replacement oracle must land in quoter storage");

        // The no-pre-sync path (sync only after the swap) must land identically
        MockBPTOracle secondReplacement = new MockBPTOracle(balancerVault, address(bpt));
        vm.prank(ORACLE_QUOTER_ADMIN);
        kernel.setBPTOracle(address(secondReplacement), false);
        assertEq(kernel.getBalancerV3QuoterState().bptOracle, address(secondReplacement), "the no-pre-sync path must also land the oracle");
    }

    /// @notice An oracle that prices a different pool than this market's BPT is rejected, the mark would value the wrong inventory
    function test_RevertIf_BPTOraclePricesForeignPool() public {
        MockBPT foreignBpt = new MockBPT(IVault(address(balancerVault)), "Foreign BPT", "fBPT");
        MockBPTOracle foreignOracle = new MockBPTOracle(balancerVault, address(foreignBpt));
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(BalancerV3_LT_BPTOracle_Quoter.BPT_ORACLE_POOL_MISMATCH.selector);
        kernel.setBPTOracle(address(foreignOracle), false);
    }

    /// @notice The reinvestment slippage bound can be retuned below 100 percent, and the change lands with its event
    function test_SetMaxReinvestmentSlippage_updatesStateAndEmits() public {
        uint64 newSlippageWAD = 0.005e18;
        vm.expectEmit(address(kernel));
        emit BalancerV3_LT_BPTOracle_Quoter.MaxReinvestmentSlippageUpdated(newSlippageWAD);
        vm.prank(ORACLE_QUOTER_ADMIN);
        kernel.setMaxReinvestmentSlippage(newSlippageWAD);
        assertEq(kernel.getBalancerV3QuoterState().maxReinvestmentSlippageWAD, newSlippageWAD, "the slippage bound must land in quoter storage");
    }

    /// @notice A 100 percent slippage bound is rejected, it would let the single-sided add accept an arbitrarily bad fill
    function test_RevertIf_MaxReinvestmentSlippageIsFullWAD() public {
        vm.prank(ORACLE_QUOTER_ADMIN);
        vm.expectRevert(BalancerV3_LT_BPTOracle_Quoter.INVALID_MAX_REINVESTMENT_SLIPPAGE.selector);
        kernel.setMaxReinvestmentSlippage(uint64(WAD));
    }
}
