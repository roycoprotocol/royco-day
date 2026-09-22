// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../../lib/forge-std/src/Test.sol";
import { SafeCast } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { IStork, StorkStructs } from "../../../../src/interfaces/external/stork/IStork.sol";
import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { NAV_UNIT, toUint256 } from "../../../../src/libraries/Units.sol";
import { StorkPriceOracle } from "../../../../src/oracle/StorkPriceOracle.sol";

/// @dev The immutables Stork's official Chainlink-adapter port exposes beside the aggregator surface
interface IStorkChainlinkAdapter {
    function stork() external view returns (address);
    function priceId() external view returns (bytes32);
}

/**
 * @title Test_StorkPriceOracle_BaseFork
 * @notice Live cross-check of the Stork composed oracle for sUSN on Base against the two official Stork Chainlink-
 *         adapter ports and the Compound MultiplicativePriceFeed composing them: same price, but the update clock
 *         reported in SECONDS and never in the future, which the ports' nanosecond stamps cannot satisfy
 * @dev Pinned at a block where both legs were freshly published. Skips itself when `BASE_RPC_URL` is unset
 */
contract Test_StorkPriceOracle_BaseFork is Test {
    /// @dev Both Stork legs were published ~58 minutes before this block (ts 1789048699)
    uint256 internal constant FORK_BLOCK = 51_129_676;

    /// @dev The Stork core on Base (version "1.0.6", validTimePeriodSeconds 3600)
    address internal constant STORK = 0x647DFd812BC1e116c6992CB2bC353b2112176fD6;

    /// @dev Noon staked USN (18 decimals)
    address internal constant SUSN = 0x34a2798D47b238A7CbA9D87D49618DEE6C4D999F;

    /// @dev The Stork asset ids, read off the official ports' `priceId()`
    bytes32 internal constant SUSN_USN_ID = 0xd29a4f8c6bfaab3bb2d1892248996a33db942d8af100aef635ba25b15a5013f0;
    bytes32 internal constant USN_USD_ID = 0x980b98c48b802c650b260cc46c9c516cd3ed0873c66a52acb560c025cb4794f6;

    /// @dev The official Stork Chainlink-adapter ports and Compound's composite of them (dawn's sUSN/USD oracle)
    address internal constant SUSN_USN_PORT = 0x907fb22C2DA56642F89702b0970a03ed13EbF136;
    address internal constant USN_USD_PORT = 0x0e658Ea83d19e540a5b4cf6BC2A6093a55525561;
    address internal constant SUSN_USD_COMPOSITE = 0x92B7E06b2C78Ac1dB619980D9a1448428112a376;

    /// @dev Sized well above the observed ~hourly cadence, and above Stork's own 3600s window on purpose
    uint32 internal constant LEG_STALENESS = 6 hours;

    /// @dev The publisher second both legs were stamped in at the pinned block
    uint256 internal constant EXPECTED_UPDATED_AT = 1_789_045_199;

    StorkPriceOracle internal oracle;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        oracle = new StorkPriceOracle(SUSN, STORK, SUSN_USN_ID, USN_USD_ID, LEG_STALENESS, LEG_STALENESS);
    }

    /// The ids and core address match the official ports' own wiring, and the core is the expected version
    function test_Live_Wiring() public view {
        assertEq(IStorkChainlinkAdapter(SUSN_USN_PORT).stork(), STORK, "sUSN/USN port core");
        assertEq(IStorkChainlinkAdapter(USN_USD_PORT).stork(), STORK, "USN/USD port core");
        assertEq(IStorkChainlinkAdapter(SUSN_USN_PORT).priceId(), SUSN_USN_ID, "sUSN/USN id");
        assertEq(IStorkChainlinkAdapter(USN_USD_PORT).priceId(), USN_USD_ID, "USN/USD id");
        assertEq(IStork(STORK).version(), "1.0.6", "core version");
        assertEq(oracle.COLLATERAL_ASSET(), SUSN, "collateral wired");
        assertEq(oracle.decimals(), 18, "NAV units are WAD");
    }

    /// The composed price equals the product of the live legs AND the Compound composite's answer at the same block
    function test_Live_MatchesTheLegsAndTheCompoundComposite() public view {
        StorkStructs.TemporalNumericValue memory a = IStork(STORK).getTemporalNumericValueUnsafeV1(SUSN_USN_ID);
        StorkStructs.TemporalNumericValue memory b = IStork(STORK).getTemporalNumericValueUnsafeV1(USN_USD_ID);
        uint256 expected = uint256(int256(a.quantizedValue)) * uint256(int256(b.quantizedValue)) / 1e18;

        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(toUint256(price), expected, "price = a x b / 1e18");

        (, int256 compositeAnswer,, uint256 compositeUpdatedAt,) = AggregatorV3Interface(SUSN_USD_COMPOSITE).latestRoundData();
        assertEq(uint256(compositeAnswer), expected, "the Compound composite agrees on the price");

        // sUSN is yield-bearing: sane band, strictly above 1 USD
        assertGt(toUint256(price), 1e18, "sUSN > 1 USD");
        assertLt(toUint256(price), 5e18, "sUSN < 5 USD");

        // The clock: the older leg's publisher second, not the composite's nanosecond stamp
        assertEq(updatedAt, Math_min(uint256(a.timestampNs) / 1e9, uint256(b.timestampNs) / 1e9), "oldest leg in seconds");
        assertEq(updatedAt, EXPECTED_UPDATED_AT, "pinned publisher second");
        assertLe(updatedAt, block.timestamp, "never in the future");
        assertGt(compositeUpdatedAt, block.timestamp, "the composite's stamp IS in the future (nanoseconds)");
    }

    /// The entry point's gate preconditions hold: poke fits uint32 and is not in the future, unlike the ports
    function test_Live_UpdateClockSatisfiesTheEntryPointGate() public {
        uint256 poked = oracle.poke();
        uint32 gateStamp = SafeCast.toUint32(poked);
        assertEq(uint256(gateStamp), EXPECTED_UPDATED_AT, "poke fits the entry point's uint32 clock");
        assertLe(poked, block.timestamp, "poke is never in the future");
        assertEq(oracle.previewPoke(), poked, "preview agrees");

        // The official ports would have overflowed the same cast and failed the future check
        (,,, uint256 portUpdatedAt,) = AggregatorV3Interface(SUSN_USN_PORT).latestRoundData();
        assertGt(portUpdatedAt, uint256(type(uint32).max), "the port's stamp overflows uint32");
        assertGt(portUpdatedAt, block.timestamp, "the port's stamp is in the future");
    }

    /// Stork's contract-wide window trips before ours: the checked getter reverts while this oracle still prices
    function test_Live_StorksOwnWindowDoesNotGateUs() public {
        uint256 window = IStork(STORK).validTimePeriodSeconds();
        assertEq(window, 3600, "pinned contract-wide window");
        // Past the core's window but well inside the per-leg thresholds
        vm.warp(EXPECTED_UPDATED_AT + window + 1);
        vm.expectRevert(IStork.StaleValue.selector);
        IStork(STORK).getTemporalNumericValueV1(SUSN_USN_ID);
        (, uint256 updatedAt) = oracle.getPrice();
        assertEq(updatedAt, EXPECTED_UPDATED_AT, "still priced under the per-leg threshold");

        // And our own gate fires exactly past its boundary: both legs share the same publisher second at this block,
        // and the collateral leg is gated first, so it is the one named
        vm.warp(EXPECTED_UPDATED_AT + LEG_STALENESS);
        oracle.getPrice();
        vm.warp(EXPECTED_UPDATED_AT + LEG_STALENESS + 1);
        vm.expectRevert(abi.encodeWithSelector(StorkPriceOracle.STALE_STORK_PRICE.selector, SUSN_USN_ID));
        oracle.getPrice();
    }

    /// @dev Local min to keep the assertion readable without an OZ import
    function Math_min(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return _a < _b ? _a : _b;
    }
}
