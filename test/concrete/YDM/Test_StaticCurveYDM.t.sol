// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test, stdError } from "../../../lib/forge-std/src/Test.sol";
import { Vm } from "../../../lib/forge-std/src/Vm.sol";
import { SafeCast } from "../../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { IYDM } from "../../../src/interfaces/IYDM.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { MarketState } from "../../../src/libraries/Types.sol";
import { StaticCurveYDM } from "../../../src/ydm/StaticCurveYDM.sol";

/**
 * @title Test_StaticCurveYDM
 * @notice Unit and fuzz tests for the static (non-adapting) two-segment yield curve. Stateful invariant
 *         coverage lives in test/invariant/Invariant_YDM.t.sol.
 * @dev Every expected value is hand-derived from src/ydm/StaticCurveYDM.sol. No call to the contract
 *      under test ever appears on the expected side of an assertion.
 *
 * Curve math (floor rounding in both legs):
 *   slopeLt  = floor((yT - y0) * WAD / target)
 *   slopeGte = floor((yFull - yT) * WAD / (WAD - target))
 *   U < target : Y = floor(slopeLt  * U           / WAD) + y0
 *   U >= target: Y = floor(slopeGte * (U - target) / WAD) + yT     (U capped to WAD first)
 */
contract Test_StaticCurveYDM is Test {
    uint64 constant UINT64_MAX = type(uint64).max; // 18446744073709551615 ~= 1.8447e19

    // Distinct non-test accountant address for per-sender keying tests.
    address constant ACCT_B = address(0xB0B);

    event StaticCurveYdmInitialized(address indexed accountant, uint256 yieldShareAtZeroUtilWAD, uint256 slopeLptTargetUtilWAD, uint256 slopeGteTargetUtilWAD);
    event YdmOutput(address indexed accountant, uint256 yieldShareWAD);

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _deploy(uint256 target) internal returns (StaticCurveYDM) {
        return new StaticCurveYDM(target);
    }

    /// The reference curve: target=8e17, init(1e17,5e17,9e17) => slopeLt=5e17, slopeGte=2e18.
    function _referenceCurve() internal returns (StaticCurveYDM ydm) {
        ydm = _deploy(8e17);
        ydm.initializeYDMForMarket(1e17, 5e17, 9e17);
    }

    // =====================================================================
    // Constructor: the (0, WAD] target utilization gate (shared BaseYDM check)
    // =====================================================================

    /// A zero target utilization is rejected: the curve needs a positive kink to interpolate around
    function test_RevertIf_ConstructorTargetZero() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        new StaticCurveYDM(0);
    }

    /// One wei is the smallest accepted target utilization
    function test_Constructor_TargetOneWei() public {
        StaticCurveYDM ydm = _deploy(1);
        assertEq(ydm.TARGET_UTILIZATION_WAD(), 1, "target getter == 1");
    }

    /// A mid-range target utilization is stored verbatim
    function test_Constructor_TargetHalf() public {
        StaticCurveYDM ydm = _deploy(5e17);
        assertEq(ydm.TARGET_UTILIZATION_WAD(), 5e17, "target getter == 5e17");
    }

    /// WAD minus one wei is accepted as a target utilization
    function test_Constructor_TargetWadMinusOne() public {
        StaticCurveYDM ydm = _deploy(WAD - 1);
        assertEq(ydm.TARGET_UTILIZATION_WAD(), WAD - 1, "target getter == WAD-1");
    }

    /// The constructor allows target == WAD; initializeYDMForMarket later reverts on the zero denominator
    function test_Constructor_TargetWadAllowed() public {
        StaticCurveYDM ydm = _deploy(WAD);
        assertEq(ydm.TARGET_UTILIZATION_WAD(), WAD, "target getter == WAD");
    }

    /// A target above WAD is meaningless (utilization is capped at WAD) and rejected
    function test_RevertIf_ConstructorTargetAboveWad() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        new StaticCurveYDM(WAD + 1);
    }

    /// The extreme uint256 max target is rejected by the same gate
    function test_RevertIf_ConstructorTargetUintMax() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        new StaticCurveYDM(type(uint256).max);
    }

    // =====================================================================
    // initializeYDMForMarket parameter validation (target = 8e17)
    // =====================================================================

    /// y0 above yT would give a negative discount and is rejected
    function test_RevertIf_InitializeY0AboveYTarget() public {
        StaticCurveYDM ydm = _deploy(8e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(5e17, 4e17, 6e17); // y0 > yT
    }

    /// yT above yFull would give a downward upper segment and is rejected
    function test_RevertIf_InitializeYTargetAboveYFull() public {
        StaticCurveYDM ydm = _deploy(8e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(1e17, 6e17, 5e17); // yT > yFull
    }

    /// yFull above WAD could pay more than the whole gain and is rejected
    function test_RevertIf_InitializeYFullAboveWad() public {
        StaticCurveYDM ydm = _deploy(8e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(1e17, 5e17, uint64(WAD + 1)); // yFull > WAD
    }

    /// yT == 0 is rejected even when the orderings hold (all-zero curve)
    function test_RevertIf_InitializeYTargetZero_AllZero() public {
        StaticCurveYDM ydm = _deploy(8e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(0, 0, 0); // yT == 0
    }

    /// yT == 0 with a positive yFull is rejected: the yT > 0 gate is independent of the ordering checks
    function test_RevertIf_InitializeYTargetZero_PositiveYFull() public {
        StaticCurveYDM ydm = _deploy(8e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(0, 0, 5e17); // yT == 0 though ordering holds
    }

    /// yT == 0 with a positive y0 is rejected (the ordering also fails, but yT == 0 is the pinned gate)
    function test_RevertIf_InitializeYTargetZero_PositiveY0() public {
        StaticCurveYDM ydm = _deploy(8e17);
        // y0=1 > yT=0 also fails ordering, but the point is yT==0 is rejected
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(1, 0, 1);
    }

    /// A flat curve parked above WAD is rejected by the yFull <= WAD gate
    function test_RevertIf_InitializeFlatCurveAboveWad() public {
        StaticCurveYDM ydm = _deploy(8e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(uint64(WAD + 1), uint64(WAD + 1), uint64(WAD + 1)); // yFull > WAD
    }

    /// Valid init emits StaticCurveYdmInitialized(accountant, y0, slopeLt, slopeGte).
    /// The reference curve: slopeLt = (5e17-1e17)*1e18/8e17 = 4e35/8e17 = 5e17.
    ///          slopeGte = (9e17-5e17)*1e18/(2e17) = 4e35/2e17 = 2e18.
    function test_Initialize_ReferenceCurve_EmitsSlopes() public {
        StaticCurveYDM ydm = _deploy(8e17);
        vm.expectEmit(true, true, true, true, address(ydm));
        emit StaticCurveYdmInitialized(address(this), 1e17, 5e17, 2e18);
        ydm.initializeYDMForMarket(1e17, 5e17, 9e17);

        (uint64 y0, uint64 sLt, uint64 yT, uint64 sGte) = ydm.accountantToCurve(address(this));
        assertEq(y0, 1e17, "stored y0");
        assertEq(sLt, 5e17, "stored slopeLt");
        assertEq(yT, 5e17, "stored yT");
        assertEq(sGte, 2e18, "stored slopeGte");
    }

    /// Minimal valid: yT = 1 > 0. slopeLt = floor((1-0)*1e18/8e17) = floor(1.25) = 1, slopeGte = 0.
    function test_Initialize_MinimalCurve_OneWeiYTarget() public {
        StaticCurveYDM ydm = _deploy(8e17);
        ydm.initializeYDMForMarket(0, 1, 1);
        (uint64 y0, uint64 sLt, uint64 yT, uint64 sGte) = ydm.accountantToCurve(address(this));
        assertEq(y0, 0);
        assertEq(sLt, 1, "floor(1e18/8e17)=1");
        assertEq(yT, 1);
        assertEq(sGte, 0);
    }

    /// Flat at ceiling: (WAD,WAD,WAD) valid. Y == WAD everywhere. slopes both 0.
    function test_Initialize_FlatCurveAtWadCeiling() public {
        StaticCurveYDM ydm = _deploy(8e17);
        ydm.initializeYDMForMarket(uint64(WAD), uint64(WAD), uint64(WAD));
        (uint64 y0, uint64 sLt, uint64 yT, uint64 sGte) = ydm.accountantToCurve(address(this));
        assertEq(y0, WAD);
        assertEq(sLt, 0);
        assertEq(yT, WAD);
        assertEq(sGte, 0);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), WAD, "flat ceiling Y==WAD @0");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, type(uint256).max), WAD, "flat ceiling Y==WAD @max");
    }

    /// yFull == WAD boundary allowed.
    function test_Initialize_YFullAtWadBoundary() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(0, 5e17, uint64(WAD));
        (, uint64 sLt,, uint64 sGte) = ydm.accountantToCurve(address(this));
        // slopeLt = 5e17*1e18/5e17 = 1e18 ; slopeGte = (WAD-5e17)*1e18/(WAD-5e17) = 1e18
        assertEq(sLt, 1e18, "slopeLt");
        assertEq(sGte, 1e18, "slopeGte");
    }

    // =====================================================================
    // SafeCast slope overflow at initialization
    // =====================================================================

    /// slopeLt = 1e36/5e16 = 2e19 > uint64.max => SafeCast overflow.
    function test_RevertIf_InitializeSlopeBelowTargetOverflowsUint64() public {
        StaticCurveYDM ydm = _deploy(5e16);
        vm.expectPartialRevert(SafeCast.SafeCastOverflowedUintDowncast.selector);
        ydm.initializeYDMForMarket(0, uint64(WAD), uint64(WAD));
    }

    /// Safe neighbor: target=6e16, slopeLt = floor(1e36/6e16) = 16666666666666666666 < max.
    function test_Initialize_SlopeBelowTargetJustUnderUint64Max() public {
        StaticCurveYDM ydm = _deploy(6e16);
        ydm.initializeYDMForMarket(0, uint64(WAD), uint64(WAD));
        (, uint64 sLt,, uint64 sGte) = ydm.accountantToCurve(address(this));
        assertEq(sLt, 16_666_666_666_666_666_666, "floor(1e36/6e16)");
        assertEq(sGte, 0, "yT==yFull => slopeGte 0");
        assertLe(sLt, UINT64_MAX, "within uint64");
    }

    /// slopeGte overflow: target=95e16, init(0,1,WAD).
    /// slopeGte = (WAD-1)*1e18/(WAD-95e16) = (1e36-1e18)/5e16 ~= 1.9999...e19 > uint64.max.
    function test_RevertIf_InitializeSlopeAboveTargetOverflowsUint64() public {
        StaticCurveYDM ydm = _deploy(95e16);
        vm.expectPartialRevert(SafeCast.SafeCastOverflowedUintDowncast.selector);
        ydm.initializeYDMForMarket(0, 1, uint64(WAD));
    }

    /// Safe neighbor: target=94e16, slopeGte = floor((1e36-1e18)/6e16) < max.
    function test_Initialize_SlopeAboveTargetJustUnderUint64Max() public {
        StaticCurveYDM ydm = _deploy(94e16);
        ydm.initializeYDMForMarket(0, 1, uint64(WAD));
        (,,, uint64 sGte) = ydm.accountantToCurve(address(this));
        assertLe(sGte, UINT64_MAX, "within uint64");
        // slopeGte = floor((WAD-1)*WAD/(WAD-94e16)) = floor((1e36 - 1e18)/6e16) = floor((1e20 - 100)/6)
        //          = 99999999999999999900/6 = 16666666666666666650 exactly (the numerator divides by 6)
        assertEq(sGte, 16_666_666_666_666_666_650, "hand-derived slopeGte literal");
    }

    /// Overflow is gap-driven, not target-alone: extreme target=5e16 but tiny gap => tiny slope.
    function test_Initialize_TinyGapAtExtremeTarget_NoOverflow() public {
        StaticCurveYDM ydm = _deploy(5e16);
        ydm.initializeYDMForMarket(0, 1, 1); // slopeLt = floor(1*1e18/5e16) = 20
        (, uint64 sLt,, uint64 sGte) = ydm.accountantToCurve(address(this));
        assertEq(sLt, 20, "floor(1e18/5e16)");
        assertEq(sGte, 0);
    }

    /// slopeLt is computed before slopeGte: 1-wei target with positive lt gap overflows on lt.
    function test_RevertIf_InitializeOneWeiTargetWithPositiveLowerGap() public {
        StaticCurveYDM ydm = _deploy(1);
        vm.expectPartialRevert(SafeCast.SafeCastOverflowedUintDowncast.selector);
        ydm.initializeYDMForMarket(1e17, 5e17, 9e17); // slopeLt = 4e17*1e18/1 = 4e35
    }

    /// 1-wei target usable when y0==yT (flat lt leg): slopeLt = 0.
    function test_Initialize_OneWeiTargetWithFlatLowerLeg() public {
        StaticCurveYDM ydm = _deploy(1);
        // slopeGte = floor(4e17*1e18/(1e18-1)) = floor(4e35/(1e18-1)). Since (1e18-1)*4e17 = 4e35 - 4e17,
        // the remainder is 4e17 < 1e18-1: the one-wei-shrunk denominator cannot lift the slope a whole wei,
        // so the floor is exactly 4e17 (safe, far under uint64.max)
        ydm.initializeYDMForMarket(5e17, 5e17, 9e17);
        (, uint64 sLt,, uint64 sGte) = ydm.accountantToCurve(address(this));
        assertEq(sLt, 0, "flat lt");
        assertEq(sGte, 400_000_000_000_000_000, "hand-derived slopeGte literal");
    }

    /// Near-WAD target usable when yT==yFull (flat gte leg): slopeGte = 0.
    function test_Initialize_NearWadTargetWithFlatUpperLeg() public {
        StaticCurveYDM ydm = _deploy(WAD - 1);
        ydm.initializeYDMForMarket(5e17, 9e17, 9e17);
        (, uint64 sLt,, uint64 sGte) = ydm.accountantToCurve(address(this));
        assertEq(sGte, 0, "flat gte");
        // slopeLt = floor(4e17*1e18/(1e18-1)): (1e18-1)*4e17 = 4e35 - 4e17 leaves remainder 4e17 < 1e18-1,
        // so the floor is exactly 4e17
        assertEq(sLt, 400_000_000_000_000_000, "hand-derived slopeLt literal");
    }

    // =====================================================================
    // target == WAD initialization reverts (division by zero, Panic 0x12)
    // =====================================================================

    /// target == WAD makes the upper-segment denominator zero: a normal curve reverts with the division panic
    function test_RevertIf_InitializeAtWadTarget_NormalParams() public {
        StaticCurveYDM ydm = _deploy(WAD);
        vm.expectRevert(stdError.divisionError);
        ydm.initializeYDMForMarket(1e17, 5e17, 9e17);
    }

    /// Even a flat curve computes the upper slope with denominator zero at target == WAD, so it panics too
    function test_RevertIf_InitializeAtWadTarget_FlatParams() public {
        StaticCurveYDM ydm = _deploy(WAD);
        // even a flat curve computes slopeGte with denominator 0 => 0/0 => Panic 0x12
        vm.expectRevert(stdError.divisionError);
        ydm.initializeYDMForMarket(5e17, 5e17, 5e17);
    }

    /// A full-span curve at target == WAD hits the same division panic
    function test_RevertIf_InitializeAtWadTarget_FullSpanParams() public {
        StaticCurveYDM ydm = _deploy(WAD);
        vm.expectRevert(stdError.divisionError);
        ydm.initializeYDMForMarket(0, 1, uint64(WAD));
    }

    // =====================================================================
    // Uninitialized market query reverts
    // =====================================================================

    /// previewYieldShare for a never-initialized accountant reverts instead of quoting a zero curve
    function test_RevertIf_PreviewYieldShareUninitialized() public {
        StaticCurveYDM ydm = _deploy(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.previewYieldShare(MarketState.PERPETUAL, 0);
    }

    /// yieldShare for a never-initialized accountant reverts instead of paying on a zero curve
    function test_RevertIf_YieldShareUninitialized() public {
        StaticCurveYDM ydm = _deploy(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.yieldShare(MarketState.PERPETUAL, 5e17);
    }

    /// The uninitialized gate fires before any utilization handling, even at uint256 max
    function test_RevertIf_PreviewYieldShareUninitialized_MaxUtilization() public {
        StaticCurveYDM ydm = _deploy(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.previewYieldShare(MarketState.FIXED_TERM, type(uint256).max);
    }

    /// mapping is keyed by msg.sender: A inits, B (pranked) is still uninitialized.
    function test_RevertIf_YieldShareQueriedByUninitializedAccountant() public {
        StaticCurveYDM ydm = _referenceCurve(); // address(this) initialized
        vm.prank(ACCT_B);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.yieldShare(MarketState.PERPETUAL, 0);
    }

    /// The initialized sender queries cleanly (the anti-vacuity control for the per-sender revert above)
    function test_YieldShare_InitializedSenderCanQuery() public {
        StaticCurveYDM ydm = _referenceCurve();
        // no revert, returns y0 at U=0
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, 0), 1e17, "reference curve Y(0) == y0");
    }

    // =====================================================================
    // Boundary utilization sweep on the reference curve
    // target=8e17, slopeLt=5e17, slopeGte=2e18, y0=1e17, yT=5e17, yFull=9e17
    // =====================================================================

    function _assertReferenceCurvePoint(StaticCurveYDM ydm, uint256 u, uint256 expected) internal {
        // state-independence
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, u), expected, "preview PERPETUAL");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, u), expected, "preview FIXED_TERM");
        // preview == yieldShare
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, u), expected, "yieldShare PERPETUAL");
        assertEq(ydm.yieldShare(MarketState.FIXED_TERM, u), expected, "yieldShare FIXED_TERM");
        assertLe(expected, WAD, "<= WAD invariant");
    }

    /// Wei-exact sweep across every utilization boundary of the reference curve, both states, both entrypoints
    function test_PreviewYieldShare_ReferenceCurveUtilizationSweep() public {
        StaticCurveYDM ydm = _referenceCurve();
        _assertReferenceCurvePoint(ydm, 0, 1e17); // Y(0) = y0
        _assertReferenceCurvePoint(ydm, 1, 1e17); // Y(1): floor(0.5) = 0, still y0
        _assertReferenceCurvePoint(ydm, 1e17, 15e16); // Y(1e17) = 5e16 + 1e17
        _assertReferenceCurvePoint(ydm, 4e17, 3e17); // Y(4e17) = 2e17 + 1e17
        _assertReferenceCurvePoint(ydm, 8e17 - 1, 499_999_999_999_999_999); // Y(target - 1) = yT - 1 (floor)
        _assertReferenceCurvePoint(ydm, 8e17, 5e17); // Y(target) == yT (kink continuity)
        _assertReferenceCurvePoint(ydm, 8e17 + 1, 500_000_000_000_000_002); // Y(target + 1) = floor(2) + 5e17
        _assertReferenceCurvePoint(ydm, 9e17, 7e17); // Y(9e17) = 2e17 + 5e17
        _assertReferenceCurvePoint(ydm, WAD - 1, 899_999_999_999_999_998); // Y(WAD - 1) = yFull - 2 (floor)
        _assertReferenceCurvePoint(ydm, WAD, 9e17); // Y(WAD) == yFull
        _assertReferenceCurvePoint(ydm, WAD + 1, 9e17); // capped past WAD
        _assertReferenceCurvePoint(ydm, 2e18, 9e17); // capped at 2*WAD
        _assertReferenceCurvePoint(ydm, type(uint256).max, 9e17); // capped at uint256 max, no overflow
    }

    /// Monotonic non-decrease across the swept points.
    function test_PreviewYieldShare_MonotoneNonDecreasing() public {
        StaticCurveYDM ydm = _referenceCurve();
        uint256[10] memory us = [uint256(0), 1e17, 4e17, 8e17 - 1, 8e17, 8e17 + 1, 9e17, WAD - 1, WAD, WAD + 1];
        uint256 prev = 0;
        for (uint256 i = 0; i < us.length; i++) {
            uint256 y = ydm.previewYieldShare(MarketState.PERPETUAL, us[i]);
            assertGe(y, prev, "monotone non-decreasing");
            prev = y;
        }
    }

    // =====================================================================
    // Floor rounding toward the paying tranche
    // =====================================================================

    /// target=5e17, init(0,1,1): slopeLt=2, slopeGte=0.
    function test_PreviewYieldShare_FloorRounding_SubUnitSlope() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(0, 1, 1);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 1e17), 0, "floor(2*1e17/1e18) = 0");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 5e17 - 1), 0, "floor((1e18-2)/1e18) = 0");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 5e17), 1, "kink -> yT = 1");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, WAD), 1, "slopeGte 0 -> yFull = 1");
    }

    /// target=7e17, init(0,3e17,4e17): slopeGte = floor(1e17*1e18/3e17) = 333333333333333333.
    /// Y(WAD) = floor(333333333333333333 * 3e17/1e18) + 3e17 = 99999999999999999 + 3e17 = 4e17 - 1.
    function test_PreviewYieldShare_FloorRounding_OneWeiUnderYFull() public {
        StaticCurveYDM ydm = _deploy(7e17);
        ydm.initializeYDMForMarket(0, 3e17, 4e17);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, WAD), 399_999_999_999_999_999, "4e17 - 1 (floor loss)");
    }

    /// A symmetric curve: target=5e17, init(2e17,5e17,8e17) => slopeLt=slopeGte=6e17.
    /// U=target+1: floor(6e17*1/1e18)=floor(0.6)=0 => equals yT despite U>target.
    function test_PreviewYieldShare_FloorRounding_JustPastKinkRoundsFlat() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(2e17, 5e17, 8e17);
        (, uint64 sLt,, uint64 sGte) = ydm.accountantToCurve(address(this));
        assertEq(sLt, 6e17, "slopeLt");
        assertEq(sGte, 6e17, "slopeGte");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 2e17, "Y(0)=y0");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 5e17 + 1), 5e17, "just past kink floors to yT");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, WAD), 8e17, "Y(WAD)=yFull");
    }

    // =====================================================================
    // Yield-share value boundaries (output floor and ceiling)
    // =====================================================================

    /// (WAD,WAD,WAD): Y == WAD for every U including > WAD. Assert equal, never exceeds.
    function test_PreviewYieldShare_FlatCeilingNeverExceedsWad() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(uint64(WAD), uint64(WAD), uint64(WAD));
        uint256[4] memory us = [uint256(0), 5e17, WAD, 2 * WAD];
        for (uint256 i = 0; i < us.length; i++) {
            uint256 y = ydm.previewYieldShare(MarketState.PERPETUAL, us[i]);
            assertEq(y, WAD, "flat ceiling == WAD");
            assertLe(y, WAD, "never exceeds WAD");
        }
    }

    /// (1,1,1): Y == 1 everywhere (minimum nonzero constant).
    function test_PreviewYieldShare_FlatMinimalConstant() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(1, 1, 1);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 1);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, type(uint256).max), 1);
    }

    /// (0,5e17,WAD): reaches exactly WAD at full util and caps there. Zero at zero util.
    function test_PreviewYieldShare_ReachesWadExactlyAtFullUtilization() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(0, 5e17, uint64(WAD));
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 0, "y0=0 at U=0");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 25e16), 25e16, "linear mid");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 5e17), 5e17, "kink=yT");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, WAD), WAD, "hits WAD at full util");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 2 * WAD), WAD, "caps at WAD");
    }

    /// zero yield share at zero utilization is valid.
    function test_PreviewYieldShare_ZeroAtZeroUtilization() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(0, 3e17, 5e17);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 0, "Y(0)==0");
    }

    // =====================================================================
    // State independence, preview/mutate parity, idempotence
    // =====================================================================

    /// The static model ignores the market state: PERPETUAL and FIXED_TERM agree everywhere
    function test_YieldShare_MarketStateIndependent() public {
        StaticCurveYDM ydm = _referenceCurve();
        uint256[6] memory us = [uint256(0), 25e16, 5e17, 75e16, WAD, 2 * WAD];
        for (uint256 i = 0; i < us.length; i++) {
            assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, us[i]), ydm.previewYieldShare(MarketState.FIXED_TERM, us[i]), "state ignored (preview)");
            assertEq(ydm.yieldShare(MarketState.PERPETUAL, us[i]), ydm.yieldShare(MarketState.FIXED_TERM, us[i]), "state ignored (yieldShare)");
        }
    }

    /// preview does not persist state (curve bytes unchanged before/after).
    function test_PreviewYieldShare_DoesNotMutateCurve() public {
        StaticCurveYDM ydm = _referenceCurve();
        (uint64 a0, uint64 a1, uint64 a2, uint64 a3) = ydm.accountantToCurve(address(this));
        ydm.previewYieldShare(MarketState.PERPETUAL, 7e17);
        (uint64 b0, uint64 b1, uint64 b2, uint64 b3) = ydm.accountantToCurve(address(this));
        assertEq(a0, b0);
        assertEq(a1, b1);
        assertEq(a2, b2);
        assertEq(a3, b3);
    }

    /// yieldShare does not mutate the curve either (Static is stateless).
    function test_YieldShare_DoesNotMutateCurve() public {
        StaticCurveYDM ydm = _referenceCurve();
        (uint64 a0, uint64 a1, uint64 a2, uint64 a3) = ydm.accountantToCurve(address(this));
        ydm.yieldShare(MarketState.PERPETUAL, 7e17);
        (uint64 b0, uint64 b1, uint64 b2, uint64 b3) = ydm.accountantToCurve(address(this));
        assertEq(a0, b0);
        assertEq(a1, b1);
        assertEq(a2, b2);
        assertEq(a3, b3);
    }

    /// idempotence: repeated calls return the identical value, no drift.
    function test_YieldShare_RepeatedCallsNoDrift() public {
        StaticCurveYDM ydm = _referenceCurve();
        uint256 first = ydm.yieldShare(MarketState.PERPETUAL, 5e17);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(ydm.yieldShare(MarketState.PERPETUAL, 5e17), first, "no drift across calls");
        }
    }

    /// Static does NOT drift with time (negative adaptation test).
    function test_PreviewYieldShare_NoTimeAdaptation() public {
        StaticCurveYDM ydm = _referenceCurve();
        uint256 before = ydm.previewYieldShare(MarketState.PERPETUAL, 4e17);
        vm.warp(block.timestamp + 3650 days);
        uint256 afterWarp = ydm.previewYieldShare(MarketState.PERPETUAL, 4e17);
        assertEq(before, afterWarp, "no time adaptation");
    }

    /// yieldShare emits YdmOutput with the computed value. Preview emits nothing.
    function test_YieldShare_EmitsYdmOutput_PreviewSilent() public {
        StaticCurveYDM ydm = _referenceCurve();

        // Y(7.5e17) on the reference curve = floor(2e18*(75e16-8e17)/1e18)? 75e16 < 8e17 -> lt leg.
        // floor(5e17 * 75e16 / 1e18) + 1e17 = floor(3.75e17)+1e17 = 375e15 + 1e17 = 475e15.
        vm.expectEmit(true, true, true, true, address(ydm));
        emit YdmOutput(address(this), 475e15);
        ydm.yieldShare(MarketState.PERPETUAL, 75e16);

        // preview emits no logs
        vm.recordLogs();
        ydm.previewYieldShare(MarketState.PERPETUAL, 75e16);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "preview emits nothing");
    }

    // =====================================================================
    // Re-initialization (no re-init guard) and per-accountant isolation
    // =====================================================================

    /// Re-initialization overwrites the stored curve (there is no re-init guard, the accountant owns its curve)
    function test_Initialize_ReinitializeOverwritesCurve() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(1e17, 3e17, 5e17); // first curve -> Y(0)=1e17
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 1e17, "before re-init");
        ydm.initializeYDMForMarket(0, 1e17, 2e17); // second curve -> Y(0)=0
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 0, "after re-init reflects new curve");
    }

    /// A failed re-initialization must leave the previous curve byte-identical
    function test_RevertIf_ReinitializeInvalid_PreservesCurve() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(1e17, 3e17, 5e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(2e17, 1e17, 5e17); // invalid, must not touch storage
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 1e17, "the first curve must be intact after the failed re-init");
    }

    /// Curves are keyed by msg.sender: two accountants on one model never read each other's parameters
    function test_YieldShare_PerAccountantCurveIsolation() public {
        StaticCurveYDM ydm = _deploy(5e17);
        // this = curve X: y0=1e17
        ydm.initializeYDMForMarket(1e17, 3e17, 5e17);
        // B = curve Y: y0=0
        vm.prank(ACCT_B);
        ydm.initializeYDMForMarket(0, 2e17, 4e17);

        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 1e17, "this curve Y(0)=1e17");
        vm.prank(ACCT_B);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 0, "B curve Y(0)=0");
    }

    // =====================================================================
    // FUZZ TESTS
    // =====================================================================

    struct Cfg {
        uint256 target;
        uint64 y0;
        uint64 yT;
        uint64 yFull;
    }

    /// Draw an overflow-safe, non-WAD config. target in [1e17, 9e17] guarantees both
    /// slopes <= WAD*WAD/1e17 = 1e19 < uint64.max for any gap up to WAD.
    function _boundedConfig(uint256 t, uint256 a, uint256 b, uint256 c) internal pure returns (Cfg memory cfg) {
        cfg.target = bound(t, 1e17, 9e17);
        uint64 yT = uint64(bound(a, 1, WAD)); // yT >= 1
        uint64 y0 = uint64(bound(b, 0, yT)); // 0 <= y0 <= yT
        uint64 yFull = uint64(bound(c, yT, WAD)); // yT <= yFull <= WAD
        cfg.y0 = y0;
        cfg.yT = yT;
        cfg.yFull = yFull;
    }

    /// Hand-recompute Y(U) independently of the contract (mirror of _yieldShare).
    function _expectedY(Cfg memory cfg, uint256 u) internal pure returns (uint256) {
        uint256 uu = u > WAD ? WAD : u;
        uint256 slopeLt = ((uint256(cfg.yT) - cfg.y0) * WAD) / cfg.target;
        uint256 slopeGte = ((uint256(cfg.yFull) - cfg.yT) * WAD) / (WAD - cfg.target);
        if (uu < cfg.target) {
            return (slopeLt * uu) / WAD + cfg.y0;
        } else {
            return (slopeGte * (uu - cfg.target)) / WAD + cfg.yT;
        }
    }

    /// Any uint256 U on any valid curve: Y <= WAD, no revert, matches the hand-derived math,
    /// preview == yieldShare, state-independent, and Y >= y0.
    function testFuzz_YieldShare_BoundedAndMatchesHandMath(uint256 t, uint256 a, uint256 b, uint256 c, uint256 u) public {
        Cfg memory cfg = _boundedConfig(t, a, b, c);
        StaticCurveYDM ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);

        uint256 expected = _expectedY(cfg, u);

        uint256 p1 = ydm.previewYieldShare(MarketState.PERPETUAL, u);
        uint256 p2 = ydm.previewYieldShare(MarketState.FIXED_TERM, u);
        uint256 y1 = ydm.yieldShare(MarketState.PERPETUAL, u);
        uint256 y2 = ydm.yieldShare(MarketState.FIXED_TERM, u);

        assertEq(p1, expected, "preview matches hand math");
        assertEq(p1, p2, "state independence (preview)");
        assertEq(y1, y2, "state independence (yieldShare)");
        assertEq(p1, y1, "preview == yieldShare");
        assertLe(p1, WAD, "Y <= WAD");
        assertGe(p1, cfg.y0, "Y >= y0");
        assertLe(p1, cfg.yFull, "Y <= yFull");
    }

    /// Y(0) == y0 exactly and Y(target) == yT exactly.
    function testFuzz_PreviewYieldShare_AnchorsAtZeroAndTarget(uint256 t, uint256 a, uint256 b, uint256 c) public {
        Cfg memory cfg = _boundedConfig(t, a, b, c);
        StaticCurveYDM ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);

        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), cfg.y0, "Y(0)==y0");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, cfg.target), cfg.yT, "Y(target)==yT");
    }

    /// Monotone non-decreasing in utilization for a fixed curve.
    function testFuzz_PreviewYieldShare_MonotoneNonDecreasing(uint256 t, uint256 a, uint256 b, uint256 c, uint256 u1, uint256 u2) public {
        Cfg memory cfg = _boundedConfig(t, a, b, c);
        StaticCurveYDM ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);

        if (u1 > u2) (u1, u2) = (u2, u1);
        uint256 y1 = ydm.previewYieldShare(MarketState.PERPETUAL, u1);
        uint256 y2 = ydm.previewYieldShare(MarketState.PERPETUAL, u2);
        assertLe(y1, y2, "U1 <= U2 => Y(U1) <= Y(U2)");
    }

    /// Saturation: Y(U) == Y(WAD) for every U >= WAD.
    function testFuzz_PreviewYieldShare_SaturatesAboveWad(uint256 t, uint256 a, uint256 b, uint256 c, uint256 uOver) public {
        Cfg memory cfg = _boundedConfig(t, a, b, c);
        StaticCurveYDM ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);

        uOver = bound(uOver, WAD, type(uint256).max);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, uOver), ydm.previewYieldShare(MarketState.PERPETUAL, WAD), "saturates at WAD");
    }

    /// Per-sender isolation under fuzzed distinct curves.
    function testFuzz_YieldShare_PerAccountantCurveIsolation(uint256 t, uint256 a1, uint256 b1, uint256 c1, uint256 a2, uint256 b2, uint256 c2, uint256 u) public {
        Cfg memory cfgA = _boundedConfig(t, a1, b1, c1);
        // second curve reuses same target (target is per-instance immutable)
        Cfg memory cfgB = _boundedConfig(t, a2, b2, c2);
        StaticCurveYDM ydm = _deploy(cfgA.target);

        ydm.initializeYDMForMarket(cfgA.y0, cfgA.yT, cfgA.yFull); // this
        vm.prank(ACCT_B);
        ydm.initializeYDMForMarket(cfgB.y0, cfgB.yT, cfgB.yFull); // B

        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, u), _expectedY(cfgA, u), "this uses its own curve");
        vm.prank(ACCT_B);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, u), _expectedY(cfgB, u), "B uses its own curve");
    }

    /// Init reverts on SafeCast overflow for a fuzzed small target with a full gap.
    function testFuzz_RevertIf_InitializeSmallTargetSlopeOverflows(uint256 t) public {
        // For target <= 5e16 with gap WAD, slopeLt = 1e36/target >= 2e19 > uint64.max (~1.8447e19).
        uint256 target = bound(t, 1, 5e16);
        StaticCurveYDM ydm = _deploy(target);
        vm.expectPartialRevert(SafeCast.SafeCastOverflowedUintDowncast.selector);
        ydm.initializeYDMForMarket(0, uint64(WAD), uint64(WAD));
    }
}
