// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { WAD, ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { MarketState, Operation, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits } from "../../../src/libraries/Units.sol";
import { toUint256 } from "../../../src/libraries/Units.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_Utilization_Accountant
 * @notice The coverage and liquidity utilization computations on the post-op surface: the zero
 *         short-circuits and their precedence over the max edges, ceil bias exactness, the junior raw
 *         NAV in the coverage numerator, and the pre-op placeholder versus post-op fresh-value contract
 */
contract Test_Utilization_Accountant is AccountantTestBase {
    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(_defaultParams());
    }

    /**
     * zero minimum requirements short-circuit both utilizations to 0 before any max edge can fire —
     * a live senior exposure against a zero junior buffer and zero market-making inventory reads (0, 0), so
     * the fully enforced deposit passes both gates
     */
    function test_Utilization_bothZeroWhenMinimumRequirementsZero() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.minCoverageWAD = 0;
        p.minLiquidityWAD = 0;
        _deploy(p);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, 0, "zero minimum coverage short-circuits before the empty-buffer max edge");
        assertEq(state.liquidityUtilizationWAD, 0, "zero minimum liquidity short-circuits before the empty-inventory max edge");
    }

    /**
     * a zero covered exposure reads a zero coverage utilization and a zero senior effective NAV reads
     * a zero liquidity utilization, each taking precedence over its own zero-denominator max edge, so a
     * market drained by a full senior redemption reads (0, 0) instead of (max, max)
     */
    function test_Utilization_zeroExposureAndZeroSTEffectivePrecedeMaxEdges() public {
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
        SyncedAccountingState memory state = kernel.doPostOp(Operation.ST_REDEEM, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, 0, "no covered exposure so coverage utilization is zero, preceding the empty-buffer max edge");
        assertEq(state.liquidityUtilizationWAD, 0, "zero senior effective NAV precedes the zero-inventory max edge");
    }

    /**
     * live exposure against a zero junior buffer reads a uint256 max coverage utilization, and live
     * senior value against a zero market-making inventory reads a uint256 max liquidity utilization — and the
     * enforced gate then rejects the next senior deposit on the coverage side first
     */
    function test_Utilization_bothMaxWhenBuffersZero() public {
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
        assertEq(state.coverageUtilizationWAD, type(uint256).max, "zero junior buffer against live exposure reads max");
        assertEq(state.liquidityUtilizationWAD, type(uint256).max, "zero inventory against live senior value reads max");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(100e18 + 1)), ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, true);
    }

    /**
     * ceil bias exactness on awkward values against independent math — each utilization matches the
     * spec formula and satisfies util * denominator >= product > (util - 1) * denominator
     */
    function test_Utilization_ceilBiasExactness() public {
        _seedState(SEED_ST_RAW, 300e18, SEED_ST_RAW, 300e18, 0, 100e18, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 7), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, false);
        uint256 coverageUtilization = state.coverageUtilizationWAD;
        uint256 covProduct = (SEED_ST_RAW + 7 + 300e18) * uint256(DEFAULT_MIN_COVERAGE_WAD);
        assertEq(coverageUtilization, _specCoverageUtilization(SEED_ST_RAW + 7, 300e18, DEFAULT_MIN_COVERAGE_WAD, 300e18), "coverage matches the independent ceil");
        assertGe(coverageUtilization * 300e18, covProduct, "coverage ceil bias covers the exact product");
        assertLt((coverageUtilization - 1) * 300e18, covProduct, "coverage ceil tightness, one less would under-cover");
        uint256 liquidityUtilization = state.liquidityUtilizationWAD;
        uint256 liqProduct = (SEED_ST_RAW + 7) * uint256(DEFAULT_MIN_LIQUIDITY_WAD);
        assertEq(liquidityUtilization, _specLiquidityUtilization(SEED_ST_RAW + 7, DEFAULT_MIN_LIQUIDITY_WAD, 100e18), "liquidity matches the independent ceil");
        assertGe(liquidityUtilization * 100e18, liqProduct, "liquidity ceil bias covers the exact product");
        assertLt((liquidityUtilization - 1) * 100e18, liqProduct, "liquidity ceil tightness, one less would under-cover");
    }

    /**
     * the coverage numerator includes the junior raw NAV alongside the senior raw NAV
     * Derivation: after a 50e18 junior deposit, ceil((1000e18 + 250e18) * 0.1e18 / 250e18) = 0.5e18,
     * while a numerator excluding the junior raw NAV would read ceil(1000e18 * 0.1e18 / 250e18) = 0.4e18
     */
    function test_Utilization_coverageNumeratorIncludesJTRaw() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(uint256(250e18)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(state.coverageUtilizationWAD, 0.5e18, "coverage numerator includes the junior raw NAV");
    }

    /**
     * a zero minimum liquidity reads zero even against a zero market-making inventory, taking precedence
     * over the zero-inventory max edge, so the enforced senior deposit passes its liquidity gate
     */
    function test_Utilization_liquidityZeroWhenMinLiquidityZero() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.minLiquidityWAD = 0;
        _deploy(p);
        _seedFlatWithLT(0);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW), ZERO_NAV_UNITS, ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, 0, "zero minimum liquidity precedes the zero-inventory max edge");
        assertLe(state.coverageUtilizationWAD, WAD, "coverage gate satisfied on its own terms");
    }

    /// a zero market-making inventory against a live requirement reads uint256 max and fires the enforced liquidity gate
    function test_Utilization_liquidityMaxWhenLTRawZero() public {
        _seedFlatWithLT(0);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW), ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
        assertEq(state.liquidityUtilizationWAD, type(uint256).max, "zero inventory against a live requirement reads max");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 11e18), toNAVUnits(SEED_JT_RAW), ZERO_NAV_UNITS, ZERO_NAV_UNITS, true);
    }

    /**
     * the pre-op returned state carries zero placeholders for the liquidity raw NAV and utilization (the
     * kernel refreshes them after committing the fresh mark) without clobbering the committed liquidity mark,
     * while the post-op returns the fresh real values
     */
    function test_Utilization_preOpPlaceholdersAndPostOpFreshValues() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory preOpState = kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(preOpState.ltRawNAV), 0, "pre-op lt raw NAV is a zero placeholder");
        assertEq(preOpState.liquidityUtilizationWAD, 0, "pre-op liquidity utilization is a zero placeholder");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), SEED_LT_RAW, "the placeholder never clobbers the committed lt mark");

        // The post-op returns the freshly marked liquidity values: liquidityUtilization = ceil(1010e18 * 0.05e18 / 100e18) = 0.505e18
        SyncedAccountingState memory postOpState =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(postOpState.ltRawNAV), SEED_LT_RAW, "post-op returns the real lt raw NAV");
        assertEq(postOpState.liquidityUtilizationWAD, 0.505e18, "post-op returns the fresh liquidity utilization");
    }
}
