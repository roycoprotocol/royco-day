// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Strings } from "../../../lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import { IStork } from "../../../src/interfaces/external/stork/IStork.sol";
import { NAV_UNIT, toUint256 } from "../../../src/libraries/Units.sol";
import { StorkPriceOracle } from "../../../src/oracle/StorkPriceOracle.sol";
import { MockERC20C } from "../../mocks/MockERC20C.sol";
import { MockStork } from "../../mocks/MockStork.sol";

/**
 * @title Test_StorkPriceOracle
 * @notice Concrete vectors for the Stork composed price oracle: the two-leg floored composition, the nanosecond-to-
 *         second normalization every consumer of the update clock depends on, the oldest-hop report, the per-leg
 *         staleness gates, the identity reference leg, and the construction sanity checks
 * @dev Every expected value is derived by hand from price = floor(a x b / 1e18) and updatedAt = min(tsA, tsB) / 1e9,
 *      never captured from the oracle
 */
contract Test_StorkPriceOracle is Test {
    /// @dev Base timestamp so update timestamps assert against stable absolute values
    uint256 internal constant T0 = 1_700_000_000;

    /// @dev Distinct per-leg thresholds so each gate can be crossed independently
    uint32 internal constant COLLATERAL_LEG_STALENESS = 6 hours;
    uint32 internal constant REFERENCE_LEG_STALENESS = 12 hours;

    /// @dev Opaque Stork asset ids (any nonzero values)
    bytes32 internal constant ID_A = keccak256("SUSNUSN");
    bytes32 internal constant ID_B = keccak256("USNUSD");

    /// @dev Hand-picked leg values: sUSN/USN 1.2209 and USN/USD 0.999
    int192 internal constant VALUE_A = 1.2209e18;
    int192 internal constant VALUE_B = 0.999e18;

    MockERC20C internal collateral;
    MockStork internal stork;
    StorkPriceOracle internal oracle;

    function setUp() public {
        vm.warp(T0);
        collateral = new MockERC20C("sUSN", "sUSN", 18);
        stork = new MockStork();
        // Both legs published within the second T0, at sub-second nanosecond offsets that must floor away
        stork.setValue(ID_A, _ns(T0) + 123_456_789, VALUE_A);
        stork.setValue(ID_B, _ns(T0) + 500_000_000, VALUE_B);
        oracle = new StorkPriceOracle(address(collateral), address(stork), ID_A, ID_B, COLLATERAL_LEG_STALENESS, REFERENCE_LEG_STALENESS);
    }

    /// @dev A whole-second timestamp in Stork's nanoseconds
    function _ns(uint256 _seconds) internal pure returns (uint64) {
        return uint64(_seconds * 1e9);
    }

    /*----------------------------------------------------------------------
                                Composition
    ----------------------------------------------------------------------*/

    /**
     * The composed price is the single floored product of the two 18-decimal legs
     * Derivation: 1.2209e18 x 0.999e18 / 1e18 = 1.2196791e18 exact
     */
    function test_Composition_isTheFlooredProductOfBothLegs() public view {
        (NAV_UNIT price,) = oracle.getPrice();
        assertEq(toUint256(price), 1.2196791e18, "price = floor(a x b / 1e18)");
    }

    /**
     * Precision beyond WAD floors once, never rounds up
     * Derivation: (1e18 + 1) x 5e17 / 1e18 = 5e17 + 0.5, floored to 5e17 exact
     */
    function test_Composition_floorsPrecisionBeyondWAD() public {
        stork.setValue(ID_A, _ns(T0), 1e18 + 1);
        stork.setValue(ID_B, _ns(T0), 5e17);
        (NAV_UNIT price,) = oracle.getPrice();
        assertEq(toUint256(price), 5e17, "the half unit floors away");
    }

    /// A zero reference id is the identity leg: the collateral leg IS the NAV price, read as current
    function test_IdentityLeg_passesTheCollateralLegThrough() public {
        MockStork lone = new MockStork();
        lone.setValue(ID_A, _ns(T0 - 10), VALUE_A);
        // Construction does not read the reference leg, so a core holding only the collateral id suffices
        StorkPriceOracle identity = new StorkPriceOracle(address(collateral), address(lone), ID_A, bytes32(0), COLLATERAL_LEG_STALENESS, REFERENCE_LEG_STALENESS);
        (NAV_UNIT price, uint256 updatedAt) = identity.getPrice();
        assertEq(toUint256(price), uint256(int256(VALUE_A)), "identity leg: price is the collateral leg verbatim");
        assertEq(updatedAt, T0 - 10, "identity leg reads as current, so the collateral leg is the oldest hop");
        assertEq(identity.REFERENCE_TO_NAV_ID(), bytes32(0), "identity leg wired");
    }

    /*----------------------------------------------------------------------
                          Timestamp normalization + clock
    ----------------------------------------------------------------------*/

    /**
     * Nanosecond publisher stamps are floored to seconds on every surface, and the result satisfies the entry point's
     * gate preconditions (fits uint32, not in the future), which is the reason this oracle exists
     */
    function test_UpdatedAt_isNormalizedToSecondsOnAllThreeSurfaces() public {
        (, uint256 updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0, "sub-second nanoseconds floor away");
        assertEq(oracle.previewPoke(), T0, "previewPoke reports the same stamp");
        assertEq(oracle.poke(), T0, "poke reports the same stamp");
        assertLe(updatedAt, block.timestamp, "never in the future");
        assertLt(updatedAt, 2 ** 32, "fits the entry point's uint32 clock");
    }

    /// The report's updatedAt is the OLDER leg, in either ordering
    function test_UpdatedAt_isTheOldestLeg() public {
        stork.setValue(ID_B, _ns(T0 - 30), VALUE_B);
        (, uint256 updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0 - 30, "the reference leg is older");

        stork.setValue(ID_A, _ns(T0 - 60), VALUE_A);
        stork.setValue(ID_B, _ns(T0 - 1), VALUE_B);
        (, updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0 - 60, "the collateral leg is older");
    }

    /// A publisher clock ahead of the chain is clamped to the block, so the gate can never open early
    function test_UpdatedAt_futurePublisherStampIsClampedToTheBlock() public {
        stork.setValue(ID_A, _ns(T0 + 3600), VALUE_A);
        (NAV_UNIT price, uint256 updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0, "clamped to block.timestamp");
        assertEq(toUint256(price), 1.2196791e18, "the price is still served");
        assertEq(oracle.poke(), T0, "poke clamps identically");
    }

    /*----------------------------------------------------------------------
                                Staleness gates
    ----------------------------------------------------------------------*/

    /// Each leg fails shut exactly past its own threshold, naming the stale leg, with the other leg held fresh
    function test_Staleness_gatesEachLegIndependentlyAtItsBoundary() public {
        // Collateral leg: at the boundary prices, one second past reverts naming ID_A
        stork.setValue(ID_A, _ns(T0 - COLLATERAL_LEG_STALENESS), VALUE_A);
        (, uint256 updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0 - COLLATERAL_LEG_STALENESS, "boundary prices");
        stork.setValue(ID_A, _ns(T0 - COLLATERAL_LEG_STALENESS - 1), VALUE_A);
        vm.expectRevert(abi.encodeWithSelector(StorkPriceOracle.STALE_STORK_PRICE.selector, ID_A));
        oracle.getPrice();

        // Reference leg: same shape against its own (wider) threshold, with the collateral leg fresh again
        stork.setValue(ID_A, _ns(T0), VALUE_A);
        stork.setValue(ID_B, _ns(T0 - REFERENCE_LEG_STALENESS), VALUE_B);
        (, updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0 - REFERENCE_LEG_STALENESS, "boundary prices");
        stork.setValue(ID_B, _ns(T0 - REFERENCE_LEG_STALENESS - 1), VALUE_B);
        vm.expectRevert(abi.encodeWithSelector(StorkPriceOracle.STALE_STORK_PRICE.selector, ID_B));
        oracle.getPrice();
    }

    /// The staleness gate is driven by time as well as by republishes: warping past the collateral window fails shut
    function test_Staleness_warpingPastTheWindowFailsShut() public {
        vm.warp(T0 + COLLATERAL_LEG_STALENESS);
        oracle.getPrice();
        vm.warp(T0 + COLLATERAL_LEG_STALENESS + 1);
        vm.expectRevert(abi.encodeWithSelector(StorkPriceOracle.STALE_STORK_PRICE.selector, ID_A));
        oracle.getPrice();
    }

    /// Stork's own contract-wide window is NOT consulted: the checked getter may already revert while this oracle prices
    function test_Staleness_doesNotDependOnStorksContractWideWindow() public {
        stork.setValidTimePeriodSeconds(1);
        vm.warp(T0 + 100);
        vm.expectRevert(IStork.StaleValue.selector);
        stork.getTemporalNumericValueV1(ID_A);
        (, uint256 updatedAt) = oracle.getPrice();
        assertEq(updatedAt, T0, "the per-leg threshold is the only freshness gate");
    }

    /*----------------------------------------------------------------------
                                 Fail-shut paths
    ----------------------------------------------------------------------*/

    /// A non-positive value on either leg fails shut
    function test_RevertIf_LegValueNonPositive() public {
        stork.setValue(ID_A, _ns(T0), 0);
        vm.expectRevert(StorkPriceOracle.INVALID_PRICE.selector);
        oracle.getPrice();
        stork.setValue(ID_A, _ns(T0), -1);
        vm.expectRevert(StorkPriceOracle.INVALID_PRICE.selector);
        oracle.getPrice();

        stork.setValue(ID_A, _ns(T0), VALUE_A);
        stork.setValue(ID_B, _ns(T0), 0);
        vm.expectRevert(StorkPriceOracle.INVALID_PRICE.selector);
        oracle.getPrice();
    }

    /// An id the core no longer serves bubbles the core's NotFound, and a reverting core bubbles its revert
    function test_RevertIf_CoreFailsToServeALeg() public {
        stork.removeValue(ID_B);
        vm.expectRevert(IStork.NotFound.selector);
        oracle.getPrice();
        vm.expectRevert(IStork.NotFound.selector);
        oracle.poke();

        stork.setValue(ID_B, _ns(T0), VALUE_B);
        stork.setRevertMode(true);
        vm.expectRevert(MockStork.STORK_REVERT_MODE.selector);
        oracle.previewPoke();
    }

    /*----------------------------------------------------------------------
                                  Construction
    ----------------------------------------------------------------------*/

    /// Construction pins the wiring and rejects null or empty components
    function test_Construction_identityAndSanityChecks() public {
        assertEq(oracle.COLLATERAL_ASSET(), address(collateral), "the collateral asset is wired");
        assertEq(address(oracle.STORK()), address(stork), "the core is wired");
        assertEq(oracle.COLLATERAL_TO_REFERENCE_ID(), ID_A, "collateral leg id");
        assertEq(oracle.REFERENCE_TO_NAV_ID(), ID_B, "reference leg id");
        assertEq(oracle.COLLATERAL_LEG_STALENESS_THRESHOLD_SECONDS(), COLLATERAL_LEG_STALENESS, "collateral leg threshold");
        assertEq(oracle.REFERENCE_LEG_STALENESS_THRESHOLD_SECONDS(), REFERENCE_LEG_STALENESS, "reference leg threshold");
        assertEq(oracle.decimals(), 18, "NAV units are WAD");
        assertEq(oracle.version(), 1, "version");
        assertEq(
            oracle.description(),
            string.concat("Stork ", Strings.toHexString(uint256(ID_A), 32), " x ", Strings.toHexString(uint256(ID_B), 32)),
            "the description names both ids"
        );

        vm.expectRevert(StorkPriceOracle.NULL_ADDRESS.selector);
        new StorkPriceOracle(address(0), address(stork), ID_A, ID_B, COLLATERAL_LEG_STALENESS, REFERENCE_LEG_STALENESS);
        vm.expectRevert(StorkPriceOracle.NULL_ADDRESS.selector);
        new StorkPriceOracle(address(collateral), address(0), ID_A, ID_B, COLLATERAL_LEG_STALENESS, REFERENCE_LEG_STALENESS);
        vm.expectRevert(StorkPriceOracle.INVALID_PRICE_ID.selector);
        new StorkPriceOracle(address(collateral), address(stork), bytes32(0), ID_B, COLLATERAL_LEG_STALENESS, REFERENCE_LEG_STALENESS);
        vm.expectRevert(StorkPriceOracle.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        new StorkPriceOracle(address(collateral), address(stork), ID_A, ID_B, 0, REFERENCE_LEG_STALENESS);
        vm.expectRevert(StorkPriceOracle.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        new StorkPriceOracle(address(collateral), address(stork), ID_A, ID_B, COLLATERAL_LEG_STALENESS, 0);
    }

    /// An id the core does not serve fails the deployment, on either leg
    function test_RevertIf_ConstructedWithAnUnknownId() public {
        bytes32 unknown = keccak256("UNKNOWN");
        vm.expectRevert(IStork.NotFound.selector);
        new StorkPriceOracle(address(collateral), address(stork), unknown, ID_B, COLLATERAL_LEG_STALENESS, REFERENCE_LEG_STALENESS);
        vm.expectRevert(IStork.NotFound.selector);
        new StorkPriceOracle(address(collateral), address(stork), ID_A, unknown, COLLATERAL_LEG_STALENESS, REFERENCE_LEG_STALENESS);
    }

    /// The oracle is fully immutable: no proxy initializer and no setters
    function test_Construction_hasNoAdminSurface() public {
        (bool initOk,) = address(oracle).call(abi.encodeWithSignature("initialize(address,uint256,uint32)", address(this), uint256(0), uint32(0)));
        assertFalse(initOk, "the oracle is not a proxy and exposes no initializer");
        (bool thresholdOk,) = address(oracle).call(abi.encodeWithSignature("setStalenessThreshold(uint32)", uint32(1)));
        assertFalse(thresholdOk, "no threshold setter exists");
        (bool idsOk,) = address(oracle).call(abi.encodeWithSignature("setPriceIds(bytes32,bytes32)", ID_A, ID_B));
        assertFalse(idsOk, "no id setter exists");
        (bool storkOk,) = address(oracle).call(abi.encodeWithSignature("setStork(address)", address(stork)));
        assertFalse(storkOk, "no core setter exists");
    }
}
