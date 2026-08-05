// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { NAV_UNIT, toUint256 } from "../../../src/libraries/Units.sol";
import { ChainlinkPriceOracle } from "../../../src/oracle/ChainlinkPriceOracle.sol";
import { ChainlinkPriceOracleBase } from "../../../src/oracle/base/ChainlinkPriceOracleBase.sol";
import { MockAggregatorV3 } from "../../mocks/MockAggregatorV3.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";

/**
 * @title Test_ChainlinkIdentityOracle
 * @notice Concrete vectors for the plain ChainlinkPriceOracle: the identity conversion hop means the reported price
 *         is exactly the feed's answer rescaled to WAD, the feed's timestamp passes through unchanged, and the
 *         description is the feed's own pair without a triangulation prefix
 * @dev Every expected value is derived by hand from price = floor(WAD * answer / 10^feedDecimals)
 */
contract Test_ChainlinkIdentityOracle is Test {
    /// @dev Base timestamp so update timestamps assert against stable absolute values
    uint256 internal constant T0 = 1_700_000_000;

    MockERC20C internal collateral;
    MockAggregatorV3 internal feed;
    ChainlinkPriceOracle internal oracle;

    function setUp() public {
        vm.warp(T0);
        // A 6-decimal collateral directly priced by an 8-decimal feed, the standard USDC / USD shape
        collateral = new MockERC20C("USDC", "USDC", 6);
        feed = new MockAggregatorV3(8, 1e8);
        oracle = new ChainlinkPriceOracle(address(collateral), address(feed), 1 days);
    }

    /**
     * The identity hop rescales the feed's answer to WAD with no other transformation
     * Derivation: feed 0.99987654e8 at 8 decimals: price = floor(1e18 * 99987654 / 1e8) = 999876540000000000 exact
     */
    function test_Identity_rescalesFeedAnswerToWAD() public {
        feed.setAnswer(0.99987654e8);
        (NAV_UNIT price,) = oracle.getPrice();
        assertEq(toUint256(price), 999_876_540_000_000_000, "the identity hop must rescale the answer to WAD exactly");
        assertEq(oracle.decimals(), 18, "prices are reported at WAD precision");
    }

    /**
     * A feed more precise than WAD floors the excess precision away, never rounds up
     * Derivation: feed 1e21 + 7 at 21 decimals: price = floor(1e18 * (1e21 + 7) / 1e21) = 1e18, the trailing 7 drops
     * And 1.999999999999999999999e21 floors to 1999999999999999999, not up to 2e18
     */
    function test_Identity_floorsFeedPrecisionBeyondWAD() public {
        MockAggregatorV3 preciseFeed = new MockAggregatorV3(21, int256(1e21 + 7));
        ChainlinkPriceOracle preciseOracle = new ChainlinkPriceOracle(address(collateral), address(preciseFeed), 1 days);
        (NAV_UNIT price,) = preciseOracle.getPrice();
        assertEq(toUint256(price), 1e18, "sub-WAD feed precision must floor away");

        preciseFeed.setAnswer(1_999_999_999_999_999_999_999);
        (price,) = preciseOracle.getPrice();
        assertEq(toUint256(price), 1_999_999_999_999_999_999, "the rescale must never round up");
    }

    /// The feed's update timestamp passes through unchanged, and poke and previewPoke report the same clock as getPrice
    function test_UpdatedAt_feedTimestampPassesThroughAllThreeSurfaces() public {
        feed.setUpdatedAt(T0 - 123);
        (, uint256 updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0 - 123, "getPrice must pass the feed's timestamp through unchanged");
        assertEq(oracle.poke(), T0 - 123, "poke must report the feed's timestamp");
        assertEq(oracle.previewPoke(), T0 - 123, "previewPoke must agree with poke");

        // An answer move without a feed restamp must not refresh the clock, freshness keys on the feed alone
        feed.setAnswer(1.5e8);
        assertEq(oracle.poke(), T0 - 123, "a price move without a feed update must not advance the clock");
    }

    /// The identity hop adds no pair segment, so the description is the feed's own and carries no collateral prefix
    function test_Description_isFeedPassthroughWithoutPairPrefix() public view {
        assertEq(oracle.description(), feed.description(), "the identity oracle must pass the feed's description through");
        assertNotEq(oracle.description(), string.concat(collateral.symbol(), " / ", feed.description()), "no triangulation prefix may be added");
    }

    /// A non-positive answer is refused, a zero or negative mark can never price collateral
    function test_RevertIf_FeedAnswerNonPositive() public {
        feed.setAnswer(0);
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_PRICE.selector);
        oracle.getPrice();
        feed.setAnswer(-1);
        vm.expectRevert(ChainlinkPriceOracleBase.INVALID_PRICE.selector);
        oracle.getPrice();
    }

    /// A round answered before it started carries a stale answer forward, so the composition refuses it
    function test_RevertIf_FeedRoundIncomplete() public {
        feed.setRoundId(5);
        feed.setAnsweredInRound(4);
        vm.expectRevert(ChainlinkPriceOracleBase.INCOMPLETE_PRICE.selector);
        oracle.getPrice();
    }

    /// Construction pins the wiring and rejects null components
    function test_Construction_identityAndNullChecks() public {
        assertEq(oracle.COLLATERAL_ASSET(), address(collateral), "the collateral asset is wired");
        assertEq(address(oracle.ORACLE()), address(feed), "the feed is wired");
        assertEq(oracle.version(), 1, "version");
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new ChainlinkPriceOracle(address(0), address(feed), 1 days);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new ChainlinkPriceOracle(address(collateral), address(0), 1 days);
    }
}
