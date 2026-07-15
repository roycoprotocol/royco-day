// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Vm } from "../../../lib/forge-std/src/Vm.sol";
import { FixedPointMathLib } from "../../../lib/solady/src/utils/FixedPointMathLib.sol";
import { IYDM } from "../../../src/interfaces/IYDM.sol";
import { WAD, WAD_INT } from "../../../src/libraries/Constants.sol";
import { MarketState } from "../../../src/libraries/Types.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";

/**
 * @title Test_AdaptiveCurveYDM_V2
 * @notice Unit and fuzz tests for AdaptiveCurveYDM_V2. Stateful invariant coverage lives in
 *         test/invariant/Invariant_YDM.t.sol.
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
contract Test_AdaptiveCurveYDM_V2 is Test {
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
        return new AdaptiveCurveYDM_V2(target, 0.0001e18, 1e18, (100e18 / uint256(365 days)));
    }

    /// Canonical curve: target=0.5, y0=0.1, yT=0.3, yFull=0.9 => FD=0.2, FP=0.6. Clean powers of ten.
    function _canonical() internal returns (AdaptiveCurveYDM_V2 ydm) {
        ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(1e17, 3e17, 9e17);
    }

    function _readCurve(AdaptiveCurveYDM_V2 ydm, address acct) internal view returns (uint64 yT, uint32 lastTs, uint64 discount, uint64 premium) {
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
    function _mirror(
        uint256 target,
        uint256 FD,
        uint256 FP,
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
    // Constructor and immutables
    // =====================================================================

    /// A zero target utilization is rejected: the curve needs a positive kink to interpolate around
    function test_RevertIf_ConstructorTargetZero() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        new AdaptiveCurveYDM_V2(0, 0.0001e18, 1e18, (100e18 / uint256(365 days)));
    }

    /// One wei is the smallest accepted target utilization
    function test_Constructor_TargetOneWei() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(1);
        assertEq(ydm.TARGET_UTILIZATION_WAD(), 1, "target==1");
    }

    /// target == WAD (full utilization) is an accepted boundary
    function test_Constructor_TargetAtWad() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(WAD);
        assertEq(ydm.TARGET_UTILIZATION_WAD(), WAD, "target==WAD");
    }

    /// A target above WAD is meaningless (utilization is capped at WAD) and rejected
    function test_RevertIf_ConstructorTargetAboveWad() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        new AdaptiveCurveYDM_V2(WAD + 1, 0.0001e18, 1e18, (100e18 / uint256(365 days)));
    }

    /// The extreme uint256 max target is rejected by the same gate
    function test_RevertIf_ConstructorTargetUintMax() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        new AdaptiveCurveYDM_V2(type(uint256).max, 0.0001e18, 1e18, (100e18 / uint256(365 days)));
    }

    /// V2's fixed speed is exactly the deploy-time limit (100e18/365days). No per-market speed field.
    function test_Constructor_Immutables() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        assertEq(ydm.MIN_YIELD_SHARE_AT_TARGET_WAD(), MIN_YT, "min yT == 1e14");
        assertEq(ydm.MAX_YIELD_SHARE_AT_TARGET_WAD(), MAX_YT, "max yT == WAD");
        assertEq(ydm.ADAPTATION_SPEED_AT_BOUNDARY_WAD(), SPEED_V2, "V2 speed == 100e18/365days");
        assertEq(ydm.MAX_ADAPTATION_SPEED_WAD(), SPEED_LIMIT, "speed limit == 100e18/365days");
        assertEq(ydm.ADAPTATION_SPEED_AT_BOUNDARY_WAD(), ydm.MAX_ADAPTATION_SPEED_WAD(), "V2 speed sits at the limit");
    }

    // =====================================================================
    // initializeYDMForMarket validation (3-arg, no speed param)
    // =====================================================================

    /// A yield-share-at-target below the clamp floor is rejected at initialization
    function test_RevertIf_InitializeYTargetBelowMin() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(0, uint64(MIN_YT - 1), uint64(WAD)); // yT < 1e14
    }

    /// The clamp floor itself is an accepted yield-share-at-target
    function test_Initialize_YTargetAtMin() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(uint64(MIN_YT), uint64(MIN_YT), uint64(WAD));
        (uint64 yT,, uint64 discount, uint64 premium) = _readCurve(ydm, address(this));
        assertEq(yT, MIN_YT, "yT stored at min");
        assertEq(discount, 0, "FD == yT - y0 == 0");
        assertEq(premium, uint64(WAD - MIN_YT), "FP == yFull - yT");
    }

    /// y0 above yT would give a negative discount and is rejected
    function test_RevertIf_InitializeY0AboveYTarget() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(4e17, 3e17, 9e17); // y0 > yT
    }

    /// yT above yFull would give a downward upper segment and is rejected
    function test_RevertIf_InitializeYTargetAboveYFull() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(1e17, 5e17, 3e17); // yT > yFull
    }

    /// yFull above WAD could pay more than the whole gain and is rejected
    function test_RevertIf_InitializeYFullAboveWad() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(1e17, 5e17, uint64(WAD + 1)); // yFull > WAD
    }

    /// A valid initialization emits the init event with exact args and stores the derived curve fields
    function test_Initialize_ValidCurve_EmitsAndStores() public {
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
    function test_Initialize_FlatCurve_ZeroSpreads() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(3e17, 3e17, 3e17);
        (,, uint64 discount, uint64 premium) = _readCurve(ydm, address(this));
        assertEq(discount, 0, "FD == 0");
        assertEq(premium, 0, "FP == 0");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 0), 3e17, "flat @0");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17), 3e17, "flat @target");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, WAD), 3e17, "flat @full");
    }

    /// y0 == 0 is a valid floor. FD == yT and Y(0) == 0 exactly.
    function test_Initialize_Y0Zero_DiscountEqualsYTarget() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(0, 3e17, 9e17);
        (,, uint64 discount,) = _readCurve(ydm, address(this));
        assertEq(discount, 3e17, "FD == yT when y0 == 0");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 0), 0, "Y(0) == y0 == 0");
    }

    /// yFull == WAD is valid. Y(WAD) == WAD exactly.
    function test_Initialize_YFullAtWad() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(1e17, 3e17, uint64(WAD));
        (,,, uint64 premium) = _readCurve(ydm, address(this));
        assertEq(premium, uint64(WAD - 3e17), "FP == WAD - yT");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, WAD), WAD, "Y(WAD) == yFull == WAD");
    }

    // =====================================================================
    // Uninitialized market reverts
    // =====================================================================

    /// previewYieldShare for a never-initialized accountant reverts instead of quoting a zero curve
    function test_RevertIf_PreviewYieldShareUninitialized() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.previewYieldShare(MarketState.PERPETUAL, 0);
    }

    /// yieldShare for a never-initialized accountant reverts instead of paying on a zero curve
    function test_RevertIf_YieldShareUninitialized() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.yieldShare(MarketState.PERPETUAL, 5e17);
    }

    /// The uninitialized gate fires before any utilization handling, even at uint256 max
    function test_RevertIf_PreviewYieldShareUninitialized_MaxUtilization() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.previewYieldShare(MarketState.FIXED_TERM, type(uint256).max);
    }

    function test_RevertIf_YieldShareQueriedByUninitializedAccountant() public {
        AdaptiveCurveYDM_V2 ydm = _canonical(); // address(this) initialized
        vm.prank(ACCT_B);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.yieldShare(MarketState.PERPETUAL, 0);
    }

    // =====================================================================
    // Exact anchor values (FIXED_TERM, no adaptation)
    // canonical: target=5e17, y0=1e17, yT=3e17, yFull=9e17, FD=2e17, FP=6e17
    // =====================================================================

    function _assertBothStatesFirstCall(AdaptiveCurveYDM_V2 ydm, uint256 u, uint256 expected) internal {
        // On the very first query lastTs==0 => elapsed 0 => PERPETUAL cannot adapt => equals FIXED_TERM.
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, u), expected, "fixed-term value");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, u), expected, "perpetual first-call value");
        assertLe(expected, WAD, "<= WAD");
    }

    /// The canonical curve anchors are wei-exact on the first call: Y(0), both midpoints, Y(target), Y(WAD)
    function test_PreviewYieldShare_CanonicalCurveAnchors() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        _assertBothStatesFirstCall(ydm, 0, 1e17); // Y(0) == y0
        _assertBothStatesFirstCall(ydm, 25e16, 2e17); // below-target midpoint: yT - FD/2 = 3e17 - 1e17
        _assertBothStatesFirstCall(ydm, 5e17, 3e17); // Y(target) == yT
        _assertBothStatesFirstCall(ydm, 75e16, 6e17); // above-target midpoint: yT + FP/2 = 3e17 + 3e17
        _assertBothStatesFirstCall(ydm, WAD, 9e17); // Y(WAD) == yFull
    }

    /// Any utilization above WAD resolves exactly to the WAD value: no overflow up to uint256 max
    function test_PreviewYieldShare_SaturatesAboveWad() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 atFull = ydm.previewYieldShare(MarketState.FIXED_TERM, WAD);
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, WAD + 1), atFull, "cap just past WAD");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 2 * WAD), atFull, "cap at 2*WAD");
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, type(uint256).max), atFull, "cap at uint256 max, no overflow");
    }

    /// Continuity around the kink: exactly yT at target, and non-crossing on each side. The additive
    /// adjustment truncates toward zero, so at 1-wei offsets the output can round back onto yT (the
    /// spread is not strict at wei granularity). Once the offset is large enough it becomes strict.
    function test_PreviewYieldShare_KinkContinuityAtTarget() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17), 3e17, "Y(target)==yT");
        assertLe(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17 - 1), 3e17, "just below target <= yT");
        assertGe(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17 + 1), 3e17, "just above target >= yT");
        // With a meaningful offset the adjustment is non-zero and the spread is strict on both sides.
        assertLt(ydm.previewYieldShare(MarketState.FIXED_TERM, 4e17), 3e17, "0.1 below target < yT");
        assertGt(ydm.previewYieldShare(MarketState.FIXED_TERM, 6e17), 3e17, "0.1 above target > yT");
    }

    /// The curve is monotone non-decreasing across the swept utilization boundaries
    function test_PreviewYieldShare_MonotoneNonDecreasing() public {
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
    function test_PreviewYieldShare_RegionSpreadSign() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        // below: Δ=(1e17-5e17)/5e17=-0.8 => adj=-0.8*FD=-1.6e17 => 3e17-1.6e17=1.4e17
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 1e17), 14e16, "below target: yT + nd*FD");
        // above: Delta=(9e17-5e17)/5e17=0.8 => adj=0.8*FP=4.8e17 => 3e17+4.8e17=7.8e17
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 9e17), 78e16, "above target: yT + nd*FP");
    }

    /// A second shape on a non-half target confirms the exact additive anchors.
    function test_PreviewYieldShare_SecondCurveAnchors() public {
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

    /**
     * @notice Extra wei-exact literal anchors on both sides of the canonical kink, worked out with plain
     *         arithmetic (never the model's fixed-point ops), so an arithmetic bug shared between the contract
     *         and the fuzz mirror still trips a hand number
     */
    function test_PreviewYieldShare_CanonicalCurveExtraLiteralAnchors() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        // Below the kink the discount leg applies: Y = yT + Δ*FD with FD = 2e17:
        //   U=2e17: Δ = (0.2-0.5)/0.5 = -0.6 => 3e17 - 1.2e17 = 1.8e17
        //   U=4e17: Δ = -0.2                 => 3e17 - 0.4e17 = 2.6e17
        _assertBothStatesFirstCall(ydm, 2e17, 18e16);
        _assertBothStatesFirstCall(ydm, 4e17, 26e16);
        // Above the kink the premium leg applies: Y = yT + Δ*FP with FP = 6e17:
        //   U=6e17: Δ = (0.6-0.5)/(1-0.5) = 0.2 => 3e17 + 1.2e17 = 4.2e17
        //   U=8e17: Δ = 0.6                     => 3e17 + 3.6e17 = 6.6e17
        _assertBothStatesFirstCall(ydm, 6e17, 42e16);
        _assertBothStatesFirstCall(ydm, 8e17, 66e16);
    }

    /**
     * @notice A low-kink curve (target well below half) pins the kink and one point per region as hand literals,
     *         so the additive shape is anchored where the two normalization denominators are far apart (0.2 below,
     *         0.8 above) and a swapped-denominator bug cannot cancel out
     */
    function test_PreviewYieldShare_LowKinkCurveLiteralAnchors() public {
        // target=0.2, y0=5e16, yT=25e16, yFull=85e16 => FD=2e17, FP=6e17
        AdaptiveCurveYDM_V2 ydm = _deploy(2e17);
        ydm.initializeYDMForMarket(5e16, 25e16, 85e16);
        // Kink: Y(target) == yT with no adaptation possible on a first call
        _assertBothStatesFirstCall(ydm, 2e17, 25e16);
        // Below: U=1e17: Δ = (0.1-0.2)/0.2 = -0.5 => 25e16 - 0.5*2e17 = 15e16
        _assertBothStatesFirstCall(ydm, 1e17, 15e16);
        // Above: U=6e17: Δ = (0.6-0.2)/0.8 = 0.5 => 25e16 + 0.5*6e17 = 55e16
        _assertBothStatesFirstCall(ydm, 6e17, 55e16);
    }

    // =====================================================================
    // Target-utilization boundary coverage (fresh model per target)
    // =====================================================================

    /// Y(target)==yT, Y(0)==y0, Y(WAD)==yFull hold exactly for every representative target.
    function test_PreviewYieldShare_TargetSweep_ExactAnchors() public {
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
    // Adaptation up and down over warps (exact via the mirror)
    // =====================================================================

    /// First PERPETUAL call never adapts (lastTs starts at 0 => elapsed 0), but it stamps lastTs.
    function test_YieldShare_FirstCallNoAdaptation_StampsTimestamp() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        vm.warp(1_000_000);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // high util, but elapsed==0
        (uint64 yT, uint32 lastTs,,) = _readCurve(ydm, address(this));
        assertEq(yT, 3e17, "yT unchanged on first call");
        assertEq(lastTs, 1_000_000, "lastTs stamped to block.timestamp");
    }

    /// Sustained over-target utilization adapts yT up: output and persisted yT match the independent mirror exactly
    function test_YieldShare_AdaptationUp_IncreasesYieldShareAtTarget() public {
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

    /// Sustained zero utilization adapts yT down: output and persisted yT match the independent mirror exactly
    function test_YieldShare_AdaptationDown_DecreasesYieldShareAtTarget() public {
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
    function test_YieldShare_ParkedAtTarget_NeverAdapts() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, 5e17);
        vm.warp(start + 3650 days);
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, 5e17), 3e17, "Y(target) still yT after long warp");
        (uint64 yT,,,) = _readCurve(ydm, address(this));
        assertEq(yT, 3e17, "yT unchanged at target");
    }

    /**
     * @notice Adversarial boundary parking: holding utilization at exactly target + 1 wei freezes adaptation
     *         forever, because the adaptation speed floors to zero before it is scaled by elapsed time
     * @dev speed = SPEED_V2 * nd / WAD with nd = 1 * WAD / (WAD - 5e17) = 2, so speed = floor(3170979198376 * 2
     *      / 1e18) = 0 and the linear factor is 0 for ANY elapsed time. The payout is the fixed additive point:
     *      yT + nd * FP / WAD = 3e17 + 2 * 6e17 / 1e18 = 3e17 + 1 — one extra wei of utilization buys one wei
     *      of yield share and zero curve movement, so the kink cannot be farmed
     */
    function test_YieldShare_ParkedOneWeiAboveTarget_AdaptationFloorsToZero() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, 5e17 + 1); // stamp lastTs
        vm.warp(start + 3650 days);
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, 5e17 + 1), 3e17 + 1, "the fixed curve point one wei above the kink");
        (uint64 yT, uint32 lastTs,,) = _readCurve(ydm, address(this));
        assertEq(yT, 3e17, "a floored-to-zero speed must never move yT, even over ten years");
        assertEq(lastTs, start + 3650 days, "lastTs still restamps on every mutating call");
    }

    /// FIXED_TERM never adapts yT even across warps, though it still restamps lastTs.
    function test_YieldShare_FixedTermNeverAdapts() public {
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
    function test_PreviewYieldShare_StatesDivergeAfterWarp() public {
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
    // Long-dormancy saturation and signed output clamps (no revert)
    // =====================================================================

    /// Sustained high util drives yT to MAX_YT (WAD). No overflow despite huge linear factor.
    function test_YieldShare_LongDormancyUp_SaturatesToMaxYieldShare() public {
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
    function test_YieldShare_LongDormancyDown_SaturatesToMinYieldShare() public {
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
    function test_YieldShare_SignedOutputClampsToZero() public {
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
    function test_YieldShare_SignedOutputClampsToWad() public {
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

    /**
     * @notice Down-dormancy clamp literals: ten years parked at zero utilization lands the persisted yield share
     *         at target exactly on the MIN clamp, zero-floors the clamping call's payout, and afterwards the fixed
     *         spreads ride on the clamped floor — all hand numbers, derivable without the exponential because e^x
     *         underflows to zero wei at this horizon
     * @dev Economically: the additive discount FD = 2e17 dwarfs the clamped floor 1e14 at zero utilization, so the
     *      pool earns nothing while idle, yet the moment utilization crosses the kink the full fixed premium is
     *      restored on top of the floor — the spread never decays with the curve
     */
    function test_YieldShare_DormancyDownClampLiteralAnchors() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, 0); // stamp only (elapsed 0, curve untouched)
        vm.warp(start + 3650 days);
        // Δ = -1 => the linear factor is about -5.0e20 and its half about -2.5e20, both far below expWad's
        // zero-underflow threshold, so the end and midpoint yield-shares-at-target both clamp to MIN = 1e14.
        // Trapezoid blend: (3e17 + 1e14 + 2*1e14) / 4 = 300300000000000000 / 4 = 75075000000000000.
        // Payout at U=0: 75075000000000000 - FD (2e17) is negative => zero-floored output.
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 0, "the clamping call zero-floors the payout");
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, 0), 0, "yieldShare pays the same zero-floored literal");
        (uint64 yT,,,) = _readCurve(ydm, address(this));
        assertEq(yT, 1e14, "the persisted yield share at target lands exactly on the MIN clamp");
        // Same block (elapsed 0, no further adaptation): the kink pays exactly the clamp floor, and above the
        // kink the FIXED premium spread rides on it: U=75e16 => 1e14 + 0.5*6e17 = 300100000000000000
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 5e17), 1e14, "the kink now pays exactly MIN");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 75e16), 300_100_000_000_000_000, "above the kink the fixed spread rides on the clamped floor");
    }

    /**
     * @notice Up-dormancy clamp literals: ten years parked at full utilization lands the persisted yield share at
     *         target exactly on the MAX clamp (WAD) and WAD-caps the payout — hand numbers, since the clamped
     *         exponent e^{135.3} dwarfs 1/0.3 and saturates both trapezoid samples to MAX
     * @dev Economically: even a maximally adapted curve cannot promise more than 100% of the senior gain, and
     *      below the kink the fixed discount still bites, so zero utilization pays exactly WAD - FD
     */
    function test_YieldShare_DormancyUpClampLiteralAnchors() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        uint256 start = 1_000_000;
        vm.warp(start);
        ydm.yieldShare(MarketState.PERPETUAL, WAD); // stamp only
        vm.warp(start + 3650 days);
        // Both trapezoid samples clamp to MAX = WAD, so the blend is (3e17 + 1e18 + 2e18) / 4 = 825000000000000000.
        // Payout at U=WAD: 825000000000000000 + FP (6e17) = 1.425e18 >= WAD => capped to WAD exactly.
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, WAD), WAD, "the clamping call caps the payout at WAD");
        assertEq(ydm.yieldShare(MarketState.PERPETUAL, WAD), WAD, "yieldShare pays the same capped literal");
        (uint64 yT,,,) = _readCurve(ydm, address(this));
        assertEq(uint256(yT), WAD, "the persisted yield share at target lands exactly on the MAX clamp");
        // Same block: the kink pays exactly the clamp ceiling, and below the kink the fixed discount still
        // bites: U=0 => 1e18 - 2e17 = 8e17
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 5e17), WAD, "the kink now pays exactly MAX");
        assertEq(ydm.previewYieldShare(MarketState.PERPETUAL, 0), 8e17, "zero utilization pays exactly WAD minus the fixed discount");
    }

    /// Extremely long dormancy still returns and stays bounded (mirror parity at the clamp regime).
    function test_YieldShare_LongDormancyClampRegime_MatchesMirror() public {
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
    // Preview/mutate parity, non-persistence, events
    // =====================================================================

    /// preview never mutates the stored curve (checked with a pending adaptation available).
    function test_PreviewYieldShare_DoesNotPersistPendingAdaptation() public {
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
    function test_PreviewYieldShare_EqualsYieldShareSameBlock() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
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
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        vm.expectEmit(true, true, true, true, address(ydm));
        emit AdaptiveCurveYdmInitialized(address(this), 2e17, 3e17, 6e17);
        ydm.initializeYDMForMarket(1e17, 3e17, 9e17);
    }

    /// On the first call (elapsed 0) at U=target, output==yT and newYT==yT: exact event payload.
    function test_YieldShare_EmitsYdmAdaptedOutput_FirstCall() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        vm.warp(1_000_000);
        vm.expectEmit(true, true, true, true, address(ydm));
        emit YdmAdaptedOutput(address(this), 3e17, 3e17); // avg output == yT, newYT == yT
        ydm.yieldShare(MarketState.PERPETUAL, 5e17);
    }

    /// The preview path is silent: no logs, so off-chain quoting cannot be mistaken for a mutation
    function test_PreviewYieldShare_EmitsNothing() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
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

    /// A failed re-initialization must leave the previous curve byte-identical
    function test_RevertIf_ReinitializeInvalid_PreservesCurve() public {
        AdaptiveCurveYDM_V2 ydm = _canonical();
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        ydm.initializeYDMForMarket(1e17, 5e17, 3e17); // yT > yFull
        (uint64 yT,, uint64 discount, uint64 premium) = _readCurve(ydm, address(this));
        assertEq(yT, 3e17, "yT intact after failed reinit");
        assertEq(discount, 2e17, "FD intact after failed reinit");
        assertEq(premium, 6e17, "FP intact after failed reinit");
    }

    /// Curves are keyed by msg.sender: two accountants on one model never read each other's parameters
    function test_YieldShare_PerAccountantCurveIsolation() public {
        AdaptiveCurveYDM_V2 ydm = _deploy(5e17);
        ydm.initializeYDMForMarket(1e17, 3e17, 9e17); // this: Y(target)=3e17
        vm.prank(ACCT_B);
        ydm.initializeYDMForMarket(1e17, 1e17, 3e17); // B: Y(target)=1e17

        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17), 3e17, "this curve");
        vm.prank(ACCT_B);
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, 5e17), 1e17, "B curve");
    }

    /// Adaptation is per-accountant: warping and adapting `this` leaves B's curve untouched.
    function test_YieldShare_PerAccountantAdaptationIsolation() public {
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
    function testFuzz_YieldShare_FirstCallBoundedAndMatchesMirror(uint256 t, uint256 z, uint256 a, uint256 b, uint256 u) public {
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
    function testFuzz_PreviewYieldShare_ExactAnchors(uint256 t, uint256 z, uint256 a, uint256 b) public {
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
    function testFuzz_PreviewYieldShare_MonotoneNonDecreasing(uint256 t, uint256 z, uint256 a, uint256 b, uint256 u1, uint256 u2) public {
        Cfg memory cfg = _cfg(t, z, a, b);
        AdaptiveCurveYDM_V2 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);
        if (u1 > u2) (u1, u2) = (u2, u1);
        uint256 y1 = ydm.previewYieldShare(MarketState.FIXED_TERM, u1);
        uint256 y2 = ydm.previewYieldShare(MarketState.FIXED_TERM, u2);
        assertLe(y1, y2, "U1<=U2 => Y1<=Y2");
    }

    /// Saturation: Y(U)==Y(WAD) for all U>=WAD. No overflow at full uint256.
    function testFuzz_PreviewYieldShare_SaturatesAboveWad(uint256 t, uint256 z, uint256 a, uint256 b, uint256 uOver) public {
        Cfg memory cfg = _cfg(t, z, a, b);
        AdaptiveCurveYDM_V2 ydm = _deploy(cfg.target);
        ydm.initializeYDMForMarket(cfg.y0, cfg.yT, cfg.yFull);
        uOver = bound(uOver, WAD, type(uint256).max);
        assertEq(ydm.previewYieldShare(MarketState.FIXED_TERM, uOver), ydm.previewYieldShare(MarketState.FIXED_TERM, WAD), "saturates at WAD");
    }

    /// Adaptation parity: after stamping and warping, preview==mirror and yieldShare persists newYT.
    /// Also asserts the canonical invariants (Y<=WAD, no revert) across fuzzed time and util.
    function testFuzz_YieldShare_AdaptationMatchesMirror(uint256 t, uint256 z, uint256 a, uint256 b, uint256 u, uint256 startRaw, uint256 dtRaw) public {
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
    function testFuzz_YieldShare_AdaptationDirection(uint256 t, uint256 z, uint256 a, uint256 b, uint256 dtRaw) public {
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
    function testFuzz_PreviewYieldShare_DoesNotPersist(uint256 t, uint256 z, uint256 a, uint256 b, uint256 u, uint256 dtRaw) public {
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
