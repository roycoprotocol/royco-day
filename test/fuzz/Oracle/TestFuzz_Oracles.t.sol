// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { NAV_UNIT, toUint256 } from "../../../src/libraries/Units.sol";
import { ChainlinkPriceOracle } from "../../../src/oracle/ChainlinkPriceOracle.sol";
import { DiscreteIdleCDOTranchePriceOracle } from "../../../src/oracle/DiscreteIdleCDOTranchePriceOracle.sol";
import { ERC4626SharePriceOracle } from "../../../src/oracle/ERC4626SharePriceOracle.sol";
import { IdleCDOTranchePriceOracle } from "../../../src/oracle/IdleCDOTranchePriceOracle.sol";
import { MakinaSharePriceOracle } from "../../../src/oracle/MakinaSharePriceOracle.sol";
import { ChainlinkPriceOracleBase } from "../../../src/oracle/base/ChainlinkPriceOracleBase.sol";
import { ClockedChainlinkPriceOracleBase } from "../../../src/oracle/base/ClockedChainlinkPriceOracleBase.sol";
import { DiscretePriceOracleBase } from "../../../src/oracle/base/DiscretePriceOracleBase.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockCheckpointClock } from "../../mocks/MockCheckpointClock.sol";
import { MockDiscretePriceOracle } from "../../mocks/MockDiscretePriceOracle.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { MockERC4626C } from "../../mocks/MockERC4626C.sol";
import { MockIdleCDO } from "../../mocks/MockIdleCDO.sol";
import { MockMakinaMachine } from "../../mocks/MockMakinaMachine.sol";
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
    uint32 internal constant MAKINA_ACCOUNTING_STALENESS = 2 days;
    uint32 internal constant SETTLEMENT_STALENESS = 45 days;

    MockERC20C internal baseAsset;
    MockERC4626C internal vault;
    MockAggregatorV3 internal feed;
    MockValueSource internal source;
    MockValueSource internal discreteSource;
    address internal discreteOwner;

    function setUp() public {
        vm.warp(T0);
        baseAsset = new MockERC20C("NUSD", "NUSD", 6);
        vault = new MockERC4626C(address(baseAsset), "Staked NUSD", "sNUSD", 18);
        feed = new MockAggregatorV3(8, 1e8);
        source = new MockValueSource(1e18);
        discreteSource = new MockValueSource(1e18);
        discreteOwner = makeAddr("DISCRETE_ORACLE_OWNER");
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

        ERC4626SharePriceOracle oracle = new ERC4626SharePriceOracle(
            address(vault), ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS, address(feed), 0, uint32(T0), FEED_STALENESS, SHARE_PRICE_STALENESS
        );
        (NAV_UNIT price,) = oracle.getPrice();
        assertEq(toUint256(price), Math.mulDiv(rate, answer, 1e8), "composed price must equal the mirror's single-floored product");
    }

    /**
     * Query-mode selection matches the vault mirror for any rate, haircut, and answer: the PREVIEW_REDEEM
     * composition prices floor(previewRedeem x answer / feedPrecision) while CONVERT_TO_ASSETS prices the
     * nominal floor(rate x answer / feedPrecision), and the two agree exactly iff the haircut is zero
     */
    function testFuzz_ERC4626QueryMode_SelectsTheMirroredSource(uint256 _rate, uint256 _haircut, uint256 _answer) public {
        uint256 rate = bound(_rate, 1e9, 1e27);
        uint256 haircut = bound(_haircut, 0, 1e18 - 1);
        uint256 answer = bound(_answer, 1, 1e12);
        vault.setRate(rate);
        vault.setRedemptionHaircut(haircut);
        feed.setAnswer(int256(answer));

        ERC4626SharePriceOracle convertOracle = new ERC4626SharePriceOracle(
            address(vault), ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS, address(feed), 0, uint32(T0), FEED_STALENESS, SHARE_PRICE_STALENESS
        );
        ERC4626SharePriceOracle redeemOracle = new ERC4626SharePriceOracle(
            address(vault), ERC4626SharePriceOracle.ERC4626QueryMode.PREVIEW_REDEEM, address(feed), 0, uint32(T0), FEED_STALENESS, SHARE_PRICE_STALENESS
        );

        // Mirror the mock vault's quotes: the nominal conversion and the haircut redemption value
        uint256 redeemSource = rate - Math.mulDiv(rate, haircut, 1e18);
        (NAV_UNIT convertPrice,) = convertOracle.getPrice();
        (NAV_UNIT redeemPrice,) = redeemOracle.getPrice();
        assertEq(toUint256(convertPrice), Math.mulDiv(rate, answer, 1e8), "CONVERT_TO_ASSETS must compose the nominal rate");
        assertEq(toUint256(redeemPrice), Math.mulDiv(redeemSource, answer, 1e8), "PREVIEW_REDEEM must compose the redemption value");
        if (haircut == 0) {
            assertEq(toUint256(convertPrice), toUint256(redeemPrice), "the modes must agree exactly on a haircut-free vault");
        }
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
        if (next == baseline) {
            expectDeviated = false;
        } else if (thresholdWAD == 0 || baseline == 0) {
            expectDeviated = true;
        } else {
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

        ERC4626SharePriceOracle oracle = new ERC4626SharePriceOracle(
            address(vault),
            ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS,
            address(feed),
            0,
            uint32(T0 - clockAge),
            FEED_STALENESS,
            SHARE_PRICE_STALENESS
        );
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
        ERC4626SharePriceOracle oracle = new ERC4626SharePriceOracle(
            address(vault), ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS, address(feed), 0, uint32(T0), FEED_STALENESS, SHARE_PRICE_STALENESS
        );

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

    /**
     * The Makina report matches the oldest-hop mirror for any accounting and feed ages, including the gate
     * precedence: the feed gate (checked first) fires past its boundary, then the accounting gate, and inside
     * both windows getPrice, poke, and previewPoke agree on the older hop
     */
    function testFuzz_MakinaReport_MatchesOldestHopMirror(uint256 _accountingAge, uint256 _feedAge) public {
        uint256 accountingAge = bound(_accountingAge, 0, 2 * uint256(MAKINA_ACCOUNTING_STALENESS));
        uint256 feedAge = bound(_feedAge, 0, 2 * uint256(FEED_STALENESS));

        MockERC20C share = new MockERC20C("DUSD", "DUSD", 18);
        MockERC20C accounting = new MockERC20C("USDC", "USDC", 6);
        MockMakinaMachine machine = new MockMakinaMachine(address(share), address(accounting), 1e18);
        MakinaSharePriceOracle oracle = new MakinaSharePriceOracle(address(machine), address(feed), FEED_STALENESS, MAKINA_ACCOUNTING_STALENESS);

        machine.setLastGlobalAccountingTime(T0 - accountingAge);
        feed.setUpdatedAt(T0 - feedAge);

        if (feedAge > FEED_STALENESS) {
            // The feed gate runs first inside getPrice, so it takes precedence whenever both hops are stale
            vm.expectRevert(ChainlinkPriceOracleBase.STALE_FEED_PRICE.selector);
            oracle.getPrice();
        } else if (accountingAge > MAKINA_ACCOUNTING_STALENESS) {
            vm.expectRevert(MakinaSharePriceOracle.STALE_MAKINA_ACCOUNTING.selector);
            oracle.getPrice();
        } else {
            uint256 expected = Math.min(T0 - feedAge, T0 - accountingAge);
            (, uint256 updatedAt) = oracle.getPrice();
            assertEq(updatedAt, expected, "getPrice must report the older hop");
            assertEq(oracle.previewPoke(), expected, "previewPoke must agree with getPrice");
            assertEq(oracle.poke(), expected, "poke must agree with getPrice");
        }
    }

    /**
     * The CDO composition matches the lifted mirror for any virtual price and answer:
     * price = floor(virtualPrice x 10^(18 - underlyingDecimals) x answer / feedPrecision)
     */
    function testFuzz_CDOComposition_MatchesLiftedMirror(uint256 _virtualPrice, uint256 _answer) public {
        uint256 virtualPrice = bound(_virtualPrice, 1, 1e15);
        uint256 answer = bound(_answer, 1, 1e12);

        MockERC20C aaTranche = new MockERC20C("AA", "AA", 18);
        MockERC20C underlying = new MockERC20C("USDC", "USDC", 6);
        MockIdleCDO cdo = new MockIdleCDO(address(aaTranche), address(underlying), virtualPrice);
        feed.setAnswer(int256(answer));
        IdleCDOTranchePriceOracle oracle =
            new IdleCDOTranchePriceOracle(address(cdo), address(aaTranche), address(feed), 0, uint32(T0), FEED_STALENESS, SHARE_PRICE_STALENESS);

        (NAV_UNIT price,) = oracle.getPrice();
        assertEq(toUint256(price), Math.mulDiv(virtualPrice * 1e12, answer, 1e8), "composed price must equal the mirror's lifted floored product");
    }

    /**
     * The discrete CDO composition matches the lifted mirror for any checkpointed virtual price and answer, and
     * live drift after the checkpoint never enters the formula:
     * price = floor(checkpointedVirtualPrice x 10^(18 - underlyingDecimals) x answer / feedPrecision)
     */
    function testFuzz_DiscreteCDOComposition_MatchesLiftedMirror(uint256 _virtualPrice, uint256 _drift, uint256 _answer) public {
        uint256 virtualPrice = bound(_virtualPrice, 1, 1e15);
        uint256 drift = bound(_drift, 1, 1e15);
        uint256 answer = bound(_answer, 1, 1e12);

        MockERC20C aaTranche = new MockERC20C("AA", "AA", 18);
        MockERC20C underlying = new MockERC20C("USDC", "USDC", 6);
        MockIdleCDO cdo = new MockIdleCDO(address(aaTranche), address(underlying), virtualPrice);
        feed.setAnswer(int256(answer));
        DiscreteIdleCDOTranchePriceOracle oracle = new DiscreteIdleCDOTranchePriceOracle(
            discreteOwner, address(cdo), address(aaTranche), address(feed), FEED_STALENESS, SHARE_PRICE_STALENESS
        );
        vm.prank(discreteOwner);
        oracle.checkpointPrice();

        // Any post-checkpoint drift on the live virtual price must never enter the composition
        cdo.setVirtualPrice(drift);
        (NAV_UNIT price,) = oracle.getPrice();
        assertEq(
            toUint256(price), Math.mulDiv(virtualPrice * 1e12, answer, 1e8), "composed price must equal the mirror's lifted product of the checkpointed virtual price"
        );
    }

    /**
     * The probe-amount algebra makes the composition decimals-invariant: for ANY share/asset decimal pair the
     * probe 10^(18 + shareDecimals - assetDecimals) converts to the WAD share rate verbatim, so the composed
     * price equals floor(rate x answer / feedPrecision) regardless of the shape
     */
    function testFuzz_ProbeDecimalsAlgebra_IsShapeInvariant(uint8 _shareDecimals, uint8 _assetDecimals, uint256 _rate, uint256 _answer) public {
        uint8 shareDecimals = uint8(bound(_shareDecimals, 0, 18));
        uint8 assetDecimals = uint8(bound(_assetDecimals, 0, 18));
        uint256 rate = bound(_rate, 1e9, 1e27);
        uint256 answer = bound(_answer, 1, 1e12);

        MockERC20C shapedAsset = new MockERC20C("A", "A", assetDecimals);
        MockERC4626C shapedVault = new MockERC4626C(address(shapedAsset), "S", "S", shareDecimals);
        shapedVault.setRate(rate);
        feed.setAnswer(int256(answer));
        ERC4626SharePriceOracle oracle = new ERC4626SharePriceOracle(
            address(shapedVault),
            ERC4626SharePriceOracle.ERC4626QueryMode.CONVERT_TO_ASSETS,
            address(feed),
            0,
            uint32(T0),
            FEED_STALENESS,
            SHARE_PRICE_STALENESS
        );

        (NAV_UNIT price,) = oracle.getPrice();
        assertEq(toUint256(price), Math.mulDiv(rate, answer, 1e8), "the composition must be invariant to the vault's decimal shape");
    }

    /**
     * The discrete composition equals the single-floored product of the checkpointed source price and the feed
     * answer for any price and any positive answer: price = floor(value x answer / feedPrecision)
     */
    function testFuzz_DiscreteComposition_MatchesFlooredMirror(uint256 _value, uint256 _answer) public {
        // Checkpointed prices over 9 orders of magnitude in both directions, answers up to 1e4 dollars at 8 feed decimals
        uint256 value = bound(_value, 1e9, 1e27);
        uint256 answer = bound(_answer, 1, 1e12);
        feed.setAnswer(int256(answer));

        MockERC20C collateral = new MockERC20C("cpUSDC", "cpUSDC", 18);
        MockDiscretePriceOracle oracle =
            new MockDiscretePriceOracle(discreteOwner, address(collateral), address(feed), address(discreteSource), FEED_STALENESS, SETTLEMENT_STALENESS);
        // The fuzzed price reaches the conversion hop through the owner's checkpoint, the only update path
        discreteSource.setValue(value);
        vm.prank(discreteOwner);
        oracle.checkpointPrice();
        (NAV_UNIT price,) = oracle.getPrice();
        assertEq(toUint256(price), Math.mulDiv(value, answer, 1e8), "composed price must equal the mirror's single-floored product");
    }

    /**
     * The discrete report's timestamp is the older hop for any checkpoint age and feed age inside both
     * staleness windows, and getPrice, poke, and previewPoke all agree on it
     */
    function testFuzz_DiscreteReportTimestamp_IsTheOldestHop(uint256 _checkpointAge, uint256 _feedAge) public {
        // Both hops stay inside their staleness windows so the report always prices
        uint256 checkpointAge = bound(_checkpointAge, 0, SETTLEMENT_STALENESS - 1);
        uint256 feedAge = bound(_feedAge, 0, FEED_STALENESS - 1);

        // The aged checkpoint lands through the owner's call at its own timestamp
        MockERC20C collateral = new MockERC20C("cpUSDC", "cpUSDC", 18);
        MockDiscretePriceOracle oracle =
            new MockDiscretePriceOracle(discreteOwner, address(collateral), address(feed), address(discreteSource), FEED_STALENESS, SETTLEMENT_STALENESS);
        vm.warp(T0 - checkpointAge);
        vm.prank(discreteOwner);
        oracle.checkpointPrice();
        vm.warp(T0);
        feed.setUpdatedAt(T0 - feedAge);
        uint256 expected = Math.min(T0 - feedAge, T0 - checkpointAge);

        (, uint256 updatedAt) = oracle.getPrice();
        assertEq(updatedAt, expected, "getPrice must report the older hop");
        assertEq(oracle.previewPoke(), expected, "previewPoke must agree with getPrice");
        assertEq(oracle.poke(), expected, "poke must agree with getPrice");
    }

    /// The settlement staleness gate fires exactly past its boundary for any checkpoint age, with the feed held fresh
    function testFuzz_DiscreteSourceStalenessBoundary_FiresExactly(uint256 _age) public {
        uint256 age = bound(_age, 0, 2 * uint256(SETTLEMENT_STALENESS));
        MockERC20C collateral = new MockERC20C("cpUSDC", "cpUSDC", 18);
        MockDiscretePriceOracle oracle =
            new MockDiscretePriceOracle(discreteOwner, address(collateral), address(feed), address(discreteSource), FEED_STALENESS, SETTLEMENT_STALENESS);
        vm.prank(discreteOwner);
        oracle.checkpointPrice();

        vm.warp(T0 + age);
        feed.setUpdatedAt(block.timestamp);
        if (age > SETTLEMENT_STALENESS) {
            vm.expectRevert(DiscretePriceOracleBase.STALE_SOURCE_PRICE.selector);
            oracle.getPrice();
        } else {
            (, uint256 updatedAt) = oracle.getPrice();
            assertEq(updatedAt, T0, "a checkpoint inside the window prices and binds the report");
        }
    }
}
