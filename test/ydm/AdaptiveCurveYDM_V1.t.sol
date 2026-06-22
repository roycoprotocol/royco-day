// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { FixedPointMathLib } from "../../lib/solady/src/utils/FixedPointMathLib.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { WAD, WAD_INT, ZERO_NAV_UNITS } from "../../src/libraries/Constants.sol";
import { DawnUtilsLib } from "../../src/libraries/DawnUtilsLib.sol";
import { MarketState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits } from "../../src/libraries/Units.sol";
import { AdaptiveCurveYDM_V1 } from "../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { BaseTest } from "../base/BaseTest.t.sol";

contract AdaptiveCurveYDM_V1_Test is BaseTest {
    using Math for uint256;

    // ============================================
    // Test State
    // ============================================

    AdaptiveCurveYDM_V1 internal ydm;

    // Default curve parameters
    uint64 internal constant DEFAULT_YT = 0.3e18; // 30% at target util
    uint64 internal constant DEFAULT_YFULL = 0.9e18; // 90% at full util
    // Steepness = YFULL * WAD / YT = 0.9e18 * 1e18 / 0.3e18 = 3e18 (3x)
    uint256 internal constant DEFAULT_STEEPNESS = 3e18;

    // Contract constants (copied for testing)
    int256 internal constant MAX_ADAPTATION_SPEED_WAD = 50e18 / int256(365 days);
    uint256 internal constant MIN_JT_YIELD_SHARE_AT_TARGET_WAD = 0.0001e18;
    uint256 internal constant MAX_JT_YIELD_SHARE_AT_TARGET_WAD = WAD;

    // ============================================
    // Setup
    // ============================================

    function setUp() public {
        _setUpRoyco();
        ydm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);
        // Initialize with default curve (caller becomes the "accountant" key)
        ydm.initializeYDMForMarket(DEFAULT_YT, DEFAULT_YFULL);
    }

    // ============================================
    // Helper Functions
    // ============================================

    /// @dev Creates inputs that result in a specific coverageUtilization
    function _createInputsForCoverageUtilization(uint256 _coverageUtilizationWAD) internal pure returns (NAV_UNIT, NAV_UNIT, uint256, uint256, NAV_UNIT) {
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(_coverageUtilizationWAD / 2));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(_coverageUtilizationWAD / 2));
        uint256 betaWAD = WAD;
        uint256 minCoverageWAD = WAD;
        return (stRawNAV, jtRawNAV, betaWAD, minCoverageWAD, jtEffectiveNAV);
    }

    /// @dev Computes the coverage utilization from the 5 NAV/uint args the YDM used to take internally
    function _coverageUtilizationFromNAVs(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV, uint256 _betaWAD, uint256 _minCoverageWAD, NAV_UNIT _jtEffectiveNAV)
        internal
        pure
        returns (uint256)
    {
        return DawnUtilsLib.computeCoverageUtilization(_stRawNAV, _jtRawNAV, _betaWAD, _minCoverageWAD, _jtEffectiveNAV);
    }

    /// @dev Computes expected normalized delta from target
    function _computeNormalizedDelta(uint256 _coverageUtilizationWAD) internal pure returns (int256) {
        uint256 cappedUtil = _coverageUtilizationWAD > WAD ? WAD : _coverageUtilizationWAD;
        uint256 maxDelta = cappedUtil > TARGET_COVERAGE_UTILIZATION_WAD ? (WAD - TARGET_COVERAGE_UTILIZATION_WAD) : TARGET_COVERAGE_UTILIZATION_WAD;
        return ((int256(cappedUtil) - TARGET_COVERAGE_UTILIZATION_WAD_INT) * WAD_INT) / int256(maxDelta);
    }

    /// @dev Computes expected yield share at current coverageUtilization (no adaptation)
    function _computeExpectedYieldShare(uint256 _steepnessWAD, int256 _normalizedDelta, uint256 _ytWAD) internal pure returns (uint256) {
        int256 coefficient = _normalizedDelta < 0 ? WAD_INT - ((WAD_INT * WAD_INT) / int256(_steepnessWAD)) : int256(_steepnessWAD) - WAD_INT;

        uint256 result = uint256((((coefficient * _normalizedDelta / WAD_INT) + WAD_INT) * int256(_ytWAD)) / WAD_INT);
        return result > WAD ? WAD : result;
    }

    /// @dev Computes expected yield share at target after adaptation
    function _computeAdaptedYT(uint256 _initialYT, int256 _linearAdaptation) internal pure returns (uint256) {
        uint256 result = uint256((int256(_initialYT) * FixedPointMathLib.expWad(_linearAdaptation)) / WAD_INT);
        if (result < MIN_JT_YIELD_SHARE_AT_TARGET_WAD) return MIN_JT_YIELD_SHARE_AT_TARGET_WAD;
        if (result > MAX_JT_YIELD_SHARE_AT_TARGET_WAD) return MAX_JT_YIELD_SHARE_AT_TARGET_WAD;
        return result;
    }

    // ============================================
    // Initialization Tests
    // ============================================

    function test_initializeYDMForMarket_setsCorrectCurveParams() public {
        AdaptiveCurveYDM_V1 newYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);
        newYdm.initializeYDMForMarket(0.2e18, 0.6e18);

        (uint64 yT, uint32 lastTimestamp, uint160 steepness) = newYdm.accountantToCurve(address(this));

        assertEq(yT, 0.2e18, "YT should be set");
        assertEq(lastTimestamp, 0, "Last timestamp should be 0 initially");
        // Steepness = 0.6e18 * WAD / 0.2e18 = 3e18
        assertEq(steepness, 3e18, "Steepness should be computed correctly");
    }

    function test_initializeYDMForMarket_emitsEvent() public {
        AdaptiveCurveYDM_V1 newYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);

        uint256 expectedSteepness = (uint256(DEFAULT_YFULL) * WAD) / DEFAULT_YT;

        vm.expectEmit(true, false, false, true);
        emit AdaptiveCurveYDM_V1.AdaptiveCurveYdmInitialized(address(this), expectedSteepness, DEFAULT_YT);

        newYdm.initializeYDMForMarket(DEFAULT_YT, DEFAULT_YFULL);
    }

    function test_initializeYDMForMarket_revertsWhenYTBelowMin() public {
        AdaptiveCurveYDM_V1 newYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);

        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        newYdm.initializeYDMForMarket(uint64(MIN_JT_YIELD_SHARE_AT_TARGET_WAD - 1), 0.5e18);
    }

    function test_initializeYDMForMarket_revertsWhenYTAboveMax() public {
        AdaptiveCurveYDM_V1 newYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);

        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        // YT > WAD is invalid
        newYdm.initializeYDMForMarket(uint64(WAD + 1), uint64(WAD + 2));
    }

    function test_initializeYDMForMarket_revertsWhenYTGreaterThanYFull() public {
        AdaptiveCurveYDM_V1 newYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);

        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        newYdm.initializeYDMForMarket(0.5e18, 0.3e18); // YT > YFull
    }

    function test_initializeYDMForMarket_revertsWhenYFullGreaterThanWAD() public {
        AdaptiveCurveYDM_V1 newYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);

        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        newYdm.initializeYDMForMarket(0.5e18, uint64(WAD + 1));
    }

    function test_initializeYDMForMarket_allowsMinYT() public {
        AdaptiveCurveYDM_V1 newYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);
        newYdm.initializeYDMForMarket(uint64(MIN_JT_YIELD_SHARE_AT_TARGET_WAD), uint64(WAD));

        (uint64 yT,,) = newYdm.accountantToCurve(address(this));
        assertEq(yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, "Should allow min YT");
    }

    function test_initializeYDMForMarket_allowsMaxYT() public {
        AdaptiveCurveYDM_V1 newYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);
        newYdm.initializeYDMForMarket(uint64(WAD), uint64(WAD));

        (uint64 yT,, uint160 steepness) = newYdm.accountantToCurve(address(this));
        assertEq(yT, WAD, "Should allow max YT");
        assertEq(steepness, WAD, "Steepness should be 1x when YT = YFull");
    }

    function test_initializeYDMForMarket_allowsYTEqualsYFull() public {
        AdaptiveCurveYDM_V1 newYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);
        newYdm.initializeYDMForMarket(0.5e18, 0.5e18);

        (uint64 yT,, uint160 steepness) = newYdm.accountantToCurve(address(this));
        assertEq(yT, 0.5e18, "YT should be set");
        assertEq(steepness, WAD, "Steepness should be 1x when YT = YFull");
    }

    function test_initializeYDMForMarket_allowsReinitialization() public {
        // Re-initialize with different params
        ydm.initializeYDMForMarket(0.1e18, 0.2e18);

        (uint64 yT,, uint160 steepness) = ydm.accountantToCurve(address(this));
        assertEq(yT, 0.1e18, "YT should be updated");
        assertEq(steepness, 2e18, "Steepness should be updated");
    }

    function test_initializeYDMForMarket_resetsTimestampOnReinit() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(WAD);

        // First call sets timestamp
        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        (, uint32 timestamp1,) = ydm.accountantToCurve(address(this));
        assertGt(timestamp1, 0, "Timestamp should be set after first call");

        // Advance time significantly
        vm.warp(vm.getBlockTimestamp() + 30 days);

        // Re-initialize should reset timestamp to 0
        ydm.initializeYDMForMarket(0.5e18, 0.8e18);
        (, uint32 timestamp2,) = ydm.accountantToCurve(address(this));
        assertEq(timestamp2, 0, "Timestamp should be reset to 0 on re-init");

        // First call after re-init should have no adaptation (clean slate)
        (uint64 ytBefore,,) = ydm.accountantToCurve(address(this));
        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        (uint64 ytAfter,,) = ydm.accountantToCurve(address(this));

        assertEq(ytAfter, ytBefore, "No adaptation should occur on first call after re-init");
    }

    // ============================================
    // Market State Tests
    // ============================================

    function test_yieldShare_adaptsInPerpetualState() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(WAD); // 100% coverageUtilization

        // First call to set timestamp
        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        (uint64 ytBefore,,) = ydm.accountantToCurve(address(this));

        // Advance time
        vm.warp(vm.getBlockTimestamp() + 30 days);

        // Second call should adapt the curve upward (high coverageUtilization)
        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        (uint64 ytAfter,,) = ydm.accountantToCurve(address(this));

        assertGt(ytAfter, ytBefore, "YT should increase with high coverageUtilization over time");
    }

    function test_yieldShare_doesNotAdaptInFixedTermState() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(WAD); // 100% coverageUtilization

        // First call to set timestamp in PERPETUAL
        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        (uint64 ytBefore,,) = ydm.accountantToCurve(address(this));

        // Advance time
        vm.warp(vm.getBlockTimestamp() + 30 days);

        // Call in FIXED_TERM state - should not adapt
        ydm.yieldShare(MarketState.FIXED_TERM, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        (uint64 ytAfter,,) = ydm.accountantToCurve(address(this));

        // YT should stay the same in FIXED_TERM (no adaptation applied)
        // Note: the timestamp will still be updated, but no adaptation is applied
        assertEq(ytAfter, ytBefore, "YT should not change in FIXED_TERM state");
    }

    function test_previewYieldShare_doesNotModifyState() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(WAD);

        // Set initial timestamp
        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        (uint64 ytBefore, uint32 timestampBefore,) = ydm.accountantToCurve(address(this));

        vm.warp(vm.getBlockTimestamp() + 30 days);

        // Preview should not modify state
        ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        (uint64 ytAfter, uint32 timestampAfter,) = ydm.accountantToCurve(address(this));

        assertEq(ytAfter, ytBefore, "YT should not change after preview");
        assertEq(timestampAfter, timestampBefore, "Timestamp should not change after preview");
    }

    function test_previewYieldShare_matchesYieldShare() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(0.5e18);

        // Set initial timestamp
        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        vm.warp(vm.getBlockTimestamp() + 10 days);

        // Preview and actual should return the same value
        uint256 preview = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        uint256 actual = ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        assertEq(preview, actual, "Preview and actual should match");
    }

    // ============================================
    // Adaptation Mechanism Tests
    // ============================================

    function test_adaptation_noAdaptationOnFirstCall() public {
        // Create a fresh YDM
        AdaptiveCurveYDM_V1 freshYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);
        freshYdm.initializeYDMForMarket(DEFAULT_YT, DEFAULT_YFULL);

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(WAD);

        // First call - lastAdaptationTimestamp is 0, so elapsed = 0
        freshYdm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        (uint64 yT,,) = freshYdm.accountantToCurve(address(this));

        // YT should not have changed from initial value
        assertEq(yT, DEFAULT_YT, "YT should not change on first call");
    }

    function test_adaptation_noAdaptationAtTargetCoverageUtilization() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) =
            _createInputsForCoverageUtilization(TARGET_COVERAGE_UTILIZATION_WAD);

        // First call to set timestamp
        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        (uint64 ytBefore,,) = ydm.accountantToCurve(address(this));

        vm.warp(vm.getBlockTimestamp() + 365 days);

        // At target coverageUtilization, normalized delta = 0, so adaptation speed = 0
        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        (uint64 ytAfter,,) = ydm.accountantToCurve(address(this));

        assertEq(ytAfter, ytBefore, "YT should not change at target coverageUtilization");
    }

    function test_adaptation_increasesWithHighCoverageUtilization() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(WAD); // 100% coverageUtilization

        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        (uint64 ytBefore,,) = ydm.accountantToCurve(address(this));

        vm.warp(vm.getBlockTimestamp() + 30 days);

        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        (uint64 ytAfter,,) = ydm.accountantToCurve(address(this));

        assertGt(ytAfter, ytBefore, "YT should increase with high coverageUtilization");
    }

    function test_adaptation_decreasesWithLowCoverageUtilization() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(0); // 0% coverageUtilization

        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        (uint64 ytBefore,,) = ydm.accountantToCurve(address(this));

        vm.warp(vm.getBlockTimestamp() + 30 days);

        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        (uint64 ytAfter,,) = ydm.accountantToCurve(address(this));

        assertLt(ytAfter, ytBefore, "YT should decrease with low coverageUtilization");
    }

    function test_adaptation_clampsToMinimum() public {
        // Start with minimum YT
        AdaptiveCurveYDM_V1 minYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);
        minYdm.initializeYDMForMarket(uint64(MIN_JT_YIELD_SHARE_AT_TARGET_WAD), uint64(WAD));

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(0); // 0% coverageUtilization

        minYdm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        // Advance a very long time with low coverageUtilization
        vm.warp(vm.getBlockTimestamp() + 3650 days); // 10 years

        minYdm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        (uint64 yT,,) = minYdm.accountantToCurve(address(this));

        assertGe(yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should not go below minimum");
    }

    function test_adaptation_clampsToMaximum() public {
        // Start with YT close to max
        AdaptiveCurveYDM_V1 maxYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);
        maxYdm.initializeYDMForMarket(0.9e18, uint64(WAD));

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(WAD); // 100% coverageUtilization

        maxYdm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        // Advance in multiple steps to avoid exp overflow (100 days each, 10 iterations)
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(vm.getBlockTimestamp() + 100 days);
            maxYdm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        }

        (uint64 yT,,) = maxYdm.accountantToCurve(address(this));

        assertLe(yT, MAX_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should not exceed maximum");
    }

    function test_adaptation_emitsEvent() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(WAD);

        // First call to set timestamp
        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        vm.warp(vm.getBlockTimestamp() + 30 days);

        // Expect YdmAdaptedOutput event
        vm.expectEmit(true, false, false, false);
        emit AdaptiveCurveYDM_V1.YdmAdaptedOutput(address(this), 0, 0); // We don't check exact values

        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
    }

    function test_adaptation_updatesTimestamp() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(0.5e18);

        // First call
        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        (, uint32 timestamp1,) = ydm.accountantToCurve(address(this));

        // Advance time
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // Second call
        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        (, uint32 timestamp2,) = ydm.accountantToCurve(address(this));

        // Timestamp should have increased
        assertGt(timestamp2, timestamp1, "Timestamp should be updated");
    }

    // ============================================
    // Curve Output Tests
    // ============================================

    function test_curveOutput_atTargetCoverageUtilization() public view {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) =
            _createInputsForCoverageUtilization(TARGET_COVERAGE_UTILIZATION_WAD);

        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        // At target coverageUtilization, Y = Y_T
        assertEq(yieldShare, DEFAULT_YT, "Yield share at target should equal YT");
    }

    function test_curveOutput_atFullCoverageUtilization() public view {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(WAD);

        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        // At full coverageUtilization, Y = S * Y_T = 3 * 0.3 = 0.9
        assertEq(yieldShare, DEFAULT_YFULL, "Yield share at full util should equal S * YT");
    }

    function test_curveOutput_atZeroCoverageUtilization() public view {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(0);

        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        // At zero coverageUtilization, Y = Y_T / S = 0.3 / 3 = 0.1
        uint256 expectedYield = DEFAULT_YT / (DEFAULT_STEEPNESS / WAD);
        assertApproxEqAbs(yieldShare, expectedYield, 1, "Yield share at zero util should equal YT / S");
    }

    function test_curveOutput_cappedAtWAD() public {
        // Create a curve where S * Y_T > WAD
        AdaptiveCurveYDM_V1 highYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);
        highYdm.initializeYDMForMarket(0.9e18, uint64(WAD)); // S = WAD / 0.9 = 1.111...

        // With YT = 0.9 and S = 1.111, at full util: Y = S * YT = 1.111 * 0.9 = 1.0 = WAD
        // Let's use a case where we'd go over
        AdaptiveCurveYDM_V1 extremeYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);
        extremeYdm.initializeYDMForMarket(0.5e18, uint64(WAD)); // S = 2

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(WAD);

        uint256 yieldShare = extremeYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        // S * YT = 2 * 0.5 = 1.0 = WAD (exactly at cap)
        assertLe(yieldShare, WAD, "Yield share should be capped at WAD");
    }

    function test_curveOutput_continuityAtTarget() public view {
        // Test values just below and above target coverageUtilization
        uint256 justBelow = TARGET_COVERAGE_UTILIZATION_WAD - 1;
        uint256 justAbove = TARGET_COVERAGE_UTILIZATION_WAD + 1;

        (NAV_UNIT stRawNAV1, NAV_UNIT jtRawNAV1, uint256 betaWAD1, uint256 minCoverageWAD1, NAV_UNIT jtEffectiveNAV1) = _createInputsForCoverageUtilization(justBelow);
        (NAV_UNIT stRawNAV2, NAV_UNIT jtRawNAV2, uint256 betaWAD2, uint256 minCoverageWAD2, NAV_UNIT jtEffectiveNAV2) = _createInputsForCoverageUtilization(justAbove);
        (NAV_UNIT stRawNAV3, NAV_UNIT jtRawNAV3, uint256 betaWAD3, uint256 minCoverageWAD3, NAV_UNIT jtEffectiveNAV3) =
            _createInputsForCoverageUtilization(TARGET_COVERAGE_UTILIZATION_WAD);

        uint256 yieldBelow = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV1,jtRawNAV1,betaWAD1,minCoverageWAD1,jtEffectiveNAV1));
        uint256 yieldAbove = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV2,jtRawNAV2,betaWAD2,minCoverageWAD2,jtEffectiveNAV2));
        uint256 yieldAt = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV3,jtRawNAV3,betaWAD3,minCoverageWAD3,jtEffectiveNAV3));

        // All should be approximately equal (continuity)
        assertApproxEqAbs(yieldBelow, yieldAt, 1e12, "Should be continuous from below");
        assertApproxEqAbs(yieldAbove, yieldAt, 1e12, "Should be continuous from above");
    }

    function test_curveOutput_monotonicallyIncreasing() public view {
        uint256[5] memory coverageUtilizations = [uint256(0), 0.3e18, TARGET_COVERAGE_UTILIZATION_WAD, 0.95e18, WAD];

        uint256 previousYield = 0;
        for (uint256 i = 0; i < coverageUtilizations.length; i++) {
            (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(coverageUtilizations[i]);

            uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

            assertGe(yieldShare, previousYield, "Yield should increase with coverageUtilization");
            previousYield = yieldShare;
        }
    }

    function test_curveOutput_coverageUtilizationAboveOneIsCapped() public view {
        // Create inputs that would result in coverageUtilization > 100%
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(0.5e18)); // Small JT effective NAV
        NAV_UNIT stRawNAV = toNAVUnits(uint256(1e18)); // Large ST NAV
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0));
        uint256 betaWAD = WAD;
        uint256 minCoverageWAD = WAD;

        // CoverageUtilization = (1e18 + 0) * 1 / 0.5e18 = 2e18 (200%), should be capped to 100%
        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        // Should return the same as full coverageUtilization
        (NAV_UNIT stRawNAV2, NAV_UNIT jtRawNAV2, uint256 betaWAD2, uint256 minCoverageWAD2, NAV_UNIT jtEffectiveNAV2) = _createInputsForCoverageUtilization(WAD);
        uint256 yieldShareAtFull = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV2,jtRawNAV2,betaWAD2,minCoverageWAD2,jtEffectiveNAV2));

        assertEq(yieldShare, yieldShareAtFull, "CoverageUtilization > 100% should be capped to 100%");
    }

    // ============================================
    // Steepness Tests
    // ============================================

    function test_steepness_flatCurve() public {
        // S = 1 means YT = YFull, flat curve after target
        AdaptiveCurveYDM_V1 flatYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);
        flatYdm.initializeYDMForMarket(0.5e18, 0.5e18);

        (NAV_UNIT stRawNAV1, NAV_UNIT jtRawNAV1, uint256 betaWAD1, uint256 minCoverageWAD1, NAV_UNIT jtEffectiveNAV1) =
            _createInputsForCoverageUtilization(TARGET_COVERAGE_UTILIZATION_WAD);
        (NAV_UNIT stRawNAV2, NAV_UNIT jtRawNAV2, uint256 betaWAD2, uint256 minCoverageWAD2, NAV_UNIT jtEffectiveNAV2) = _createInputsForCoverageUtilization(WAD);

        uint256 yieldAtTarget = flatYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV1,jtRawNAV1,betaWAD1,minCoverageWAD1,jtEffectiveNAV1));
        uint256 yieldAtFull = flatYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV2,jtRawNAV2,betaWAD2,minCoverageWAD2,jtEffectiveNAV2));

        assertEq(yieldAtTarget, yieldAtFull, "Flat curve should have same yield at target and full");
    }

    function test_steepness_steepCurve() public {
        // High steepness: S = 10 (YFull = 10 * YT)
        AdaptiveCurveYDM_V1 steepYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);
        steepYdm.initializeYDMForMarket(0.1e18, uint64(WAD)); // S = 1e18 / 0.1e18 = 10

        (,, uint160 steepness) = steepYdm.accountantToCurve(address(this));
        assertEq(steepness, 10e18, "Steepness should be 10x");

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(0);

        uint256 yieldAtZero = steepYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        // At zero util, Y = YT / S = 0.1 / 10 = 0.01
        assertEq(yieldAtZero, 0.01e18, "Steep curve should have low yield at zero util");
    }

    // ============================================
    // Multi-Accountant Tests
    // ============================================

    function test_differentAccountants_haveDifferentCurves() public {
        address accountant1 = address(this);
        address accountant2 = address(0x1234);

        // Already initialized for accountant1 in setUp

        // Initialize for accountant2 with different params
        vm.prank(accountant2);
        ydm.initializeYDMForMarket(0.5e18, 0.8e18);

        (uint64 yT1,, uint160 steepness1) = ydm.accountantToCurve(accountant1);
        (uint64 yT2,, uint160 steepness2) = ydm.accountantToCurve(accountant2);

        assertEq(yT1, DEFAULT_YT, "Accountant1 YT should be default");
        assertEq(yT2, 0.5e18, "Accountant2 YT should be 0.5");
        assertNotEq(steepness1, steepness2, "Steepness should differ");
    }

    function test_uninitializedAccountant_reverts() public {
        address uninitialized = address(0xDEAD);

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(0.5e18);

        // Uninitialized accountant has steepness = 0, which causes division by zero
        vm.prank(uninitialized);
        vm.expectRevert(); // Division by zero panic
        ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
    }

    // ============================================
    // Simpson's Rule / Trapezoidal Average Tests
    // ============================================

    function test_simpsonsRule_averageIsCorrect() public {
        // The average formula: (initial + new + 2*mid) / 4
        // This is Simpson's 1/3 rule approximation for integral average

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(WAD);

        // Set initial timestamp
        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        (uint64 initialYT,,) = ydm.accountantToCurve(address(this));

        uint256 elapsed = 30 days;
        vm.warp(vm.getBlockTimestamp() + elapsed);

        // Get the returned yield share (which is the average)
        uint256 avgYieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        // Compute expected values manually
        int256 normalizedDelta = _computeNormalizedDelta(WAD);
        int256 adaptationSpeed = (MAX_ADAPTATION_SPEED_WAD * normalizedDelta) / WAD_INT;
        int256 linearAdaptation = adaptationSpeed * int256(elapsed);

        uint256 newYT = _computeAdaptedYT(initialYT, linearAdaptation);
        uint256 midYT = _computeAdaptedYT(initialYT, linearAdaptation / 2);
        uint256 expectedAvgYT = (initialYT + newYT + 2 * midYT) / 4;

        uint256 expectedAvgYieldShare = _computeExpectedYieldShare(DEFAULT_STEEPNESS, normalizedDelta, expectedAvgYT);

        assertApproxEqAbs(avgYieldShare, expectedAvgYieldShare, 1, "Average yield share should match Simpson's rule");
    }

    // ============================================
    // Edge Cases
    // ============================================

    function test_edgeCase_zeroJTEffectiveNAV() public view {
        NAV_UNIT stRawNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0));
        NAV_UNIT jtEffectiveNAV = ZERO_NAV_UNITS; // Zero
        uint256 betaWAD = WAD;
        uint256 minCoverageWAD = WAD;

        // CoverageUtilization = infinity, capped to WAD
        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        // Should return yield at full coverageUtilization
        (NAV_UNIT stRawNAV2, NAV_UNIT jtRawNAV2, uint256 betaWAD2, uint256 minCoverageWAD2, NAV_UNIT jtEffectiveNAV2) = _createInputsForCoverageUtilization(WAD);
        uint256 yieldShareAtFull = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV2,jtRawNAV2,betaWAD2,minCoverageWAD2,jtEffectiveNAV2));

        assertEq(yieldShare, yieldShareAtFull, "Zero JT effective NAV should cap coverageUtilization");
    }

    function test_edgeCase_zeroBeta() public view {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV,, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(0.5e18);

        uint256 betaWAD = 0;

        // With beta = 0, coverageUtilization only considers ST
        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        // CoverageUtilization = ST * coverage / jtEffective = 0.25e18 * 1 / 1e18 = 0.25
        // This should result in a lower yield than with beta = 1
        assertGt(yieldShare, 0, "Should return non-zero yield share");
    }

    function test_edgeCase_differentBeta() public view {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV,, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(0.5e18);

        uint256 yield1 = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,0,minCoverageWAD,jtEffectiveNAV));
        uint256 yield2 = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,0.5e18,minCoverageWAD,jtEffectiveNAV));
        uint256 yield3 = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,WAD,minCoverageWAD,jtEffectiveNAV));

        assertLe(yield1, yield2, "Higher beta should mean higher coverageUtilization and yield");
        assertLe(yield2, yield3, "Higher beta should mean higher coverageUtilization and yield");
    }

    function test_edgeCase_differentCoverage() public view {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD,, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(0.5e18);

        uint256 yield1 = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,0.5e18,jtEffectiveNAV));
        uint256 yield2 = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,WAD,jtEffectiveNAV));

        assertLe(yield1, yield2, "Higher coverage should mean higher coverageUtilization and yield");
    }

    // ============================================
    // Fuzz Tests
    // ============================================

    function testFuzz_initializeYDMForMarket_validParams(uint64 _yT, uint64 _yFull) public {
        _yT = uint64(bound(_yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, WAD));
        _yFull = uint64(bound(_yFull, _yT, WAD));

        AdaptiveCurveYDM_V1 newYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);
        newYdm.initializeYDMForMarket(_yT, _yFull);

        (uint64 storedYT,, uint160 storedSteepness) = newYdm.accountantToCurve(address(this));

        assertEq(storedYT, _yT, "YT should be stored correctly");
        assertEq(storedSteepness, uint160((uint256(_yFull) * WAD) / _yT), "Steepness should be computed correctly");
    }

    function testFuzz_previewYieldShare_resultInValidRange(
        uint128 _stRawNAV,
        uint128 _jtRawNAV,
        uint128 _jtEffectiveNAV,
        uint128 _betaWAD,
        uint128 _minCoverageWAD
    )
        public
        view
    {
        // Bound inputs to reasonable ranges
        _jtEffectiveNAV = uint128(bound(_jtEffectiveNAV, 1e12, type(uint128).max));
        _betaWAD = uint128(bound(_betaWAD, 0, WAD));
        _minCoverageWAD = uint128(bound(_minCoverageWAD, 0.01e18, WAD));

        NAV_UNIT stRawNAV = toNAVUnits(uint256(_stRawNAV));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(_jtRawNAV));
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(_jtEffectiveNAV));

        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,_betaWAD,_minCoverageWAD,jtEffectiveNAV));

        assertLe(yieldShare, WAD, "Yield share should not exceed WAD");
    }

    function testFuzz_adaptation_directionCorrect(uint256 _coverageUtilizationWAD, uint256 _elapsed) public {
        _coverageUtilizationWAD = bound(_coverageUtilizationWAD, 0, 2 * WAD); // Allow > 100% to test capping
        _elapsed = bound(_elapsed, 1 days, 365 days);

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(_coverageUtilizationWAD);

        // Initialize and set timestamp
        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        (uint64 ytBefore,,) = ydm.accountantToCurve(address(this));

        vm.warp(vm.getBlockTimestamp() + _elapsed);

        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        (uint64 ytAfter,,) = ydm.accountantToCurve(address(this));

        uint256 cappedUtil = _coverageUtilizationWAD > WAD ? WAD : _coverageUtilizationWAD;
        if (cappedUtil > TARGET_COVERAGE_UTILIZATION_WAD) {
            assertGe(ytAfter, ytBefore, "YT should increase or stay same with high coverageUtilization");
        } else if (cappedUtil < TARGET_COVERAGE_UTILIZATION_WAD) {
            assertLe(ytAfter, ytBefore, "YT should decrease or stay same with low coverageUtilization");
        }
    }

    function testFuzz_monotonicity_acrossCoverageUtilization(uint256 _util1, uint256 _util2) public view {
        _util1 = bound(_util1, 0, WAD);
        _util2 = bound(_util2, 0, WAD);

        if (_util1 > _util2) {
            (_util1, _util2) = (_util2, _util1);
        }

        (NAV_UNIT stRawNAV1, NAV_UNIT jtRawNAV1, uint256 betaWAD1, uint256 minCoverageWAD1, NAV_UNIT jtEffectiveNAV1) = _createInputsForCoverageUtilization(_util1);
        (NAV_UNIT stRawNAV2, NAV_UNIT jtRawNAV2, uint256 betaWAD2, uint256 minCoverageWAD2, NAV_UNIT jtEffectiveNAV2) = _createInputsForCoverageUtilization(_util2);

        uint256 yield1 = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV1,jtRawNAV1,betaWAD1,minCoverageWAD1,jtEffectiveNAV1));
        uint256 yield2 = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV2,jtRawNAV2,betaWAD2,minCoverageWAD2,jtEffectiveNAV2));

        assertLe(yield1, yield2, "Yield should be monotonically increasing with coverageUtilization");
    }

    function testFuzz_yieldShare_matchesPreview(
        uint128 _stRawNAV,
        uint128 _jtRawNAV,
        uint128 _jtEffectiveNAV,
        uint128 _betaWAD,
        uint128 _minCoverageWAD
    )
        public
    {
        _jtEffectiveNAV = uint128(bound(_jtEffectiveNAV, 1e12, type(uint128).max));
        _betaWAD = uint128(bound(_betaWAD, 0, WAD));
        _minCoverageWAD = uint128(bound(_minCoverageWAD, 0.01e18, WAD));

        NAV_UNIT stRawNAV = toNAVUnits(uint256(_stRawNAV));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(_jtRawNAV));
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(_jtEffectiveNAV));

        // Set initial timestamp
        ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,_betaWAD,_minCoverageWAD,jtEffectiveNAV));

        vm.warp(vm.getBlockTimestamp() + 1 days);

        uint256 preview = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,_betaWAD,_minCoverageWAD,jtEffectiveNAV));
        uint256 actual = ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,_betaWAD,_minCoverageWAD,jtEffectiveNAV));

        assertEq(preview, actual, "Preview should match actual");
    }

    function testFuzz_curveConfiguration_invariants(uint64 _yT, uint64 _yFull, uint256 _coverageUtilizationWAD) public {
        _yT = uint64(bound(_yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, WAD));
        _yFull = uint64(bound(_yFull, _yT, WAD));
        _coverageUtilizationWAD = bound(_coverageUtilizationWAD, 0, WAD);

        AdaptiveCurveYDM_V1 testYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);
        testYdm.initializeYDMForMarket(_yT, _yFull);

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(_coverageUtilizationWAD);

        uint256 yieldShare = testYdm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        // Invariants:
        // 1. Result should be within [YT/S, S*YT] capped at WAD
        // Allow 1 wei tolerance for integer division rounding
        (,, uint160 steepness) = testYdm.accountantToCurve(address(this));
        uint256 minYield = (_yT * WAD) / steepness;
        uint256 maxYield = (uint256(_yT) * steepness) / WAD;
        if (maxYield > WAD) maxYield = WAD;

        // Use approximate equality to handle rounding (1 wei tolerance)
        assertGe(yieldShare + 1, minYield, "Yield should be >= YT/S (with 1 wei tolerance)");
        assertLe(yieldShare, maxYield + 1, "Yield should be <= S*YT (with 1 wei tolerance)");
    }

    function testFuzz_adaptation_clampingWorks(uint256 _numSteps, bool _highUtil) public {
        // Use multiple smaller steps to avoid exp overflow
        _numSteps = bound(_numSteps, 1, 20); // 1-20 iterations of 30 days each

        uint256 coverageUtilizationWAD = _highUtil ? WAD : 0;
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(coverageUtilizationWAD);

        // Start near the boundary that we're testing
        AdaptiveCurveYDM_V1 testYdm = new AdaptiveCurveYDM_V1(TARGET_COVERAGE_UTILIZATION_WAD);
        if (_highUtil) {
            testYdm.initializeYDMForMarket(0.9e18, uint64(WAD)); // Near max
        } else {
            testYdm.initializeYDMForMarket(uint64(MIN_JT_YIELD_SHARE_AT_TARGET_WAD), uint64(WAD)); // At min
        }

        testYdm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        // Apply adaptation in multiple steps to avoid exp overflow
        for (uint256 i = 0; i < _numSteps; i++) {
            vm.warp(vm.getBlockTimestamp() + 30 days);
            testYdm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        }

        (uint64 yT,,) = testYdm.accountantToCurve(address(this));

        assertGe(yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be >= MIN");
        assertLe(yT, MAX_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be <= MAX");
    }

    // ============================================
    // Adversarial Tests
    // ============================================

    function test_adversarial_rapidStateChanges() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(WAD);

        // Rapid back-and-forth between PERPETUAL and FIXED_TERM
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            MarketState state = i % 2 == 0 ? MarketState.PERPETUAL : MarketState.FIXED_TERM;
            ydm.yieldShare(state, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        }

        // Should not revert, curve should still be valid
        (uint64 yT,,) = ydm.accountantToCurve(address(this));
        assertGe(yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be valid after rapid state changes");
        assertLe(yT, MAX_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be valid after rapid state changes");
    }

    function test_adversarial_extremeCoverageUtilizationSwings() public {
        // Swing between 0% and 100% coverageUtilization rapidly
        for (uint256 i = 0; i < 10; i++) {
            uint256 util = i % 2 == 0 ? 0 : WAD;
            (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(util);

            vm.warp(vm.getBlockTimestamp() + 1 days);
            ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
        }

        // Should not revert, curve should still be valid
        (uint64 yT,,) = ydm.accountantToCurve(address(this));
        assertGe(yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be valid after extreme swings");
        assertLe(yT, MAX_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be valid after extreme swings");
    }

    function test_adversarial_multipleAccountantsSimultaneous() public {
        address[] memory accountants = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            accountants[i] = address(uint160(i + 100));
            vm.prank(accountants[i]);
            ydm.initializeYDMForMarket(uint64(MIN_JT_YIELD_SHARE_AT_TARGET_WAD + i * 0.1e18), uint64(WAD));
        }

        // All accountants call in rapid succession
        for (uint256 round = 0; round < 5; round++) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            for (uint256 i = 0; i < 5; i++) {
                uint256 util = (i * 0.25e18);
                (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 minCoverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForCoverageUtilization(util);

                vm.prank(accountants[i]);
                ydm.yieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));
            }
        }

        // All curves should still be valid and independent
        for (uint256 i = 0; i < 5; i++) {
            (uint64 yT,,) = ydm.accountantToCurve(accountants[i]);
            assertGe(yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be valid");
            assertLe(yT, MAX_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be valid");
        }
    }

    function test_adversarial_veryLargeNAVValues() public view {
        // Use near-max uint128 values
        NAV_UNIT stRawNAV = toNAVUnits(uint256(type(uint128).max));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(type(uint128).max));
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(type(uint128).max));
        uint256 betaWAD = WAD;
        uint256 minCoverageWAD = WAD;

        // Should not revert
        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        assertLe(yieldShare, WAD, "Yield should be capped at WAD even with large values");
    }

    function test_adversarial_verySmallNAVValues() public view {
        // Use very small values
        NAV_UNIT stRawNAV = toNAVUnits(uint256(1));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(1));
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1));
        uint256 betaWAD = WAD;
        uint256 minCoverageWAD = WAD;

        // Should not revert
        uint256 yieldShare = ydm.previewYieldShare(MarketState.PERPETUAL, _coverageUtilizationFromNAVs(stRawNAV,jtRawNAV,betaWAD,minCoverageWAD,jtEffectiveNAV));

        assertLe(yieldShare, WAD, "Yield should be valid with small values");
    }
}
