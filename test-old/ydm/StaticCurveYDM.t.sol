// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { WAD, ZERO_NAV_UNITS } from "../../src/libraries/Constants.sol";
import { MarketState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits } from "../../src/libraries/Units.sol";
import { UtilsLib } from "../../src/libraries/UtilsLib.sol";
import { StaticCurveYDM } from "../../src/ydm/StaticCurveYDM.sol";
import { BaseTest } from "../base/BaseTest.t.sol";

contract StaticCurveYDMTest is BaseTest {
    using Math for uint256;

    // ============================================
    // Test State
    // ============================================

    StaticCurveYDM internal ydm;

    // Default curve parameters used in most tests
    uint64 internal constant DEFAULT_Y0 = 0; // 0% at zero util
    uint64 internal constant DEFAULT_YT = 0.225e18; // 22.5% at target util
    uint64 internal constant DEFAULT_YFULL = uint64(WAD); // 100% at full util

    // Computed slopes for default curve
    // S_lt = (Y_T - Y_0) / 0.9 = 0.225 / 0.9 = 0.25
    // S_gte = (Y_full - Y_T) / 0.1 = (1 - 0.225) / 0.1 = 7.75
    uint256 internal constant DEFAULT_SLOPE_LT = 0.25e18;
    uint256 internal constant DEFAULT_SLOPE_GTE = 7.75e18;

    // ============================================
    // Setup
    // ============================================

    function setUp() public {
        _setUpRoyco();
        ydm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);
        // Initialize with default curve (caller becomes the "accountant" key)
        ydm.initializeYDMForMarket(DEFAULT_Y0, DEFAULT_YT, DEFAULT_YFULL);
    }

    // ============================================
    // Helper Functions
    // ============================================

    /// @dev Creates inputs that result in a specific coverageUtilization
    /// @param _coverageUtilizationWAD The target coverageUtilization (0 to WAD+)
    /// @return stRawNAV, jtRawNAV, jtCoinvested, minCoverageWAD, jtEffectiveNAV
    function _createInputsForCoverageUtilization(uint256 _coverageUtilizationWAD) internal pure returns (NAV_UNIT, NAV_UNIT, bool, uint256, NAV_UNIT) {
        // With jtCoinvested=true (JT included), coverage=1, jtEffectiveNAV=1e18:
        // U = (ST + JT) * 1 / 1e18 = (ST + JT) / 1e18
        // So ST + JT = U * 1e18 / 1e18 = U
        // Split evenly: ST = JT = U / 2
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(_coverageUtilizationWAD / 2));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(_coverageUtilizationWAD / 2));
        bool jtCoinvested = true;
        uint256 minCoverageWAD = WAD;
        return (stRawNAV, jtRawNAV, jtCoinvested, minCoverageWAD, jtEffectiveNAV);
    }

    /// @dev Computes expected yield share for default curve given coverageUtilization
    function _expectedYieldShare(uint256 _coverageUtilizationWAD) internal pure returns (uint256) {
        if (_coverageUtilizationWAD >= WAD) return WAD;
        if (_coverageUtilizationWAD < TARGET_COVERAGE_UTILIZATION_WAD) {
            // First leg: Y = Y_0 + S_lt * U = 0 + 0.25 * U
            return DEFAULT_SLOPE_LT.mulDiv(_coverageUtilizationWAD, WAD, Math.Rounding.Floor) + DEFAULT_Y0;
        } else {
            // Second leg: Y = Y_T + S_gte * (U - 0.9)
            return DEFAULT_SLOPE_GTE.mulDiv(_coverageUtilizationWAD - TARGET_COVERAGE_UTILIZATION_WAD, WAD, Math.Rounding.Floor) + DEFAULT_YT;
        }
    }

    /// @dev Computes the coverage utilization the YDM previously derived internally from the 5 NAV args
    function _coverageUtilizationFromNAVs(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        bool _jtCoinvested,
        uint256 _minCoverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        internal
        pure
        returns (uint256)
    {
        return UtilsLib.computeCoverageUtilization(_stRawNAV, _jtRawNAV, _jtCoinvested, _minCoverageWAD, _jtEffectiveNAV);
    }

    // ============================================
    // Initialization Tests
    // ============================================

    function test_initializeYDMForMarket_setsCorrectCurveParams() public {
        StaticCurveYDM newYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);
        newYdm.initializeYDMForMarket(0.1e18, 0.3e18, 0.8e18);

        (uint64 y0, uint192 slopeLt, uint64 yT, uint192 slopeGte) = newYdm.accountantToCurve(address(this));

        assertEq(y0, 0.1e18, "Y0 should be set");
        assertEq(yT, 0.3e18, "YT should be set");

        // slopeLt = (0.3 - 0.1) / 0.9 = 0.2 / 0.9 = 0.222...e18
        uint256 expectedSlopeLt = uint256(0.2e18).mulDiv(WAD, TARGET_COVERAGE_UTILIZATION_WAD, Math.Rounding.Floor);
        assertEq(slopeLt, expectedSlopeLt, "Slope LT should be computed correctly");

        // slopeGte = (0.8 - 0.3) / 0.1 = 0.5 / 0.1 = 5e18
        uint256 expectedSlopeGte = uint256(0.5e18).mulDiv(WAD, WAD - TARGET_COVERAGE_UTILIZATION_WAD, Math.Rounding.Floor);
        assertEq(slopeGte, expectedSlopeGte, "Slope GTE should be computed correctly");
    }

    function test_initializeYDMForMarket_emitsEvent() public {
        StaticCurveYDM newYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);

        uint256 expectedSlopeLt = uint256(DEFAULT_YT - DEFAULT_Y0).mulDiv(WAD, TARGET_COVERAGE_UTILIZATION_WAD, Math.Rounding.Floor);
        uint256 expectedSlopeGte = uint256(DEFAULT_YFULL - DEFAULT_YT).mulDiv(WAD, WAD - TARGET_COVERAGE_UTILIZATION_WAD, Math.Rounding.Floor);

        vm.expectEmit(true, false, false, true);
        emit StaticCurveYDM.StaticCurveYdmInitialized(address(this), DEFAULT_Y0, expectedSlopeLt, expectedSlopeGte);

        newYdm.initializeYDMForMarket(DEFAULT_Y0, DEFAULT_YT, DEFAULT_YFULL);
    }

    function test_initializeYDMForMarket_revertsWhenY0GreaterThanYT() public {
        StaticCurveYDM newYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);

        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        newYdm.initializeYDMForMarket(0.5e18, 0.3e18, 1e18); // Y0 > YT
    }

    function test_initializeYDMForMarket_revertsWhenYTGreaterThanYFull() public {
        StaticCurveYDM newYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);

        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        newYdm.initializeYDMForMarket(0, 0.8e18, 0.5e18); // YT > YFull
    }

    function test_initializeYDMForMarket_revertsWhenYFullGreaterThanWAD() public {
        StaticCurveYDM newYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);

        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        newYdm.initializeYDMForMarket(0, 0.5e18, uint64(WAD + 1)); // YFull > WAD
    }

    function test_initializeYDMForMarket_allowsReinitialization() public {
        // First initialization
        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(0.5e18);
        uint256 resultBefore = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        // Re-initialize with different curve
        ydm.initializeYDMForMarket(0.1e18, 0.5e18, 0.9e18);
        uint256 resultAfter = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        assertNotEq(resultBefore, resultAfter, "Re-initialization should change curve behavior");
    }

    function test_initializeYDMForMarket_revertsWithAllZeros() public {
        StaticCurveYDM newYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);

        // Y_T must be > 0, so all zeros should revert
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        newYdm.initializeYDMForMarket(0, 0, 0);
    }

    function test_initializeYDMForMarket_allowsAllWAD() public {
        StaticCurveYDM newYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);
        newYdm.initializeYDMForMarket(uint64(WAD), uint64(WAD), uint64(WAD));

        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(0.5e18);
        uint256 result = newYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        assertEq(result, WAD, "All-WAD curve should return WAD for all coverageUtilizations");
    }

    function testFuzz_initializeYDMForMarket_validParams(uint64 _y0, uint64 _yT, uint64 _yFull) public {
        // Bound to valid ordering
        _y0 = uint64(bound(_y0, 1, WAD));
        _yT = uint64(bound(_yT, _y0, WAD));
        _yFull = uint64(bound(_yFull, _yT, WAD));

        StaticCurveYDM newYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);
        newYdm.initializeYDMForMarket(_y0, _yT, _yFull);

        (uint128 storedY0,,,) = newYdm.accountantToCurve(address(this));
        assertEq(storedY0, _y0, "Y0 should be stored");
    }

    /// @notice Fuzz test: verify curve invariants hold for any valid configuration
    function testFuzz_curveConfiguration_invariants(uint64 _y0, uint64 _yT, uint64 _yFull, uint256 _coverageUtilizationWAD) public {
        // Bound curve parameters to valid ordering (Y_T must be > 0)
        _yT = uint64(bound(_yT, 1, WAD));
        _y0 = uint64(bound(_y0, 0, _yT));
        _yFull = uint64(bound(_yFull, _yT, WAD));
        _coverageUtilizationWAD = bound(_coverageUtilizationWAD, 0, 2 * WAD);

        // Create a new YDM with fuzzed curve
        StaticCurveYDM fuzzedYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);
        fuzzedYdm.initializeYDMForMarket(_y0, _yT, _yFull);

        // Create inputs for the fuzzed coverageUtilization
        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(_coverageUtilizationWAD);

        uint256 result = fuzzedYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        // Invariant 1: Result is always in [0, WAD]
        assertGe(result, 0, "Result should be >= 0");
        assertLe(result, WAD, "Result should be <= WAD");

        // Invariant 2: Result is >= Y0 (minimum yield share)
        assertGe(result, _y0, "Result should be >= Y0");

        // Invariant 3: At U=0, result should be Y0
        if (_coverageUtilizationWAD == 0) {
            assertEq(result, _y0, "At U=0, result should equal Y0");
        }

        // Invariant 4: At U>=1.0, result should be capped at WAD
        if (_coverageUtilizationWAD >= WAD) {
            assertEq(result, _yFull > WAD ? uint256(WAD) : _yFull, "At U>=1.0, result should be YFull or capped at WAD");
        }
    }

    /// @notice Fuzz test: verify monotonicity for any curve configuration
    function testFuzz_curveConfiguration_monotonicity(uint64 _y0, uint64 _yT, uint64 _yFull, uint256 _util1, uint256 _util2) public {
        // Bound curve parameters to valid ordering (Y_T must be > 0)
        _yT = uint64(bound(_yT, 1, WAD));
        _y0 = uint64(bound(_y0, 0, _yT));
        _yFull = uint64(bound(_yFull, _yT, WAD));

        // Bound coverageUtilizations
        _util1 = bound(_util1, 0, 2 * WAD);
        _util2 = bound(_util2, 0, 2 * WAD);

        // Ensure _util1 <= _util2
        if (_util1 > _util2) {
            (_util1, _util2) = (_util2, _util1);
        }

        // Create a new YDM with fuzzed curve
        StaticCurveYDM fuzzedYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);
        fuzzedYdm.initializeYDMForMarket(_y0, _yT, _yFull);

        (NAV_UNIT stRaw1, NAV_UNIT jtRaw1, bool beta1, uint256 cov1, NAV_UNIT jtEff1) = _createInputsForCoverageUtilization(_util1);
        (NAV_UNIT stRaw2, NAV_UNIT jtRaw2, bool beta2, uint256 cov2, NAV_UNIT jtEff2) = _createInputsForCoverageUtilization(_util2);

        uint256 result1 = fuzzedYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw1, jtRaw1, beta1, cov1, jtEff1));
        uint256 result2 = fuzzedYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw2, jtRaw2, beta2, cov2, jtEff2));

        // Monotonicity: higher coverageUtilization should give higher or equal yield share
        assertLe(result1, result2, "Yield share should be monotonically non-decreasing");
    }

    /// @notice Fuzz test: verify continuity at target coverageUtilization for any curve
    function testFuzz_curveConfiguration_continuityAtTarget(uint64 _y0, uint64 _yT, uint64 _yFull) public {
        // Bound curve parameters to valid ordering (Y_T must be > 0)
        _yT = uint64(bound(_yT, 1, WAD));
        _y0 = uint64(bound(_y0, 0, _yT));
        _yFull = uint64(bound(_yFull, _yT, WAD));

        StaticCurveYDM fuzzedYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);
        fuzzedYdm.initializeYDMForMarket(_y0, _yT, _yFull);

        // Get result at exactly target coverageUtilization
        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(TARGET_COVERAGE_UTILIZATION_WAD);
        uint256 resultAtTarget = fuzzedYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        // Result at target should equal YT
        assertEq(resultAtTarget, _yT, "At target coverageUtilization, result should equal YT");
    }

    // ============================================
    // Boundary Condition Tests
    // ============================================

    function test_previewYieldShare_coverageUtilizationZero() public view {
        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(0);
        uint256 result = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        assertEq(result, DEFAULT_Y0, "At U=0, yield share should equal Y0");
    }

    function test_previewYieldShare_coverageUtilizationAtTarget() public view {
        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(TARGET_COVERAGE_UTILIZATION_WAD);
        uint256 result = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        assertEq(result, DEFAULT_YT, "At U=0.9, yield share should equal YT");
    }

    function test_previewYieldShare_coverageUtilizationAtOne() public view {
        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(WAD);
        uint256 result = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        assertEq(result, WAD, "At U=1.0, yield share should be 100%");
    }

    function test_previewYieldShare_coverageUtilizationAboveOne() public view {
        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(1.5e18);
        uint256 result = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        assertEq(result, WAD, "At U>1.0, yield share should be capped at 100%");
    }

    function test_previewYieldShare_coverageUtilizationJustBelowTarget() public view {
        uint256 coverageUtilizationWAD = TARGET_COVERAGE_UTILIZATION_WAD - 1;
        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(coverageUtilizationWAD);
        uint256 result = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        uint256 expected = _expectedYieldShare(coverageUtilizationWAD);
        assertEq(result, expected, "Just below target should use first leg formula");
        assertLt(result, DEFAULT_YT, "Result should be less than YT");
    }

    function test_previewYieldShare_coverageUtilizationJustAboveTarget() public view {
        uint256 coverageUtilizationWAD = TARGET_COVERAGE_UTILIZATION_WAD + 1;
        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(coverageUtilizationWAD);
        uint256 result = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        assertGe(result, DEFAULT_YT, "Just above target should be >= YT");
    }

    function test_previewYieldShare_coverageUtilizationJustBelowOne() public view {
        uint256 coverageUtilizationWAD = WAD - 1;
        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(coverageUtilizationWAD);
        uint256 result = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        assertLt(result, WAD, "Just below 1.0 should be < 100%");
        assertGt(result, DEFAULT_YT, "Should be greater than YT");
    }

    function test_previewYieldShare_zeroJTEffectiveNAV() public view {
        // Zero JT effective NAV = infinite coverageUtilization = capped at 100%
        NAV_UNIT stRawNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT jtEffectiveNAV = ZERO_NAV_UNITS;

        uint256 result = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV, jtRawNAV, true, WAD, jtEffectiveNAV));

        assertEq(result, WAD, "Infinite coverageUtilization should return 100%");
    }

    // ============================================
    // Specific Point Tests (Known Values)
    // ============================================

    function test_previewYieldShare_knownPoints() public view {
        // Test several known points on the curve
        uint256[5] memory coverageUtilizations = [uint256(0.1e18), uint256(0.45e18), uint256(0.5e18), uint256(0.8e18), uint256(0.95e18)];
        uint256[5] memory expectedResults = [
            // U=0.1: 0.25 * 0.1 = 0.025
            uint256(0.025e18),
            // U=0.45: 0.25 * 0.45 = 0.1125
            uint256(0.1125e18),
            // U=0.5: 0.25 * 0.5 = 0.125
            uint256(0.125e18),
            // U=0.8: 0.25 * 0.8 = 0.2
            uint256(0.2e18),
            // U=0.95: 7.75 * (0.95 - 0.9) + 0.225 = 0.3875 + 0.225 = 0.6125
            uint256(0.6125e18)
        ];

        for (uint256 i = 0; i < coverageUtilizations.length; i++) {
            (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(coverageUtilizations[i]);
            uint256 result = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

            assertEq(result, expectedResults[i], string.concat("Failed at index ", vm.toString(i)));
        }
    }

    function test_previewYieldShare_continuityAtBoundary() public pure {
        // Both legs should give the same result at U = 0.9
        // First leg: Y = 0.25 * 0.9 = 0.225
        // Second leg: Y = 7.75 * (0.9 - 0.9) + 0.225 = 0.225
        uint256 firstLeg = DEFAULT_SLOPE_LT.mulDiv(TARGET_COVERAGE_UTILIZATION_WAD, WAD, Math.Rounding.Floor) + DEFAULT_Y0;
        uint256 secondLeg = DEFAULT_YT;

        assertEq(firstLeg, secondLeg, "Curve should be continuous at target coverageUtilization");
    }

    // ============================================
    // Market State Tests
    // ============================================

    function test_previewYieldShare_ignoresMarketState() public view {
        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(0.5e18);

        uint256 perpetualResult = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));
        uint256 fixedTermResult = ydm.previewYieldShare(MarketState.FIXED_TERM, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        assertEq(perpetualResult, fixedTermResult, "StaticCurve should ignore MarketState");
    }

    function test_yieldShare_ignoresMarketState() public {
        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(0.5e18);

        uint256 perpetualResult = ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));
        uint256 fixedTermResult = ydm.yieldShare(MarketState.FIXED_TERM, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        assertEq(perpetualResult, fixedTermResult, "StaticCurve yieldShare should ignore MarketState");
    }

    // ============================================
    // Different Curve Configurations
    // ============================================

    function test_flatCurve_returnsConstantYield() public {
        StaticCurveYDM flatYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);
        flatYdm.initializeYDMForMarket(0.5e18, 0.5e18, 0.5e18);

        uint256[4] memory coverageUtilizations = [uint256(0), 0.5e18, 0.9e18, WAD];

        for (uint256 i = 0; i < coverageUtilizations.length; i++) {
            (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(coverageUtilizations[i]);
            uint256 result = flatYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

            assertEq(result, 0.5e18, "Flat curve should return constant yield");
        }
    }

    function test_steepFirstLeg_flatSecondLeg() public {
        // Y0=0, YT=0.9, YFull=0.9 (steep below target, flat above)
        StaticCurveYDM steepFlatYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);
        steepFlatYdm.initializeYDMForMarket(0, 0.9e18, 0.9e18);

        // Below target: should rise steeply
        (NAV_UNIT stRaw1, NAV_UNIT jtRaw1, bool beta1, uint256 cov1, NAV_UNIT jtEff1) = _createInputsForCoverageUtilization(0.45e18);
        uint256 result1 = steepFlatYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw1, jtRaw1, beta1, cov1, jtEff1));
        // Expected: (0.9 - 0) / 0.9 * 0.45 = 0.45
        assertEq(result1, 0.45e18, "Steep first leg at U=0.45");

        // Above target: should be flat at 0.9
        (NAV_UNIT stRaw2, NAV_UNIT jtRaw2, bool beta2, uint256 cov2, NAV_UNIT jtEff2) = _createInputsForCoverageUtilization(0.95e18);
        uint256 result2 = steepFlatYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw2, jtRaw2, beta2, cov2, jtEff2));
        assertEq(result2, 0.9e18, "Flat second leg should stay at 0.9");
    }

    function test_flatFirstLeg_steepSecondLeg() public {
        // Y0=0.1, YT=0.1, YFull=1.0 (flat below target, steep above)
        StaticCurveYDM flatSteepYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);
        flatSteepYdm.initializeYDMForMarket(0.1e18, 0.1e18, uint64(WAD));

        // Below target: should be flat at 0.1
        (NAV_UNIT stRaw1, NAV_UNIT jtRaw1, bool beta1, uint256 cov1, NAV_UNIT jtEff1) = _createInputsForCoverageUtilization(0.45e18);
        uint256 result1 = flatSteepYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw1, jtRaw1, beta1, cov1, jtEff1));
        assertEq(result1, 0.1e18, "Flat first leg should stay at 0.1");

        // Above target: should rise steeply
        (NAV_UNIT stRaw2, NAV_UNIT jtRaw2, bool beta2, uint256 cov2, NAV_UNIT jtEff2) = _createInputsForCoverageUtilization(0.95e18);
        uint256 result2 = flatSteepYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw2, jtRaw2, beta2, cov2, jtEff2));
        // Expected: (1.0 - 0.1) / 0.1 * (0.95 - 0.9) + 0.1 = 9 * 0.05 + 0.1 = 0.55
        assertEq(result2, 0.55e18, "Steep second leg at U=0.95");
    }

    // ============================================
    // Beta and Coverage Parameter Tests
    // ============================================

    function test_previewYieldShare_coinvested() public view {
        // With jtCoinvested=true, JT contributes fully to coverageUtilization
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.25e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.25e18));
        bool jtCoinvested = true;
        uint256 minCoverageWAD = WAD;

        // U = (0.25 + 0.25) * 1 / 1 = 0.5
        uint256 expectedUtil = 0.5e18;
        uint256 expectedYield = _expectedYieldShare(expectedUtil);

        uint256 result =
            ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV, jtRawNAV, jtCoinvested, minCoverageWAD, jtEffectiveNAV));
        assertEq(result, expectedYield, "Should handle coinvested junior tranche");
    }

    function test_previewYieldShare_differentCoverage() public view {
        // With coverage=0.5, coverageUtilization is halved
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.5e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.5e18));
        bool jtCoinvested = true;
        uint256 minCoverageWAD = 0.5e18; // 50% coverage

        // U = (0.5 + 0.5) * 0.5 / 1 = 0.5
        uint256 expectedUtil = 0.5e18;
        uint256 expectedYield = _expectedYieldShare(expectedUtil);

        uint256 result =
            ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV, jtRawNAV, jtCoinvested, minCoverageWAD, jtEffectiveNAV));
        assertEq(result, expectedYield, "Should handle different coverage values");
    }

    function test_previewYieldShare_notCoinvested() public view {
        // With jtCoinvested=false, only ST contributes to coverageUtilization
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.5e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(1e18)); // This shouldn't matter
        bool jtCoinvested = false;
        uint256 minCoverageWAD = WAD;

        // U = (0.5 + 0) * 1 / 1 = 0.5
        uint256 expectedUtil = 0.5e18;
        uint256 expectedYield = _expectedYieldShare(expectedUtil);

        uint256 result =
            ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV, jtRawNAV, jtCoinvested, minCoverageWAD, jtEffectiveNAV));
        assertEq(result, expectedYield, "Should handle non-coinvested junior tranche");
    }

    // ============================================
    // Function Consistency Tests
    // ============================================

    function test_yieldShare_matchesPreview() public {
        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(0.8e18);

        uint256 preview = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));
        uint256 actual = ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        assertEq(actual, preview, "yieldShare should equal previewYieldShare");
    }

    function testFuzz_yieldShare_matchesPreview(
        uint128 _stRawNAV,
        uint128 _jtRawNAV,
        bool _jtCoinvested,
        uint128 _minCoverageWAD,
        uint128 _jtEffectiveNAV
    )
        public
    {
        // Bound to reasonable values
        _minCoverageWAD = uint128(bound(_minCoverageWAD, 0, WAD * 2));

        NAV_UNIT stRaw = toNAVUnits(uint256(_stRawNAV));
        NAV_UNIT jtRaw = toNAVUnits(uint256(_jtRawNAV));
        NAV_UNIT jtEff = toNAVUnits(uint256(_jtEffectiveNAV));

        uint256 preview = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, _jtCoinvested, _minCoverageWAD, jtEff));
        uint256 actual = ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, _jtCoinvested, _minCoverageWAD, jtEff));

        assertEq(actual, preview, "yieldShare should always equal previewYieldShare");
    }

    // ============================================
    // Invariant: Result Always in [0, WAD]
    // ============================================

    function testFuzz_previewYieldShare_resultInValidRange(
        uint128 _stRawNAV,
        uint128 _jtRawNAV,
        bool _jtCoinvested,
        uint128 _minCoverageWAD,
        uint128 _jtEffectiveNAV
    )
        public
        view
    {
        _minCoverageWAD = uint128(bound(_minCoverageWAD, 0, WAD * 2));

        uint256 result = ydm.previewYieldShare(
            MarketState.PERPETUAL,
            _coverageUtilizationFromNAVs(
                toNAVUnits(uint256(_stRawNAV)), toNAVUnits(uint256(_jtRawNAV)), _jtCoinvested, _minCoverageWAD, toNAVUnits(uint256(_jtEffectiveNAV))
            )
        );

        assertGe(result, 0, "Result should be >= 0");
        assertLe(result, WAD, "Result should be <= WAD");
    }

    // ============================================
    // Invariant: Monotonically Non-Decreasing
    // ============================================

    function testFuzz_previewYieldShare_monotonicWithCoverageUtilization(uint256 _util1, uint256 _util2) public view {
        // Bound coverageUtilizations to [0, 2*WAD] to test beyond 100%
        _util1 = bound(_util1, 0, 2 * WAD);
        _util2 = bound(_util2, 0, 2 * WAD);

        // Ensure _util1 <= _util2
        if (_util1 > _util2) {
            (_util1, _util2) = (_util2, _util1);
        }

        (NAV_UNIT stRaw1, NAV_UNIT jtRaw1, bool beta1, uint256 cov1, NAV_UNIT jtEff1) = _createInputsForCoverageUtilization(_util1);
        (NAV_UNIT stRaw2, NAV_UNIT jtRaw2, bool beta2, uint256 cov2, NAV_UNIT jtEff2) = _createInputsForCoverageUtilization(_util2);

        uint256 result1 = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw1, jtRaw1, beta1, cov1, jtEff1));
        uint256 result2 = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw2, jtRaw2, beta2, cov2, jtEff2));

        assertLe(result1, result2, "Yield share should be monotonically non-decreasing with coverageUtilization");
    }

    function test_monotonicity_acrossEntireCurve() public view {
        uint256 prevResult = 0;

        // Test 100 points across the curve
        for (uint256 i = 0; i <= 100; i++) {
            uint256 coverageUtilizationWAD = (WAD * i) / 100;
            (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(coverageUtilizationWAD);
            uint256 result = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

            assertGe(result, prevResult, string.concat("Monotonicity violated at i=", vm.toString(i)));
            prevResult = result;
        }
    }

    // ============================================
    // Invariant: High CoverageUtilization Returns WAD
    // ============================================

    function testFuzz_previewYieldShare_coverageUtilizationAboveOneReturnsWAD(
        uint128 _stRawNAV,
        uint128 _jtRawNAV,
        bool _jtCoinvested,
        uint128 _minCoverageWAD,
        uint128 _jtEffectiveNAV
    )
        public
        view
    {
        _minCoverageWAD = uint128(bound(_minCoverageWAD, 0, WAD * 2));
        _jtEffectiveNAV = uint128(bound(_jtEffectiveNAV, 1, type(uint128).max));

        NAV_UNIT stRaw = toNAVUnits(uint256(_stRawNAV));
        NAV_UNIT jtRaw = toNAVUnits(uint256(_jtRawNAV));
        NAV_UNIT jtEff = toNAVUnits(uint256(_jtEffectiveNAV));

        uint256 coverageUtilizationWAD = UtilsLib.computeCoverageUtilization(stRaw, jtRaw, _jtCoinvested, _minCoverageWAD, jtEff);

        if (coverageUtilizationWAD >= WAD) {
            uint256 result = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, _jtCoinvested, _minCoverageWAD, jtEff));
            assertEq(result, WAD, "CoverageUtilization >= 100% should return WAD");
        }
    }

    // ============================================
    // Invariant: Formula Correctness
    // ============================================

    function testFuzz_previewYieldShare_firstLegFormula(uint256 _coverageUtilizationWAD) public view {
        // Test first leg: U < 0.9
        _coverageUtilizationWAD = bound(_coverageUtilizationWAD, 0, TARGET_COVERAGE_UTILIZATION_WAD - 1);

        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(_coverageUtilizationWAD);
        uint256 result = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        // Y = Y_0 + S_lt * U
        uint256 expected = DEFAULT_SLOPE_LT.mulDiv(_coverageUtilizationWAD, WAD, Math.Rounding.Floor) + DEFAULT_Y0;
        assertEq(result, expected, "First leg formula should be correct");
    }

    function testFuzz_previewYieldShare_secondLegFormula(uint256 _coverageUtilizationWAD) public view {
        // Test second leg: 0.9 <= U < 1.0
        _coverageUtilizationWAD = bound(_coverageUtilizationWAD, TARGET_COVERAGE_UTILIZATION_WAD, WAD - 1);

        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(_coverageUtilizationWAD);
        uint256 result = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        // Y = Y_T + S_gte * (U - 0.9)
        // Note: Allow 1 wei tolerance due to rounding differences in coverageUtilization calculation
        uint256 expected = DEFAULT_SLOPE_GTE.mulDiv(_coverageUtilizationWAD - TARGET_COVERAGE_UTILIZATION_WAD, WAD, Math.Rounding.Floor) + DEFAULT_YT;
        assertApproxEqAbs(result, expected, 10, "Second leg formula should be correct within rounding tolerance");
    }

    // ============================================
    // Multi-Accountant Tests
    // ============================================

    function test_differentAccountants_haveDifferentCurves() public {
        // Deploy YDM and initialize from different addresses
        StaticCurveYDM sharedYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);

        // Initialize from address(this)
        sharedYdm.initializeYDMForMarket(0, 0.2e18, uint64(WAD));

        // Initialize from a different address
        address otherAccountant = address(0x1234);
        vm.prank(otherAccountant);
        sharedYdm.initializeYDMForMarket(0.1e18, 0.5e18, 0.8e18);

        // Query as address(this)
        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(0.5e18);
        uint256 result1 = sharedYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        // Query as otherAccountant
        vm.prank(otherAccountant);
        uint256 result2 = sharedYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));

        assertNotEq(result1, result2, "Different accountants should have different curves");
    }

    function test_uninitializedAccountant_reverts() public {
        StaticCurveYDM freshYdm = new StaticCurveYDM(TARGET_COVERAGE_UTILIZATION_WAD);
        // Don't initialize

        (NAV_UNIT stRaw, NAV_UNIT jtRaw, bool beta, uint256 cov, NAV_UNIT jtEff) = _createInputsForCoverageUtilization(0.5e18);

        // Uninitialized curve should revert with UNINITIALIZED_YDM
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        freshYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRaw, jtRaw, beta, cov, jtEff));
    }

    // ============================================
    // Edge Cases with Large Numbers
    // ============================================

    function testFuzz_previewYieldShare_largeNAVValues(uint128 _scale) public view {
        // Test with large NAV values (scaled up)
        // Use minimum of 4e18 to ensure clean division by 4
        _scale = uint128(bound(_scale, 4e18, type(uint128).max / 2));

        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(_scale));
        // Create 50% coverageUtilization with large numbers
        NAV_UNIT stRawNAV = toNAVUnits(uint256(_scale / 4));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(_scale / 4));

        uint256 result = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV, jtRawNAV, true, WAD, jtEffectiveNAV));

        // Should be approximately same as 50% coverageUtilization with small numbers
        // Allow small tolerance due to rounding in coverageUtilization calculation
        uint256 expectedYield = _expectedYieldShare(0.5e18);
        assertApproxEqAbs(result, expectedYield, 1, "Large NAV values should compute correctly within rounding");
    }

    function test_previewYieldShare_maxUint128Values() public view {
        // Test with maximum uint128 values
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(type(uint128).max));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(type(uint128).max / 4));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(type(uint128).max / 4));

        // Should not revert
        uint256 result = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV, jtRawNAV, true, WAD, jtEffectiveNAV));

        assertLe(result, WAD, "Result should be bounded even with max values");
    }
}
