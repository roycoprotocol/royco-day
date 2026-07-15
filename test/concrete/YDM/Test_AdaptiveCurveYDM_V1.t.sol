// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Vm } from "../../../lib/forge-std/src/Vm.sol";
import { FixedPointMathLib } from "../../../lib/solady/src/utils/FixedPointMathLib.sol";
import { IYDM } from "../../../src/interfaces/IYDM.sol";
import { WAD, WAD_INT } from "../../../src/libraries/Constants.sol";
import { MarketState } from "../../../src/libraries/Types.sol";
import { AdaptiveCurveYDM_V1 } from "../../../src/ydm/AdaptiveCurveYDM_V1.sol";

/**
 * @title Test_AdaptiveCurveYDM_V1
 * @notice Unit and fuzz tests for AdaptiveCurveYDM_V1. Stateful invariant coverage lives in
 *         test/invariant/Invariant_YDM.t.sol.
 * @dev The multiplicative adaptive curve. Every expected value is hand-derived or reproduced by an
 *      independent mirror (`_mirror`) that re-implements src/ydm/base/BaseAdaptiveCurveYDM.sol and
 *      src/ydm/AdaptiveCurveYDM_V1.sol using FixedPointMathLib. The contract under test never appears
 *      on the expected side of an assertion.
 *
 * V1 curve (steepness form), with avgYT the time-averaged yield-share-at-target:
 *   S    = steepnessAfterTargetWAD = floor(yFull * WAD / yT)   (fixed at init)
 *   Δ    = normalized signed delta from target, in [-WAD, WAD]
 *          below target: Δ = (U - U_T) * WAD / U_T
 *          above target: Δ = (U - U_T) * WAD / (WAD - U_T)
 *   coeff = (Δ < 0) ? WAD - WAD^2/S : S - WAD
 *   Y(U) = ((coeff * Δ / WAD) + WAD) * avgYT / WAD      (capped at WAD)
 *
 * Anchors (FIXED_TERM, avgYT == yT):
 *   Y(U_T) = yT, Y(WAD) = floor(S*yT/WAD) ≈ yFull, Y(0) = floor(WAD^2/S)*yT/WAD ≈ yT/S
 *
 * Adaptation (PERPETUAL only): yT is exponentiated by a time/distance-weighted linear factor and
 * clamped to [MIN_YT, MAX_YT], avgYT is a trapezoidal blend (init + new + 2*mid)/4.
 */
contract Test_AdaptiveCurveYDM_V1 is Test {
    // Model constants mirrored from source (never read back from the contract under test).
    uint256 constant SPEED_V1 = 50e18 / uint256(365 days);
    uint256 constant SPEED_LIMIT = 100e18 / uint256(365 days);
    uint256 constant MIN_YT = 0.0001e18; // 1e14
    uint256 constant MAX_YT = WAD;
    int256 constant MAX_LINEAR = 135_305_999_368_893_231_589 - 1;

    address constant ACCT_B = address(0xB0B);

    event AdaptiveCurveYdmInitialized(address indexed accountant, uint256 steepnessAfterTargetWAD, uint256 initialYieldShareAtTargetWAD);
    event YdmAdaptedOutput(address indexed accountant, uint256 avgYieldShareWAD, uint256 newYieldShareAtTargetWAD);

    // ---------------------------------------------------------------------
    // deploy helpers
    // ---------------------------------------------------------------------

    function _deploy(uint256 target) internal returns (AdaptiveCurveYDM_V1) {
        return new AdaptiveCurveYDM_V1(target, 0.0001e18, 1e18, (50e18 / uint256(365 days)));
    }

    /// Canonical curve: target=0.5, yT=0.2, yFull=0.8 => S=4e18. Clean powers of ten.
    function _canonical() internal returns (AdaptiveCurveYDM_V1 ydm) {
        ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(2e17, 8e17);
    }

    function _readCurve(AdaptiveCurveYDM_V1 ydm, address acct) internal view returns (uint64 yT, uint32 lastTs, uint160 steep) {
        (yT, lastTs, steep) = ydm.accountantToCurve(acct);
    }

    // ---------------------------------------------------------------------
    // independent mirror of the model math
    // ---------------------------------------------------------------------

    function _steepness(uint256 yT, uint256 yFull) internal pure returns (uint256) {
        return (yFull * WAD) / yT;
    }

    function _mirrorYT(uint256 lastYT, int256 lin) internal pure returns (uint256 yt) {
        if (lin > MAX_LINEAR) lin = MAX_LINEAR;
        yt = FixedPointMathLib.fullMulDiv(lastYT, uint256(FixedPointMathLib.expWad(lin)), WAD);
        if (yt < MIN_YT) return MIN_YT;
        if (yt > MAX_YT) return MAX_YT;
    }

    /// Returns the yield share output and the newYT that the model would compute/persist.
    function _mirror(
        uint256 target,
        uint256 S,
        uint256 initYT,
        uint256 lastTs,
        uint256 nowTs,
        MarketState state,
        uint256 util
    )
        internal
        pure
        returns (uint256 out, uint256 newYT)
    {
        uint256 u = util > WAD ? WAD : util;
        uint256 maxDelta = u > target ? (WAD - target) : target;
        int256 nd = ((int256(u) - int256(target)) * WAD_INT) / int256(maxDelta);

        uint256 avgYT;
        if (state == MarketState.PERPETUAL) {
            int256 speed = (int256(SPEED_V1) * nd) / WAD_INT;
            uint256 elapsed = lastTs == 0 ? 0 : nowTs - lastTs;
            int256 lin = speed * int256(elapsed);
            newYT = _mirrorYT(initYT, lin);
            uint256 midYT = _mirrorYT(initYT, lin / 2);
            avgYT = (initYT + newYT + (2 * midYT)) / 4;
        } else {
            newYT = avgYT = initYT;
        }

        int256 steep = int256(S);
        int256 coeff = nd < 0 ? (WAD_INT - ((WAD_INT * WAD_INT) / steep)) : (steep - WAD_INT);
        uint256 y = uint256((((coeff * nd / WAD_INT) + WAD_INT) * int256(avgYT)) / WAD_INT);
        if (y > WAD) y = WAD;
        out = y;
    }

    // =====================================================================
    // Constructor and immutables
    // =====================================================================

    /// A zero target utilization is rejected: the curve needs a positive kink to interpolate around
    function test_RevertIf_ConstructorTargetZero() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        new AdaptiveCurveYDM_V1(0, 0.0001e18, 1e18, (50e18 / uint256(365 days)));
    }

    /// One wei is the smallest accepted target utilization
    function test_Constructor_TargetOneWei() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(1);
        assertEq(ydm.TARGET_UTILIZATION_WAD(), 1, "target==1");
    }

    /// target == WAD (full utilization) is an accepted boundary
    function test_Constructor_TargetAtWad() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(WAD);
        assertEq(ydm.TARGET_UTILIZATION_WAD(), WAD, "target==WAD");
    }

    /// A target above WAD is meaningless (utilization is capped at WAD) and rejected
    function test_RevertIf_ConstructorTargetAboveWad() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        new AdaptiveCurveYDM_V1(WAD + 1, 0.0001e18, 1e18, (50e18 / uint256(365 days)));
    }

    /// The extreme uint256 max target is rejected by the same gate
    function test_RevertIf_ConstructorTargetUintMax() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        new AdaptiveCurveYDM_V1(type(uint256).max, 0.0001e18, 1e18, (50e18 / uint256(365 days)));
    }

    /// The hardcoded model constants land in the immutables exactly as mirrored from source
    function test_Constructor_Immutables() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(5e17);
        assertEq(ydm.MIN_YIELD_SHARE_AT_TARGET_WAD(), MIN_YT, "min yT == 1e14");
        assertEq(ydm.MAX_YIELD_SHARE_AT_TARGET_WAD(), MAX_YT, "max yT == WAD");
        assertEq(ydm.ADAPTATION_SPEED_AT_BOUNDARY_WAD(), SPEED_V1, "V1 speed == 50e18/365days");
        assertEq(ydm.MAX_ADAPTATION_SPEED_WAD(), SPEED_LIMIT, "speed limit == 100e18/365days");
        // V1 sits at exactly half the deploy-time limit.
        assertEq(ydm.ADAPTATION_SPEED_AT_BOUNDARY_WAD() * 2, ydm.MAX_ADAPTATION_SPEED_WAD(), "V1 speed is half the limit");
    }

    // =====================================================================
    // initializeYDMForMarket validation
    // =====================================================================

    /// A yield-share-at-target below the clamp floor is rejected at initialization
    function test_RevertIf_InitializeYTargetBelowMin() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(uint64(MIN_YT - 1), uint64(WAD)); // yT < 1e14
    }

    /// The clamp floor itself is an accepted yield-share-at-target
    function test_Initialize_YTargetAtMin() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(uint64(MIN_YT), uint64(WAD));
        (uint64 yT,, uint160 steep) = _readCurve(ydm, address(this));
        assertEq(yT, MIN_YT, "yT stored at min");
        assertEq(steep, _steepness(MIN_YT, WAD), "S = WAD^2/1e14 = 1e22");
    }

    /// A yield-share-at-target above WAD is rejected
    function test_RevertIf_InitializeYTargetAboveWad() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(uint64(WAD + 1), uint64(WAD + 1)); // yT > WAD
    }

    /// yT above yFull would give a downward upper segment and is rejected
    function test_RevertIf_InitializeYTargetAboveYFull() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(5e17, 3e17); // yT > yFull
    }

    /// yFull above WAD could pay more than the whole gain and is rejected
    function test_RevertIf_InitializeYFullAboveWad() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(5e17, uint64(WAD + 1)); // yFull > WAD
    }

    /// A valid initialization emits the init event with exact args and stores the derived curve fields
    function test_Initialize_ValidCurve_EmitsAndStores() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(5e17);
        vm.expectEmit(true, true, true, true, address(ydm));
        emit AdaptiveCurveYdmInitialized(address(this), 4e18, 2e17);
        ydm.initializeYDMForMarket(2e17, 8e17);

        (uint64 yT, uint32 lastTs, uint160 steep) = _readCurve(ydm, address(this));
        assertEq(yT, 2e17, "stored yT");
        assertEq(lastTs, 0, "lastTs zero on init");
        assertEq(steep, 4e18, "S = 8e17*WAD/2e17 = 4e18");
    }

    /// yT == yFull => S == WAD => flat curve (Y == yT everywhere in FIXED_TERM).
    function test_Initialize_FlatCurve_SteepnessIsWad() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(3e17, 3e17);
        (,, uint160 steep) = _readCurve(ydm, address(this));
        assertEq(steep, WAD, "S == WAD when yT==yFull");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 0), 3e17, "flat @0");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17), 3e17, "flat @target");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, WAD), 3e17, "flat @full");
    }

    /// Steepness is floored: yFull=WAD, yT=3e17 => S = floor(1e36/3e17) = 3333333333333333333.
    function test_Initialize_SteepnessIsFloored() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(3e17, uint64(WAD));
        (,, uint160 steep) = _readCurve(ydm, address(this));
        assertEq(steep, (uint256(WAD) * WAD) / 3e17, "floored steepness");
    }

    // =====================================================================
    // Uninitialized market reverts
    // =====================================================================

    /// previewYieldShare for a never-initialized accountant reverts instead of quoting a zero curve
    function test_RevertIf_PreviewYieldShareUninitialized() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.previewYieldShare(MarketState.PERPETUAL, 0);
    }

    /// yieldShare for a never-initialized accountant reverts instead of paying on a zero curve
    function test_RevertIf_YieldShareUninitialized() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.yieldShare(MarketState.PERPETUAL, 5e17);
    }

    /// The uninitialized gate fires before any utilization handling, even at uint256 max
    function test_RevertIf_PreviewYieldShareUninitialized_MaxUtilization() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.previewYieldShare(MarketState.FIXED_TERM, type(uint256).max);
    }

    function test_RevertIf_YieldShareQueriedByUninitializedAccountant() public {
        AdaptiveCurveYDM_V1 ydm = _canonical(); // address(this) initialized
        vm.prank(ACCT_B);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.yieldShare(MarketState.PERPETUAL, 0);
    }

    // =====================================================================
    // Exact anchor values (FIXED_TERM, no adaptation)
    // canonical: target=5e17, yT=2e17, yFull=8e17, S=4e18
    // =====================================================================

    function _assertBothStatesFirstCall(AdaptiveCurveYDM_V1 ydm, uint256 u, uint256 expected) internal {
        // On the very first query lastTs==0 => elapsed 0 => PERPETUAL cannot adapt => equals FIXED_TERM.
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, u), expected, "fixed-term value");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, u), expected, "perpetual first-call value");
        assertLe(expected, WAD, "<= WAD");
    }

    /// The canonical curve anchors are wei-exact on the first call: Y(0), both midpoints, Y(target), Y(WAD)
    function test_PreviewYieldShare_CanonicalCurveAnchors() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        _assertBothStatesFirstCall(ydm, 0, 5e16); // Y(0) = yT/S = 0.2/4 = 0.05
        _assertBothStatesFirstCall(ydm, 25e16, 125e15); // below-target midpoint
        _assertBothStatesFirstCall(ydm, 5e17, 2e17); // Y(target) == yT
        _assertBothStatesFirstCall(ydm, 75e16, 5e17); // above-target midpoint
        _assertBothStatesFirstCall(ydm, WAD, 8e17); // Y(WAD) == yFull
    }

    /// Any utilization above WAD resolves exactly to the WAD value: no overflow up to uint256 max
    function test_PreviewYieldShare_SaturatesAboveWad() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256 atFull = ydm.previewYieldShare(MarketState.FIXED_TERM, WAD);
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, WAD + 1), atFull, "cap just past WAD");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 2 * WAD), atFull, "cap at 2*WAD");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, type(uint256).max), atFull, "cap at uint256 max, no overflow");
    }

    /// The kink is exact at target and the curve strictly straddles it one wei to either side
    function test_PreviewYieldShare_KinkContinuityAtTarget() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17), 2e17, "Y(target)==yT");
        assertLt(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17 - 1), 2e17, "just below target < yT");
        assertGt(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17 + 1), 2e17, "just above target > yT");
    }

    /// The curve is monotone non-decreasing across the swept utilization boundaries
    function test_PreviewYieldShare_MonotoneNonDecreasing() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256[9] memory us = [uint256(0), 1e17, 25e16, 5e17 - 1, 5e17, 5e17 + 1, 75e16, WAD - 1, WAD];
        uint256 prev = 0;
        for (uint256 i = 0; i < us.length; i++) {
            uint256 y = ydm.previewYieldShare(MarketState.FIXED_TERM, us[i]);
            assertGe(y, prev, "monotone non-decreasing");
            prev = y;
        }
    }

    /// Region coefficient sign: below target the curve sits under yT. Above it sits over yT.
    function test_PreviewYieldShare_RegionCoefficientSign() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        assertLt(ydm.previewYieldShare(MarketState.FIXED_TERM, 1e17), 2e17, "below target < yT");
        assertGt(ydm.previewYieldShare(MarketState.FIXED_TERM, 9e17), 2e17, "above target > yT");
    }

    /// A second canonical shape confirms Y(0)=yT/S and Y(WAD)=yFull on non-half target.
    function test_PreviewYieldShare_SecondCurveAnchors() public {
        // target=0.8, yT=1e17, yFull=1e18 => S = floor(1e36/1e17) = 10e18.
        AdaptiveCurveYDM_V1 ydm = _deploy(8e17);
        ydm.initializeYDMForMarket(1e17, uint64(WAD));
        uint256 S = _steepness(1e17, WAD);
        // Y(0) = floor(WAD^2/S)*yT/WAD
        uint256 y0 = (((WAD * WAD) / S) * 1e17) / WAD;
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 0), y0, "Y(0) mirror");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 8e17), 1e17, "Y(target)==yT");
        // Y(WAD) = floor(S*yT/WAD), capped to WAD
        uint256 yF = (S * 1e17) / WAD;
        if (yF > WAD) yF = WAD;
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, WAD), yF, "Y(WAD) mirror");
    }

    /**
     * @notice Extra wei-exact literal anchors on both sides of the canonical kink, worked out with plain
     *         arithmetic (never the model's fixed-point ops), so an arithmetic bug shared between the contract
     *         and the fuzz mirror still trips a hand number
     */
    function test_PreviewYieldShare_CanonicalCurveExtraLiteralAnchors() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        // Below the kink the multiplier is (1 + (1 - 1/S)*Δ) with 1 - 1/4 = 0.75:
        //   U=1e17: Δ = (0.1-0.5)/0.5 = -0.8 => (1 - 0.60) * 0.2 = 0.08
        //   U=2e17: Δ = -0.6                 => (1 - 0.45) * 0.2 = 0.11
        //   U=4e17: Δ = -0.2                 => (1 - 0.15) * 0.2 = 0.17
        _assertBothStatesFirstCall(ydm, 1e17, 8e16);
        _assertBothStatesFirstCall(ydm, 2e17, 11e16);
        _assertBothStatesFirstCall(ydm, 4e17, 17e16);
        // Above the kink the multiplier is (1 + (S - 1)*Δ) with S - 1 = 3:
        //   U=6e17: Δ = (0.6-0.5)/(1-0.5) = 0.2 => (1 + 0.6) * 0.2 = 0.32
        //   U=9e17: Δ = 0.8                     => (1 + 2.4) * 0.2 = 0.68
        _assertBothStatesFirstCall(ydm, 6e17, 32e16);
        _assertBothStatesFirstCall(ydm, 9e17, 68e16);
    }

    /**
     * @notice A steepness-3 curve pins the kink, a below-kink point whose intermediate division truncates, and
     *         the full-utilization endpoint as hand literals, so the curve shape is anchored on a non-power-of-two
     *         steepness where the coefficient itself carries a floored fraction
     */
    function test_PreviewYieldShare_SteepnessThreeCurveLiteralAnchors() public {
        // target=0.8, yT=25e16, yFull=75e16 => S = floor(75e16*1e18/25e16) = 3e18 exactly
        AdaptiveCurveYDM_V1 ydm = _deploy(8e17);
        ydm.initializeYDMForMarket(25e16, 75e16);
        // Kink: Y(target) == yT with no adaptation possible on a first call
        _assertBothStatesFirstCall(ydm, 8e17, 25e16);
        // Below kink at U=2e17: Δ = (0.2-0.8)/0.8 = -0.75. The coefficient floors first:
        //   1e18 - floor(1e36/3e18) = 1e18 - 333333333333333333 = 666666666666666667.
        //   666666666666666667 * (-75e16) = -500000000000000000250000000000000000, and signed division
        //   truncates toward zero => -5e17 exactly. (1e18 - 5e17) * 25e16 / 1e18 = 125e15.
        _assertBothStatesFirstCall(ydm, 2e17, 125e15);
        // Full utilization: Δ = 1 => (1 + (3 - 1)) * 0.25 = 0.75, recovering yFull exactly (S divided evenly)
        _assertBothStatesFirstCall(ydm, WAD, 75e16);
    }

    // =====================================================================
    // Target-utilization boundary coverage (fresh model per target)
    // =====================================================================

    /// The kink is exactly yT at U==target, and below/above straddle it, for every representative target.
    function test_PreviewYieldShare_TargetSweep_KinkExact() public {
        uint256[7] memory targets = [uint256(1), MIN_YT, 1e17, 5e17, 9e17, WAD - 1, WAD];
        for (uint256 i = 0; i < targets.length; i++) {
            uint256 target = targets[i];
            AdaptiveCurveYDM_V1 ydm = _deploy(target);
            ydm.initializeYDMForMarket(2e17, 8e17);

            // Y(target) == yT exactly regardless of state (Δ==0 => no adaptation, coeff*Δ==0).
            assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, target), 2e17, "Y(target)==yT (fixed)");
            assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, target), 2e17, "Y(target)==yT (perp)");

            // Below-target sample (only meaningful when target > 0 boundary allows a lower point).
            if (target > 0) {
                uint256 below = target == WAD ? WAD - 1 : (target > 1 ? target - 1 : 0);
                uint256 yb = ydm.previewYieldShare(MarketState.FIXED_TERM, below);
                assertLe(yb, 2e17, "at/below target <= yT");
            }
            // Above-target sample (util capped at WAD, so only when target < WAD).
            if (target < WAD) {
                uint256 above = target + 1;
                uint256 ya = ydm.previewYieldShare(MarketState.FIXED_TERM, above);
                assertGe(ya, 2e17, "at/above target >= yT");
                assertLe(ya, WAD, "<= WAD");
            }
        }
    }

    // =====================================================================
    // Adaptation up and down over warps (exact via the mirror)
    // =====================================================================

    /// First PERPETUAL call never adapts (lastTs starts at 0 => elapsed 0), but it stamps lastTs.
    function test_YieldShare_FirstCallNoAdaptation_StampsTimestamp() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        vm.warp(1_000_000);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // high util, but elapsed==0
        (uint64 yT, uint32 lastTs,) = _readCurve(ydm, address(this));
        assertEq(yT, 2e17, "yT unchanged on first call");
        assertEq(lastTs, 1_000_000, "lastTs stamped to block.timestamp");
    }

    /// Sustained over-target utilization adapts yT up: output and persisted yT match the independent mirror exactly
    function test_YieldShare_AdaptationUp_IncreasesYieldShareAtTarget() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // stamp lastTs=start, yT unchanged

        uint256 dt = 30 days;
        vm.warp(start + dt);
        (uint256 expOut, uint256 expNewYT) = _mirror(5e17, 4e18, 2e17, start, start + dt, MarketState.PERPETUAL, WAD);

        // preview does not mutate; equals mirror
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, WAD), expOut, "up preview == mirror");
        // yieldShare mutates yT to newYT and returns the same output
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, WAD), expOut, "up yieldShare == mirror");
        (uint64 yT, uint32 lastTs,) = _readCurve(ydm, address(this));
        assertEq(yT, expNewYT, "yT persisted to newYT");
        assertGt(yT, 2e17, "yT increased under high util");
        assertEq(lastTs, start + dt, "lastTs advanced");
    }

    /// Sustained zero utilization adapts yT down: output and persisted yT match the independent mirror exactly
    function test_YieldShare_AdaptationDown_DecreasesYieldShareAtTarget() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, 0); // stamp, yT unchanged

        uint256 dt = 30 days;
        vm.warp(start + dt);
        (uint256 expOut, uint256 expNewYT) = _mirror(5e17, 4e18, 2e17, start, start + dt, MarketState.PERPETUAL, 0);

        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), expOut, "down preview == mirror");
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, 0), expOut, "down yieldShare == mirror");
        (uint64 yT,,) = _readCurve(ydm, address(this));
        assertEq(yT, expNewYT, "yT persisted to newYT");
        assertLt(yT, 2e17, "yT decreased under zero util");
    }

    /// At U==target the curve does not adapt over time (Δ==0 => speed 0), even in PERPETUAL.
    function test_YieldShare_ParkedAtTarget_NeverAdapts() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, 5e17);
        vm.warp(start + 3650 days);
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, 5e17), 2e17, "Y(target) still yT after long warp");
        (uint64 yT,,) = _readCurve(ydm, address(this));
        assertEq(yT, 2e17, "yT unchanged at target");
    }

    /**
     * @notice Adversarial boundary parking: holding utilization at exactly target + 1 wei freezes adaptation
     *         forever, because the adaptation speed floors to zero before it is scaled by elapsed time
     * @dev speed = SPEED_V1 * nd / WAD with nd = 1 * WAD / (WAD - 5e17) = 2, so speed = floor(1585489599188 * 2
     *      / 1e18) = 0 and the linear factor is 0 for ANY elapsed time. The payout is the fixed curve point:
     *      ((S - WAD) * 2 / WAD + WAD) * yT / WAD = (6 + 1e18) * 2e17 / 1e18 = 2e17 + 1 — one extra wei of
     *      utilization buys one wei of yield share and zero curve movement, so the kink cannot be farmed
     */
    function test_YieldShare_ParkedOneWeiAboveTarget_AdaptationFloorsToZero() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, 5e17 + 1); // stamp lastTs
        vm.warp(start + 3650 days);
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, 5e17 + 1), 2e17 + 1, "the fixed curve point one wei above the kink");
        (uint64 yT, uint32 lastTs,) = _readCurve(ydm, address(this));
        assertEq(yT, 2e17, "a floored-to-zero speed must never move yT, even over ten years");
        assertEq(lastTs, start + 3650 days, "lastTs still restamps on every mutating call");
    }

    /// FIXED_TERM never adapts yT even across warps, though it still restamps lastTs.
    function test_YieldShare_FixedTermNeverAdapts() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.FIXED_TERM, WAD);
        vm.warp(start + 3650 days);
        ydm.yieldShare(MarketState.FIXED_TERM, WAD);
        (uint64 yT, uint32 lastTs,) = _readCurve(ydm, address(this));
        assertEq(yT, 2e17, "yT unchanged in FIXED_TERM");
        assertEq(lastTs, start + 3650 days, "lastTs still restamped");
    }

    /// PERPETUAL and FIXED_TERM diverge once elapsed>0 and util!=target: PERP adapts, FIXED holds.
    function test_PreviewYieldShare_StatesDivergeAfterWarp() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // stamp
        vm.warp(start + 100 days);
        uint256 perp = ydm.previewYieldShare(MarketState.PERPETUAL, WAD);
        uint256 fixedTerm = ydm.previewYieldShare(MarketState.FIXED_TERM, WAD);
        assertGt(perp, fixedTerm, "PERP adapts above the un-adapted FIXED_TERM value");
        // FIXED_TERM equals the un-adapted anchor (yFull for canonical).
        assertEq(fixedTerm, 8e17, "FIXED_TERM holds at yFull");
    }

    // =====================================================================
    // Long-dormancy saturation (clamp to bounds, no revert)
    // =====================================================================

    /// Sustained high util drives yT to MAX_YT (WAD). No overflow despite huge linear factor.
    function test_YieldShare_LongDormancyUp_SaturatesToMaxYieldShare() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD);
        vm.warp(start + 3650 days); // ~10y >> saturation horizon
        uint256 out = ydm.yieldShare(MarketState.PERPETUAL, WAD);
        (uint64 yT,,) = _readCurve(ydm, address(this));
        assertEq(yT, MAX_YT, "yT clamped to MAX_YT");
        assertLe(out, WAD, "output <= WAD");
    }

    /// Sustained zero util drives yT to MIN_YT (1e14). No revert.
    function test_YieldShare_LongDormancyDown_SaturatesToMinYieldShare() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, 0);
        vm.warp(start + 3650 days);
        uint256 out = ydm.yieldShare(MarketState.PERPETUAL, 0);
        (uint64 yT,,) = _readCurve(ydm, address(this));
        assertEq(yT, MIN_YT, "yT clamped to MIN_YT");
        assertLe(out, WAD, "output <= WAD");
    }

    /**
     * @notice Down-dormancy clamp literals: ten years parked at zero utilization lands the persisted yield share
     *         at target exactly on the MIN clamp, and the clamping call pays the exact trapezoid blend — all hand
     *         numbers, derivable without the exponential because e^x underflows to zero wei at this horizon
     * @dev The floor matters economically: however abandoned the pool, the model cannot decay the kink payout
     *      to zero, so a market that regains utilization immediately prices off the configured minimum
     */
    function test_YieldShare_DormancyDownClampLiteralAnchors() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, 0); // stamp only (elapsed 0, curve untouched)
        vm.warp(start + 3650 days);
        // Δ = -1 => the linear factor is about -5.0e20 and its half about -2.5e20, both far below expWad's
        // zero-underflow threshold, so the end and midpoint yield-shares-at-target both clamp to MIN = 1e14.
        // Trapezoid blend: (2e17 + 1e14 + 2*1e14) / 4 = 200300000000000000 / 4 = 50075000000000000.
        // Payout at U=0: (1 - 0.75) * 50075000000000000 = 12518750000000000 exactly.
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 12_518_750_000_000_000, "the clamping call pays the exact trapezoid blend");
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, 0), 12_518_750_000_000_000, "yieldShare pays the same literal");
        (uint64 yT,,) = _readCurve(ydm, address(this));
        assertEq(yT, 1e14, "the persisted yield share at target lands exactly on the MIN clamp");
        // Same block (elapsed 0, no further adaptation): the kink pays exactly the clamp floor, and the
        // multiplicative shape scales that floor, so one wei above nothing: U=75e16 => (1 + 3*0.5) * 1e14
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 5e17), 1e14, "the kink now pays exactly MIN");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 75e16), 250_000_000_000_000, "above the kink the shape multiplies the clamped floor");
    }

    /**
     * @notice Up-dormancy clamp literals: ten years parked at full utilization lands the persisted yield share
     *         at target exactly on the MAX clamp (WAD) and caps the payout at WAD — hand numbers, since the
     *         clamped exponent e^{135.3} dwarfs 1/0.2 and saturates both trapezoid samples to MAX
     * @dev The cap matters economically: no dormancy horizon can make the model promise more than 100% of the
     *      senior gain, so the paying tranche can never be turned upside down by a stale curve
     */
    function test_YieldShare_DormancyUpClampLiteralAnchors() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // stamp only
        vm.warp(start + 3650 days);
        // Both trapezoid samples clamp to MAX = WAD, so the blend is (2e17 + 1e18 + 2e18) / 4 = 8e17.
        // Payout at U=WAD: (1 + 3) * 0.8 = 3.2 > 1 => capped to WAD exactly.
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, WAD), WAD, "the clamping call caps the payout at WAD");
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, WAD), WAD, "yieldShare pays the same capped literal");
        (uint64 yT,,) = _readCurve(ydm, address(this));
        assertEq(uint256(yT), WAD, "the persisted yield share at target lands exactly on the MAX clamp");
        // Same block: the kink pays exactly the clamp ceiling, and below the kink the multiplicative shape
        // discounts it: U=0 => (1 - 0.75) * 1e18 = 2.5e17
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 5e17), WAD, "the kink now pays exactly MAX");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 25e16, "below the kink the shape discounts the clamped ceiling");
    }

    /// Extremely long dormancy still returns and stays bounded (mirror parity at the clamp regime).
    function test_YieldShare_LongDormancyClampRegime_MatchesMirror() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD);
        uint256 dt = 100_000 days;
        vm.warp(start + dt);
        (uint256 expOut, uint256 expNewYT) = _mirror(5e17, 4e18, 2e17, start, start + dt, MarketState.PERPETUAL, WAD);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, WAD), expOut, "clamped-regime preview == mirror");
        ydm.yieldShare(MarketState.PERPETUAL, WAD);
        (uint64 yT,,) = _readCurve(ydm, address(this));
        assertEq(yT, expNewYT, "clamped newYT == mirror");
    }

    // =====================================================================
    // Preview/mutate parity, non-persistence, events
    // =====================================================================

    /// preview never mutates the stored curve (checked with a pending adaptation available).
    function test_PreviewYieldShare_DoesNotPersistPendingAdaptation() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // stamp
        vm.warp(start + 50 days);
        (uint64 a0, uint32 a1, uint160 a2) = _readCurve(ydm, address(this));
        ydm.previewYieldShare(MarketState.PERPETUAL, WAD);
        ydm.previewYieldShare(MarketState.PERPETUAL, 0);
        (uint64 b0, uint32 b1, uint160 b2) = _readCurve(ydm, address(this));
        assertEq(a0, b0, "yT unchanged by preview");
        assertEq(a1, b1, "lastTs unchanged by preview");
        assertEq(a2, b2, "steepness unchanged by preview");
    }

    /// At the same block, preview equals the value yieldShare returns (computed pre-write).
    function test_PreviewYieldShare_EqualsYieldShareSameBlock() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD);
        vm.warp(start + 12 days);
        uint256 p = ydm.previewYieldShare(MarketState.PERPETUAL, WAD);
        uint256 y = ydm.yieldShare(MarketState.PERPETUAL, WAD);
        assertEq(p, y, "preview == yieldShare at same block");
    }

    /// Initialization emits AdaptiveCurveYdmInitialized with the exact derived arguments
    function test_Initialize_EmitsAdaptiveCurveYdmInitialized() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(5e17);
        vm.expectEmit(true, true, true, true, address(ydm));
        emit AdaptiveCurveYdmInitialized(address(this), 4e18, 2e17);
        ydm.initializeYDMForMarket(2e17, 8e17);
    }

    /// On the first call (elapsed 0) at U=target, output==yT and newYT==yT: exact event payload.
    function test_YieldShare_EmitsYdmAdaptedOutput_FirstCall() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        vm.warp(1_000_000);
        vm.expectEmit(true, true, true, true, address(ydm));
        emit YdmAdaptedOutput(address(this), 2e17, 2e17); // avg output == yT, newYT == yT
        ydm.yieldShare(MarketState.PERPETUAL, 5e17);
    }

    /// The preview path is silent: no logs, so off-chain quoting cannot be mistaken for a mutation
    function test_PreviewYieldShare_EmitsNothing() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        vm.recordLogs();
        ydm.previewYieldShare(MarketState.PERPETUAL, 7e17);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "preview emits nothing");
    }

    // =====================================================================
    // Reinitialization and per-accountant isolation
    // =====================================================================

    /// Re-initialization overwrites the curve and resets the adaptation clock to the un-stamped state
    function test_Initialize_ReinitializeOverwritesAndResetsTimestamp() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // sets lastTs
        (, uint32 lastTsBefore,) = _readCurve(ydm, address(this));
        assertEq(lastTsBefore, start, "stamped before reinit");

        ydm.initializeYDMForMarket(1e17, 5e17); // new curve, S=5e18
        (uint64 yT, uint32 lastTs, uint160 steep) = _readCurve(ydm, address(this));
        assertEq(yT, 1e17, "new yT");
        assertEq(lastTs, 0, "lastTs reset on reinit");
        assertEq(steep, _steepness(1e17, 5e17), "new steepness");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17), 1e17, "reinit curve Y(target)==new yT");
    }

    /// A failed re-initialization must leave the previous curve byte-identical
    function test_RevertIf_ReinitializeInvalid_PreservesCurve() public {
        AdaptiveCurveYDM_V1 ydm = _canonical();
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(5e17, 3e17); // yT > yFull
        (uint64 yT,, uint160 steep) = _readCurve(ydm, address(this));
        assertEq(yT, 2e17, "yT intact after failed reinit");
        assertEq(steep, 4e18, "steepness intact after failed reinit");
    }

    /// Curves are keyed by msg.sender: two accountants on one model never read each other's parameters
    function test_YieldShare_PerAccountantCurveIsolation() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(2e17, 8e17); // this: Y(target)=2e17
        vm.prank(ACCT_B);
        ydm.initializeYDMForMarket(1e17, 3e17); // B: Y(target)=1e17

        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17), 2e17, "this curve");
        vm.prank(ACCT_B);
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17), 1e17, "B curve");
    }

    /// Adaptation is per-accountant: warping and adapting `this` leaves B's curve untouched.
    function test_YieldShare_PerAccountantAdaptationIsolation() public {
        AdaptiveCurveYDM_V1 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(2e17, 8e17); // this
        vm.prank(ACCT_B);
        ydm.initializeYDMForMarket(2e17, 8e17); // B (identical shape)

        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD);
        vm.warp(start + 100 days);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // this adapts up

        (uint64 yTThis,,) = _readCurve(ydm, address(this));
        (uint64 yTB, uint32 lastTsB,) = _readCurve(ydm, ACCT_B);
        assertGt(yTThis, 2e17, "this adapted up");
        assertEq(yTB, 2e17, "B unchanged");
        assertEq(lastTsB, 0, "B never stamped");
    }

    // =====================================================================
    // FUZZ TESTS
    // =====================================================================

    struct Cfg {
        uint256 target;
        uint64 yT;
        uint64 yFull;
    }

    function _cfg(uint256 t, uint256 a, uint256 b) internal pure returns (Cfg memory cfg) {
        cfg.target = bound(t, 1, WAD); // full (0, WAD] target range
        cfg.yT = uint64(bound(a, MIN_YT, WAD));
        cfg.yFull = uint64(bound(b, cfg.yT, WAD));
    }

    /// First-call parity (lastTs==0 => no adaptation): output matches mirror, is state-independent,
    /// bounded by WAD, and preview==yieldShare. Full uint256 utilization.
    function testFuzz_YieldShare_FirstCallBoundedAndMatchesMirror(uint256 t, uint256 a, uint256 b, uint256 u) public {
        Cfg memory cfg = _cfg(t, a, b);
        AdaptiveCurveYDM_V1 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.yT, cfg.yFull);
        uint256 S = _steepness(cfg.yT, cfg.yFull);

        (uint256 expOut,) = _mirror(cfg.target, S, cfg.yT, 0, block.timestamp, MarketState.PERPETUAL, u);

        uint256 pPerp = ydm.previewYieldShare(MarketState.PERPETUAL, u);
        uint256 pFixed = ydm.previewYieldShare(MarketState.FIXED_TERM, u);
        assertEq(pPerp, expOut, "preview PERP == mirror");
        assertEq(pFixed, expOut, "preview FIXED == mirror (elapsed 0)");
        assertLe(pPerp, WAD, "Y <= WAD");

        uint256 yPerp = ydm.yieldShare(MarketState.PERPETUAL, u);
        assertEq(yPerp, expOut, "yieldShare == mirror");
    }

    /// Y(target) == yT exactly for any valid curve and any state (Δ==0).
    function testFuzz_PreviewYieldShare_AnchorAtTarget(uint256 t, uint256 a, uint256 b) public {
        Cfg memory cfg = _cfg(t, a, b);
        AdaptiveCurveYDM_V1 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.yT, cfg.yFull);
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, cfg.target), cfg.yT, "Y(target)==yT perp");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, cfg.target), cfg.yT, "Y(target)==yT fixed");
    }

    /// Monotone non-decreasing in utilization (FIXED_TERM, fixed curve).
    function testFuzz_PreviewYieldShare_MonotoneNonDecreasing(uint256 t, uint256 a, uint256 b, uint256 u1, uint256 u2) public {
        Cfg memory cfg = _cfg(t, a, b);
        AdaptiveCurveYDM_V1 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.yT, cfg.yFull);
        if (u1 > u2) (u1, u2) = (u2, u1);
        uint256 y1 = ydm.previewYieldShare(MarketState.FIXED_TERM, u1);
        uint256 y2 = ydm.previewYieldShare(MarketState.FIXED_TERM, u2);
        assertLe(y1, y2, "U1<=U2 => Y1<=Y2");
    }

    /// Saturation: Y(U)==Y(WAD) for all U>=WAD. No overflow at full uint256.
    function testFuzz_PreviewYieldShare_SaturatesAboveWad(uint256 t, uint256 a, uint256 b, uint256 uOver) public {
        Cfg memory cfg = _cfg(t, a, b);
        AdaptiveCurveYDM_V1 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.yT, cfg.yFull);
        uOver = bound(uOver, WAD, type(uint256).max);
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, uOver), ydm.previewYieldShare(MarketState.FIXED_TERM, WAD), "saturates at WAD");
    }

    /// Adaptation parity: after stamping and warping, preview==mirror and yieldShare persists newYT.
    /// Also asserts the canonical invariants (Y<=WAD, no revert) across fuzzed time and util.
    function testFuzz_YieldShare_AdaptationMatchesMirror(uint256 t, uint256 a, uint256 b, uint256 u, uint256 startRaw, uint256 dtRaw) public {
        Cfg memory cfg = _cfg(t, a, b);
        AdaptiveCurveYDM_V1 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.yT, cfg.yFull);
        uint256 S = _steepness(cfg.yT, cfg.yFull);

        uint256 start = bound(startRaw, 1, type(uint32).max); // fits uint32 store, no truncation
        uint256 dt = bound(dtRaw, 0, 1e15); // int256-safe, spans clamp regime
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, u); // stamp lastTs=start, yT unchanged (elapsed 0)

        vm.warp(start + dt);
        (uint256 expOut, uint256 expNewYT) = _mirror(cfg.target, S, cfg.yT, start, start + dt, MarketState.PERPETUAL, u);

        uint256 p = ydm.previewYieldShare(MarketState.PERPETUAL, u);
        assertEq(p, expOut, "adaptation preview == mirror");
        assertLe(p, WAD, "Y <= WAD");

        uint256 y = ydm.yieldShare(MarketState.PERPETUAL, u);
        assertEq(y, expOut, "adaptation yieldShare == mirror");
        (uint64 yT,,) = _readCurve(ydm, address(this));
        assertEq(yT, expNewYT, "persisted newYT == mirror");
        assertGe(uint256(yT), MIN_YT, "yT >= MIN");
        assertLe(uint256(yT), MAX_YT, "yT <= MAX");
    }

    /// Adaptation direction: high util (>target) never decreases yT. Low util (<target) never increases it.
    function testFuzz_YieldShare_AdaptationDirection(uint256 t, uint256 a, uint256 b, uint256 dtRaw) public {
        Cfg memory cfg = _cfg(t, a, b);
        // Ensure a strictly-above and strictly-below sample exist by constraining target away from edges.
        cfg.target = bound(t, 1e16, WAD - 1e16);
        AdaptiveCurveYDM_V1 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.yT, cfg.yFull);

        uint256 dt = bound(dtRaw, 1, 1e12);

        // Up branch
        vm.warp(1_000_000);
        ydm.yieldShare(MarketState.PERPETUAL, WAD);
        vm.warp(1_000_000 + dt);
        ydm.yieldShare(MarketState.PERPETUAL, WAD);
        (uint64 yTUp,,) = _readCurve(ydm, address(this));
        assertGe(uint256(yTUp), cfg.yT, "high util does not decrease yT");

        // Fresh model for the down branch
        AdaptiveCurveYDM_V1 ydm2 = _deploy(cfg.target);
        ydm2.initializeYDMForMarket(cfg.yT, cfg.yFull);
        vm.warp(2_000_000);
        ydm2.yieldShare(MarketState.PERPETUAL, 0);
        vm.warp(2_000_000 + dt);
        ydm2.yieldShare(MarketState.PERPETUAL, 0);
        (uint64 yTDown,,) = _readCurve(ydm2, address(this));
        assertLe(uint256(yTDown), cfg.yT, "low util does not increase yT");
    }

    /// Preview is state-preserving under fuzzed pending adaptation.
    function testFuzz_PreviewYieldShare_DoesNotPersist(uint256 t, uint256 a, uint256 b, uint256 u, uint256 dtRaw) public {
        Cfg memory cfg = _cfg(t, a, b);
        AdaptiveCurveYDM_V1 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.yT, cfg.yFull);

        vm.warp(1_000_000);
        ydm.yieldShare(MarketState.PERPETUAL, u);
        vm.warp(1_000_000 + bound(dtRaw, 0, 1e12));

        (uint64 a0, uint32 a1, uint160 a2) = _readCurve(ydm, address(this));
        ydm.previewYieldShare(MarketState.PERPETUAL, u);
        ydm.previewYieldShare(MarketState.FIXED_TERM, u);
        (uint64 b0, uint32 b1, uint160 b2) = _readCurve(ydm, address(this));
        assertEq(a0, b0, "yT unchanged");
        assertEq(a1, b1, "lastTs unchanged");
        assertEq(a2, b2, "steepness unchanged");
    }
}
