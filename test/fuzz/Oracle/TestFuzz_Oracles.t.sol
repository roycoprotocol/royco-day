// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { NAV_UNIT, toUint256 } from "../../../src/libraries/Units.sol";
import { ChainlinkPriceOracle } from "../../../src/oracle/ChainlinkPriceOracle.sol";
import { ERC4626SharePriceOracle } from "../../../src/oracle/ERC4626SharePriceOracle.sol";
import { ChainlinkPriceOracleBase } from "../../../src/oracle/base/ChainlinkPriceOracleBase.sol";
import { ClockedChainlinkPriceOracleBase } from "../../../src/oracle/base/ClockedChainlinkPriceOracleBase.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockCheckpointClock } from "../../mocks/MockCheckpointClock.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { MockERC4626C } from "../../mocks/MockERC4626C.sol";
import { MockValueSource } from "../../mocks/MockValueSource.sol";

/**
 * @title TestFuzz_Oracles
 * @notice Fuzzes the oracle family's implementation against independent hand-written mirrors: the composed
 *         pricing math, the deviation predicate, the oldest-hop report timestamp, and both staleness boundaries
 * @dev Every expected value is recomputed by a mirror in this file from the definition, never captured from the
 *      contract under test, so an implementation drift in either direction fails the sweep
 */
contract TestFuzz_Oracles is Test {
    uint256 internal constant T0 = 1_700_000_000;
    uint32 internal constant FEED_STALENESS = 1 days;
    uint32 internal constant SHARE_PRICE_STALENESS = 3 days;

    MockERC20C internal baseAsset;
    MockERC4626C internal vault;
    MockAggregatorV3 internal feed;
    MockValueSource internal source;

    function setUp() public {
        vm.warp(T0);
        baseAsset = new MockERC20C("NUSD", "NUSD", 6);
        vault = new MockERC4626C(address(baseAsset), "Staked NUSD", "sNUSD", 18);
        feed = new MockAggregatorV3(8, 1e8);
        source = new MockValueSource(1e18);
    }

    /**
     * The composed price equals the single-floored product of the live share rate and the feed answer for any
     * rate and any positive answer: price = floor(rate x answer / feedPrecision), the mirror recomputed here
     */
    function testFuzz_ERC4626Composition_MatchesFlooredMirror(uint256 _rate, uint256 _answer) public {
        // Rates over 9 orders of magnitude in both directions, answers up to 1e4 dollars at 8 feed decimals
        uint256 rate = bound(_rate, 1e9, 1e27);
        uint256 answer = bound(_answer, 1, 1e12);
        vault.setRate(rate);
        feed.setAnswer(int256(answer));

        ERC4626SharePriceOracle oracle = new ERC4626SharePriceOracle(address(vault), address(feed), 0, uint32(T0), FEED_STALENESS, SHARE_PRICE_STALENESS);
        (NAV_UNIT price,) = oracle.getPrice();
        assertEq(toUint256(price), Math.mulDiv(rate, answer, 1e8), "composed price must equal the mirror's single-floored product");
    }

    /**
     * The deviation predicate matches the mirror exactly for any checkpoint, observation, and threshold:
     * deviated iff the values differ AND (the threshold is zero OR the checkpoint is zero OR the floored
     * relative delta reaches the threshold)
     */
    function testFuzz_DeviationPredicate_MatchesMirror(uint256 _baseline, uint256 _next, uint256 _thresholdWAD) public {
        uint256 baseline = bound(_baseline, 0, type(uint160).max);
        uint256 next = bound(_next, 0, type(uint160).max);
        uint256 thresholdWAD = bound(_thresholdWAD, 0, WAD - 1);

        source.setValue(baseline);
        MockCheckpointClock clock = new MockCheckpointClock(address(source), uint32(T0), thresholdWAD);
        vm.warp(T0 + 100);
        source.setValue(next);

        // The independent mirror of the deviation definition
        bool expectDeviated;
        if (next == baseline) expectDeviated = false;
        else if (thresholdWAD == 0 || baseline == 0) expectDeviated = true;
        else {
            uint256 delta = next > baseline ? next - baseline : baseline - next;
            expectDeviated = Math.mulDiv(WAD, delta, baseline) >= thresholdWAD;
        }

        assertEq(clock.poke(), expectDeviated ? T0 + 100 : T0, "the poke must stamp exactly when the mirror says the move deviates");
    }

    /**
     * The report's timestamp is the older hop for any attested clock age and feed age inside both staleness
     * windows, and getPrice, poke, and previewPoke all agree on it
     */
    function testFuzz_ReportTimestamp_IsTheOldestHop(uint256 _clockAge, uint256 _feedAge) public {
        // Both hops stay inside their staleness windows so the report always prices
        uint256 clockAge = bound(_clockAge, 0, SHARE_PRICE_STALENESS - 1);
        uint256 feedAge = bound(_feedAge, 0, FEED_STALENESS - 1);
        feed.setUpdatedAt(T0 - feedAge);

        ERC4626SharePriceOracle oracle =
            new ERC4626SharePriceOracle(address(vault), address(feed), 0, uint32(T0 - clockAge), FEED_STALENESS, SHARE_PRICE_STALENESS);
        uint256 expected = Math.min(T0 - feedAge, T0 - clockAge);

        (, uint256 updatedAt) = oracle.getPrice();
        assertEq(updatedAt, expected, "getPrice must report the older hop");
        assertEq(oracle.previewPoke(), expected, "previewPoke must agree with getPrice");
        assertEq(oracle.poke(), expected, "poke must agree with getPrice");
    }

    /// The feed staleness gate fires exactly past its boundary for any report age, pinned on the clockless identity adapter
    function testFuzz_FeedStalenessBoundary_FiresExactly(uint256 _age) public {
        uint256 age = bound(_age, 0, 2 * uint256(FEED_STALENESS));
        MockERC20C collateral = new MockERC20C("USDC", "USDC", 6);
        ChainlinkPriceOracle oracle = new ChainlinkPriceOracle(address(collateral), address(feed), FEED_STALENESS);

        feed.setUpdatedAt(T0);
        vm.warp(T0 + age);
        if (age > FEED_STALENESS) {
            vm.expectRevert(ChainlinkPriceOracleBase.STALE_FEED_PRICE.selector);
            oracle.getPrice();
        } else {
            (, uint256 updatedAt) = oracle.getPrice();
            assertEq(updatedAt, T0, "a report inside the window prices at the feed's timestamp");
        }
    }

    /// The source-price staleness gate fires exactly past its boundary for any checkpoint age, with the feed held fresh
    function testFuzz_SourceStalenessBoundary_FiresExactly(uint256 _age) public {
        uint256 age = bound(_age, 0, 2 * uint256(SHARE_PRICE_STALENESS));
        ERC4626SharePriceOracle oracle = new ERC4626SharePriceOracle(address(vault), address(feed), 0, uint32(T0), FEED_STALENESS, SHARE_PRICE_STALENESS);

        vm.warp(T0 + age);
        feed.setUpdatedAt(block.timestamp);
        if (age > SHARE_PRICE_STALENESS) {
            vm.expectRevert(ClockedChainlinkPriceOracleBase.STALE_SOURCE_PRICE.selector);
            oracle.getPrice();
        } else {
            (, uint256 updatedAt) = oracle.getPrice();
            assertEq(updatedAt, T0, "a checkpoint inside the window prices and binds the report");
        }
    }
}
