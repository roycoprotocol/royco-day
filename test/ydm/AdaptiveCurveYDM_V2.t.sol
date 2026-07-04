// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Vm } from "../../lib/forge-std/src/Vm.sol";
import { AdaptiveCurveYDM_V2 } from "../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { MarketState } from "../../src/libraries/Types.sol";
import { WAD, WAD_INT } from "../../src/libraries/Constants.sol";
import { FixedPointMathLib } from "../../lib/solady/src/utils/FixedPointMathLib.sol";

/**
 * @title AdaptiveCurveYDM_V2 unit + fuzz tests
 * @notice UNIT and FUZZ tests only. Invariant/Handler code lives in test/ydm/YDMInvariants.t.sol.
 * @dev The ADDITIVE adaptive curve (discount/premium spreads). Every expected value is either a
 *      hand-derived literal or reproduced by an independent mirror (`_mirror`) that re-implements
 *      src/ydm/base/BaseAdaptiveCurveYDM.sol and src/ydm/AdaptiveCurveYDM_V2.sol using FixedPointMathLib.
 *      The contract under test never appears on the expected side of an assertion.
 *
 * V2 curve (additive form), with avgYT the time-averaged yield-share-at-target:
 *   FD = discountToTargetAtZeroUtilWAD = yT - y0     (fixed at init)
 *   FP = premiumToTargetAtFullUtilWAD = yFull - yT   (fixed at init)
 *   Δ  = normalized signed delta from target, in [-WAD, WAD]
 *          below target: Δ = (U - U_T) * WAD / U_T
 *          above target: Δ = (U - U_T) * WAD / (WAD - U_T)
 *   maxAdj = (Δ < 0) ? FD : FP
 *   adj    = Δ * maxAdj / WAD                         (int, truncates toward zero)
 *   signed = avgYT + adj
 *   Y(U)   = signed <= 0 ? 0 : signed >= WAD ? WAD : signed
 *
 * Exact anchors (FIXED_TERM, avgYT == yT), all clamp-free by construction:
 *   Y(0)   = yT - FD = y0
 *   Y(U_T) = yT
 *   Y(WAD) = yT + FP = yFull
 *
 * Adaptation (PERPETUAL only): yT is exponentiated by a time/distance-weighted linear factor and
 * clamped to [MIN_YT, MAX_YT], avgYT is a trapezoidal blend (init + new + 2*mid)/4. Speed is fixed
 * at 100e18/365days (V2 sits exactly at the deploy-time limit, there is no per-market speed field).
 */
contract AdaptiveCurveYDM_V2Test is Test {
    // Model constants mirrored from source (never read back from the contract under test).
    uint256 constant SPEED_V2 = 100e18 / uint256(365 days);
    uint256 constant SPEED_LIMIT = 100e18 / uint256(365 days);
    uint256 constant MIN_YT = 0.0001e18; // 1e14
    uint256 constant MAX_YT = WAD;
    int256 constant MAX_LINEAR = 135_305_999_368_893_231_589 - 1;

    address constant ACCT_B = address(0xB0B);

    event AdaptiveCurveYdmInitialized(
        address indexed accountant, uint256 discountToTargetAtZeroUtilWAD, uint256 yieldShareAtTargetUtilWAD, uint256 premiumToTargetAtFullUtilWAD
    );
    event YdmAdaptedOutput(address indexed accountant, uint256 avgYieldShareWAD, uint256 newYieldShareAtTargetWAD);

    // ---------------------------------------------------------------------
    // deploy helpers
    // ---------------------------------------------------------------------

    function _deploy(uint256 target) internal returns (AdaptiveCurveYDM_V2) {
        return new AdaptiveCurveYDM_V2(target);
    }

    /// Canonical curve: target=0.5, y0=0.1, yT=0.3, yFull=0.9 => FD=0.2, FP=0.6. Clean powers of ten.
    function _canonical() internal returns (AdaptiveCurveYDM_V2 ydm) {
        ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(1e17, 3e17, 9e17);
    }

    function _readCurve(AdaptiveCurveYDM_V2 ydm, address acct)
        internal
        view
        returns (uint64 yT, uint32 lastTs, uint64 discount, uint64 premium)
    {
        (yT, lastTs, discount, premium) = ydm.accountantToCurve(acct);
    }

    // ---------------------------------------------------------------------
    // independent mirror of the model math
    // ---------------------------------------------------------------------

    function _mirrorYT(uint256 lastYT, int256 lin) internal pure returns (uint256 yt) {
        if (lin > MAX_LINEAR) lin = MAX_LINEAR;
        yt = FixedPointMathLib.fullMulDiv(lastYT, uint256(FixedPointMathLib.expWad(lin)), WAD);
        if (yt < MIN_YT) return MIN_YT;
        if (yt > MAX_YT) return MAX_YT;
    }

    /// Returns the yield share output and the newYT that the model would compute/persist.
    function _mirror(uint256 target, uint256 FD, uint256 FP, uint256 initYT, uint256 lastTs, uint256 nowTs, MarketState state, uint256 util)
        internal
        pure
        returns (uint256 out, uint256 newYT)
    {
        uint256 u = util > WAD ? WAD : util;
        uint256 maxDelta = u > target ? (WAD - target) : target;
        int256 nd = ((int256(u) - int256(target)) * WAD_INT) / int256(maxDelta);

        uint256 avgYT;
        if (state == MarketState.PERPETUAL) {
            int256 speed = (int256(SPEED_V2) * nd) / WAD_INT;
            uint256 elapsed = lastTs == 0 ? 0 : nowTs - lastTs;
            int256 lin = speed * int256(elapsed);
            newYT = _mirrorYT(initYT, lin);
            uint256 midYT = _mirrorYT(initYT, lin / 2);
            avgYT = (initYT + newYT + (2 * midYT)) / 4;
        } else {
            newYT = avgYT = initYT;
        }

        uint256 maxAdj = nd < 0 ? FD : FP;
        int256 adj = (nd * int256(maxAdj)) / WAD_INT;
        int256 signed = int256(avgYT) + adj;
        if (signed <= 0) out = 0;
        else if (signed >= WAD_INT) out = WAD;
        else out = uint256(signed);
    }

    // =====================================================================
    // Group A — Constructor / immutables
    // =====================================================================

    function test_ctor_targetZero_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        new AdaptiveCurveYDM_V2(0);
    }

    function test_ctor_targetOne_ok() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(1);
        assertEq(ydm.TARGET_UTILIZATION_WAD(), 1, "target==1");
    }

    function test_ctor_targetWad_ok() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(WAD);
        assertEq(ydm.TARGET_UTILIZATION_WAD(), WAD, "target==WAD");
    }

    function test_ctor_targetWadPlusOne_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        new AdaptiveCurveYDM_V2(WAD + 1);
    }

    function test_ctor_targetMax_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        new AdaptiveCurveYDM_V2(type(uint256).max);
    }

    /// V2's fixed speed is exactly the deploy-time limit (100e18/365days). No per-market speed field.
    function test_ctor_immutables() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        assertEq(ydm.MIN_YIELD_SHARE_AT_TARGET_WAD(), MIN_YT, "min yT == 1e14");
        assertEq(ydm.MAX_YIELD_SHARE_AT_TARGET_WAD(), MAX_YT, "max yT == WAD");
        assertEq(ydm.MAX_ADAPTATION_SPEED_WAD(), SPEED_V2, "V2 speed == 100e18/365days");
        assertEq(ydm.MAX_ADAPTATION_SPEED_LIMIT_WAD(), SPEED_LIMIT, "speed limit == 100e18/365days");
        assertEq(ydm.MAX_ADAPTATION_SPEED_WAD(), ydm.MAX_ADAPTATION_SPEED_LIMIT_WAD(), "V2 speed sits at the limit");
    }

    // =====================================================================
    // Group B — initializeYDMForMarket validation (3-arg, no speed param)
    // =====================================================================

    function test_init_ytBelowMin_reverts() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(0, uint64(MIN_YT - 1), uint64(WAD)); // yT < 1e14
    }

    function test_init_ytAtMin_ok() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(uint64(MIN_YT), uint64(MIN_YT), uint64(WAD));
        (uint64 yT,, uint64 discount, uint64 premium) = _readCurve(ydm, address(this));
        assertEq(yT, MIN_YT, "yT stored at min");
        assertEq(discount, 0, "FD == yT - y0 == 0");
        assertEq(premium, uint64(WAD - MIN_YT), "FP == yFull - yT");
    }

    function test_init_y0AboveYt_reverts() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(4e17, 3e17, 9e17); // y0 > yT
    }

    function test_init_ytGtYfull_reverts() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(1e17, 5e17, 3e17); // yT > yFull
    }

    function test_init_yfullGtWad_reverts() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(1e17, 5e17, uint64(WAD + 1)); // yFull > WAD
    }

    function test_init_valid_emitsAndStores() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        // event args: (discount, yT, premium) == (2e17, 3e17, 6e17)
        vm.expectEmit(true, true, true, true, address(ydm));
        emit AdaptiveCurveYdmInitialized(address(this), 2e17, 3e17, 6e17);
        ydm.initializeYDMForMarket(1e17, 3e17, 9e17);

        (uint64 yT, uint32 lastTs, uint64 discount, uint64 premium) = _readCurve(ydm, address(this));
        assertEq(yT, 3e17, "stored yT");
        assertEq(lastTs, 0, "lastTs zero on init");
        assertEq(discount, 2e17, "FD == yT - y0 == 3e17 - 1e17");
        assertEq(premium, 6e17, "FP == yFull - yT == 9e17 - 3e17");
    }

    /// y0 == yT == yFull => FD == FP == 0 => flat curve (Y == yT everywhere in FIXED_TERM).
    function test_init_flatCurve_zeroSpreads() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(3e17, 3e17, 3e17);
        (, , uint64 discount, uint64 premium) = _readCurve(ydm, address(this));
        assertEq(discount, 0, "FD == 0");
        assertEq(premium, 0, "FP == 0");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 0), 3e17, "flat @0");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17), 3e17, "flat @target");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, WAD), 3e17, "flat @full");
    }

    /// y0 == 0 is a valid floor. FD == yT and Y(0) == 0 exactly.
    function test_init_y0Zero_ok() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(0, 3e17, 9e17);
        (, , uint64 discount,) = _readCurve(ydm, address(this));
        assertEq(discount, 3e17, "FD == yT when y0 == 0");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 0), 0, "Y(0) == y0 == 0");
    }

    /// yFull == WAD is valid. Y(WAD) == WAD exactly.
    function test_init_yfullWad_ok() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(1e17, 3e17, uint64(WAD));
        (, , , uint64 premium) = _readCurve(ydm, address(this));
        assertEq(premium, uint64(WAD - 3e17), "FP == WAD - yT");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, WAD), WAD, "Y(WAD) == yFull == WAD");
    }

    // =====================================================================
    // Group C — Uninitialized market reverts
    // =====================================================================

    function test_uninit_preview_reverts() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.previewYieldShare(MarketState.PERPETUAL, 0);
    }

    function test_uninit_yieldShare_reverts() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.yieldShare(MarketState.PERPETUAL, 5e17);
    }

    function test_uninit_maxUtil_fixedTerm_reverts() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.previewYieldShare(MarketState.FIXED_TERM, type(uint256).max);
    }

    function test_uninit_perSenderKeying_reverts() public {
        AdaptiveCurveYDM_V2 ydm = _canonical(); // address(this) initialized
        vm.prank(ACCT_B);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.yieldShare(MarketState.PERPETUAL, 0);
    }

    // =====================================================================
    // Group D — Exact anchor values (FIXED_TERM, no adaptation)
    // canonical: target=5e17, y0=1e17, yT=3e17, yFull=9e17, FD=2e17, FP=6e17
    // =====================================================================

    function _assertBothStatesFirstCall(AdaptiveCurveYDM_V2 ydm, uint256 u, uint256 expected) internal {
        // On the very first query lastTs==0 => elapsed 0 => PERPETUAL cannot adapt => equals FIXED_TERM.
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, u), expected, "fixed-term value");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, u), expected, "perpetual first-call value");
        assertLe(expected, WAD, "<= WAD");
    }

    function test_canonical_anchors() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        _assertBothStatesFirstCall(ydm, 0, 1e17); // Y(0) == y0
        _assertBothStatesFirstCall(ydm, 25e16, 2e17); // below-target midpoint: yT - FD/2 = 3e17 - 1e17
        _assertBothStatesFirstCall(ydm, 5e17, 3e17); // Y(target) == yT
        _assertBothStatesFirstCall(ydm, 75e16, 6e17); // above-target midpoint: yT + FP/2 = 3e17 + 3e17
        _assertBothStatesFirstCall(ydm, WAD, 9e17); // Y(WAD) == yFull
    }

    function test_canonical_saturation() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 atFull = ydm.previewYieldShare(MarketState.FIXED_TERM, WAD);
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, WAD + 1), atFull, "cap just past WAD");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 2 * WAD), atFull, "cap at 2*WAD");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, type(uint256).max), atFull, "cap at uint256 max, no overflow");
    }

    /// Continuity around the kink: exactly yT at target, and non-crossing on each side. The additive
    /// adjustment truncates toward zero, so at 1-wei offsets the output can round back onto yT (the
    /// spread is not strict at wei granularity). Once the offset is large enough it becomes strict.
    function test_canonical_kinkContinuity() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17), 3e17, "Y(target)==yT");
        assertLe(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17 - 1), 3e17, "just below target <= yT");
        assertGe(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17 + 1), 3e17, "just above target >= yT");
        // With a meaningful offset the adjustment is non-zero and the spread is strict on both sides.
        assertLt(ydm.previewYieldShare(MarketState.FIXED_TERM, 4e17), 3e17, "0.1 below target < yT");
        assertGt(ydm.previewYieldShare(MarketState.FIXED_TERM, 6e17), 3e17, "0.1 above target > yT");
    }

    function test_canonical_monotonic() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256[9] memory us = [uint256(0), 1e17, 25e16, 5e17 - 1, 5e17, 5e17 + 1, 75e16, WAD - 1, WAD];
        uint256 prev = 0;
        for (uint256 i = 0; i < us.length; i++) {
            uint256 y = ydm.previewYieldShare(MarketState.FIXED_TERM, us[i]);
            assertGe(y, prev, "monotone non-decreasing");
            prev = y;
        }
    }

    /// Region spread sign: below target the curve sits under yT (uses FD). Above it sits over yT (uses FP).
    function test_canonical_regionSpread() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        // below: Δ=(1e17-5e17)/5e17=-0.8 => adj=-0.8*FD=-1.6e17 => 3e17-1.6e17=1.4e17
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 1e17), 14e16, "below target: yT + nd*FD");
        // above: Delta=(9e17-5e17)/5e17=0.8 => adj=0.8*FP=4.8e17 => 3e17+4.8e17=7.8e17
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 9e17), 78e16, "above target: yT + nd*FP");
    }

    /// A second shape on a non-half target confirms the exact additive anchors.
    function test_secondCurve_anchors() public {
        // target=0.8, y0=5e16, yT=2e17, yFull=1e18 => FD=15e16, FP=8e17.
        AdaptiveCurveYDM_V2 ydm = _deploy(8e17);
        ydm.initializeYDMForMarket(5e16, 2e17, uint64(WAD));
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 0), 5e16, "Y(0)==y0");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 8e17), 2e17, "Y(target)==yT");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, WAD), WAD, "Y(WAD)==yFull==WAD");
        // below-target midpoint U=0.4: Δ=(0.4-0.8)/0.8=-0.5 => 2e17 - 0.5*15e16 = 2e17-75e15
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 4e17), 2e17 - 75e15, "below midpoint");
        // above-target midpoint U=0.9: Δ=(0.9-0.8)/0.2=0.5 => 2e17 + 0.5*8e17 = 6e17
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 9e17), 6e17, "above midpoint");
    }

    // =====================================================================
    // Group E — Target-utilization boundary coverage (fresh model per target)
    // =====================================================================

    /// Y(target)==yT, Y(0)==y0, Y(WAD)==yFull hold exactly for every representative target.
    function test_targetSweep_exactAnchors() public {
        uint256[7] memory targets = [uint256(1), MIN_YT, 1e17, 5e17, 9e17, WAD - 1, WAD];
        for (uint256 i = 0; i < targets.length; i++) {
            uint256 target = targets[i];
            AdaptiveCurveYDM_V2 ydm = _deploy(target);
            ydm.initializeYDMForMarket(1e17, 3e17, 9e17); // y0=1e17, yT=3e17, yFull=9e17

            // Y(target) == yT exactly regardless of state (Δ==0 => no adaptation, adj==0).
            assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, target), 3e17, "Y(target)==yT (fixed)");
            assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, target), 3e17, "Y(target)==yT (perp)");

            // Y(0) == y0 exactly for any target (Δ == -WAD, adj == -FD).
            assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 0), 1e17, "Y(0)==y0");

            // Y(WAD) == yFull exactly when target < WAD (Δ == WAD, adj == FP); at target==WAD, U==WAD is the kink so Y==yT.
            uint256 yFullOut = ydm.previewYieldShare(MarketState.FIXED_TERM, WAD);
            if (target < WAD) assertEq(yFullOut, 9e17, "Y(WAD)==yFull");
            else assertEq(yFullOut, 3e17, "target==WAD: Y(WAD)==yT (kink)");
        }
    }

    // =====================================================================
    // Group F — Adaptation up / down over warps (exact via mirror)
    // =====================================================================

    /// First PERPETUAL call never adapts (lastTs starts at 0 => elapsed 0), but it stamps lastTs.
    function test_firstCall_noAdaptation_stampsTimestamp() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        vm.warp(1_000_000);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // high util, but elapsed==0
        (uint64 yT, uint32 lastTs,,) = _readCurve(ydm, address(this));
        assertEq(yT, 3e17, "yT unchanged on first call");
        assertEq(lastTs, 1_000_000, "lastTs stamped to block.timestamp");
    }

    function test_adaptation_up_increasesYT() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // stamp lastTs=start, yT unchanged

        uint256 dt = 30 days;
        vm.warp(start + dt);
        (uint256 expOut, uint256 expNewYT) = _mirror(5e17, 2e17, 6e17, 3e17, start, start + dt, MarketState.PERPETUAL, WAD);

        // preview does not mutate; equals mirror
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, WAD), expOut, "up preview == mirror");
        // yieldShare mutates yT to newYT and returns the same output
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, WAD), expOut, "up yieldShare == mirror");
        (uint64 yT, uint32 lastTs,,) = _readCurve(ydm, address(this));
        assertEq(yT, expNewYT, "yT persisted to newYT");
        assertGt(yT, 3e17, "yT increased under high util");
        assertEq(lastTs, start + dt, "lastTs advanced");
    }

    function test_adaptation_down_decreasesYT() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, 0); // stamp, yT unchanged

        uint256 dt = 30 days;
        vm.warp(start + dt);
        (uint256 expOut, uint256 expNewYT) = _mirror(5e17, 2e17, 6e17, 3e17, start, start + dt, MarketState.PERPETUAL, 0);

        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), expOut, "down preview == mirror");
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, 0), expOut, "down yieldShare == mirror");
        (uint64 yT,,,) = _readCurve(ydm, address(this));
        assertEq(yT, expNewYT, "yT persisted to newYT");
        assertLt(yT, 3e17, "yT decreased under zero util");
    }

    /// At U==target the curve does not adapt over time (Δ==0 => speed 0), even in PERPETUAL.
    function test_adaptation_atTarget_noDrift() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, 5e17);
        vm.warp(start + 3650 days);
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, 5e17), 3e17, "Y(target) still yT after long warp");
        (uint64 yT,,,) = _readCurve(ydm, address(this));
        assertEq(yT, 3e17, "yT unchanged at target");
    }

    /// FIXED_TERM never adapts yT even across warps, though it still restamps lastTs.
    function test_fixedTerm_neverAdapts() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.FIXED_TERM, WAD);
        vm.warp(start + 3650 days);
        ydm.yieldShare(MarketState.FIXED_TERM, WAD);
        (uint64 yT, uint32 lastTs,,) = _readCurve(ydm, address(this));
        assertEq(yT, 3e17, "yT unchanged in FIXED_TERM");
        assertEq(lastTs, start + 3650 days, "lastTs still restamped");
    }

    /// PERPETUAL and FIXED_TERM diverge once elapsed>0 and util!=target: PERP adapts, FIXED holds.
    function test_states_divergeAfterWarp() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // stamp
        vm.warp(start + 100 days);
        uint256 perp = ydm.previewYieldShare(MarketState.PERPETUAL, WAD);
        uint256 fixedTerm = ydm.previewYieldShare(MarketState.FIXED_TERM, WAD);
        assertGt(perp, fixedTerm, "PERP adapts above the un-adapted FIXED_TERM value");
        // FIXED_TERM equals the un-adapted anchor (yFull for canonical).
        assertEq(fixedTerm, 9e17, "FIXED_TERM holds at yFull");
    }

    // =====================================================================
    // Group G — Long-dormancy saturation + signed clamps (no revert)
    // =====================================================================

    /// Sustained high util drives yT to MAX_YT (WAD). No overflow despite huge linear factor.
    function test_longDormancy_up_saturatesToMax() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD);
        vm.warp(start + 3650 days); // ~10y >> saturation horizon
        uint256 out = ydm.yieldShare(MarketState.PERPETUAL, WAD);
        (uint64 yT,,,) = _readCurve(ydm, address(this));
        assertEq(yT, MAX_YT, "yT clamped to MAX_YT");
        assertLe(out, WAD, "output <= WAD");
    }

    /// Sustained zero util drives yT to MIN_YT (1e14). No revert.
    function test_longDormancy_down_saturatesToMin() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, 0);
        vm.warp(start + 3650 days);
        uint256 out = ydm.yieldShare(MarketState.PERPETUAL, 0);
        (uint64 yT,,,) = _readCurve(ydm, address(this));
        assertEq(yT, MIN_YT, "yT clamped to MIN_YT");
        assertLe(out, WAD, "output <= WAD");
    }

    /// signedYieldShare <= 0 clamps the OUTPUT to 0: yT adapts down to MIN while FD exceeds it at U=0.
    /// Config: y0=0 => FD=yT. After down-saturation avgYT==MIN_YT, at U=0 signed = MIN - FD < 0 => 0.
    function test_signedClamp_toZero() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(0, 2e17, 8e17); // y0=0, yT=2e17 (FD=2e17), yFull=8e17
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, 0); // stamp
        vm.warp(start + 3650 days); // drive yT down to MIN

        // mirror: avgYT saturates to MIN_YT (1e14), at U=0 signed = 1e14 - 2e17 < 0 => out 0
        (uint256 expOut, uint256 expNewYT) = _mirror(5e17, 2e17, 6e17, 2e17, start, start + 3650 days, MarketState.PERPETUAL, 0);
        assertEq(expOut, 0, "mirror predicts a clamped-to-zero output");
        assertEq(expNewYT, MIN_YT, "mirror predicts yT saturated to MIN");

        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 0, "output clamped to zero");
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, 0), 0, "yieldShare clamped to zero");
        (uint64 yT,,,) = _readCurve(ydm, address(this));
        assertEq(yT, MIN_YT, "yT saturated to MIN");
    }

    /// signedYieldShare >= WAD clamps the OUTPUT to WAD: yT adapts up to MAX while FP lifts it past WAD at U=full.
    function test_signedClamp_toWad() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(1e17, 2e17, 8e17); // FP=6e17
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // stamp
        vm.warp(start + 3650 days); // drive yT up to MAX (WAD)

        // avgYT saturates to WAD; at U=WAD signed = WAD + FP > WAD => clamp to WAD
        (uint256 expOut, uint256 expNewYT) = _mirror(5e17, 1e17, 6e17, 2e17, start, start + 3650 days, MarketState.PERPETUAL, WAD);
        assertEq(expOut, WAD, "mirror predicts a clamped-to-WAD output");
        assertEq(expNewYT, MAX_YT, "mirror predicts yT saturated to MAX");

        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, WAD), WAD, "output clamped to WAD");
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, WAD), WAD, "yieldShare clamped to WAD");
        (uint64 yT,,,) = _readCurve(ydm, address(this));
        assertEq(yT, MAX_YT, "yT saturated to MAX");
    }

    /// Extremely long dormancy still returns and stays bounded (mirror parity at the clamp regime).
    function test_longDormancy_matchesMirror() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD);
        uint256 dt = 100_000 days;
        vm.warp(start + dt);
        (uint256 expOut, uint256 expNewYT) = _mirror(5e17, 2e17, 6e17, 3e17, start, start + dt, MarketState.PERPETUAL, WAD);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, WAD), expOut, "clamped-regime preview == mirror");
        ydm.yieldShare(MarketState.PERPETUAL, WAD);
        (uint64 yT,,,) = _readCurve(ydm, address(this));
        assertEq(yT, expNewYT, "clamped newYT == mirror");
    }

    // =====================================================================
    // Group H — preview/mutate parity, non-persistence, events
    // =====================================================================

    /// preview never mutates the stored curve (checked with a pending adaptation available).
    function test_preview_doesNotPersist() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // stamp
        vm.warp(start + 50 days);
        (uint64 a0, uint32 a1, uint64 a2, uint64 a3) = _readCurve(ydm, address(this));
        ydm.previewYieldShare(MarketState.PERPETUAL, WAD);
        ydm.previewYieldShare(MarketState.PERPETUAL, 0);
        (uint64 b0, uint32 b1, uint64 b2, uint64 b3) = _readCurve(ydm, address(this));
        assertEq(a0, b0, "yT unchanged by preview");
        assertEq(a1, b1, "lastTs unchanged by preview");
        assertEq(a2, b2, "discount unchanged by preview");
        assertEq(a3, b3, "premium unchanged by preview");
    }

    /// At the same block, preview equals the value yieldShare returns (computed pre-write).
    function test_preview_equals_yieldShare_sameBlock() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD);
        vm.warp(start + 12 days);
        uint256 p = ydm.previewYieldShare(MarketState.PERPETUAL, WAD);
        uint256 y = ydm.yieldShare(MarketState.PERPETUAL, WAD);
        assertEq(p, y, "preview == yieldShare at same block");
    }

    function test_events_initEmit() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectEmit(true, true, true, true, address(ydm));
        emit AdaptiveCurveYdmInitialized(address(this), 2e17, 3e17, 6e17);
        ydm.initializeYDMForMarket(1e17, 3e17, 9e17);
    }

    /// On the first call (elapsed 0) at U=target, output==yT and newYT==yT: exact event payload.
    function test_events_yieldShareEmit_firstCall() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        vm.warp(1_000_000);
        vm.expectEmit(true, true, true, true, address(ydm));
        emit YdmAdaptedOutput(address(this), 3e17, 3e17); // avg output == yT, newYT == yT
        ydm.yieldShare(MarketState.PERPETUAL, 5e17);
    }

    function test_events_previewSilent() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        vm.recordLogs();
        ydm.previewYieldShare(MarketState.PERPETUAL, 7e17);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "preview emits nothing");
    }

    // =====================================================================
    // Group I — reinitialization and per-accountant isolation
    // =====================================================================

    function test_reinit_overwrites_and_resetsTimestamp() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // sets lastTs
        (, uint32 lastTsBefore,,) = _readCurve(ydm, address(this));
        assertEq(lastTsBefore, start, "stamped before reinit");

        ydm.initializeYDMForMarket(1e17, 2e17, 5e17); // new curve: FD=1e17, FP=3e17
        (uint64 yT, uint32 lastTs, uint64 discount, uint64 premium) = _readCurve(ydm, address(this));
        assertEq(yT, 2e17, "new yT");
        assertEq(lastTs, 0, "lastTs reset on reinit");
        assertEq(discount, 1e17, "new FD");
        assertEq(premium, 3e17, "new FP");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17), 2e17, "reinit curve Y(target)==new yT");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 0), 1e17, "reinit curve Y(0)==new y0");
    }

    function test_reinit_invalid_preservesState() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(1e17, 5e17, 3e17); // yT > yFull
        (uint64 yT,, uint64 discount, uint64 premium) = _readCurve(ydm, address(this));
        assertEq(yT, 3e17, "yT intact after failed reinit");
        assertEq(discount, 2e17, "FD intact after failed reinit");
        assertEq(premium, 6e17, "FP intact after failed reinit");
    }

    function test_perAccountantIsolation() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(1e17, 3e17, 9e17); // this: Y(target)=3e17
        vm.prank(ACCT_B);
        ydm.initializeYDMForMarket(1e17, 1e17, 3e17); // B: Y(target)=1e17

        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17), 3e17, "this curve");
        vm.prank(ACCT_B);
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17), 1e17, "B curve");
    }

    /// Adaptation is per-accountant: warping and adapting `this` leaves B's curve untouched.
    function test_perAccountant_adaptationIsolation() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(1e17, 3e17, 9e17); // this
        vm.prank(ACCT_B);
        ydm.initializeYDMForMarket(1e17, 3e17, 9e17); // B (identical shape)

        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD);
        vm.warp(start + 100 days);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // this adapts up

        (uint64 yTThis,,,) = _readCurve(ydm, address(this));
        (uint64 yTB, uint32 lastTsB,,) = _readCurve(ydm, ACCT_B);
        assertGt(yTThis, 3e17, "this adapted up");
        assertEq(yTB, 3e17, "B unchanged");
        assertEq(lastTsB, 0, "B never stamped");
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

    function _cfg(uint256 t, uint256 z, uint256 a, uint256 b) internal pure returns (Cfg memory cfg) {
        cfg.target = bound(t, 1, WAD); // full (0, WAD] target range
        cfg.yT = uint64(bound(a, MIN_YT, WAD));
        cfg.y0 = uint64(bound(z, 0, cfg.yT)); // 0 <= y0 <= yT
        cfg.yFull = uint64(bound(b, cfg.yT, WAD)); // yT <= yFull <= WAD
    }

    /// First-call parity (lastTs==0 => no adaptation): output matches mirror, is state-independent,
    /// bounded by WAD, and preview==yieldShare. Full uint256 utilization.
    function testFuzz_firstCall_boundedAndParity(uint256 t, uint256 z, uint256 a, uint256 b, uint256 u) public {
        Cfg memory cfg = _cfg(t, z, a, b);
        AdaptiveCurveYDM_V2 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);
        uint256 FD = cfg.yT - cfg.y0;
        uint256 FP = cfg.yFull - cfg.yT;

        (uint256 expOut,) = _mirror(cfg.target, FD, FP, cfg.yT, 0, block.timestamp, MarketState.PERPETUAL, u);

        uint256 pPerp = ydm.previewYieldShare(MarketState.PERPETUAL, u);
        uint256 pFixed = ydm.previewYieldShare(MarketState.FIXED_TERM, u);
        assertEq(pPerp, expOut, "preview PERP == mirror");
        assertEq(pFixed, expOut, "preview FIXED == mirror (elapsed 0)");
        assertLe(pPerp, WAD, "Y <= WAD");

        uint256 yPerp = ydm.yieldShare(MarketState.PERPETUAL, u);
        assertEq(yPerp, expOut, "yieldShare == mirror");
    }

    /// Exact additive anchors for any valid curve and any state: Y(target)==yT, Y(0)==y0, Y(WAD)==yFull (target<WAD).
    function testFuzz_exactAnchors(uint256 t, uint256 z, uint256 a, uint256 b) public {
        Cfg memory cfg = _cfg(t, z, a, b);
        AdaptiveCurveYDM_V2 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);

        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, cfg.target), cfg.yT, "Y(target)==yT perp");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, cfg.target), cfg.yT, "Y(target)==yT fixed");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 0), cfg.y0, "Y(0)==y0");
        if (cfg.target < WAD) {
            assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, WAD), cfg.yFull, "Y(WAD)==yFull");
        } else {
            assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, WAD), cfg.yT, "target==WAD: Y(WAD)==yT");
        }
    }

    /// Monotone non-decreasing in utilization (FIXED_TERM, fixed curve).
    function testFuzz_monotonic(uint256 t, uint256 z, uint256 a, uint256 b, uint256 u1, uint256 u2) public {
        Cfg memory cfg = _cfg(t, z, a, b);
        AdaptiveCurveYDM_V2 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);
        if (u1 > u2) (u1, u2) = (u2, u1);
        uint256 y1 = ydm.previewYieldShare(MarketState.FIXED_TERM, u1);
        uint256 y2 = ydm.previewYieldShare(MarketState.FIXED_TERM, u2);
        assertLe(y1, y2, "U1<=U2 => Y1<=Y2");
    }

    /// Saturation: Y(U)==Y(WAD) for all U>=WAD. No overflow at full uint256.
    function testFuzz_saturation(uint256 t, uint256 z, uint256 a, uint256 b, uint256 uOver) public {
        Cfg memory cfg = _cfg(t, z, a, b);
        AdaptiveCurveYDM_V2 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);
        uOver = bound(uOver, WAD, type(uint256).max);
        assertEq(
            ydm.previewYieldShare(MarketState.FIXED_TERM, uOver),
            ydm.previewYieldShare(MarketState.FIXED_TERM, WAD),
            "saturates at WAD"
        );
    }

    /// Adaptation parity: after stamping and warping, preview==mirror and yieldShare persists newYT.
    /// Also asserts the canonical invariants (Y<=WAD, no revert) across fuzzed time and util.
    function testFuzz_adaptation_matchesMirror(uint256 t, uint256 z, uint256 a, uint256 b, uint256 u, uint256 startRaw, uint256 dtRaw) public {
        Cfg memory cfg = _cfg(t, z, a, b);
        AdaptiveCurveYDM_V2 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);
        uint256 FD = cfg.yT - cfg.y0;
        uint256 FP = cfg.yFull - cfg.yT;

        uint256 start = bound(startRaw, 1, type(uint32).max); // fits uint32 store, no truncation
        uint256 dt = bound(dtRaw, 0, 1e15); // int256-safe, spans clamp regime
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, u); // stamp lastTs=start, yT unchanged (elapsed 0)

        vm.warp(start + dt);
        (uint256 expOut, uint256 expNewYT) = _mirror(cfg.target, FD, FP, cfg.yT, start, start + dt, MarketState.PERPETUAL, u);

        uint256 p = ydm.previewYieldShare(MarketState.PERPETUAL, u);
        assertEq(p, expOut, "adaptation preview == mirror");
        assertLe(p, WAD, "Y <= WAD");

        uint256 y = ydm.yieldShare(MarketState.PERPETUAL, u);
        assertEq(y, expOut, "adaptation yieldShare == mirror");
        (uint64 yT,,,) = _readCurve(ydm, address(this));
        assertEq(yT, expNewYT, "persisted newYT == mirror");
        assertGe(uint256(yT), MIN_YT, "yT >= MIN");
        assertLe(uint256(yT), MAX_YT, "yT <= MAX");
    }

    /// Adaptation direction: high util (>target) never decreases yT. Low util (<target) never increases it.
    function testFuzz_adaptationDirection(uint256 t, uint256 z, uint256 a, uint256 b, uint256 dtRaw) public {
        Cfg memory cfg = _cfg(t, z, a, b);
        // Ensure a strictly-above and strictly-below sample exist by constraining target away from edges.
        cfg.target = bound(t, 1e16, WAD - 1e16);
        AdaptiveCurveYDM_V2 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);

        uint256 dt = bound(dtRaw, 1, 1e12);

        // Up branch
        vm.warp(1_000_000);
        ydm.yieldShare(MarketState.PERPETUAL, WAD);
        vm.warp(1_000_000 + dt);
        ydm.yieldShare(MarketState.PERPETUAL, WAD);
        (uint64 yTUp,,,) = _readCurve(ydm, address(this));
        assertGe(uint256(yTUp), cfg.yT, "high util does not decrease yT");

        // Fresh model for the down branch
        AdaptiveCurveYDM_V2 ydm2 = _deploy(cfg.target);
        ydm2.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);
        vm.warp(2_000_000);
        ydm2.yieldShare(MarketState.PERPETUAL, 0);
        vm.warp(2_000_000 + dt);
        ydm2.yieldShare(MarketState.PERPETUAL, 0);
        (uint64 yTDown,,,) = _readCurve(ydm2, address(this));
        assertLe(uint256(yTDown), cfg.yT, "low util does not increase yT");
    }

    /// Preview is state-preserving under fuzzed pending adaptation.
    function testFuzz_previewNonPersistence(uint256 t, uint256 z, uint256 a, uint256 b, uint256 u, uint256 dtRaw) public {
        Cfg memory cfg = _cfg(t, z, a, b);
        AdaptiveCurveYDM_V2 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);

        vm.warp(1_000_000);
        ydm.yieldShare(MarketState.PERPETUAL, u);
        vm.warp(1_000_000 + bound(dtRaw, 0, 1e12));

        (uint64 a0, uint32 a1, uint64 a2, uint64 a3) = _readCurve(ydm, address(this));
        ydm.previewYieldShare(MarketState.PERPETUAL, u);
        ydm.previewYieldShare(MarketState.FIXED_TERM, u);
        (uint64 b0, uint32 b1, uint64 b2, uint64 b3) = _readCurve(ydm, address(this));
        assertEq(a0, b0, "yT unchanged");
        assertEq(a1, b1, "lastTs unchanged");
        assertEq(a2, b2, "discount unchanged");
        assertEq(a3, b3, "premium unchanged");
    }
}
