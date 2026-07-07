// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Vm } from "../../../lib/forge-std/src/Vm.sol";
import { IYDM } from "../../../src/interfaces/IYDM.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { MarketState } from "../../../src/libraries/Types.sol";
import { AdaptiveCurveYDM_V1 } from "../../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { MockAdaptiveCurveYDM } from "../../mocks/MockAdaptiveCurveYDM.sol";

/**
 * @title Test_BaseAdaptiveCurveYDM
 * @notice Unit and fuzz tests for the shared adaptive-curve base machinery. Stateful invariant coverage
 *         lives in test/invariant/Invariant_YDM.t.sol.
 * @dev Focus is the SHARED base behavior, exercised through the mock (for the base constructor gate
 *      that V1/V2 cannot reach because they hardcode min/max/speed) and through V1/V2 (for the base
 *      capping, uninitialized gate, and immutable getters that the concrete models inherit verbatim).
 */
contract Test_BaseAdaptiveCurveYDM is Test {
    // Base-defined limits / bounds, mirrored from source (never read back from the contract to build an expectation).
    uint256 constant SPEED_LIMIT = 100e18 / uint256(365 days); // MAX_ADAPTATION_SPEED_LIMIT_WAD
    uint256 constant SPEED_V1 = 50e18 / uint256(365 days);
    uint256 constant SPEED_V2 = 100e18 / uint256(365 days);
    uint256 constant MIN_YT = 0.0001e18; // 1e14
    uint256 constant MAX_YT = WAD;

    address constant ACCT_B = address(0xB0B);

    // Baseline valid mock params (target = 0.5, full bound span, half-limit speed).
    function _mock(uint256 minY, uint256 maxY, uint256 speed) internal returns (MockAdaptiveCurveYDM) {
        return new MockAdaptiveCurveYDM(5e17, minY, maxY, speed);
    }

    function _mockTarget(uint256 target) internal returns (MockAdaptiveCurveYDM) {
        return new MockAdaptiveCurveYDM(target, MIN_YT, MAX_YT, SPEED_LIMIT);
    }

    // =====================================================================
    // Base constructor parameter gate (via the mock)
    // require: min>0 && min<=max && max<=WAD && speed>0 && speed<=LIMIT ; plus the BaseYDM target in (0,WAD]
    // =====================================================================

    /// A fully valid parameter set stores every immutable verbatim
    function test_Constructor_ValidParams_SetsAllImmutables() public {
        MockAdaptiveCurveYDM m = new MockAdaptiveCurveYDM(3e17, 2e14, 8e17, SPEED_V1);
        assertEq(m.TARGET_UTILIZATION_WAD(), 3e17, "target");
        assertEq(m.MIN_YIELD_SHARE_AT_TARGET_WAD(), 2e14, "min");
        assertEq(m.MAX_YIELD_SHARE_AT_TARGET_WAD(), 8e17, "max");
        assertEq(m.MAX_ADAPTATION_SPEED_WAD(), SPEED_V1, "speed");
        assertEq(m.MAX_ADAPTATION_SPEED_LIMIT_WAD(), SPEED_LIMIT, "limit constant");
    }

    // --- min bound ---

    /// A zero minimum yield-share-at-target is rejected: the adaptation clamp needs a positive floor
    function test_RevertIf_ConstructorMinYieldShareZero() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mock(0, MAX_YT, SPEED_LIMIT);
    }

    /// min == max pins the curve to a single yield-share-at-target and is accepted
    function test_Constructor_MinEqualsMax() public {
        // A degenerate-but-valid clamp: min == max collapses the adaptation range to a point, turning the
        // adaptive model into a fixed-premium one. Deployers may legitimately want a non-adapting premium,
        // so the gate must accept equality rather than require strict min < max.
        MockAdaptiveCurveYDM m = _mock(3e17, 3e17, SPEED_LIMIT);
        assertEq(m.MIN_YIELD_SHARE_AT_TARGET_WAD(), 3e17);
        assertEq(m.MAX_YIELD_SHARE_AT_TARGET_WAD(), 3e17);
    }

    /// min above max is an empty clamp range and rejected
    function test_RevertIf_ConstructorMinAboveMax() public {
        // min > max leaves NO value the adaptation clamp could return: every adapted yield-share would be
        // simultaneously below the floor and above the ceiling, so any curve built this way is unusable
        // from the first sync. The gate must reject it at deploy rather than let a market wire a dead model.
        // 3e17 + 1 is the tightest violation, one wei past the accepted min == max boundary.
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mock(3e17 + 1, 3e17, SPEED_LIMIT);
    }

    /// One wei is the smallest accepted clamp floor
    function test_Constructor_MinOneWei() public {
        // The gate requires only min > 0 (a positive floor keeps the premium from adapting to exactly zero
        // and permanently switching the junior payment off), so the 1-wei floor -- economically negligible
        // but strictly positive -- must pass, pinning the boundary exactly one wei above the rejected zero.
        MockAdaptiveCurveYDM m = _mock(1, MAX_YT, SPEED_LIMIT);
        assertEq(m.MIN_YIELD_SHARE_AT_TARGET_WAD(), 1);
    }

    // --- max bound ---

    /// The clamp ceiling may sit exactly at WAD
    function test_Constructor_MaxAtWad() public {
        MockAdaptiveCurveYDM m = _mock(MIN_YT, WAD, SPEED_LIMIT);
        assertEq(m.MAX_YIELD_SHARE_AT_TARGET_WAD(), WAD);
    }

    /// A clamp ceiling above WAD could pay more than the whole gain and is rejected
    function test_RevertIf_ConstructorMaxAboveWad() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mock(MIN_YT, WAD + 1, SPEED_LIMIT);
    }

    /// The extreme uint256 max ceiling is rejected by the same gate
    function test_RevertIf_ConstructorMaxUintMax() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mock(MIN_YT, type(uint256).max, SPEED_LIMIT);
    }

    // --- speed bound (the base's headline test: (0, LIMIT]) ---

    /// A zero adaptation speed would freeze the curve permanently and is rejected
    function test_RevertIf_ConstructorSpeedZero() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mock(MIN_YT, MAX_YT, 0);
    }

    /// The adaptation speed may sit exactly at the deploy-time limit
    function test_Constructor_SpeedAtLimit() public {
        MockAdaptiveCurveYDM m = _mock(MIN_YT, MAX_YT, SPEED_LIMIT);
        assertEq(m.MAX_ADAPTATION_SPEED_WAD(), SPEED_LIMIT, "speed == limit accepted");
    }

    /// One wei above the adaptation speed limit is rejected
    function test_RevertIf_ConstructorSpeedOverLimit() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mock(MIN_YT, MAX_YT, SPEED_LIMIT + 1);
    }

    /// The extreme uint256 max speed is rejected by the same gate
    function test_RevertIf_ConstructorSpeedUintMax() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mock(MIN_YT, MAX_YT, type(uint256).max);
    }

    /// One wei is the smallest accepted adaptation speed
    function test_Constructor_SpeedOneWei() public {
        MockAdaptiveCurveYDM m = _mock(MIN_YT, MAX_YT, 1);
        assertEq(m.MAX_ADAPTATION_SPEED_WAD(), 1);
    }

    // --- target bound (BaseYDM gate, evaluated in the parent constructor) ---

    /// A zero target utilization is rejected: the curve needs a positive kink to interpolate around
    function test_RevertIf_ConstructorTargetZero() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mockTarget(0);
    }

    /// One wei is the smallest accepted target utilization
    function test_Constructor_TargetOneWei() public {
        MockAdaptiveCurveYDM m = _mockTarget(1);
        assertEq(m.TARGET_UTILIZATION_WAD(), 1);
    }

    /// target == WAD (full utilization) is an accepted boundary
    function test_Constructor_TargetAtWad() public {
        MockAdaptiveCurveYDM m = _mockTarget(WAD);
        assertEq(m.TARGET_UTILIZATION_WAD(), WAD);
    }

    /// A target above WAD is meaningless (utilization is capped at WAD) and rejected
    function test_RevertIf_ConstructorTargetAboveWad() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mockTarget(WAD + 1);
    }

    /// The extreme uint256 max target is rejected by the same gate
    function test_RevertIf_ConstructorTargetUintMax() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mockTarget(type(uint256).max);
    }

    // =====================================================================
    // The immutable getters return the values V1/V2 forward to the base
    // =====================================================================

    /// V1 forwards its hardcoded (min, max, speed) triple to the base and the getters return it verbatim
    function test_ImmutableGetters_V1() public {
        AdaptiveCurveYDM_V1 y = new AdaptiveCurveYDM_V1(7e17);
        assertEq(y.TARGET_UTILIZATION_WAD(), 7e17, "V1 target");
        assertEq(y.MIN_YIELD_SHARE_AT_TARGET_WAD(), MIN_YT, "V1 min");
        assertEq(y.MAX_YIELD_SHARE_AT_TARGET_WAD(), MAX_YT, "V1 max");
        assertEq(y.MAX_ADAPTATION_SPEED_WAD(), SPEED_V1, "V1 speed == 50e18/365d");
        assertEq(y.MAX_ADAPTATION_SPEED_LIMIT_WAD(), SPEED_LIMIT, "limit constant");
    }

    /// V2 forwards its hardcoded (min, max, speed) triple to the base and the getters return it verbatim
    function test_ImmutableGetters_V2() public {
        AdaptiveCurveYDM_V2 y = new AdaptiveCurveYDM_V2(2e17);
        assertEq(y.TARGET_UTILIZATION_WAD(), 2e17, "V2 target");
        assertEq(y.MIN_YIELD_SHARE_AT_TARGET_WAD(), MIN_YT, "V2 min");
        assertEq(y.MAX_YIELD_SHARE_AT_TARGET_WAD(), MAX_YT, "V2 max");
        assertEq(y.MAX_ADAPTATION_SPEED_WAD(), SPEED_V2, "V2 speed == 100e18/365d (== limit)");
        assertEq(y.MAX_ADAPTATION_SPEED_LIMIT_WAD(), SPEED_LIMIT, "limit constant");
    }

    /// V2 adapts at exactly the deploy-time speed limit
    function test_ImmutableGetters_V2SpeedSitsAtLimit() public {
        AdaptiveCurveYDM_V2 y = new AdaptiveCurveYDM_V2(5e17);
        assertEq(y.MAX_ADAPTATION_SPEED_WAD(), y.MAX_ADAPTATION_SPEED_LIMIT_WAD(), "V2 sits exactly at the limit");
    }

    /// V1 adapts at exactly half the deploy-time speed limit
    function test_ImmutableGetters_V1SpeedIsHalfLimit() public {
        AdaptiveCurveYDM_V1 y = new AdaptiveCurveYDM_V1(5e17);
        assertEq(y.MAX_ADAPTATION_SPEED_WAD() * 2, y.MAX_ADAPTATION_SPEED_LIMIT_WAD(), "V1 is half the limit");
    }

    // =====================================================================
    // Uninitialized market reverts on BOTH entrypoints (base gate)
    // =====================================================================

    /// previewYieldShare for a never-initialized accountant reverts (base gate, via the mock)
    function test_RevertIf_PreviewYieldShareUninitialized_Mock() public {
        MockAdaptiveCurveYDM m = _mock(MIN_YT, MAX_YT, SPEED_LIMIT);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        m.previewYieldShare(MarketState.PERPETUAL, 0);
    }

    /// yieldShare for a never-initialized accountant reverts (base gate, via the mock)
    function test_RevertIf_YieldShareUninitialized_Mock() public {
        MockAdaptiveCurveYDM m = _mock(MIN_YT, MAX_YT, SPEED_LIMIT);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        m.yieldShare(MarketState.PERPETUAL, 5e17);
    }

    /// previewYieldShare for a never-initialized accountant reverts on V1
    function test_RevertIf_PreviewYieldShareUninitialized_V1() public {
        AdaptiveCurveYDM_V1 y = new AdaptiveCurveYDM_V1(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        y.previewYieldShare(MarketState.FIXED_TERM, type(uint256).max);
    }

    /// yieldShare for a never-initialized accountant reverts on V1
    function test_RevertIf_YieldShareUninitialized_V1() public {
        AdaptiveCurveYDM_V1 y = new AdaptiveCurveYDM_V1(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        y.yieldShare(MarketState.PERPETUAL, 0);
    }

    /// previewYieldShare for a never-initialized accountant reverts on V2
    function test_RevertIf_PreviewYieldShareUninitialized_V2() public {
        AdaptiveCurveYDM_V2 y = new AdaptiveCurveYDM_V2(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        y.previewYieldShare(MarketState.PERPETUAL, WAD);
    }

    /// yieldShare for a never-initialized accountant reverts on V2
    function test_RevertIf_YieldShareUninitialized_V2() public {
        AdaptiveCurveYDM_V2 y = new AdaptiveCurveYDM_V2(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        y.yieldShare(MarketState.FIXED_TERM, 3e17);
    }

    /// mapping is keyed by msg.sender: this-init'd, B still uninitialized => reverts.
    function test_RevertIf_YieldShareQueriedByUninitializedAccountant() public {
        AdaptiveCurveYDM_V1 y = new AdaptiveCurveYDM_V1(5e17);
        y.initializeYDMForMarket(uint64(1e17), uint64(5e17));
        vm.prank(ACCT_B);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        y.yieldShare(MarketState.PERPETUAL, 0);
    }

    // =====================================================================
    // Base utilization capping to WAD
    // On a FIXED_TERM (non-adapting) curve the output is time-independent, so any util above WAD
    // must resolve identically to WAD: the base caps _utilizationWAD before shaping the curve.
    // =====================================================================

    function _v1(uint256 target, uint64 yT, uint64 yFull) internal returns (AdaptiveCurveYDM_V1 y) {
        y = new AdaptiveCurveYDM_V1(target);
        y.initializeYDMForMarket(yT, yFull);
    }

    function _v2(uint256 target, uint64 y0, uint64 yT, uint64 yFull) internal returns (AdaptiveCurveYDM_V2 y) {
        y = new AdaptiveCurveYDM_V2(target);
        y.initializeYDMForMarket(y0, yT, yFull);
    }

    /// The base caps utilization to WAD before shaping the V1 curve (time-independent under FIXED_TERM)
    function test_PreviewYieldShare_UtilizationCappedToWad_V1FixedTerm() public {
        AdaptiveCurveYDM_V1 y = _v1(8e17, uint64(3e17), uint64(9e17));
        uint256 atWad = y.previewYieldShare(MarketState.FIXED_TERM, WAD);
        assertEq(y.previewYieldShare(MarketState.FIXED_TERM, WAD + 1), atWad, "WAD+1 caps to WAD");
        assertEq(y.previewYieldShare(MarketState.FIXED_TERM, 2 * WAD), atWad, "2*WAD caps to WAD");
        assertEq(y.previewYieldShare(MarketState.FIXED_TERM, type(uint256).max), atWad, "uint256 max caps to WAD");
    }

    /// The base caps utilization to WAD before shaping the V2 curve (time-independent under FIXED_TERM)
    function test_PreviewYieldShare_UtilizationCappedToWad_V2FixedTerm() public {
        AdaptiveCurveYDM_V2 y = _v2(3e17, uint64(1e17), uint64(4e17), uint64(9e17));
        uint256 atWad = y.previewYieldShare(MarketState.FIXED_TERM, WAD);
        assertEq(y.previewYieldShare(MarketState.FIXED_TERM, WAD + 1), atWad, "WAD+1 caps to WAD");
        assertEq(y.previewYieldShare(MarketState.FIXED_TERM, type(uint256).max), atWad, "uint256 max caps to WAD");
    }

    /// The capping holds under the mutating entrypoint too (FIXED_TERM does not adapt yT, so no drift).
    function test_YieldShare_UtilizationCappedToWad_V1FixedTerm() public {
        AdaptiveCurveYDM_V1 y = _v1(8e17, uint64(3e17), uint64(9e17));
        uint256 a = y.yieldShare(MarketState.FIXED_TERM, WAD);
        uint256 b = y.yieldShare(MarketState.FIXED_TERM, type(uint256).max);
        assertEq(a, b, "mutate: WAD == max under FIXED_TERM");
    }

    // =====================================================================
    // Base output is bounded by WAD everywhere (unit spot checks)
    // =====================================================================

    /// V1 output never exceeds WAD, including the flat-at-ceiling curve and uint256 max utilization
    function test_PreviewYieldShare_OutputBoundedByWad_V1Extremes() public {
        // Steep curve reaching full util at WAD.
        AdaptiveCurveYDM_V1 y = _v1(5e17, uint64(5e17), uint64(WAD));
        assertLe(y.previewYieldShare(MarketState.PERPETUAL, WAD), WAD, "V1 Y(WAD) <= WAD");
        assertLe(y.previewYieldShare(MarketState.PERPETUAL, type(uint256).max), WAD, "V1 Y(max) <= WAD");
        // Flat at ceiling: yT == yFull == WAD => Y == WAD everywhere.
        AdaptiveCurveYDM_V1 f = _v1(5e17, uint64(WAD), uint64(WAD));
        assertEq(f.previewYieldShare(MarketState.PERPETUAL, 0), WAD, "flat ceiling @0");
        assertEq(f.previewYieldShare(MarketState.PERPETUAL, type(uint256).max), WAD, "flat ceiling @max");
    }

    /// V2 output never exceeds WAD, including at uint256 max utilization, and honors y0 at zero
    function test_PreviewYieldShare_OutputBoundedByWad_V2Extremes() public {
        AdaptiveCurveYDM_V2 y = _v2(5e17, uint64(0), uint64(5e17), uint64(WAD));
        assertLe(y.previewYieldShare(MarketState.PERPETUAL, WAD), WAD, "V2 Y(WAD) <= WAD");
        assertLe(y.previewYieldShare(MarketState.PERPETUAL, type(uint256).max), WAD, "V2 Y(max) <= WAD");
        assertEq(y.previewYieldShare(MarketState.PERPETUAL, 0), 0, "V2 y0 == 0 at U=0");
    }

    // =====================================================================
    // Anchor: at U == target both models return yT (delta == 0 in the base)
    // =====================================================================

    /// At U == target the normalized delta is zero, so V1 returns exactly yT in both states
    function test_PreviewYieldShare_AtTargetReturnsYT_V1() public {
        AdaptiveCurveYDM_V1 y = _v1(8e17, uint64(3e17), uint64(9e17));
        assertEq(y.previewYieldShare(MarketState.FIXED_TERM, 8e17), 3e17, "V1 Y(target) == yT");
        assertEq(y.previewYieldShare(MarketState.PERPETUAL, 8e17), 3e17, "V1 Y(target) == yT (fresh, elapsed 0)");
    }

    /// At U == target the normalized delta is zero, so V2 returns exactly yT in both states
    function test_PreviewYieldShare_AtTargetReturnsYT_V2() public {
        AdaptiveCurveYDM_V2 y = _v2(3e17, uint64(1e17), uint64(4e17), uint64(9e17));
        assertEq(y.previewYieldShare(MarketState.FIXED_TERM, 3e17), 4e17, "V2 Y(target) == yT");
        assertEq(y.previewYieldShare(MarketState.PERPETUAL, 3e17), 4e17, "V2 Y(target) == yT (fresh, elapsed 0)");
    }

    // =====================================================================
    // Preview/mutate parity and preview non-persistence (base flow)
    // On a fresh curve (lastAdaptationTimestamp == 0) elapsed == 0, so PERPETUAL and FIXED_TERM
    // coincide and preview == yieldShare. preview must not touch storage.
    // =====================================================================

    /// On a fresh V1 curve preview equals yieldShare, both states coincide, and preview writes nothing
    function test_PreviewYieldShare_ParityAndNonPersistence_V1() public {
        AdaptiveCurveYDM_V1 y = _v1(8e17, uint64(3e17), uint64(9e17));
        (uint64 yt0, uint32 ts0, uint160 st0) = y.accountantToCurve(address(this));

        uint256 p = y.previewYieldShare(MarketState.PERPETUAL, 6e17);

        // preview persisted nothing
        (uint64 yt1, uint32 ts1, uint160 st1) = y.accountantToCurve(address(this));
        assertEq(yt0, yt1, "preview did not change yT");
        assertEq(ts0, ts1, "preview did not change timestamp");
        assertEq(st0, st1, "preview did not change steepness");

        // both states agree on a fresh curve, and mutate == preview
        assertEq(p, y.previewYieldShare(MarketState.FIXED_TERM, 6e17), "PERPETUAL == FIXED_TERM (fresh)");
        assertEq(p, y.yieldShare(MarketState.PERPETUAL, 6e17), "mutate == preview");
    }

    /// On a fresh V2 curve preview equals yieldShare, both states coincide, and preview writes nothing
    function test_PreviewYieldShare_ParityAndNonPersistence_V2() public {
        AdaptiveCurveYDM_V2 y = _v2(3e17, uint64(1e17), uint64(4e17), uint64(9e17));
        (uint64 yt0, uint32 ts0,,) = y.accountantToCurve(address(this));

        uint256 p = y.previewYieldShare(MarketState.PERPETUAL, 5e17);

        (uint64 yt1, uint32 ts1,,) = y.accountantToCurve(address(this));
        assertEq(yt0, yt1, "preview did not change yT");
        assertEq(ts0, ts1, "preview did not change timestamp");

        assertEq(p, y.previewYieldShare(MarketState.FIXED_TERM, 5e17), "PERPETUAL == FIXED_TERM (fresh)");
        assertEq(p, y.yieldShare(MarketState.PERPETUAL, 5e17), "mutate == preview");
    }

    // =====================================================================
    // FUZZ — base capping, <= WAD bound, never-revert, parity across full uint256 utilization
    // and the full (0, WAD] target range, for both concrete models.
    // =====================================================================

    /// V1: fuzz target across (0, WAD], a valid steepness curve, and a full-range utilization.
    function testFuzz_YieldShare_BaseBoundsAndParity_V1(uint256 target, uint256 yT, uint256 yFull, uint256 u) public {
        target = bound(target, 1, WAD);
        yT = bound(yT, MIN_YT, MAX_YT);
        yFull = bound(yFull, yT, WAD);
        AdaptiveCurveYDM_V1 y = _v1(target, uint64(yT), uint64(yFull));

        // Never reverts on any util; bounded by WAD.
        uint256 pPerp = y.previewYieldShare(MarketState.PERPETUAL, u);
        uint256 pFixed = y.previewYieldShare(MarketState.FIXED_TERM, u);
        assertLe(pPerp, WAD, "V1 PERPETUAL <= WAD");
        assertLe(pFixed, WAD, "V1 FIXED_TERM <= WAD");

        // Base capping: any util resolves to its min(util, WAD) form (time-independent in FIXED_TERM).
        uint256 capped = u > WAD ? WAD : u;
        assertEq(pFixed, y.previewYieldShare(MarketState.FIXED_TERM, capped), "V1 base caps util to WAD");

        // Fresh curve: elapsed == 0 => PERPETUAL == FIXED_TERM and preview == mutate.
        assertEq(pPerp, pFixed, "V1 fresh: states coincide");
        assertEq(pPerp, y.yieldShare(MarketState.PERPETUAL, u), "V1 mutate == preview");
    }

    /// V2: same shape, additive curve, fuzzed discount/premium via y0.
    function testFuzz_YieldShare_BaseBoundsAndParity_V2(uint256 target, uint256 y0, uint256 yT, uint256 yFull, uint256 u) public {
        target = bound(target, 1, WAD);
        yT = bound(yT, MIN_YT, MAX_YT);
        y0 = bound(y0, 0, yT);
        yFull = bound(yFull, yT, WAD);
        AdaptiveCurveYDM_V2 y = _v2(target, uint64(y0), uint64(yT), uint64(yFull));

        uint256 pPerp = y.previewYieldShare(MarketState.PERPETUAL, u);
        uint256 pFixed = y.previewYieldShare(MarketState.FIXED_TERM, u);
        assertLe(pPerp, WAD, "V2 PERPETUAL <= WAD");
        assertLe(pFixed, WAD, "V2 FIXED_TERM <= WAD");

        uint256 capped = u > WAD ? WAD : u;
        assertEq(pFixed, y.previewYieldShare(MarketState.FIXED_TERM, capped), "V2 base caps util to WAD");

        assertEq(pPerp, pFixed, "V2 fresh: states coincide");
        assertEq(pPerp, y.yieldShare(MarketState.PERPETUAL, u), "V2 mutate == preview");
    }

    /// Base capping through the trivial mock isolates the cap from any concrete curve shape:
    /// the mock returns the (bounded) yT for every util, so every util maps to the same value and
    /// the call never reverts across the full uint256 range.
    function testFuzz_PreviewYieldShare_BaseCappingNeverReverts_Mock(uint256 target, uint256 yT, uint256 u) public {
        target = bound(target, 1, WAD);
        yT = bound(yT, MIN_YT, MAX_YT); // within [min,max] so it survives the base clamp
        MockAdaptiveCurveYDM m = _mockTarget(target);
        m.initFor(yT);

        uint256 y = m.previewYieldShare(MarketState.FIXED_TERM, u);
        assertLe(y, WAD, "mock <= WAD");
        assertEq(y, yT, "mock returns bounded yT regardless of (capped) util");
        assertEq(y, m.previewYieldShare(MarketState.PERPETUAL, u), "mock fresh: states coincide");
    }

    /// Fuzz the mock's constructor speed: (0, LIMIT] succeeds and records the speed. Outside reverts.
    function testFuzz_Constructor_SpeedBound(uint256 speed) public {
        if (speed == 0 || speed > SPEED_LIMIT) {
            vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
            _mock(MIN_YT, MAX_YT, speed);
        } else {
            MockAdaptiveCurveYDM m = _mock(MIN_YT, MAX_YT, speed);
            assertEq(m.MAX_ADAPTATION_SPEED_WAD(), speed, "in-range speed stored");
        }
    }

    /// Fuzz the mock's (min, max) pair: valid iff 0 < min <= max <= WAD.
    function testFuzz_Constructor_MinMaxBound(uint256 minY, uint256 maxY) public {
        bool valid = minY > 0 && minY <= maxY && maxY <= WAD;
        if (!valid) {
            vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
            _mock(minY, maxY, SPEED_LIMIT);
        } else {
            MockAdaptiveCurveYDM m = _mock(minY, maxY, SPEED_LIMIT);
            assertEq(m.MIN_YIELD_SHARE_AT_TARGET_WAD(), minY, "min stored");
            assertEq(m.MAX_YIELD_SHARE_AT_TARGET_WAD(), maxY, "max stored");
        }
    }
}
