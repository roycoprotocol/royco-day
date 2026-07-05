// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Vm } from "../../lib/forge-std/src/Vm.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { MarketState } from "../../src/libraries/Types.sol";
import { AdaptiveCurveYDM_V1 } from "../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { BaseAdaptiveCurveYDM } from "../../src/ydm/base/BaseAdaptiveCurveYDM.sol";

/**
 * @title MockAdaptiveCurveYDM
 * @notice Minimal concrete model that forwards ARBITRARY constructor parameters straight to the
 *         BaseAdaptiveCurveYDM constructor. V1 and V2 hardcode their (min, max, speed) triple, so
 *         this mock is the only way to exercise the base constructor's parameter gate across the
 *         full space (min == 0, min > max, max > WAD, speed == 0, speed > limit, speed == limit).
 * @dev The curve shape is deliberately trivial: `_computeYieldShare` returns the (already-bounded)
 *      time-averaged yield share at target, ignoring the delta. That keeps the mock's output a pure
 *      function of base machinery so the base behavior (capping, uninitialized gate, immutable
 *      getters) is what is under test, not a concrete curve.
 */
contract MockAdaptiveCurveYDM is BaseAdaptiveCurveYDM {
    mapping(address => uint256) public yAtTarget;
    mapping(address => uint256) public lastTs;

    constructor(uint256 _target, uint256 _minY, uint256 _maxY, uint256 _speed) BaseAdaptiveCurveYDM(_target, _minY, _maxY, _speed) { }

    /// @notice Seed a nonzero yield-share-at-target for msg.sender so the market reads as initialized.
    function initFor(uint256 _y) external {
        yAtTarget[msg.sender] = _y;
        lastTs[msg.sender] = 0;
    }

    function _computeYieldShare(int256, uint256 _avgYieldShareAtTargetWAD) internal pure override returns (uint256) {
        return _avgYieldShareAtTargetWAD;
    }

    function _readAdaptiveCurve() internal view override returns (uint256, uint256) {
        return (yAtTarget[msg.sender], lastTs[msg.sender]);
    }

    function _writeAdaptiveCurve(uint256 _newYieldShareAtTargetWAD, uint256) internal override {
        yAtTarget[msg.sender] = _newYieldShareAtTargetWAD;
        lastTs[msg.sender] = block.timestamp;
    }
}

/**
 * @title BaseAdaptiveCurveYDM unit + fuzz tests
 * @notice UNIT and FUZZ tests only. Invariant/Handler code lives in test/ydm/YDMInvariants.t.sol.
 * @dev Focus is the SHARED base behavior, exercised through the mock (for the base constructor gate
 *      that V1/V2 cannot reach because they hardcode min/max/speed) and through V1/V2 (for the base
 *      capping, uninitialized gate, and immutable getters that the concrete models inherit verbatim).
 */
contract BaseAdaptiveCurveYDMTest is Test {
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
    // Group A — base constructor parameter gate (via the mock)
    // require: min>0 && min<=max && max<=WAD && speed>0 && speed<=LIMIT ; plus BaseYDM target in (0,WAD]
    // =====================================================================

    function test_ctor_valid_setsAllImmutables() public {
        MockAdaptiveCurveYDM m = new MockAdaptiveCurveYDM(3e17, 2e14, 8e17, SPEED_V1);
        assertEq(m.TARGET_UTILIZATION_WAD(), 3e17, "target");
        assertEq(m.MIN_YIELD_SHARE_AT_TARGET_WAD(), 2e14, "min");
        assertEq(m.MAX_YIELD_SHARE_AT_TARGET_WAD(), 8e17, "max");
        assertEq(m.MAX_ADAPTATION_SPEED_WAD(), SPEED_V1, "speed");
        assertEq(m.MAX_ADAPTATION_SPEED_LIMIT_WAD(), SPEED_LIMIT, "limit constant");
    }

    // --- min bound ---

    function test_ctor_minZero_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mock(0, MAX_YT, SPEED_LIMIT);
    }

    function test_ctor_minEqMax_ok() public {
        MockAdaptiveCurveYDM m = _mock(3e17, 3e17, SPEED_LIMIT);
        assertEq(m.MIN_YIELD_SHARE_AT_TARGET_WAD(), 3e17);
        assertEq(m.MAX_YIELD_SHARE_AT_TARGET_WAD(), 3e17);
    }

    function test_ctor_minGtMax_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mock(3e17 + 1, 3e17, SPEED_LIMIT);
    }

    function test_ctor_minOne_ok() public {
        MockAdaptiveCurveYDM m = _mock(1, MAX_YT, SPEED_LIMIT);
        assertEq(m.MIN_YIELD_SHARE_AT_TARGET_WAD(), 1);
    }

    // --- max bound ---

    function test_ctor_maxEqWad_ok() public {
        MockAdaptiveCurveYDM m = _mock(MIN_YT, WAD, SPEED_LIMIT);
        assertEq(m.MAX_YIELD_SHARE_AT_TARGET_WAD(), WAD);
    }

    function test_ctor_maxGtWad_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mock(MIN_YT, WAD + 1, SPEED_LIMIT);
    }

    function test_ctor_maxMax_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mock(MIN_YT, type(uint256).max, SPEED_LIMIT);
    }

    // --- speed bound (the base's headline test: (0, LIMIT]) ---

    function test_ctor_speedZero_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mock(MIN_YT, MAX_YT, 0);
    }

    function test_ctor_speedAtLimit_ok() public {
        MockAdaptiveCurveYDM m = _mock(MIN_YT, MAX_YT, SPEED_LIMIT);
        assertEq(m.MAX_ADAPTATION_SPEED_WAD(), SPEED_LIMIT, "speed == limit accepted");
    }

    function test_ctor_speedOverLimit_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mock(MIN_YT, MAX_YT, SPEED_LIMIT + 1);
    }

    function test_ctor_speedMax_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mock(MIN_YT, MAX_YT, type(uint256).max);
    }

    function test_ctor_speedOne_ok() public {
        MockAdaptiveCurveYDM m = _mock(MIN_YT, MAX_YT, 1);
        assertEq(m.MAX_ADAPTATION_SPEED_WAD(), 1);
    }

    // --- target bound (BaseYDM gate, evaluated in the parent constructor) ---

    function test_ctor_targetZero_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mockTarget(0);
    }

    function test_ctor_targetOne_ok() public {
        MockAdaptiveCurveYDM m = _mockTarget(1);
        assertEq(m.TARGET_UTILIZATION_WAD(), 1);
    }

    function test_ctor_targetWad_ok() public {
        MockAdaptiveCurveYDM m = _mockTarget(WAD);
        assertEq(m.TARGET_UTILIZATION_WAD(), WAD);
    }

    function test_ctor_targetWadPlusOne_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mockTarget(WAD + 1);
    }

    function test_ctor_targetMax_reverts() public {
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        _mockTarget(type(uint256).max);
    }

    // =====================================================================
    // Group B — the immutable getters return the values V1/V2 forward to the base
    // =====================================================================

    function test_getters_v1() public {
        AdaptiveCurveYDM_V1 y = new AdaptiveCurveYDM_V1(7e17);
        assertEq(y.TARGET_UTILIZATION_WAD(), 7e17, "V1 target");
        assertEq(y.MIN_YIELD_SHARE_AT_TARGET_WAD(), MIN_YT, "V1 min");
        assertEq(y.MAX_YIELD_SHARE_AT_TARGET_WAD(), MAX_YT, "V1 max");
        assertEq(y.MAX_ADAPTATION_SPEED_WAD(), SPEED_V1, "V1 speed == 50e18/365d");
        assertEq(y.MAX_ADAPTATION_SPEED_LIMIT_WAD(), SPEED_LIMIT, "limit constant");
    }

    function test_getters_v2() public {
        AdaptiveCurveYDM_V2 y = new AdaptiveCurveYDM_V2(2e17);
        assertEq(y.TARGET_UTILIZATION_WAD(), 2e17, "V2 target");
        assertEq(y.MIN_YIELD_SHARE_AT_TARGET_WAD(), MIN_YT, "V2 min");
        assertEq(y.MAX_YIELD_SHARE_AT_TARGET_WAD(), MAX_YT, "V2 max");
        assertEq(y.MAX_ADAPTATION_SPEED_WAD(), SPEED_V2, "V2 speed == 100e18/365d (== limit)");
        assertEq(y.MAX_ADAPTATION_SPEED_LIMIT_WAD(), SPEED_LIMIT, "limit constant");
    }

    function test_v2_speed_isAtLimit() public {
        AdaptiveCurveYDM_V2 y = new AdaptiveCurveYDM_V2(5e17);
        assertEq(y.MAX_ADAPTATION_SPEED_WAD(), y.MAX_ADAPTATION_SPEED_LIMIT_WAD(), "V2 sits exactly at the limit");
    }

    function test_v1_speed_isHalfLimit() public {
        AdaptiveCurveYDM_V1 y = new AdaptiveCurveYDM_V1(5e17);
        assertEq(y.MAX_ADAPTATION_SPEED_WAD() * 2, y.MAX_ADAPTATION_SPEED_LIMIT_WAD(), "V1 is half the limit");
    }

    // =====================================================================
    // Group C — uninitialized market reverts on BOTH entrypoints (base gate)
    // =====================================================================

    function test_uninit_mock_preview_reverts() public {
        MockAdaptiveCurveYDM m = _mock(MIN_YT, MAX_YT, SPEED_LIMIT);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        m.previewYieldShare(MarketState.PERPETUAL, 0);
    }

    function test_uninit_mock_yieldShare_reverts() public {
        MockAdaptiveCurveYDM m = _mock(MIN_YT, MAX_YT, SPEED_LIMIT);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        m.yieldShare(MarketState.PERPETUAL, 5e17);
    }

    function test_uninit_v1_preview_reverts() public {
        AdaptiveCurveYDM_V1 y = new AdaptiveCurveYDM_V1(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        y.previewYieldShare(MarketState.FIXED_TERM, type(uint256).max);
    }

    function test_uninit_v1_yieldShare_reverts() public {
        AdaptiveCurveYDM_V1 y = new AdaptiveCurveYDM_V1(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        y.yieldShare(MarketState.PERPETUAL, 0);
    }

    function test_uninit_v2_preview_reverts() public {
        AdaptiveCurveYDM_V2 y = new AdaptiveCurveYDM_V2(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        y.previewYieldShare(MarketState.PERPETUAL, WAD);
    }

    function test_uninit_v2_yieldShare_reverts() public {
        AdaptiveCurveYDM_V2 y = new AdaptiveCurveYDM_V2(5e17);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        y.yieldShare(MarketState.FIXED_TERM, 3e17);
    }

    /// mapping is keyed by msg.sender: this-init'd, B still uninitialized => reverts.
    function test_uninit_perSenderKeying_reverts() public {
        AdaptiveCurveYDM_V1 y = new AdaptiveCurveYDM_V1(5e17);
        y.initializeYDMForMarket(uint64(1e17), uint64(5e17));
        vm.prank(ACCT_B);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        y.yieldShare(MarketState.PERPETUAL, 0);
    }

    // =====================================================================
    // Group D — base utilization capping to WAD
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

    function test_cap_v1_wadEqMax_fixedTerm() public {
        AdaptiveCurveYDM_V1 y = _v1(8e17, uint64(3e17), uint64(9e17));
        uint256 atWad = y.previewYieldShare(MarketState.FIXED_TERM, WAD);
        assertEq(y.previewYieldShare(MarketState.FIXED_TERM, WAD + 1), atWad, "WAD+1 caps to WAD");
        assertEq(y.previewYieldShare(MarketState.FIXED_TERM, 2 * WAD), atWad, "2*WAD caps to WAD");
        assertEq(y.previewYieldShare(MarketState.FIXED_TERM, type(uint256).max), atWad, "uint256 max caps to WAD");
    }

    function test_cap_v2_wadEqMax_fixedTerm() public {
        AdaptiveCurveYDM_V2 y = _v2(3e17, uint64(1e17), uint64(4e17), uint64(9e17));
        uint256 atWad = y.previewYieldShare(MarketState.FIXED_TERM, WAD);
        assertEq(y.previewYieldShare(MarketState.FIXED_TERM, WAD + 1), atWad, "WAD+1 caps to WAD");
        assertEq(y.previewYieldShare(MarketState.FIXED_TERM, type(uint256).max), atWad, "uint256 max caps to WAD");
    }

    /// The capping holds under the mutating entrypoint too (FIXED_TERM does not adapt yT, so no drift).
    function test_cap_v1_yieldShare_wadEqMax_fixedTerm() public {
        AdaptiveCurveYDM_V1 y = _v1(8e17, uint64(3e17), uint64(9e17));
        uint256 a = y.yieldShare(MarketState.FIXED_TERM, WAD);
        uint256 b = y.yieldShare(MarketState.FIXED_TERM, type(uint256).max);
        assertEq(a, b, "mutate: WAD == max under FIXED_TERM");
    }

    // =====================================================================
    // Group E — base output is bounded by WAD everywhere (unit spot checks)
    // =====================================================================

    function test_output_leWad_v1_extremes() public {
        // Steep curve reaching full util at WAD.
        AdaptiveCurveYDM_V1 y = _v1(5e17, uint64(5e17), uint64(WAD));
        assertLe(y.previewYieldShare(MarketState.PERPETUAL, WAD), WAD, "V1 Y(WAD) <= WAD");
        assertLe(y.previewYieldShare(MarketState.PERPETUAL, type(uint256).max), WAD, "V1 Y(max) <= WAD");
        // Flat at ceiling: yT == yFull == WAD => Y == WAD everywhere.
        AdaptiveCurveYDM_V1 f = _v1(5e17, uint64(WAD), uint64(WAD));
        assertEq(f.previewYieldShare(MarketState.PERPETUAL, 0), WAD, "flat ceiling @0");
        assertEq(f.previewYieldShare(MarketState.PERPETUAL, type(uint256).max), WAD, "flat ceiling @max");
    }

    function test_output_leWad_v2_extremes() public {
        AdaptiveCurveYDM_V2 y = _v2(5e17, uint64(0), uint64(5e17), uint64(WAD));
        assertLe(y.previewYieldShare(MarketState.PERPETUAL, WAD), WAD, "V2 Y(WAD) <= WAD");
        assertLe(y.previewYieldShare(MarketState.PERPETUAL, type(uint256).max), WAD, "V2 Y(max) <= WAD");
        assertEq(y.previewYieldShare(MarketState.PERPETUAL, 0), 0, "V2 y0 == 0 at U=0");
    }

    // =====================================================================
    // Group F — anchor: at U == target both models return yT (delta == 0 in the base)
    // =====================================================================

    function test_anchor_v1_targetReturnsYt() public {
        AdaptiveCurveYDM_V1 y = _v1(8e17, uint64(3e17), uint64(9e17));
        assertEq(y.previewYieldShare(MarketState.FIXED_TERM, 8e17), 3e17, "V1 Y(target) == yT");
        assertEq(y.previewYieldShare(MarketState.PERPETUAL, 8e17), 3e17, "V1 Y(target) == yT (fresh, elapsed 0)");
    }

    function test_anchor_v2_targetReturnsYt() public {
        AdaptiveCurveYDM_V2 y = _v2(3e17, uint64(1e17), uint64(4e17), uint64(9e17));
        assertEq(y.previewYieldShare(MarketState.FIXED_TERM, 3e17), 4e17, "V2 Y(target) == yT");
        assertEq(y.previewYieldShare(MarketState.PERPETUAL, 3e17), 4e17, "V2 Y(target) == yT (fresh, elapsed 0)");
    }

    // =====================================================================
    // Group G — preview/mutate parity and preview non-persistence (base flow)
    // On a fresh curve (lastAdaptationTimestamp == 0) elapsed == 0, so PERPETUAL and FIXED_TERM
    // coincide and preview == yieldShare. preview must not touch storage.
    // =====================================================================

    function test_parity_and_nonPersistence_v1() public {
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

    function test_parity_and_nonPersistence_v2() public {
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
    function testFuzz_v1_base(uint256 target, uint256 yT, uint256 yFull, uint256 u) public {
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
    function testFuzz_v2_base(uint256 target, uint256 y0, uint256 yT, uint256 yFull, uint256 u) public {
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
    function testFuzz_mock_baseCapping_neverReverts(uint256 target, uint256 yT, uint256 u) public {
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
    function testFuzz_ctor_speedBound(uint256 speed) public {
        if (speed == 0 || speed > SPEED_LIMIT) {
            vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
            _mock(MIN_YT, MAX_YT, speed);
        } else {
            MockAdaptiveCurveYDM m = _mock(MIN_YT, MAX_YT, speed);
            assertEq(m.MAX_ADAPTATION_SPEED_WAD(), speed, "in-range speed stored");
        }
    }

    /// Fuzz the mock's (min, max) pair: valid iff 0 < min <= max <= WAD.
    function testFuzz_ctor_minMaxBound(uint256 minY, uint256 maxY) public {
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
