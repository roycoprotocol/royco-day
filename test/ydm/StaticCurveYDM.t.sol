// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test, stdError } from "../../lib/forge-std/src/Test.sol";
import { Vm } from "../../lib/forge-std/src/Vm.sol";
import { StaticCurveYDM } from "../../src/ydm/StaticCurveYDM.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { MarketState } from "../../src/libraries/Types.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { SafeCast } from "../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

/**
 * @title StaticCurveYDM unit + fuzz tests
 * @notice UNIT and FUZZ tests only. Invariant/Handler code lives in test/ydm/YDMInvariants.t.sol.
 * @dev Every expected value is hand-derived from src/ydm/StaticCurveYDM.sol. No call to the contract
 *      under test ever appears on the expected side of an assertion.
 *
 * Curve math (floor rounding in both legs):
 *   slopeLt  = floor((yT - y0) * WAD / target)
 *   slopeGte = floor((yFull - yT) * WAD / (WAD - target))
 *   U < target : Y = floor(slopeLt  * U           / WAD) + y0
 *   U >= target: Y = floor(slopeGte * (U - target) / WAD) + yT     (U capped to WAD first)
 */
contract StaticCurveYDMTest is Test {
    uint64 constant UINT64_MAX = type(uint64).max; // 18446744073709551615 ~= 1.8447e19

    // Distinct non-test accountant address for per-sender keying tests.
    address constant ACCT_B = address(0xB0B);

    event StaticCurveYdmInitialized(address indexed accountant, uint256 yieldShareAtZeroUtilWAD, uint256 slopeLtTargetUtilWAD, uint256 slopeGteTargetUtilWAD);
    event YdmOutput(address indexed accountant, uint256 yieldShareWAD);

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _deploy(uint256 target) internal returns (StaticCurveYDM) {
        return new StaticCurveYDM(target);
    }

    /// Canonical Curve A: target=8e17, init(1e17,5e17,9e17) => slopeLt=5e17, slopeGte=2e18.
    function _curveA() internal returns (StaticCurveYDM ydm) {
        ydm = _deploy(8e17);
        ydm.initializeYDMForMarket(1e17, 5e17, 9e17);
    }

    // =====================================================================
    // Group A / §1 — Constructor (BaseYDM target gate)
    // =====================================================================

    function test_ctor_targetZero_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        new StaticCurveYDM(0);
    }

    function test_ctor_targetOne_ok() public {
        StaticCurveYDM ydm = _deploy(1);
        assertEq(ydm.TARGET_UTILIZATION_WAD(), 1, "target getter == 1");
    }

    function test_ctor_targetHalf_ok() public {
        StaticCurveYDM ydm = _deploy(5e17);
        assertEq(ydm.TARGET_UTILIZATION_WAD(), 5e17, "target getter == 5e17");
    }

    function test_ctor_targetWadMinusOne_ok() public {
        StaticCurveYDM ydm = _deploy(WAD - 1);
        assertEq(ydm.TARGET_UTILIZATION_WAD(), WAD - 1, "target getter == WAD-1");
    }

    function test_ctor_targetWad_ok() public {
        // constructor allows target == WAD; initialize() later reverts (see W-group)
        StaticCurveYDM ydm = _deploy(WAD);
        assertEq(ydm.TARGET_UTILIZATION_WAD(), WAD, "target getter == WAD");
    }

    function test_ctor_targetWadPlusOne_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        new StaticCurveYDM(WAD + 1);
    }

    function test_ctor_targetMax_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        new StaticCurveYDM(type(uint256).max);
    }

    // =====================================================================
    // Group B / §2 — initializeYDMForMarket param validation (target = 8e17)
    // =====================================================================

    function test_init_invalid_y0GtYt_reverts() public {
        StaticCurveYDM ydm = _deploy(8e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(5e17, 4e17, 6e17); // y0 > yT
    }

    function test_init_invalid_ytGtYfull_reverts() public {
        StaticCurveYDM ydm = _deploy(8e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(1e17, 6e17, 5e17); // yT > yFull
    }

    function test_init_invalid_yfullGtWad_reverts() public {
        StaticCurveYDM ydm = _deploy(8e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(1e17, 5e17, uint64(WAD + 1)); // yFull > WAD
    }

    function test_init_invalid_ytZero_ordersHold_reverts() public {
        StaticCurveYDM ydm = _deploy(8e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(0, 0, 0); // yT == 0
    }

    function test_init_invalid_ytZero_positiveFull_reverts() public {
        StaticCurveYDM ydm = _deploy(8e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(0, 0, 5e17); // yT == 0 though ordering holds
    }

    function test_init_invalid_ytZero_y0Positive_reverts() public {
        StaticCurveYDM ydm = _deploy(8e17);
        // y0=1 > yT=0 also fails ordering, but the point is yT==0 is rejected
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(1, 0, 1);
    }

    function test_init_invalid_flatAboveCeiling_reverts() public {
        StaticCurveYDM ydm = _deploy(8e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(uint64(WAD + 1), uint64(WAD + 1), uint64(WAD + 1)); // yFull > WAD
    }

    /// Valid init emits StaticCurveYdmInitialized(accountant, y0, slopeLt, slopeGte).
    /// Curve A: slopeLt = (5e17-1e17)*1e18/8e17 = 4e35/8e17 = 5e17.
    ///          slopeGte = (9e17-5e17)*1e18/(2e17) = 4e35/2e17 = 2e18.
    function test_init_valid_curveA_emitsSlopes() public {
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
    function test_init_valid_minimal_ok() public {
        StaticCurveYDM ydm = _deploy(8e17);
        ydm.initializeYDMForMarket(0, 1, 1);
        (uint64 y0, uint64 sLt, uint64 yT, uint64 sGte) = ydm.accountantToCurve(address(this));
        assertEq(y0, 0);
        assertEq(sLt, 1, "floor(1e18/8e17)=1");
        assertEq(yT, 1);
        assertEq(sGte, 0);
    }

    /// Flat at ceiling: (WAD,WAD,WAD) valid. Y == WAD everywhere. slopes both 0.
    function test_init_valid_flatCeiling_ok() public {
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
    function test_init_valid_yfullWad_ok() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(0, 5e17, uint64(WAD));
        (, uint64 sLt,, uint64 sGte) = ydm.accountantToCurve(address(this));
        // slopeLt = 5e17*1e18/5e17 = 1e18 ; slopeGte = (WAD-5e17)*1e18/(WAD-5e17) = 1e18
        assertEq(sLt, 1e18, "slopeLt");
        assertEq(sGte, 1e18, "slopeGte");
    }

    // =====================================================================
    // Group C / §3 — SafeCast slope overflow at init
    // =====================================================================

    /// slopeLt = 1e36/5e16 = 2e19 > uint64.max => SafeCast overflow.
    function test_init_overflow_slopeLt_reverts() public {
        StaticCurveYDM ydm = _deploy(5e16);
        vm.expectPartialRevert(SafeCast.SafeCastOverflowedUintDowncast.selector);
        ydm.initializeYDMForMarket(0, uint64(WAD), uint64(WAD));
    }

    /// Safe neighbor: target=6e16, slopeLt = floor(1e36/6e16) = 16666666666666666666 < max.
    function test_init_overflow_slopeLt_safeNeighbor_ok() public {
        StaticCurveYDM ydm = _deploy(6e16);
        ydm.initializeYDMForMarket(0, uint64(WAD), uint64(WAD));
        (, uint64 sLt,, uint64 sGte) = ydm.accountantToCurve(address(this));
        assertEq(sLt, 16666666666666666666, "floor(1e36/6e16)");
        assertEq(sGte, 0, "yT==yFull => slopeGte 0");
        assertLe(sLt, UINT64_MAX, "within uint64");
    }

    /// slopeGte overflow: target=95e16, init(0,1,WAD).
    /// slopeGte = (WAD-1)*1e18/(WAD-95e16) = (1e36-1e18)/5e16 ~= 1.9999...e19 > uint64.max.
    function test_init_overflow_slopeGte_reverts() public {
        StaticCurveYDM ydm = _deploy(95e16);
        vm.expectPartialRevert(SafeCast.SafeCastOverflowedUintDowncast.selector);
        ydm.initializeYDMForMarket(0, 1, uint64(WAD));
    }

    /// Safe neighbor: target=94e16, slopeGte = floor((1e36-1e18)/6e16) < max.
    function test_init_overflow_slopeGte_safeNeighbor_ok() public {
        StaticCurveYDM ydm = _deploy(94e16);
        ydm.initializeYDMForMarket(0, 1, uint64(WAD));
        (,,, uint64 sGte) = ydm.accountantToCurve(address(this));
        assertLe(sGte, UINT64_MAX, "within uint64");
        // floor((1e36 - 1e18)/6e16)
        assertEq(sGte, (1e36 - 1e18) / 6e16, "hand-derived slopeGte");
    }

    /// Overflow is gap-driven, not target-alone: extreme target=5e16 but tiny gap => tiny slope.
    function test_init_overflow_gapDriven_tinyGap_ok() public {
        StaticCurveYDM ydm = _deploy(5e16);
        ydm.initializeYDMForMarket(0, 1, 1); // slopeLt = floor(1*1e18/5e16) = 20
        (, uint64 sLt,, uint64 sGte) = ydm.accountantToCurve(address(this));
        assertEq(sLt, 20, "floor(1e18/5e16)");
        assertEq(sGte, 0);
    }

    /// slopeLt is computed before slopeGte: 1-wei target with positive lt gap overflows on lt.
    function test_init_overflow_slopeLt_tinyTarget_reverts() public {
        StaticCurveYDM ydm = _deploy(1);
        vm.expectPartialRevert(SafeCast.SafeCastOverflowedUintDowncast.selector);
        ydm.initializeYDMForMarket(1e17, 5e17, 9e17); // slopeLt = 4e17*1e18/1 = 4e35
    }

    /// 1-wei target usable when y0==yT (flat lt leg): slopeLt = 0.
    function test_init_tinyTarget_flatLt_ok() public {
        StaticCurveYDM ydm = _deploy(1);
        // slopeGte = (9e17-5e17)*1e18/(WAD-1) = 4e35/(1e18-1) = floor -> 4e17-ish, safe (< max)
        ydm.initializeYDMForMarket(5e17, 5e17, 9e17);
        (, uint64 sLt,, uint64 sGte) = ydm.accountantToCurve(address(this));
        assertEq(sLt, 0, "flat lt");
        assertEq(sGte, (4e17 * WAD) / (WAD - 1), "hand-derived slopeGte");
    }

    /// Near-WAD target usable when yT==yFull (flat gte leg): slopeGte = 0.
    function test_init_nearWadTarget_flatGte_ok() public {
        StaticCurveYDM ydm = _deploy(WAD - 1);
        ydm.initializeYDMForMarket(5e17, 9e17, 9e17);
        (, uint64 sLt,, uint64 sGte) = ydm.accountantToCurve(address(this));
        assertEq(sGte, 0, "flat gte");
        // slopeLt = (9e17-5e17)*1e18/(WAD-1) = 4e35/(1e18-1), floor
        assertEq(sLt, (4e17 * WAD) / (WAD - 1), "hand-derived slopeLt");
    }

    // =====================================================================
    // Group W / §4 — target == WAD init reverts (division by zero, Panic 0x12)
    // =====================================================================

    function test_init_targetWad_normalParams_divByZero() public {
        StaticCurveYDM ydm = _deploy(WAD);
        vm.expectRevert(stdError.divisionError);
        ydm.initializeYDMForMarket(1e17, 5e17, 9e17);
    }

    function test_init_targetWad_flatParams_divByZero() public {
        StaticCurveYDM ydm = _deploy(WAD);
        // even a flat curve computes slopeGte with denominator 0 => 0/0 => Panic 0x12
        vm.expectRevert(stdError.divisionError);
        ydm.initializeYDMForMarket(5e17, 5e17, 5e17);
    }

    function test_init_targetWad_spanParams_divByZero() public {
        StaticCurveYDM ydm = _deploy(WAD);
        vm.expectRevert(stdError.divisionError);
        ydm.initializeYDMForMarket(0, 1, uint64(WAD));
    }

    // =====================================================================
    // Group D / §5 — Uninitialized market query reverts
    // =====================================================================

    function test_uninit_preview_reverts() public {
        StaticCurveYDM ydm = _deploy(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.previewYieldShare(MarketState.PERPETUAL, 0);
    }

    function test_uninit_yieldShare_reverts() public {
        StaticCurveYDM ydm = _deploy(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.yieldShare(MarketState.PERPETUAL, 5e17);
    }

    function test_uninit_preview_maxUtil_reverts() public {
        StaticCurveYDM ydm = _deploy(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.previewYieldShare(MarketState.FIXED_TERM, type(uint256).max);
    }

    /// mapping is keyed by msg.sender: A inits, B (pranked) is still uninitialized.
    function test_uninit_perSenderKeying_reverts() public {
        StaticCurveYDM ydm = _curveA(); // address(this) initialized
        vm.prank(ACCT_B);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.yieldShare(MarketState.PERPETUAL, 0);
    }

    function test_init_sender_canQuery() public {
        StaticCurveYDM ydm = _curveA();
        // no revert, returns y0 at U=0
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, 0), 1e17, "curve A Y(0)==y0");
    }

    // =====================================================================
    // Group E / §6 — Boundary utilization sweep on Curve A
    // target=8e17, slopeLt=5e17, slopeGte=2e18, y0=1e17, yT=5e17, yFull=9e17
    // =====================================================================

    function _assertCurveAPoint(StaticCurveYDM ydm, uint256 u, uint256 expected) internal {
        // state-independence
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, u), expected, "preview PERPETUAL");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, u), expected, "preview FIXED_TERM");
        // preview == yieldShare
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, u), expected, "yieldShare PERPETUAL");
        assertEq(ydm.yieldShare(MarketState.FIXED_TERM, u), expected, "yieldShare FIXED_TERM");
        assertLe(expected, WAD, "<= WAD invariant");
    }

    function test_curveA_sweep() public {
        StaticCurveYDM ydm = _curveA();
        _assertCurveAPoint(ydm, 0, 1e17); // A0
        _assertCurveAPoint(ydm, 1, 1e17); // A1 floor(0.5)=0
        _assertCurveAPoint(ydm, 1e17, 15e16); // A2 5e16+1e17
        _assertCurveAPoint(ydm, 4e17, 3e17); // A3 2e17+1e17
        _assertCurveAPoint(ydm, 8e17 - 1, 499999999999999999); // A4 yT-1 (floor)
        _assertCurveAPoint(ydm, 8e17, 5e17); // A5 == yT (kink continuity)
        _assertCurveAPoint(ydm, 8e17 + 1, 500000000000000002); // A6 floor(2)+5e17
        _assertCurveAPoint(ydm, 9e17, 7e17); // A7 2e17+5e17
        _assertCurveAPoint(ydm, WAD - 1, 899999999999999998); // A8 yFull-2 (floor)
        _assertCurveAPoint(ydm, WAD, 9e17); // A9 == yFull
        _assertCurveAPoint(ydm, WAD + 1, 9e17); // A10 capped
        _assertCurveAPoint(ydm, 2e18, 9e17); // A11 capped
        _assertCurveAPoint(ydm, type(uint256).max, 9e17); // A12 capped, no overflow
    }

    /// Explicit kink continuity + endpoints.
    function test_curveA_kinkAndEndpoints() public {
        StaticCurveYDM ydm = _curveA();
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 8e17), 5e17, "Y(target)==yT");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, WAD), 9e17, "Y(WAD)==yFull");
        assertLt(ydm.previewYieldShare(MarketState.PERPETUAL, 8e17 - 1), 5e17, "Y(target-1) < yT (floor)");
    }

    /// Monotonic non-decrease across the swept points.
    function test_curveA_monotonic() public {
        StaticCurveYDM ydm = _curveA();
        uint256[10] memory us = [uint256(0), 1e17, 4e17, 8e17 - 1, 8e17, 8e17 + 1, 9e17, WAD - 1, WAD, WAD + 1];
        uint256 prev = 0;
        for (uint256 i = 0; i < us.length; i++) {
            uint256 y = ydm.previewYieldShare(MarketState.PERPETUAL, us[i]);
            assertGe(y, prev, "monotone non-decreasing");
            prev = y;
        }
    }

    // =====================================================================
    // Group F — floor rounding toward the paying tranche
    // =====================================================================

    /// target=5e17, init(0,1,1): slopeLt=2, slopeGte=0.
    function test_floor_subUnitSlope() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(0, 1, 1);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 1e17), 0, "F1 floor(2*1e17/1e18)=0");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 5e17 - 1), 0, "F2 floor((1e18-2)/1e18)=0");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 5e17), 1, "F3 kink -> yT=1");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, WAD), 1, "F4 slopeGte 0 -> yFull=1");
    }

    /// target=7e17, init(0,3e17,4e17): slopeGte = floor(1e17*1e18/3e17) = 333333333333333333.
    /// Y(WAD) = floor(333333333333333333 * 3e17/1e18) + 3e17 = 99999999999999999 + 3e17 = 4e17 - 1.
    function test_floor_oneWeiUnderFull() public {
        StaticCurveYDM ydm = _deploy(7e17);
        ydm.initializeYDMForMarket(0, 3e17, 4e17);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, WAD), 399999999999999999, "4e17 - 1 (floor loss)");
    }

    /// Curve B symmetric: target=5e17, init(2e17,5e17,8e17) => slopeLt=slopeGte=6e17.
    /// U=target+1: floor(6e17*1/1e18)=floor(0.6)=0 => equals yT despite U>target.
    function test_floor_justPastKinkRoundsFlat() public {
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
    // Group G — yield-share value boundaries (output floor/ceiling)
    // =====================================================================

    /// (WAD,WAD,WAD): Y == WAD for every U including > WAD. Assert equal, never exceeds.
    function test_bound_flatCeiling() public {
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
    function test_bound_flatMinimal() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(1, 1, 1);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 1);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, type(uint256).max), 1);
    }

    /// (0,5e17,WAD): reaches exactly WAD at full util and caps there. Zero at zero util.
    function test_bound_reachesWadExactly() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(0, 5e17, uint64(WAD));
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 0, "y0=0 at U=0");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 25e16), 25e16, "linear mid");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 5e17), 5e17, "kink=yT");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, WAD), WAD, "hits WAD at full util");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 2 * WAD), WAD, "caps at WAD");
    }

    /// zero yield share at zero utilization is valid.
    function test_bound_zeroAtZero() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(0, 3e17, 5e17);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 0, "Y(0)==0");
    }

    // =====================================================================
    // Group H / §9 — state independence, preview/mutate parity, idempotence
    // =====================================================================

    function test_stateIndependence() public {
        StaticCurveYDM ydm = _curveA();
        uint256[6] memory us = [uint256(0), 25e16, 5e17, 75e16, WAD, 2 * WAD];
        for (uint256 i = 0; i < us.length; i++) {
            assertEq(
                ydm.previewYieldShare(MarketState.PERPETUAL, us[i]),
                ydm.previewYieldShare(MarketState.FIXED_TERM, us[i]),
                "state ignored (preview)"
            );
            assertEq(
                ydm.yieldShare(MarketState.PERPETUAL, us[i]),
                ydm.yieldShare(MarketState.FIXED_TERM, us[i]),
                "state ignored (yieldShare)"
            );
        }
    }

    /// preview does not persist state (curve bytes unchanged before/after).
    function test_preview_doesNotMutate() public {
        StaticCurveYDM ydm = _curveA();
        (uint64 a0, uint64 a1, uint64 a2, uint64 a3) = ydm.accountantToCurve(address(this));
        ydm.previewYieldShare(MarketState.PERPETUAL, 7e17);
        (uint64 b0, uint64 b1, uint64 b2, uint64 b3) = ydm.accountantToCurve(address(this));
        assertEq(a0, b0);
        assertEq(a1, b1);
        assertEq(a2, b2);
        assertEq(a3, b3);
    }

    /// yieldShare does not mutate the curve either (Static is stateless).
    function test_yieldShare_doesNotMutate() public {
        StaticCurveYDM ydm = _curveA();
        (uint64 a0, uint64 a1, uint64 a2, uint64 a3) = ydm.accountantToCurve(address(this));
        ydm.yieldShare(MarketState.PERPETUAL, 7e17);
        (uint64 b0, uint64 b1, uint64 b2, uint64 b3) = ydm.accountantToCurve(address(this));
        assertEq(a0, b0);
        assertEq(a1, b1);
        assertEq(a2, b2);
        assertEq(a3, b3);
    }

    /// idempotence: repeated calls return the identical value, no drift.
    function test_idempotent_repeatedCalls() public {
        StaticCurveYDM ydm = _curveA();
        uint256 first = ydm.yieldShare(MarketState.PERPETUAL, 5e17);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(ydm.yieldShare(MarketState.PERPETUAL, 5e17), first, "no drift across calls");
        }
    }

    /// Static does NOT drift with time (negative adaptation test).
    function test_noTimeDrift() public {
        StaticCurveYDM ydm = _curveA();
        uint256 before = ydm.previewYieldShare(MarketState.PERPETUAL, 4e17);
        vm.warp(block.timestamp + 3650 days);
        uint256 afterWarp = ydm.previewYieldShare(MarketState.PERPETUAL, 4e17);
        assertEq(before, afterWarp, "no time adaptation");
    }

    /// yieldShare emits YdmOutput with the computed value. Preview emits nothing.
    function test_events_yieldShareEmits_previewSilent() public {
        StaticCurveYDM ydm = _curveA();

        // Y(7.5e17) on curve A = floor(2e18*(75e16-8e17)/1e18)? 75e16 < 8e17 -> lt leg.
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
    // Group I — re-initialization (no re-init guard) & per-accountant isolation
    // =====================================================================

    function test_reinit_overwrites() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(1e17, 3e17, 5e17); // curve A' -> Y(0)=1e17
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 1e17, "before re-init");
        ydm.initializeYDMForMarket(0, 1e17, 2e17); // curve B' -> Y(0)=0
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 0, "after re-init reflects new curve");
    }

    function test_reinit_invalidPreservesState() public {
        StaticCurveYDM ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(1e17, 3e17, 5e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(2e17, 1e17, 5e17); // invalid, must not touch storage
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 1e17, "curve A intact after failed re-init");
    }

    function test_perAccountantIsolation() public {
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

    /// P1/P2/P4/P7/P8: any uint256 U on any valid curve => Y<=WAD, no revert, matches hand math,
    /// preview==yieldShare, state-independent, Y>=y0.
    function testFuzz_yieldShare_boundedAndParity(uint256 t, uint256 a, uint256 b, uint256 c, uint256 u) public {
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
        assertLe(p1, WAD, "P1: Y <= WAD");
        assertGe(p1, cfg.y0, "P2: Y >= y0");
        assertLe(p1, cfg.yFull, "Y <= yFull");
    }

    /// P2/P3: Y(0)==y0 exactly. Y(target)==yT exactly.
    function testFuzz_anchorPoints(uint256 t, uint256 a, uint256 b, uint256 c) public {
        Cfg memory cfg = _boundedConfig(t, a, b, c);
        StaticCurveYDM ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);

        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), cfg.y0, "Y(0)==y0");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, cfg.target), cfg.yT, "Y(target)==yT");
    }

    /// P5: monotonic non-decreasing in utilization for a fixed curve.
    function testFuzz_monotonic(uint256 t, uint256 a, uint256 b, uint256 c, uint256 u1, uint256 u2) public {
        Cfg memory cfg = _boundedConfig(t, a, b, c);
        StaticCurveYDM ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);

        if (u1 > u2) (u1, u2) = (u2, u1);
        uint256 y1 = ydm.previewYieldShare(MarketState.PERPETUAL, u1);
        uint256 y2 = ydm.previewYieldShare(MarketState.PERPETUAL, u2);
        assertLe(y1, y2, "P5: U1<=U2 => Y(U1)<=Y(U2)");
    }

    /// P6: saturation — Y(U) == Y(WAD) for every U >= WAD.
    function testFuzz_saturation(uint256 t, uint256 a, uint256 b, uint256 c, uint256 uOver) public {
        Cfg memory cfg = _boundedConfig(t, a, b, c);
        StaticCurveYDM ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);

        uOver = bound(uOver, WAD, type(uint256).max);
        assertEq(
            ydm.previewYieldShare(MarketState.PERPETUAL, uOver),
            ydm.previewYieldShare(MarketState.PERPETUAL, WAD),
            "P6: saturates at WAD"
        );
    }

    /// P9: per-sender isolation under fuzzed distinct curves.
    function testFuzz_perSenderIsolation(uint256 t, uint256 a1, uint256 b1, uint256 c1, uint256 a2, uint256 b2, uint256 c2, uint256 u) public {
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
    function testFuzz_init_overflow_smallTarget_reverts(uint256 t) public {
        // For target <= 5e16 with gap WAD, slopeLt = 1e36/target >= 2e19 > uint64.max (~1.8447e19).
        uint256 target = bound(t, 1, 5e16);
        StaticCurveYDM ydm = _deploy(target);
        vm.expectPartialRevert(SafeCast.SafeCastOverflowedUintDowncast.selector);
        ydm.initializeYDMForMarket(0, uint64(WAD), uint64(WAD));
    }
}
