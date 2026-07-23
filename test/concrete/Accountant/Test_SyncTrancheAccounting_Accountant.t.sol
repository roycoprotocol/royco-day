// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IYDM } from "../../../src/interfaces/IYDM.sol";
import { WAD, ZERO_NAV_UNITS } from "../../../src/libraries/Constants.sol";
import { MarketState, SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";
import { RoycoTestMath } from "../../utils/RoycoTestMath.sol";

/**
 * @title Test_SyncTrancheAccounting_Accountant
 * @notice The tranche accounting sync scenarios: graded collateral loss/flat/gain vectors across the
 *         committed IL/state regimes, the single-delta PnL attribution, the JT fee on the post-recovery
 *         residual gain, coverage, IL recovery, the dust-erasure boundary of the state machine, the premium
 *         branches, and NAV conservation: every scenario asserted against a hand-derived literal, the
 *         RoycoTestMath mirror, and the committed checkpoint at once
 * @dev The old two-legged (ST loss/flat/gain) x (JT loss/flat/gain) grids collapse: one collateral asset at
 *      one rate means the attributed tranche deltas always share the collateral delta's sign, so each regime
 *      is now swept by graded single-delta vectors whose attribution splits are derived by hand
 */
contract Test_SyncTrancheAccounting_Accountant is AccountantTestBase {
    uint256 internal constant SEED_COLLATERAL = SEED_ST_EFF + SEED_JT_EFF;

    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(_defaultParams());
    }

    /// @dev Fully hand-derived expectation for one sync vector, asserted field-by-field by _runSyncVector
    struct ExpectedSync {
        uint256 stEffectiveNAV;
        uint256 jtEffectiveNAV;
        uint256 il;
        uint256 ltPrem;
        uint256 stFee;
        uint256 jtFee;
        uint256 ltFee;
        MarketState marketState;
        uint32 fixedTermEndTimestamp;
    }

    /**
     * @dev Scenario runner: previews then executes the identical sync, asserts preview == execution
     * byte-for-byte (the one allowed both-sides-production assertion), asserts every returned field against the
     * hand-derived expectation, then re-reads the committed checkpoint and asserts exact NAV conservation plus
     * returned-vs-persisted equality and the il > 0 iff FIXED_TERM biconditional
     *
     * The coverage utilization is asserted against the documented formula ceil(collateralNAV * minCoverage / jtEffectiveNAV)
     * evaluated with test-local math on the hand-derived jt effective NAV
     */
    function _runSyncVector(uint256 _collateralNew, ExpectedSync memory _e) internal {
        IRoycoDayAccountant.RoycoDayAccountantState memory pre = accountant.getState();
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(_collateralNew));
        // The committed sync must emit TrancheAccountingSynced with the exact hand-derived resulting state
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.TrancheAccountingSynced(_expectedSyncedState(pre, _collateralNew, _e));
        SyncedAccountingState memory executed = kernel.doPreOp(toNAVUnits(_collateralNew));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(executed)), "vector: preview must match execution exactly");

        assertEq(uint8(executed.marketState), uint8(_e.marketState), "vector: market state");
        assertEq(toUint256(executed.collateralNAV), _collateralNew, "vector: collateral NAV passthrough");
        assertEq(toUint256(executed.ltRawNAV), 0, "vector: lt raw NAV placeholder");
        assertEq(toUint256(executed.stEffectiveNAV), _e.stEffectiveNAV, "vector: st effective NAV");
        assertEq(toUint256(executed.jtEffectiveNAV), _e.jtEffectiveNAV, "vector: jt effective NAV");
        assertEq(toUint256(executed.jtImpermanentLoss), _e.il, "vector: jt impermanent loss");
        assertEq(toUint256(executed.ltLiquidityPremium), _e.ltPrem, "vector: lt liquidity premium");
        assertEq(toUint256(executed.stProtocolFee), _e.stFee, "vector: st protocol fee");
        assertEq(toUint256(executed.jtProtocolFee), _e.jtFee, "vector: jt protocol fee");
        assertEq(toUint256(executed.ltProtocolFee), _e.ltFee, "vector: lt protocol fee");
        assertEq(executed.coverageUtilizationWAD, _expectedCoverageUtilization(_collateralNew, _e.jtEffectiveNAV), "vector: coverage utilization");
        assertEq(executed.liquidityUtilizationWAD, 0, "vector: liquidity utilization placeholder");
        assertEq(executed.fixedTermEndTimestamp, _e.fixedTermEndTimestamp, "vector: fixed term end timestamp");

        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastCollateralNAV), toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), "vector: committed NAV conservation");
        assertEq(toUint256(s.lastSTEffectiveNAV), _e.stEffectiveNAV, "vector: committed st effective NAV");
        assertEq(toUint256(s.lastJTEffectiveNAV), _e.jtEffectiveNAV, "vector: committed jt effective NAV");
        assertEq(toUint256(s.lastJTImpermanentLoss), _e.il, "vector: committed il");
        assertEq(uint8(s.lastMarketState), uint8(_e.marketState), "vector: committed market state");
        assertEq(s.fixedTermEndTimestamp, _e.fixedTermEndTimestamp, "vector: committed fixed term end");
        // The state-machine biconditional: a perpetual commit never carries a drawdown and a term always does
        assertEq(s.lastMarketState == MarketState.PERPETUAL, toUint256(s.lastJTImpermanentLoss) == 0, "vector: il > 0 iff FIXED_TERM");

        _crossAssertSyncMirror(pre, _collateralNew, executed);
    }

    /**
     * @dev Assembles the full SyncedAccountingState the sync must emit in TrancheAccountingSynced, from the
     * hand-derived expectation plus the pre-sync config fields. The lt raw NAV and liquidity utilization are
     * zero placeholders on the pre-op path (the kernel commits the fresh LT mark after the sync)
     */
    function _expectedSyncedState(
        IRoycoDayAccountant.RoycoDayAccountantState memory _pre,
        uint256 _collateralNew,
        ExpectedSync memory _e
    )
        internal
        pure
        returns (SyncedAccountingState memory st)
    {
        st.marketState = _e.marketState;
        st.collateralNAV = toNAVUnits(_collateralNew);
        st.ltRawNAV = ZERO_NAV_UNITS;
        st.stEffectiveNAV = toNAVUnits(_e.stEffectiveNAV);
        st.jtEffectiveNAV = toNAVUnits(_e.jtEffectiveNAV);
        st.jtImpermanentLoss = toNAVUnits(_e.il);
        st.ltLiquidityPremium = toNAVUnits(_e.ltPrem);
        st.stProtocolFee = toNAVUnits(_e.stFee);
        st.jtProtocolFee = toNAVUnits(_e.jtFee);
        st.ltProtocolFee = toNAVUnits(_e.ltFee);
        st.coverageUtilizationWAD = _expectedCoverageUtilization(_collateralNew, _e.jtEffectiveNAV);
        st.liquidityUtilizationWAD = 0;
        st.fixedTermEndTimestamp = _e.fixedTermEndTimestamp;
        st.minCoverageWAD = _pre.minCoverageWAD;
        st.coverageLiquidationUtilizationWAD = _pre.coverageLiquidationUtilizationWAD;
        st.minLiquidityWAD = _pre.minLiquidityWAD;
    }

    /**
     * @dev Builds the RoycoTestMath.SyncInputs for one sync from the pre-sync committed checkpoint, mirroring
     * the accrual model on the test side: when time elapsed since the last accrual, the mock YDMs' MUTATING rates (capped
     * at the configured maxima) are accrued onto the stored accumulators exactly as production does before the
     * sync consumes them. Same-block syncs pass the stored accumulators through unchanged
     */
    function _buildSyncInputs(
        IRoycoDayAccountant.RoycoDayAccountantState memory _pre,
        uint256 _collateralNew
    )
        internal
        view
        returns (RoycoTestMath.SyncInputs memory in_)
    {
        in_.collateralNAVLast = toUint256(_pre.lastCollateralNAV);
        in_.stEffectiveNAVLast = toUint256(_pre.lastSTEffectiveNAV);
        in_.jtEffectiveNAVLast = toUint256(_pre.lastJTEffectiveNAV);
        in_.jtImpermanentLossLast = toUint256(_pre.lastJTImpermanentLoss);
        in_.marketStateLast = RoycoTestMath.MarketState(uint8(_pre.lastMarketState));
        in_.fixedTermEndTimestampLast = _pre.fixedTermEndTimestamp;
        in_.collateralNAVDelta = int256(_collateralNew) - int256(in_.collateralNAVLast);
        // The kernel re-commits the unchanged LT mark after the sync in this suite
        in_.ltRawNAVNew = toUint256(_pre.lastLTRawNAV);
        // Mirror-side accrual: stored accumulators plus one capped mutating-rate window (first-ever accrual
        // initializes the clock and contributes nothing)
        in_.jtTwYieldShareAccrual = _pre.twJTYieldShareAccruedWAD;
        in_.ltTwYieldShareAccrual = _pre.twLTYieldShareAccruedWAD;
        if (_pre.lastYieldShareAccrualTimestamp != 0 && block.timestamp > _pre.lastYieldShareAccrualTimestamp) {
            uint256 elapsed = block.timestamp - _pre.lastYieldShareAccrualTimestamp;
            uint256 jtRate = jtYDM.yieldShareReturn();
            uint256 ltRate = ltYDM.yieldShareReturn();
            in_.jtTwYieldShareAccrual += (jtRate > _pre.maxJTYieldShareWAD ? _pre.maxJTYieldShareWAD : jtRate) * elapsed;
            in_.ltTwYieldShareAccrual += (ltRate > _pre.maxLTYieldShareWAD ? _pre.maxLTYieldShareWAD : ltRate) * elapsed;
        }
        // A first-ever accrual stamps lastPremiumPaymentTimestamp to now, so the premium window reads 0
        in_.elapsedSincePremiumPayment = _pre.lastYieldShareAccrualTimestamp == 0 ? 0 : block.timestamp - _pre.lastPremiumPaymentTimestamp;
        in_.jtInstYieldShareWAD = jtYDM.previewYieldShareReturn();
        in_.ltInstYieldShareWAD = ltYDM.previewYieldShareReturn();
        in_.maxJTYieldShareWAD = _pre.maxJTYieldShareWAD;
        in_.maxLTYieldShareWAD = _pre.maxLTYieldShareWAD;
        in_.stProtocolFeeWAD = _pre.stProtocolFeeWAD;
        in_.jtProtocolFeeWAD = _pre.jtProtocolFeeWAD;
        in_.jtYieldShareProtocolFeeWAD = _pre.jtYieldShareProtocolFeeWAD;
        in_.ltYieldShareProtocolFeeWAD = _pre.ltYieldShareProtocolFeeWAD;
        in_.nowTimestamp = block.timestamp;
        in_.fixedTermDuration = _pre.fixedTermDurationSeconds;
        in_.minCoverageWAD = _pre.minCoverageWAD;
        in_.coverageLiquidationUtilizationWAD = _pre.coverageLiquidationUtilizationWAD;
        in_.dustTolerance = toUint256(_pre.dustTolerance);
        in_.minLiquidityWAD = _pre.minLiquidityWAD;
    }

    /**
     * @dev Cross-asserts one executed sync against the independent RoycoTestMath.syncTrancheAccounting mirror field-by-field,
     * so every scenario is pinned by three sources at once: production, the hand-derived literal, and the
     * RoycoTestMath mirror. Also asserts the premiumsPaid side effects (accumulator reset and premium-payment stamp)
     * against the committed state, then commits the unchanged LT mark and asserts the mirror's post-commit
     * ltRawNAV / liquidity-utilization view
     */
    function _crossAssertSyncMirror(
        IRoycoDayAccountant.RoycoDayAccountantState memory _pre,
        uint256 _collateralNew,
        SyncedAccountingState memory _executed
    )
        internal
    {
        RoycoTestMath.SyncInputs memory in_ = _buildSyncInputs(_pre, _collateralNew);
        RoycoTestMath.SyncOutputs memory m = RoycoTestMath.syncTrancheAccounting(in_);

        assertEq(m.collateralNAV, toUint256(_executed.collateralNAV), "mirror: collateral NAV");
        assertEq(m.stEffectiveNAV, toUint256(_executed.stEffectiveNAV), "mirror: st effective NAV");
        assertEq(m.jtEffectiveNAV, toUint256(_executed.jtEffectiveNAV), "mirror: jt effective NAV");
        assertEq(m.jtImpermanentLoss, toUint256(_executed.jtImpermanentLoss), "mirror: jt impermanent loss");
        assertEq(m.ltLiquidityPremium, toUint256(_executed.ltLiquidityPremium), "mirror: lt liquidity premium");
        assertEq(m.stProtocolFee, toUint256(_executed.stProtocolFee), "mirror: st protocol fee");
        assertEq(m.jtProtocolFee, toUint256(_executed.jtProtocolFee), "mirror: jt protocol fee");
        assertEq(m.ltProtocolFee, toUint256(_executed.ltProtocolFee), "mirror: lt protocol fee");
        assertEq(m.coverageUtilizationWAD, _executed.coverageUtilizationWAD, "mirror: coverage utilization");
        assertEq(uint8(m.marketState), uint8(_executed.marketState), "mirror: market state");
        assertEq(m.fixedTermEndTimestamp, uint256(_executed.fixedTermEndTimestamp), "mirror: fixed term end");

        // premiumsPaid side effects (RoycoDayAccountant): reset both accumulators and stamp the payment timestamp,
        // otherwise the post-accrual accumulators persist and the payment window keeps running
        IRoycoDayAccountant.RoycoDayAccountantState memory post = accountant.getState();
        if (m.premiumsPaid) {
            assertEq(uint256(post.twJTYieldShareAccruedWAD), 0, "mirror: jt accumulator reset on premium payment");
            assertEq(uint256(post.twLTYieldShareAccruedWAD), 0, "mirror: lt accumulator reset on premium payment");
            assertEq(uint256(post.lastPremiumPaymentTimestamp), block.timestamp, "mirror: premium payment stamped");
        } else {
            assertEq(uint256(post.twJTYieldShareAccruedWAD), in_.jtTwYieldShareAccrual, "mirror: jt accumulator persists unpaid");
            assertEq(uint256(post.twLTYieldShareAccruedWAD), in_.ltTwYieldShareAccrual, "mirror: lt accumulator persists unpaid");
            uint256 expectedStamp = _pre.lastYieldShareAccrualTimestamp == 0 ? block.timestamp : _pre.lastPremiumPaymentTimestamp;
            assertEq(uint256(post.lastPremiumPaymentTimestamp), expectedStamp, "mirror: premium payment stamp unchanged");
        }

        // Post-commit view: commit the unchanged LT mark, then the committed lastLTRawNAV
        // must equal the mirror's pass-through and the mirror's liquidity utilization is the RTM.liquidityUtilization view
        kernel.doCommit(_pre.lastLTRawNAV);
        assertEq(toUint256(accountant.getState().lastLTRawNAV), m.ltRawNAV, "mirror: committed lt raw NAV pass-through");
        assertEq(
            m.liquidityUtilizationWAD,
            RoycoTestMath.computeLiquidityUtilization(m.stEffectiveNAV, in_.minLiquidityWAD, in_.ltRawNAVNew),
            "mirror: post-commit liquidity utilization"
        );
    }

    /// @dev Independent coverage utilization math: ceil(collateralNAV * 0.1e18 / jtEffectiveNAV) with the default minimum coverage
    function _expectedCoverageUtilization(uint256 _collateralNAV, uint256 _jtEff) internal pure returns (uint256) {
        uint256 requiredCoverageNAV = _collateralNAV * uint256(DEFAULT_MIN_COVERAGE_WAD);
        if (requiredCoverageNAV == 0) return 0;
        if (_jtEff == 0) return type(uint256).max;
        return (requiredCoverageNAV + _jtEff - 1) / _jtEff;
    }

    /*----------------------------------------------------------------------
                SYNC SCENARIOS — IL == 0, PERPETUAL (zero dust tolerance)
    ----------------------------------------------------------------------*/

    /*
     * Checkpoint collateral 1200e18, stEffectiveNAV 1000e18, jtEffectiveNAV 200e18, il 0, zero dust, PERPETUAL.
     * Attribution: a delta d attributes floor(|d| * 1000e18 / 1200e18) = floor(5|d| / 6) to ST with JT the residual,
     * so both legs always share d's sign. Losses are fully covered (jt buffer 200e18 exceeds every st leg here),
     * so the whole loss lands on jtEffectiveNAV as drawdown with stEffectiveNAV unchanged.
     */

    /**
     * Sync scenario (deep loss -70e18, IL 0): the covered loss lands wholly on JT as drawdown
     * Derivation: deltaST = -floor(70e18 * 5 / 6) = -58333333333333333333, deltaJT = -11666666666666666667.
     * The JT loss books il, coverage covers the whole ST leg: jtEffectiveNAV = 130e18, il = 70e18,
     * stEffectiveNAV unchanged. il > 0 forces FIXED_TERM entry (end = now + duration), no fees accrued
     */
    function test_Sync_NoIL_Loss70() public {
        _seedNoIL();
        _runSyncVector(
            1130e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 130e18,
                il: 70e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (loss -50e18, IL 0)
     * Derivation: deltaST = -floor(50e18 * 5 / 6) = -41666666666666666666, deltaJT = -8333333333333333334,
     * fully covered: jtEffectiveNAV = 150e18, il = 50e18, stEffectiveNAV unchanged, FIXED_TERM entry
     */
    function test_Sync_NoIL_Loss50() public {
        _seedNoIL();
        _runSyncVector(
            1150e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 150e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (loss -30e18, IL 0): an exact-division attribution split
     * Derivation: deltaST = -floor(30e18 * 5 / 6) = -25e18 exact, deltaJT = -5e18, fully covered:
     * jtEffectiveNAV = 170e18, il = 30e18, FIXED_TERM entry
     */
    function test_Sync_NoIL_Loss30() public {
        _seedNoIL();
        _runSyncVector(
            1170e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 170e18,
                il: 30e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (loss -20e18, IL 0)
     * Derivation: deltaST = -floor(20e18 * 5 / 6) = -16666666666666666666, deltaJT = -3333333333333333334,
     * fully covered: jtEffectiveNAV = 180e18, il = 20e18, FIXED_TERM entry
     */
    function test_Sync_NoIL_Loss20() public {
        _seedNoIL();
        _runSyncVector(
            1180e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 180e18,
                il: 20e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /// Sync scenario (flat, IL 0): the no-op sync leaves every field at the checkpoint (coverageUtilization exactly 0.6e18)
    function test_Sync_NoIL_Flat() public {
        _seedNoIL();
        _runSyncVector(
            1200e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 200e18,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
        // Literal anchor for the independent ceil helper: 1200e18 * 0.1e18 / 200e18 divides exactly to 0.6e18
        assertEq(_expectedCoverageUtilization(1200e18, 200e18), 0.6e18, "anchor: exact-division coverage utilization");
    }

    /**
     * Sync scenario (gain +20e18, IL 0): the JT residual takes its dust-gated fee and the ST leg pays instantaneous premiums
     * Derivation: deltaST = floor(20e18 * 5 / 6) = 16666666666666666666, deltaJT = 3333333333333333334.
     * JT residual above zero dust: jtFee = floor(3333333333333333334 * 0.1) = 333333333333333333.
     * ST gain premiums (instantaneous, preview rates 0.1e18 / 0.05e18):
     *   jtRiskPremium = floor(16666666666666666666 * 0.1) = 1666666666666666666 (yield-share fee 166666666666666666, jtFee total 499999999999999999)
     *   ltLiquidityPremium = floor(16666666666666666666 * 0.05) = 833333333333333333, ltFee = 83333333333333333
     *   st residual = 16666666666666666666 - 1666666666666666666 - 833333333333333333 = 14166666666666666667, stFee = 1416666666666666666
     *   jtEffectiveNAV = 200e18 + 3333333333333333334 + 1666666666666666666 = 205e18 exact
     *   stEffectiveNAV = 1000e18 + 14166666666666666667 + 833333333333333333 = 1015e18 exact (the lt premium stays senior)
     */
    function test_Sync_NoIL_Gain20() public {
        _seedNoIL();
        _runSyncVector(
            1220e18,
            ExpectedSync({
                stEffectiveNAV: 1015e18,
                jtEffectiveNAV: 205e18,
                il: 0,
                ltPrem: 833_333_333_333_333_333,
                stFee: 1_416_666_666_666_666_666,
                jtFee: 499_999_999_999_999_999,
                ltFee: 83_333_333_333_333_333,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (gain +30e18, IL 0): the exact-division twin of the +20e18 vector
     * Derivation: deltaST = 25e18 exact, deltaJT = 5e18. jtFee = 0.5e18 on the residual plus floor(2.5e18 * 0.1)
     * = 0.25e18 on the premium, total 0.75e18. jtPrem = 2.5e18, ltPrem = 1.25e18, ltFee = 0.125e18,
     * st residual = 21.25e18 so stFee = 2.125e18, jtEffectiveNAV = 207.5e18, stEffectiveNAV = 1022.5e18
     */
    function test_Sync_NoIL_Gain30() public {
        _seedNoIL();
        _runSyncVector(
            1230e18,
            ExpectedSync({
                stEffectiveNAV: 1022.5e18,
                jtEffectiveNAV: 207.5e18,
                il: 0,
                ltPrem: 1.25e18,
                stFee: 2.125e18,
                jtFee: 0.75e18,
                ltFee: 0.125e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (gain +50e18, IL 0)
     * Derivation: deltaST = floor(50e18 * 5 / 6) = 41666666666666666666, deltaJT = 8333333333333333334.
     * jtFee = 833333333333333333 (residual) + 416666666666666666 (on jtPrem 4166666666666666666) = 1249999999999999999.
     * ltPrem = 2083333333333333333, ltFee = 208333333333333333, st residual = 35416666666666666667,
     * stFee = 3541666666666666666, jtEffectiveNAV = 212.5e18 exact, stEffectiveNAV = 1037.5e18 exact
     */
    function test_Sync_NoIL_Gain50() public {
        _seedNoIL();
        _runSyncVector(
            1250e18,
            ExpectedSync({
                stEffectiveNAV: 1037.5e18,
                jtEffectiveNAV: 212.5e18,
                il: 0,
                ltPrem: 2_083_333_333_333_333_333,
                stFee: 3_541_666_666_666_666_666,
                jtFee: 1_249_999_999_999_999_999,
                ltFee: 208_333_333_333_333_333,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (deep gain +70e18, IL 0)
     * Derivation: deltaST = floor(70e18 * 5 / 6) = 58333333333333333333, deltaJT = 11666666666666666667.
     * jtFee = 1166666666666666666 (residual) + 583333333333333333 (on jtPrem 5833333333333333333) = 1749999999999999999.
     * ltPrem = 2916666666666666666, ltFee = 291666666666666666, st residual = 49583333333333333334,
     * stFee = 4958333333333333333, jtEffectiveNAV = 217.5e18 exact, stEffectiveNAV = 1052.5e18 exact
     */
    function test_Sync_NoIL_Gain70() public {
        _seedNoIL();
        _runSyncVector(
            1270e18,
            ExpectedSync({
                stEffectiveNAV: 1052.5e18,
                jtEffectiveNAV: 217.5e18,
                il: 0,
                ltPrem: 2_916_666_666_666_666_666,
                stFee: 4_958_333_333_333_333_333,
                jtFee: 1_749_999_999_999_999_999,
                ltFee: 291_666_666_666_666_666,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /*----------------------------------------------------------------------
        SYNC SCENARIOS — THE DUST-ERASURE BOUNDARY (dust 7, PERPETUAL)
    ----------------------------------------------------------------------*/

    /*
     * PERPETUAL with a persisted il is unrepresentable: every perpetual commit erases the IL ledger. The dust
     * tolerance's state-machine role is therefore the erasure boundary of a loss FROM a perpetual state: a
     * drawdown of at most dust resolves PERPETUAL and is erased at commit (reset event), one wei more locks the
     * market. These vectors deploy with dust 7 over the flat 1200e18 seed and pin both sides plus the
     * post-erasure checkpoint's plain-gain behavior.
     */

    /// @dev Deploys with the single dust tolerance 7, seeds the flat market, and arms the preview rates
    function _seedDustSeven() internal {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(7));
        _deploy(p);
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /**
     * Sync scenario (loss of exactly dust, PERPETUAL): the drawdown is erased at the perpetual commit
     * Derivation: deltaST = -floor(7 * 1000e18 / 1200e18) = -5, deltaJT = -2. The covered loss lands wholly
     * on JT: jtEffectiveNAV = 200e18 - 7 with a would-be il of 7 <= dust 7 from PERPETUAL, so the perpetual
     * commit erases it (reset event 7). The loss itself stays realized on jt
     */
    function test_Sync_DustBoundary_LossOfExactlyDustErasedAtCommit() public {
        _seedDustSeven();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(7)));
        _runSyncVector(
            1200e18 - 7,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 200e18 - 7,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (loss of dust + 1, PERPETUAL): one wei above the dust tolerance locks the market
     * Derivation: deltaST = -floor(8 * 1000e18 / 1200e18) = -6, deltaJT = -2. jtEffectiveNAV = 200e18 - 8,
     * il = 8 > dust 7 so the sync enters FIXED_TERM (end = now + duration), the strict > gate pinned both sides
     */
    function test_Sync_DustBoundary_LossOneWeiAboveDustLocksFixedTerm() public {
        _seedDustSeven();
        _runSyncVector(
            1200e18 - 8,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 200e18 - 8,
                il: 8,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (gain after a dust erasure): the erased ledger leaves nothing to restore, the gain is plain
     * Derivation: after the erased 7 wei loss the checkpoint is (1200e18 - 7, stEff 1000e18, jtEff 200e18 - 7, il 0).
     * A +7 gain attributes deltaST = floor(7 * 1000e18 / (1200e18 - 7)) = 5 with JT residual 2: no ledger to
     * repay, the 2 wei JT residual is at most dust (no fee), the 5 wei ST gain is at most dust (premiumsPaid
     * false) and the instantaneous premiums floor to 0: stEffectiveNAV = 1000e18 + 5, jtEffectiveNAV = 200e18 - 5.
     * JT does NOT return to its high-water 200e18: the erasure converted the drawdown into a realized loss
     */
    function test_Sync_DustBoundary_PostErasureGainIsPlainNotRecovery() public {
        _seedDustSeven();
        kernel.doPreOp(toNAVUnits(uint256(1200e18 - 7)));
        _runSyncVector(
            1200e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 5,
                jtEffectiveNAV: 200e18 - 5,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (offset checkpoint, loss -20e18 + 7, dust 7): awkward-offset attribution floors
     * Derivation from the post-erasure checkpoint (1200e18 - 7, stEff 1000e18, jtEff 200e18 - 7):
     * the loss to 1180e18 is 19999999999999999993: deltaST = -floor(19999999999999999993 * 1000e18 / (1200e18 - 7))
     * = -16666666666666666660, deltaJT = -3333333333333333333, fully covered: jtEffectiveNAV = 180e18 exact,
     * il = 19999999999999999993 > dust, FIXED_TERM entry
     */
    function test_Sync_DustBoundary_OffsetCheckpointLossToRoundTarget() public {
        _seedDustSeven();
        kernel.doPreOp(toNAVUnits(uint256(1200e18 - 7)));
        _runSyncVector(
            1180e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 180e18,
                il: 19_999_999_999_999_999_993,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (offset checkpoint, gain +20e18 + 7, dust 7): offset premium floors above the dust gate
     * Derivation from (1200e18 - 7, stEff 1000e18, jtEff 200e18 - 7): the gain to 1220e18 is 20000000000000000007:
     * deltaST = floor(20000000000000000007 * 1000e18 / (1200e18 - 7)) = 16666666666666666672, deltaJT = 3333333333333333335.
     * JT residual above dust 7: jtFee = 333333333333333333. ST gain premiums (instantaneous 0.1e18 / 0.05e18):
     *   jtPrem = 1666666666666666667 (fee 166666666666666666, jtFee total 499999999999999999)
     *   ltPrem = 833333333333333333, ltFee = 83333333333333333
     *   st residual = 14166666666666666672, stFee = 1416666666666666667
     *   stEffectiveNAV = 1015e18 + 5, jtEffectiveNAV = 205e18 - 5
     */
    function test_Sync_DustBoundary_OffsetCheckpointGainToRoundTarget() public {
        _seedDustSeven();
        kernel.doPreOp(toNAVUnits(uint256(1200e18 - 7)));
        _runSyncVector(
            1220e18,
            ExpectedSync({
                stEffectiveNAV: 1015e18 + 5,
                jtEffectiveNAV: 205e18 - 5,
                il: 0,
                ltPrem: 833_333_333_333_333_333,
                stFee: 1_416_666_666_666_666_667,
                jtFee: 499_999_999_999_999_999,
                ltFee: 83_333_333_333_333_333,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /*----------------------------------------------------------------------
        SYNC SCENARIOS — IL > dust, FIXED_TERM (the large-IL regime)
    ----------------------------------------------------------------------*/

    /*
     * Checkpoint collateral 1200e18, stEffectiveNAV 1000e18, jtEffectiveNAV 200e18, il 100e18, zero dust,
     * FIXED_TERM with end T0+D. Attribution splits floor(5|d| / 6) to ST with JT the residual. Losses deepen
     * the drawdown wholly on JT (full coverage), gains up to 100e18 are consumed entirely by IL recovery on
     * both legs, so the aggregate behavior is jtEffectiveNAV = 200e18 + d and il = 100e18 - d.
     */

    /**
     * Sync scenario (deep loss -70e18, large IL): the drawdown deepens wholly on JT
     * Derivation: deltaST = -58333333333333333333, deltaJT = -11666666666666666667, fully covered:
     * jtEffectiveNAV = 130e18, il = 170e18, market stays FIXED_TERM with the original end
     */
    function test_Sync_LargeIL_Loss70() public {
        _seedLargeIL();
        _runSyncVector(
            1130e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 130e18,
                il: 170e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /// Sync scenario (loss -50e18, large IL): jtEffectiveNAV = 150e18, il = 150e18, original end kept
    function test_Sync_LargeIL_Loss50() public {
        _seedLargeIL();
        _runSyncVector(
            1150e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 150e18,
                il: 150e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /// Sync scenario (loss -30e18, large IL): exact-division split, jtEffectiveNAV = 170e18, il = 130e18
    function test_Sync_LargeIL_Loss30() public {
        _seedLargeIL();
        _runSyncVector(
            1170e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 170e18,
                il: 130e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /// Sync scenario (loss -20e18, large IL): jtEffectiveNAV = 180e18, il = 120e18
    function test_Sync_LargeIL_Loss20() public {
        _seedLargeIL();
        _runSyncVector(
            1180e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 180e18,
                il: 120e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /// Sync scenario (flat, large IL): the FIXED_TERM checkpoint persists unchanged, original end kept, no events
    function test_Sync_LargeIL_Flat() public {
        _seedLargeIL();
        _runSyncVector(
            1200e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 200e18,
                il: 100e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (gain +20e18, large IL): both attribution legs are fully consumed repaying the drawdown
     * Derivation: deltaST = 16666666666666666666 and deltaJT = 3333333333333333334 both recover il:
     * jtEffectiveNAV = 220e18, il = 80e18, no fee (restoration is never fee'd), no premium (no residual),
     * term persists with the original end
     */
    function test_Sync_LargeIL_Gain20() public {
        _seedLargeIL();
        _runSyncVector(
            1220e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 220e18,
                il: 80e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /// Sync scenario (gain +30e18, large IL): jtEffectiveNAV = 230e18, il = 70e18, pure recovery
    function test_Sync_LargeIL_Gain30() public {
        _seedLargeIL();
        _runSyncVector(
            1230e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 230e18,
                il: 70e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /// Sync scenario (gain +50e18, large IL): jtEffectiveNAV = 250e18, il = 50e18, pure recovery
    function test_Sync_LargeIL_Gain50() public {
        _seedLargeIL();
        _runSyncVector(
            1250e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 250e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /// Sync scenario (deep gain +70e18, large IL): jtEffectiveNAV = 270e18, il = 30e18, pure recovery
    function test_Sync_LargeIL_Gain70() public {
        _seedLargeIL();
        _runSyncVector(
            1270e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 270e18,
                il: 30e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /*----------------------------------------------------------------------
        SYNC SCENARIOS — 0 < IL <= dust, FIXED_TERM (sticky dust)
    ----------------------------------------------------------------------*/

    /*
     * Checkpoint collateral 1200e18-5, stEffectiveNAV 1000e18, jtEffectiveNAV 200e18-5, il 5, dust 7,
     * FIXED_TERM with end T0+D (the sticky-dust state: il in (0, dust] entered from a deeper drawdown).
     * Attribution: a delta d attributes floor(|d| * 1000e18 / (1200e18-5)) to ST with JT the residual.
     */

    /**
     * Sync scenario (deep loss to 1130e18, sticky dust): staging offsets cancel to round outputs
     * Derivation: the loss is 70e18-5: deltaST = -floor((70e18-5) * 1000e18 / (1200e18-5)) = -58333333333333333329,
     * deltaJT = -11666666666666666666, fully covered: jtEffectiveNAV = 130e18 exact, il = 5 + (70e18-5) = 70e18,
     * stEffectiveNAV unchanged, term persists with the original end
     */
    function test_Sync_FixedTermDustIL_LossTo1130() public {
        _seedDustILFixedTerm();
        _runSyncVector(
            1130e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 130e18,
                il: 70e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (loss to 1150e18, sticky dust)
     * Derivation: loss 50e18-5 lands wholly on JT: jtEffectiveNAV = 150e18, il = 50e18, original end kept
     */
    function test_Sync_FixedTermDustIL_LossTo1150() public {
        _seedDustILFixedTerm();
        _runSyncVector(
            1150e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 150e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (loss -20e18, sticky dust): the drawdown deepens past the dust band and the term persists
     * Derivation: deltaST = -16666666666666666666, deltaJT = -3333333333333333334, fully covered:
     * jtEffectiveNAV = 180e18-5, il = 20e18+5, original end kept
     */
    function test_Sync_FixedTermDustIL_Loss20() public {
        _seedDustILFixedTerm();
        _runSyncVector(
            1180e18 - 5,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 180e18 - 5,
                il: 20e18 + 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (flat, sticky dust): the pure dust-IL stickiness scenario
     * Derivation: zero delta, il 5 in (0, 7] with initial FIXED_TERM stays FIXED_TERM with the ORIGINAL end
     * (the dust-erasure disjunct requires an initial PERPETUAL), all fee and premium fields zero
     */
    function test_Sync_FixedTermDustIL_Flat() public {
        _seedDustILFixedTerm();
        _runSyncVector(
            1200e18 - 5,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 200e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * Sync scenario (gain +20e18, sticky dust): the repayment zeroes the dust il and exits the term with fees kept
     * Derivation: repayment 5 zeroes the il (jtEffectiveNAV 200e18, residual 20e18-5, basis 1200e18):
     * stGain = floor((20e18-5) * 1000e18 / 1200e18) = 16666666666666666662, jtGain = 3333333333333333333 > dust 7
     * books jtFee = 333333333333333333. ST premiums (instantaneous 0.1e18 / 0.05e18):
     *   jtPrem = 1666666666666666666 (fee 166666666666666666, jtFee total 499999999999999999)
     *   ltPrem = 833333333333333333, ltFee = 83333333333333333
     *   st residual = 14166666666666666663, stFee = 1416666666666666666
     *   jtEffectiveNAV = 200e18 + 3333333333333333333 + 1666666666666666666 = 204999999999999999999
     *   stEffectiveNAV = 1000e18 + 14166666666666666663 + 833333333333333333 = 1014999999999999999996
     * il 0 exits to PERPETUAL (end deleted, FixedTermEnded), the organic repayment emits no reset event
     */
    function test_Sync_FixedTermDustIL_Gain20ExitsTermWithFeesKept() public {
        _seedDustILFixedTerm();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        _runSyncVector(
            1220e18 - 5,
            ExpectedSync({
                stEffectiveNAV: 1015e18 - 4,
                jtEffectiveNAV: 205e18 - 1,
                il: 0,
                ltPrem: 833_333_333_333_333_333,
                stFee: 1_416_666_666_666_666_666,
                jtFee: 499_999_999_999_999_999,
                ltFee: 83_333_333_333_333_333,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (gain to 1250e18, sticky dust): the offset gain crosses the repayment into full premium flows
     * Derivation: the gain is 50e18+5: repayment 5 zeroes the il (jtEffectiveNAV 200e18, residual 50e18,
     * basis 1200e18): stGain = floor(50e18 * 1000e18 / 1200e18) = 41666666666666666666,
     * jtGain = 8333333333333333334 books jtFee = 833333333333333333. ST premiums: jtPrem = 4166666666666666666
     * (fee 416666666666666666, total jtFee 1249999999999999999), ltPrem = 2083333333333333333,
     * ltFee = 208333333333333333, st residual = 35416666666666666667, stFee = 3541666666666666666,
     * jtEffectiveNAV = 212.5e18 exact, stEffectiveNAV = 1037.5e18 exact, PERPETUAL exit
     */
    function test_Sync_FixedTermDustIL_GainTo1250ExitsTerm() public {
        _seedDustILFixedTerm();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        _runSyncVector(
            1250e18,
            ExpectedSync({
                stEffectiveNAV: 1037.5e18,
                jtEffectiveNAV: 212.5e18,
                il: 0,
                ltPrem: 2_083_333_333_333_333_333,
                stFee: 3_541_666_666_666_666_666,
                jtFee: 1_249_999_999_999_999_999,
                ltFee: 208_333_333_333_333_333,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /*----------------------------------------------------------------------
        AUXILIARY SYNC SCENARIOS — exhaustion, recovery boundaries, premium branches
    ----------------------------------------------------------------------*/

    /**
     * Sync scenario (loss past JT exhaustion with an uncovered residual + wipeout erasure): from the flat no-IL checkpoint,
     * sync to 900e18
     * Derivation: deltaST = -floor(300e18 * 5 / 6) = -250e18, deltaJT = -50e18. The JT leg empties toward the
     * buffer (jtEffectiveNAV 150e18, il 50e18), coverage = min(250e18, 150e18) = 150e18 exhausts jt
     * (jtEffectiveNAV = 0, would-be il 200e18), residual 100e18 hits senior: stEffectiveNAV = 900e18.
     * coverageUtilization = uint256 max (jtEffectiveNAV == 0 against a positive requirement), and the wipeout
     * disjunct (jtEffectiveNAV == 0 with stEffectiveNAV > 0) forces PERPETUAL with the full il ERASED
     * (reset event 200e18), end 0. Conservation: 900e18 == 900e18 + 0.
     * Pins the pipeline lemma: an uncovered loss implies wipeout and can never commit FIXED_TERM
     */
    function test_Sync_UncoveredResidualLossWipeoutForcesPerpetual() public {
        _seedNoIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(200e18)));
        _runSyncVector(
            900e18,
            ExpectedSync({
                stEffectiveNAV: 900e18,
                jtEffectiveNAV: 0,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (exhaustion exactly at the boundary): from the flat no-IL checkpoint, sync to 1000e18
     * Derivation: the -200e18 loss splits deltaST = -166666666666666666666 / deltaJT = -33333333333333333334.
     * After the JT leg the buffer is 166666666666666666666, exactly the ST loss, so coverage consumes it to 0
     * with no residual: stEffectiveNAV stays 1000e18, would-be il 200e18 erased by the wipeout disjunct,
     * PERPETUAL, end 0. Distinguishes "fully covered but buffer emptied" (stEffectiveNAV intact) from the
     * uncovered-residual scenario
     */
    function test_Sync_ExhaustionAtExactBoundaryFullyCoveredWipeout() public {
        _seedNoIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(200e18)));
        _runSyncVector(
            1000e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 0,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (gain exactly == il, the recovery boundary with no premiums): from the large-IL fixed-term
     * checkpoint, sync to 1300e18
     * Derivation: the +100e18 gain splits deltaST = 83333333333333333333 / deltaJT = 16666666666666666667.
     * The JT leg recovers its full residual (il 83333333333333333333 left), the ST leg's recovery consumes its
     * entire gain (il = 0): jtEffectiveNAV = 300e18, stGain = 0 so the premium block is SKIPPED (premiumsPaid
     * false, accumulators NOT reset: asserted by the runner's premiumsPaid side-effect check). il 0 with
     * initial FIXED_TERM: PERPETUAL, end 0, FixedTermEnded, and no reset event (organic recovery erases nothing)
     */
    function test_Sync_GainExactlyEqualToILRecoveryBoundary() public {
        _seedLargeIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        _runSyncVector(
            1300e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 300e18,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (gain == il + 1 wei: the junior-favoring floor routes the wei to JT): from the large-IL
     * fixed-term checkpoint, sync to 1300e18 + 1
     * Derivation: the repayment consumes 100e18 of the gain (il 0, jtEffectiveNAV 300e18, residual 1,
     * basis 1300e18): stGain = floor(1 * 1000e18 / 1300e18) = 0, jtGain = 1 (fee floors to 0).
     * No senior gain survives, so the premium block is SKIPPED (premiumsPaid false, accumulators NOT reset:
     * the mirror's premiumsPaid flag is pinned false below). jtEffectiveNAV = 300e18 + 1, PERPETUAL
     */
    function test_Sync_GainOneWeiAboveILRoutesWeiToJuniorNoPremiums() public {
        _seedLargeIL();
        IRoycoDayAccountant.RoycoDayAccountantState memory pre = accountant.getState();
        _runSyncVector(
            1300e18 + 1,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 300e18 + 1,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
        // Pin the mirror's gate outcome explicitly: a sub-attribution residual never marks premiums paid
        RoycoTestMath.SyncOutputs memory m = RoycoTestMath.syncTrancheAccounting(_buildSyncInputs(pre, 1300e18 + 1));
        assertFalse(m.premiumsPaid, "a wei routed wholly to jt pays no premiums");
    }

    /**
     * Sync scenario (gain == il + 2 wei: 1-wei premium floors with premiumsPaid true): from the large-IL
     * fixed-term checkpoint, sync to 1300e18 + 2
     * Derivation: the repayment consumes 100e18 of the gain (il 0, jtEffectiveNAV 300e18, residual 2,
     * basis 1300e18): stGain = floor(2 * 1000e18 / 1300e18) = 1, jtGain = 1 (fee floors to 0).
     * premiumsPaid = (1 > dust 0) = true, yet every floored term floors to zero:
     * jtPrem = floor(1 * 0.1) = 0, ltPrem = 0, stFee = 0. stEffectiveNAV = 1000e18 + 1,
     * jtEffectiveNAV = 300e18 + 1, PERPETUAL. Pins that premiumsPaid true with all-zero premiums and fees
     * still resets the accumulators and stamps lastPremiumPaymentTimestamp, and the mirror's premiumsPaid
     * flag is pinned true below
     */
    function test_Sync_GainTwoWeiAboveILZeroPremiumsStillPay() public {
        _seedLargeIL();
        IRoycoDayAccountant.RoycoDayAccountantState memory pre = accountant.getState();
        _runSyncVector(
            1300e18 + 2,
            ExpectedSync({
                stEffectiveNAV: 1000e18 + 1,
                jtEffectiveNAV: 300e18 + 1,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
        // Pin the mirror's dust-gate outcome explicitly: the 1-wei senior residual clears the zero dust tolerance
        RoycoTestMath.SyncOutputs memory m = RoycoTestMath.syncTrancheAccounting(_buildSyncInputs(pre, 1300e18 + 2));
        assertTrue(m.premiumsPaid, "one-wei senior residual above zero dust pays premiums");
    }

    /**
     * Sync scenario (fee-carrying term exit): a gain deep enough that a junior residual survives the
     * repayment, so BOTH JT fee parts book alongside the full premium block and every fee is kept on the
     * PERPETUAL exit
     * Derivation: the +660e18 gain on the large-IL checkpoint repays the 100e18 il off the top
     * (jtEffectiveNAV 300e18, residual 560e18, basis 1300e18): stGain = floor(560e18 * 1000e18 / 1300e18) =
     * 430769230769230769230, jtGain = 129230769230769230770 books jtFee = 12923076923076923077.
     * ST premiums (instantaneous 0.1e18 / 0.05e18): jtPrem = 43076923076923076923 (fee 4307692307692307692,
     * jtFee total 17230769230769230769), ltPrem = 21538461538461538461 (ltFee 2153846153846153846),
     * st residual = 366153846153846153846 (stFee 36615384615384615384).
     * jtEffectiveNAV = 300e18 + 129230769230769230770 + 43076923076923076923 = 472307692307692307693,
     * stEffectiveNAV = 1000e18 + 366153846153846153846 + 21538461538461538461 = 1387692307692307692307.
     * il 0 exits to PERPETUAL: any fee-carrying resolution is PERPETUAL and keeps its fees (the theorem)
     */
    function test_Sync_FeeCarryingTermExitKeepsAllFees() public {
        _seedLargeIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        _runSyncVector(
            1860e18,
            ExpectedSync({
                stEffectiveNAV: 1_387_692_307_692_307_692_307,
                jtEffectiveNAV: 472_307_692_307_692_307_693,
                il: 0,
                ltPrem: 21_538_461_538_461_538_461,
                stFee: 36_615_384_615_384_615_384,
                jtFee: 17_230_769_230_769_230_769,
                ltFee: 2_153_846_153_846_153_846,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (liquidation-forced term exit): a mid-term loss that lands coverage utilization exactly on
     * the liquidation threshold erases the accumulated drawdown and forces PERPETUAL
     * Seed: flat 1000e18/130e18 then a covered -20e18 loss enters FIXED_TERM at (1110e18, stEff 1000e18,
     * jtEff 110e18, il 20e18) with coverageUtilization ceil(1110e18 * 0.1e18 / 110e18) = 1009090909090909091 < 1.1e18.
     * Derivation of the forced sync to 1100e18: deltaST = -floor(10e18 * 1000e18 / 1110e18) = -9009009009009009009,
     * deltaJT = -990990990990990991, fully covered: jtEffectiveNAV = 100e18, would-be il = 30e18.
     * coverageUtilization = ceil(1100e18 * 0.1e18 / 100e18) = 1.1e18 lands exactly on the threshold: the
     * liquidation disjunct forces PERPETUAL, erasing the 30e18 (reset event) and deleting the end
     */
    function test_Sync_LiquidationForcedExitErasesDrawdownMidTerm() public {
        _seedState(SEED_ST_EFF, 130e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(uint256(1110e18)));
        assertEq(uint8(accountant.getState().lastMarketState), uint8(MarketState.FIXED_TERM), "staging: the covered loss locks the term");
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(30e18)));
        _runSyncVector(
            1100e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 100e18,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (time-weighted twin of the instantaneous gain sync): flat no-IL seed, mutating rates jt 0.1e18 / lt 0.05e18,
     * warp +1 day, sync to 1250e18: identical outputs to the instantaneous +50e18 vector through the OTHER premium branch (real elapsed)
     * Derivation: accrual twJT = 0.1e18 * 86400 = 8640e18 and twLT = 0.05e18 * 86400 = 4320e18 (both events
     * asserted), elapsed = 86400 and deltaST = 41666666666666666666 so jtPrem = floor(deltaST * 8640e18 / (86400 * 1e18))
     * = 4166666666666666666 and ltPrem = 2083333333333333333. Fees as the instantaneous +50e18 vector:
     * jtFee 1249999999999999999, ltFee 208333333333333333, stFee 3541666666666666666,
     * stEffectiveNAV 1037.5e18, jtEffectiveNAV 212.5e18, PERPETUAL.
     * The runner's premiumsPaid check asserts both accumulators reset and the payment stamped at the warped time
     */
    function test_Sync_TimeWeightedPremiumBranchMatchesInstantaneousGainSync() public {
        _seedNoIL();
        jtYDM.setYieldShareReturn(0.1e18);
        ltYDM.setYieldShareReturn(0.05e18);
        vm.warp(block.timestamp + 86_400);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.YieldSharesAccrued(0.1e18, 8640e18, 0.05e18, 4320e18);
        _runSyncVector(
            1250e18,
            ExpectedSync({
                stEffectiveNAV: 1037.5e18,
                jtEffectiveNAV: 212.5e18,
                il: 0,
                ltPrem: 2_083_333_333_333_333_333,
                stFee: 3_541_666_666_666_666_666,
                jtFee: 1_249_999_999_999_999_999,
                ltFee: 208_333_333_333_333_333,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (two-window time-weighted averaging + the accrual-side cap): flat no-IL seed, 12h at rate jt 0.1e18 accrued
     * by a flat sync (which pays nothing and does NOT reset), then 12h at a hostile jt rate 0.5e18 CAPPED to
     * maxJT 0.2e18 at accrual, then sync to 1250e18
     * Derivation: twJT = 0.1e18 * 43200 + 0.2e18 * 43200 = 12960e18 over elapsed 86400 since the last payment
     * (the flat sync never stamps one). deltaST = 41666666666666666666 so jtPrem = floor(deltaST * 12960e18 /
     * (86400 * 1e18)) = floor(deltaST * 0.15) = 6249999999999999999. twLT = 0.05e18 * 86400 = 4320e18 so
     * ltPrem = 2083333333333333333. jtFee = 833333333333333333 (JT residual 8333333333333333334) +
     * 624999999999999999 (on jtPrem) = 1458333333333333332, ltFee = 208333333333333333,
     * st residual = 33333333333333333334 so stFee = 3333333333333333333,
     * stEffectiveNAV = 1000e18 + 33333333333333333334 + 2083333333333333333 = 1035416666666666666667,
     * jtEffectiveNAV = 200e18 + 8333333333333333334 + 6249999999999999999 = 214583333333333333333.
     * Conservation: 1250e18 == their sum. Pins the sum(share * dt) / elapsed averaging
     */
    function test_Sync_TwoWindowTimeWeightedAveragingWithAccrualCap() public {
        _seedNoIL();
        // Mutating and preview rates aligned so the preview-path accrual matches execution byte-for-byte
        jtYDM.setRates(0.1e18);
        ltYDM.setRates(0.05e18);
        // t0 read through an external call: a plain block.timestamp local is rematerialized at use-site by
        // via-ir and would read the warped time (the seed stamped this to the current block's timestamp)
        uint256 t0 = accountant.getState().lastPremiumPaymentTimestamp;
        assertEq(t0, block.timestamp, "seed stamped the premium payment clock this block");
        vm.warp(t0 + 43_200);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        // The flat sync accrues window 1 without paying or resetting: the payment window keeps running from t0
        IRoycoDayAccountant.RoycoDayAccountantState memory mid = accountant.getState();
        assertEq(uint256(mid.twJTYieldShareAccruedWAD), 0.1e18 * 43_200, "window 1 accrued");
        assertEq(uint256(mid.twLTYieldShareAccruedWAD), 0.05e18 * 43_200, "lt window 1 accrued");
        assertEq(uint256(mid.lastPremiumPaymentTimestamp), t0, "flat sync never stamps a premium payment");
        // Window 2 at a hostile mutating rate, clamped to the 0.2e18 max at accrual
        jtYDM.setRates(0.5e18);
        vm.warp(t0 + 86_400);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.YieldSharesAccrued(0.2e18, 12_960e18, 0.05e18, 4320e18);
        _runSyncVector(
            1250e18,
            ExpectedSync({
                stEffectiveNAV: 1_035_416_666_666_666_666_667,
                jtEffectiveNAV: 214_583_333_333_333_333_333,
                il: 0,
                ltPrem: 2_083_333_333_333_333_333,
                stFee: 3_333_333_333_333_333_333,
                jtFee: 1_458_333_333_333_333_332,
                ltFee: 208_333_333_333_333_333,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /*----------------------------------------------------------------------
                        PNL ATTRIBUTION
    ----------------------------------------------------------------------*/

    /**
     * with premium-shifted claims (stEff 980e18 / jtEff 220e18 over collateral 1200e18), a collateral loss is
     * attributed pro-rata to the shifted effective claims, not to any notional split
     * Derivation for a -100e18 loss: deltaST = -floor(100e18 * 980e18 / 1200e18) = -81666666666666666666,
     * deltaJT = -18333333333333333334. The JT loss books il, coverage covers the whole ST leg:
     * jtEffectiveNAV = 120e18, il = 100e18 (JT's full drawdown), stEffectiveNAV = 980e18, FIXED_TERM
     */
    function test_Sync_shiftedClaimsShareCollateralLossProRata() public {
        _seedState(980e18, 220e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1100e18)));
        assertEq(toUint256(state.stEffectiveNAV), 980e18, "st keeps its shifted claim under full coverage");
        assertEq(toUint256(state.jtEffectiveNAV), 120e18, "jt bears its attributed share plus the coverage");
        assertEq(toUint256(state.jtImpermanentLoss), 100e18, "il equals jt's full drawdown, its residual loss share plus the coverage applied");
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "covered loss forces fixed term");
    }

    /**
     * with premium-shifted claims, a collateral gain is attributed pro-rata to the shifted effective claims
     * Derivation for a +100e18 gain: deltaST = floor(100e18 * 980e18 / 1200e18) = 81666666666666666666,
     * deltaJT = 18333333333333333334. JT residual books jtFee = 1833333333333333333, jtEffectiveNAV = 238333333333333333334.
     * ST gain pays instantaneous premiums (rates 0.1e18 / 0.05e18): jtPrem = 8166666666666666666
     * (fee 816666666666666666, jtFee total 2649999999999999999), jtEffectiveNAV = 246.5e18 exact,
     * ltPrem = 4083333333333333333 (ltFee 408333333333333333), st residual = 69416666666666666667
     * (stFee 6941666666666666666), stEffectiveNAV = 980e18 + 69416666666666666667 + 4083333333333333333 = 1053.5e18
     */
    function test_Sync_shiftedClaimsShareCollateralGainProRata() public {
        _seedState(980e18, 220e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1300e18)));
        assertEq(toUint256(state.stEffectiveNAV), 1053.5e18, "st effective NAV from attributed gain and premium share-mint legs");
        assertEq(toUint256(state.jtEffectiveNAV), 246.5e18, "jt effective NAV from residual gain plus risk premium");
        assertEq(toUint256(state.ltLiquidityPremium), 4_083_333_333_333_333_333, "lt premium on st's attributed gain only");
        assertEq(toUint256(state.stProtocolFee), 6_941_666_666_666_666_666, "st fee on the retained residual");
        assertEq(toUint256(state.jtProtocolFee), 2_649_999_999_999_999_999, "jt fee compounds residual-gain and yield-share fees");
        assertEq(toUint256(state.ltProtocolFee), 408_333_333_333_333_333, "lt fee on the liquidity premium");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "gain sync stays perpetual");
    }

    /**
     * stEffectiveNAV == 0 zeroes the ST claim so the attribution routes the entire delta to JT as residual
     * Derivation for a +50e18 gain on a junior-only market (collateral 200e18, stEff 0, jtEff 200e18):
     * deltaST = 0 (the claim guard), deltaJT = 50e18: jt net gain books jtFee = 5e18, jtEffectiveNAV = 250e18,
     * stEffectiveNAV stays 0
     */
    function test_Sync_zeroSTClaimRoutesDeltaToJT() public {
        _seedState(0, 200e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(250e18)));
        assertEq(toUint256(state.stEffectiveNAV), 0, "no live senior claims so st receives nothing");
        assertEq(toUint256(state.jtEffectiveNAV), 250e18, "residual delta lands on jt");
        assertEq(toUint256(state.jtProtocolFee), 5e18, "junior net-gain fee on the routed delta");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "no il so the market stays perpetual");
    }

    /**
     * jtEffectiveNAV == 0 makes the ST claim the whole pool so the attribution routes the entire delta to ST
     * Derivation for a +50e18 gain on a senior-only market (collateral 1000e18, stEff 1000e18, jtEff 0):
     * deltaST = floor(50e18 * 1000e18 / 1000e18) = 50e18 exact, deltaJT = 0. With zero preview rates the
     * premiums are 0 and stFee = floor(50e18 * 0.1) = 5e18 books on the retained gain. jtEffectiveNAV stays 0
     * with stEffectiveNAV > 0, so the wipeout disjunct resolves the commit PERPETUAL and the fee is KEPT:
     * fees survive every forced-perpetual resolution
     */
    function test_Sync_zeroJTClaimRoutesDeltaToSTAndFeeSurvivesWipeoutCommit() public {
        _seedState(1000e18, 0, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1050e18)));
        assertEq(toUint256(state.stEffectiveNAV), 1050e18, "the whole delta lands on st");
        assertEq(toUint256(state.jtEffectiveNAV), 0, "jt receives nothing");
        assertEq(toUint256(state.stProtocolFee), 5e18, "st fee books and survives the wipeout-resolved commit");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "the wipeout disjunct resolves perpetual");
    }

    /**
     * lastCollateralNAV == 0 takes the seniority tie-break without a division-by-zero panic: value marked
     * from an empty checkpoint has no live claims to split and routes wholly to ST
     * Derivation: from the empty checkpoint a +50e18 sync has deltaST = 50e18 (tie-break) and deltaJT = 0.
     * The senior gain pays no premiums (both mock previews are 0), so stFee = 5e18 and stEffectiveNAV = 50e18
     */
    function test_Sync_zeroLastCollateralTieBreaksWholeDeltaToSenior() public {
        kernel.doCommit(toNAVUnits(SEED_LT_RAW));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(50e18)));
        assertEq(toUint256(state.stEffectiveNAV), 50e18, "the fresh value lands wholly on st");
        assertEq(toUint256(state.jtEffectiveNAV), 0, "jt receives nothing");
        assertEq(toUint256(state.stProtocolFee), 5e18, "senior net-gain fee taken");
        assertEq(toUint256(state.jtProtocolFee), 0, "no junior fee without a junior gain");
    }

    /**
     * dip-and-recover path independence: coverage lends JT value to ST at the depressed mark and inflates ST's
     * proportional claim, so the off-the-top IL repayment must restore the claims before any distribution or ST
     * keeps the appreciation earned on the coverage it consumed
     * Derivation (zero YDM rates so premiums cannot move NAV between the paths):
     * Seed stEffectiveNAV 100e18 / jtEffectiveNAV 50e18 (collateral 150e18)
     * Dip to 120e18: deltaST = -floor(30e18 * 100 / 150) = -20e18 covered by JT, deltaJT = -10e18, landing
     * stEff 100e18, jtEff 20e18, il 30e18
     * Recover to 300e18: repayment 30e18 off the top (il 0, jtEff 50e18), residual 150e18 attributed on the
     * restored basis 150e18: deltaST = 100e18 and deltaJT = 50e18, exactly the direct 150e18 gain split, with
     * identical fees (stFee 10e18 on the 100e18 senior residual, jtFee 5e18 on the 50e18 junior residual)
     */
    function test_Sync_dipAndRecoverMatchesDirectPath() public {
        jtYDM.setPreviewYieldShareReturn(0);
        ltYDM.setPreviewYieldShareReturn(0);
        _seedState(100e18, 50e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        uint256 snapshotId = vm.snapshotState();

        // Path A: dip to 120e18 (fully covered, term entered) then recover to 300e18
        kernel.doPreOp(toNAVUnits(uint256(120e18)));
        SyncedAccountingState memory recovered = kernel.doPreOp(toNAVUnits(uint256(300e18)));
        assertEq(toUint256(recovered.stEffectiveNAV), 200e18, "path A: st lands on the direct allocation");
        assertEq(toUint256(recovered.jtEffectiveNAV), 100e18, "path A: jt lands on the direct allocation");
        assertEq(toUint256(recovered.jtImpermanentLoss), 0, "path A: drawdown fully repaid off the top");
        assertEq(toUint256(recovered.stProtocolFee), 10e18, "path A: st fee books on the residual senior gain only");
        assertEq(toUint256(recovered.jtProtocolFee), 5e18, "path A: jt fee books on the residual junior gain only");
        assertEq(uint8(recovered.marketState), uint8(MarketState.PERPETUAL), "path A: full repayment exits the term");

        // Path B: the direct 150e18 gain from the same seed
        vm.revertToState(snapshotId);
        SyncedAccountingState memory direct = kernel.doPreOp(toNAVUnits(uint256(300e18)));
        assertEq(toUint256(direct.stEffectiveNAV), 200e18, "path B: direct st allocation");
        assertEq(toUint256(direct.jtEffectiveNAV), 100e18, "path B: direct jt allocation");
        assertEq(toUint256(direct.stProtocolFee), 10e18, "path B: direct st fee");
        assertEq(toUint256(direct.jtProtocolFee), 5e18, "path B: direct jt fee");
    }

    /**
     * a gain fully consumed by the IL repayment carries zero fees and zero premiums: the repayment is
     * restoration, never yield, so nothing remains to fee even with live YDM rates
     * Derivation: seed stEffectiveNAV 100e18 / jtEffectiveNAV 20e18 / il 30e18 (collateral 120e18), gain
     * to 140e18. Repayment = min(20e18, 30e18) = 20e18: il 10e18, jtEff 40e18, residual delta 0, so the
     * attribution and both gain legs are silent and the term persists on the unrecovered drawdown
     */
    function test_Sync_gainFullyConsumedByILRepaymentCarriesNoFeesOrPremiums() public {
        jtYDM.setPreviewYieldShareReturn(0.2e18);
        ltYDM.setPreviewYieldShareReturn(0.2e18);
        _seedState(100e18, 20e18, 30e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(140e18)));
        assertEq(toUint256(state.stEffectiveNAV), 100e18, "st untouched by a restoration-only sync");
        assertEq(toUint256(state.jtEffectiveNAV), 40e18, "the whole gain restores jt");
        assertEq(toUint256(state.jtImpermanentLoss), 10e18, "the unrecovered drawdown remains");
        assertEq(toUint256(state.stProtocolFee), 0, "no st fee on restoration");
        assertEq(toUint256(state.jtProtocolFee), 0, "no jt fee on restoration");
        assertEq(toUint256(state.ltProtocolFee), 0, "no lt fee on restoration");
        assertEq(toUint256(state.ltLiquidityPremium), 0, "no premium despite live YDM rates");
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "partial repayment keeps the term");
    }

    /**
     * a gain exceeding the IL repayment books fees on the post-repayment residual only: the repayment share
     * is never in any fee base
     * Derivation: seed stEffectiveNAV 100e18 / jtEffectiveNAV 20e18 / il 30e18 (collateral 120e18), gain
     * to 180e18. Repayment 30e18 off the top (il 0, jtEff 50e18), residual 30e18 attributed on the restored
     * basis 150e18: deltaST = floor(30e18 * 100 / 150) = 20e18 and deltaJT = 10e18, so jtFee = 1e18 and
     * stFee = 2e18. Without the re-anchor the split would run on basis 120e18 (deltaST = 50e18, stFee 5e18),
     * feeing the restoration as senior yield
     */
    function test_Sync_gainExceedingILRepaymentBooksFeesOnResidualOnly() public {
        jtYDM.setPreviewYieldShareReturn(0);
        ltYDM.setPreviewYieldShareReturn(0);
        _seedState(100e18, 20e18, 30e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(180e18)));
        assertEq(toUint256(state.stEffectiveNAV), 120e18, "st takes its share of the residual only");
        assertEq(toUint256(state.jtEffectiveNAV), 60e18, "jt takes the repayment plus its residual share");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "drawdown fully repaid");
        assertEq(toUint256(state.stProtocolFee), 2e18, "st fee on the 20e18 senior residual, not the repayment");
        assertEq(toUint256(state.jtProtocolFee), 1e18, "jt fee on the 10e18 junior residual, not the repayment");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "full repayment exits the term");
    }

    /// a zero delta on a shifted-claims checkpoint short-circuits the attribution and the sync is a pure no-op
    function test_Sync_zeroDeltaShortCircuitsAttribution() public {
        _seedState(980e18, 220e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1200e18)));
        assertEq(toUint256(state.stEffectiveNAV), 980e18, "st effective NAV unchanged");
        assertEq(toUint256(state.jtEffectiveNAV), 220e18, "jt effective NAV unchanged");
        assertEq(toUint256(state.stProtocolFee) + toUint256(state.jtProtocolFee) + toUint256(state.ltProtocolFee), 0, "no fees on a flat sync");
    }

    /**
     * floor-split additivity on collateral gains: ST takes exactly its floored pro-rata share of the
     * delta, JT absorbs the rounding residual, and the split always sums to the full delta
     */
    function testFuzz_Sync_attributionFloorSplitAdditivity_gain(uint256 _shift, uint256 _gain) public {
        // Bounds: the claim shift sweeps the seedable range [0, 150e18] and the gain spans [0, 1e30] (the
        // strategy magnitude bound); both uniform via bound. Zero preview rates keep the premium legs silent
        _shift = bound(_shift, 0, 150e18);
        _gain = bound(_gain, 0, 1e30);
        uint256 stEff0 = 1000e18 + _shift;
        uint256 jtEff0 = 300e18 - _shift;
        uint256 collateral0 = 1300e18;
        _seedState(stEff0, jtEff0, 0, SEED_LT_RAW, MarketState.PERPETUAL);

        // Independent floor math: ST's share is its effective claim's fraction of the pool
        uint256 expectedAttrToST = (_gain * stEff0) / collateral0;

        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(collateral0 + _gain));
        assertLe(expectedAttrToST, _gain, "attributed magnitude bounded by the delta");
        assertEq(toUint256(state.stEffectiveNAV), stEff0 + expectedAttrToST, "st takes exactly its floored share");
        assertEq(toUint256(state.jtEffectiveNAV), jtEff0 + (_gain - expectedAttrToST), "jt absorbs the rounding residual");
        assertEq(toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV), collateral0 + _gain, "additivity: the split sums to the delta");
    }

    /*----------------------------------------------------------------------
                        THE JT LEG
    ----------------------------------------------------------------------*/

    /**
     * collateral losses never underflow the junior effective NAV from any shifted-claims checkpoint with a
     * carried drawdown: a panic anywhere in this sweep is a REAL divergence: and the final NAVs match an
     * independent floor-and-min coverage model
     */
    function testFuzz_Sync_lossAttributionNeverUnderflows(uint256 _shift, uint256 _loss) public {
        // Bounds: the drawdown-shift spans [0, 150e18] to keep the seed reachable (covered, clear of the
        // liquidation and wipeout disjuncts), the loss spans [0, 300e18] to probe the exhaustion boundary
        _shift = bound(_shift, 0, 150e18);
        _loss = bound(_loss, 0, 300e18);
        uint256 stEff0 = 1000e18;
        uint256 jtEff0 = 300e18 - _shift;
        uint256 collateral0 = stEff0 + jtEff0;
        _seedState(stEff0, jtEff0, _shift, SEED_LT_RAW, _shift > 0 ? MarketState.FIXED_TERM : MarketState.PERPETUAL);

        // Independent model: floored attribution, junior absorbs its residual loss, coverage = min(st loss, jt buffer)
        uint256 attrToST = (_loss * stEff0) / collateral0;
        uint256 jtResidualLoss = _loss - attrToST;
        uint256 jtEffAfterLoss = jtEff0 - jtResidualLoss;
        uint256 coverageApplied = attrToST < jtEffAfterLoss ? attrToST : jtEffAfterLoss;
        uint256 expectedJTEff = jtEffAfterLoss - coverageApplied;
        uint256 expectedSTEff = stEff0 - (attrToST - coverageApplied);

        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(collateral0 - _loss));
        assertEq(toUint256(state.jtEffectiveNAV), expectedJTEff, "jt effective NAV vs independent model");
        assertEq(toUint256(state.stEffectiveNAV), expectedSTEff, "st effective NAV vs independent model");
        assertEq(toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV), collateral0 - _loss, "conservation under collateral losses");
    }

    /**
     * the junior net-gain fee gates on strict dust excess: a residual gain of exactly the dust tolerance
     * takes no fee, one wei more takes the floored fee. Probed on a junior-only market so the whole delta is
     * the JT residual (the zero st claim routes everything to JT)
     * Derivation with dust 70: gain 70 -> no fee, then gain 71 -> floor(71 * 0.1e18 / 1e18) = 7
     */
    function test_Sync_jtGainFeeDustBoundary() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(70));
        _deploy(p);
        _seedState(0, 200e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(200e18 + 70)));
        assertEq(toUint256(state.jtProtocolFee), 0, "gain equal to the dust tolerance takes no fee");
        assertEq(toUint256(state.jtEffectiveNAV), 200e18 + 70, "gain NAV still booked");
        state = kernel.doPreOp(toNAVUnits(uint256(200e18 + 141)));
        assertEq(toUint256(state.jtProtocolFee), 7, "one wei above dust takes the floored fee");
        assertEq(toUint256(state.jtEffectiveNAV), 200e18 + 141, "gain NAV booked in full, fee not NAV-deducted");
    }

    /**
     * junior net-gain fee floor exactness at an awkward value, on a junior-only market so the whole delta is
     * the JT residual
     * Derivation: floor(12345678901234567 * 0.1e18 / 1e18) = 1234567890123456 (the trailing 7 truncates)
     */
    function test_Sync_jtGainFeeFloorExactness() public {
        _seedState(0, 200e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(200e18 + 12_345_678_901_234_567)));
        assertEq(toUint256(state.jtProtocolFee), 1_234_567_890_123_456, "fee floors the awkward product");
    }

    /*----------------------------------------------------------------------
                FEES ARE KEPT ON EVERY PERPETUAL RESOLUTION
    ----------------------------------------------------------------------*/

    /*
     * The old coverage-branch jtFee recompute is gone and the FIXED_TERM fee zeroing was deleted as dead code:
     * under same-sign attribution any nonzero fee requires a gain residual that fully recovered the IL, which
     * resolves PERPETUAL. These pins exercise the theorem's other side: fees booked in a sync whose commit is
     * resolved by a FORCED disjunct (permanently-perpetual, elapsed term, liquidation) are kept, never zeroed.
     */

    /**
     * fees survive the permanently-perpetual (zero-duration) resolution
     * Derivation: with duration 0 every commit is PERPETUAL. A +50e18 gain on the flat seed splits
     * deltaST = 41666666666666666666 / deltaJT = 8333333333333333334: jtFee = 833333333333333333 on the
     * residual (zero preview rates so no premiums) and stFee = 4166666666666666666 on the retained gain,
     * both kept on the forced-perpetual commit
     */
    function test_Sync_feesKeptOnPermanentlyPerpetualResolution() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.fixedTermDurationSeconds = 0;
        _deploy(p);
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1250e18)));
        assertEq(toUint256(state.jtProtocolFee), 833_333_333_333_333_333, "jt fee kept on the zero-duration commit");
        assertEq(toUint256(state.stProtocolFee), 4_166_666_666_666_666_666, "st fee kept on the zero-duration commit");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "permanently perpetual");
    }

    /**
     * fees survive an elapsed-term resolution: a deep gain past the elapsed end books the JT and ST fees,
     * all kept while the elapsed-term disjunct governs the commit
     * Derivation: warp past the end, then a +660e18 gain (time-weighted premiums 0 at zero mutating rates):
     * the repayment consumes 100e18 (il 0, jtEffectiveNAV 300e18, residual 560e18, basis 1300e18):
     * stGain = floor(560e18 * 1000e18 / 1300e18) = 430769230769230769230 books stFee 43076923076923076923,
     * jtGain = 129230769230769230770 books jtFee 12923076923076923077.
     * jtEffectiveNAV = 429230769230769230770, stEffectiveNAV = 1430769230769230769230, PERPETUAL, end 0
     */
    function test_Sync_feesKeptOnElapsedTermResolution() public {
        _seedLargeIL();
        vm.warp(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS + 1);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1860e18)));
        assertEq(toUint256(state.jtProtocolFee), 12_923_076_923_076_923_077, "jt residual fee kept on the elapsed-term commit");
        assertEq(toUint256(state.stProtocolFee), 43_076_923_076_923_076_923, "st fee kept on the elapsed-term commit");
        assertEq(toUint256(state.jtEffectiveNAV), 429_230_769_230_769_230_770, "repayment plus the junior residual");
        assertEq(toUint256(state.stEffectiveNAV), 1_430_769_230_769_230_769_230, "st retains its residual share");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "elapsed term resolves perpetual");
        assertEq(state.fixedTermEndTimestamp, 0, "end deleted");
    }

    /**
     * fees survive a liquidation-coinciding resolution: after the liquidation threshold is shrunk mid-term, a
     * gain whose post-sync coverage utilization still meets the threshold books fees and keeps them
     * Setup: threshold 2.5e18 at deploy and a thin junior (100e18) so a covered -50e18 loss locks the term at
     * coverageUtilization ceil(1050e18 * 0.1e18 / 50e18) = 2.1e18, then the setter shrinks the threshold to
     * 1.1e18 (must stay > WAD)
     * Derivation of the gain sync to 1210e18 (+160e18): the repayment consumes 50e18 (il 0,
     * jtEffectiveNAV 100e18, residual 110e18, basis 1100e18): stGain = floor(110e18 * 1000e18 / 1100e18) =
     * 100e18 exact books stFee 10e18 (zero preview rates), jtGain = 10e18 books jtFee 1e18.
     * coverageUtilization = ceil(1210e18 * 0.1e18 / 110e18) = 1.1e18 >= 1.1e18, so the liquidation disjunct
     * governs the PERPETUAL commit and every fee is kept
     */
    function test_Sync_feesKeptOnLiquidationCoincidingResolution() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.coverageLiquidationUtilizationWAD = 2.5e18;
        _deploy(p);
        _seedState(SEED_ST_EFF, 100e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(uint256(1050e18)));
        assertEq(uint8(accountant.getState().lastMarketState), uint8(MarketState.FIXED_TERM), "staging: the covered loss locks the term");
        accountant.setLiquidationCoverageUtilization(1.1e18);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1210e18)));
        assertEq(state.coverageUtilizationWAD, 1.1e18, "post-sync coverage utilization meets the shrunk threshold");
        assertEq(toUint256(state.jtProtocolFee), 1e18, "jt residual fee kept on the liquidation-coinciding commit");
        assertEq(toUint256(state.stProtocolFee), 10e18, "st fee kept on the liquidation-coinciding commit");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "liquidation resolves perpetual");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "no drawdown survives a perpetual commit");
    }

    /*----------------------------------------------------------------------
                ST LOSS COVERAGE REGIMES
    ----------------------------------------------------------------------*/

    /**
     * partial coverage with a residual senior loss: coverage is capped by the junior buffer
     * Derivation: the -250e18 loss splits deltaST = -208333333333333333333 / deltaJT = -41666666666666666667.
     * After the JT leg the buffer is 158333333333333333333, coverage consumes all of it (would-be il 200e18),
     * residual 50e18 hits st (stEffectiveNAV = 950e18). The wipeout disjunct then forces PERPETUAL and erases the il
     */
    function test_Sync_partialCoverageResidualLossHitsST() public {
        _seedAndInitAccrual();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheImpermanentLossReset(toNAVUnits(uint256(200e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(950e18)));
        assertEq(toUint256(state.stEffectiveNAV), 950e18, "st bears only the uncovered residual");
        assertEq(toUint256(state.jtEffectiveNAV), 0, "jt buffer fully consumed");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "il erased by the wipeout transition");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "wipeout forces perpetual");
    }

    /**
     * a zero junior buffer provides no coverage: the coverageApplied != 0 guard takes the false arm
     * Derivation: on the senior-only market (stEff 1000e18, jtEff 0) the whole -100e18 loss is st's
     * (deltaST = -100e18, deltaJT = 0), lands entirely on st (stEffectiveNAV = 900e18), il stays 0
     */
    function test_Sync_zeroJTBufferProvidesNoCoverage() public {
        _seedState(1000e18, 0, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(900e18)));
        assertEq(toUint256(state.stEffectiveNAV), 900e18, "uncovered loss hits st in full");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "no coverage so no il accrues");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "market stays perpetual");
    }

    /*----------------------------------------------------------------------
                ST GAIN: RECOVERY, PREMIUMS, FEES
    ----------------------------------------------------------------------*/

    /**
     * a gain equal to the il recovers it exactly, pays no premium or fee, and ends the fixed term
     * Derivation: the +100e18 gain's two legs (16666666666666666667 JT residual, 83333333333333333333 ST)
     * are both fully consumed repaying the 100e18 il: il = 0, jtEffectiveNAV = 300e18, residual gain 0 so the
     * premium block is skipped, and the organic recovery emits no il reset event (nothing is erased)
     */
    function test_Sync_ilRecoveryExactGainEndsFixedTerm() public {
        _seedLargeIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1300e18)));
        assertEq(toUint256(state.jtImpermanentLoss), 0, "il fully recovered");
        assertEq(toUint256(state.jtEffectiveNAV), 300e18, "recovery credited to jt");
        assertEq(toUint256(state.stEffectiveNAV), 1000e18, "st effective NAV unchanged");
        assertEq(toUint256(state.jtProtocolFee) + toUint256(state.stProtocolFee) + toUint256(state.ltProtocolFee), 0, "no fee on pure recovery");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "recovered market returns to perpetual");
    }

    /**
     * a gain above the il pays premiums only on the residual, via the instantaneous branch with the
     * FIXED_TERM initial state and last-committed checkpoint utilizations as the exact YDM preview arguments
     * Derivation: the +150e18 gain repays the 100e18 il off the top (jtEffectiveNAV 300e18, residual 50e18,
     * basis 1300e18): stGain = floor(50e18 * 1000e18 / 1300e18) = 38461538461538461538,
     * jtGain = 11538461538461538462 books jtFee 1153846153846153846. Checkpoint utils
     * coverageUtilization = ceil(1200e18 * 0.1e18 / 200e18) = 0.6e18 and liquidityUtilization = ceil(1000e18 *
     * 0.05e18 / 100e18) = 0.5e18. Premiums 3846153846153846153 / 1923076923076923076, fees kept because the
     * recovered market lands PERPETUAL: jtFee += 384615384615384615 (total 1538461538461538461),
     * ltFee 192307692307692307, st residual 32692307692307692309, stFee 3269230769230769230,
     * jtEffectiveNAV 315384615384615384615, stEffectiveNAV 1034615384615384615385
     */
    function test_Sync_ilRecoveryThenPremiumOnResidualWithExactYDMArgs() public {
        _seedLargeIL();
        vm.expectCall(address(jtYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.FIXED_TERM, 0.6e18)));
        vm.expectCall(address(ltYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.FIXED_TERM, 0.5e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1350e18)));
        assertEq(toUint256(state.jtImpermanentLoss), 0, "il fully repaid first");
        assertEq(toUint256(state.jtEffectiveNAV), 315_384_615_384_615_384_615, "repayment plus the junior residual and risk premium");
        assertEq(toUint256(state.ltLiquidityPremium), 1_923_076_923_076_923_076, "liquidity premium on the residual only");
        assertEq(toUint256(state.stEffectiveNAV), 1_034_615_384_615_384_615_385, "st retains residual plus the premium value retained senior");
        assertEq(toUint256(state.jtProtocolFee), 1_538_461_538_461_538_461, "jt residual and yield-share fees kept in the resulting perpetual state");
        assertEq(toUint256(state.ltProtocolFee), 192_307_692_307_692_307, "lt fee kept");
        assertEq(toUint256(state.stProtocolFee), 3_269_230_769_230_769_230, "st fee on the retained residual");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "full recovery ends the fixed term");
    }

    /**
     * the same-block instantaneous branch queries previewYieldShare with the initial market state and
     * last-committed checkpoint utilizations, and prices the premium at the preview rate over a forced 1s window
     * Derivation: checkpoint utils coverageUtilization = ceil(1200e18 * 0.1e18 / 200e18) = 0.6e18 and
     * liquidityUtilization = 0.5e18. The +100e18 gain attributes deltaST = 83333333333333333333 (JT residual
     * 16666666666666666667) so at preview rates 0.07e18 / 0.03e18:
     *   jtPrem = floor(deltaST * 0.07) = 5833333333333333333, ltPrem = floor(deltaST * 0.03) = 2499999999999999999
     *   jtEffectiveNAV = 200e18 + 16666666666666666667 + 5833333333333333333 = 222.5e18 exact
     */
    function test_Sync_instantaneousPremiumUsesPreviewRatesWithCheckpointArgs() public {
        _seedAndInitAccrual();
        jtYDM.setPreviewYieldShareReturn(0.07e18);
        ltYDM.setPreviewYieldShareReturn(0.03e18);
        vm.expectCall(address(jtYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.PERPETUAL, 0.6e18)));
        vm.expectCall(address(ltYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.PERPETUAL, 0.5e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 100e18));
        assertEq(toUint256(state.jtEffectiveNAV), 222.5e18, "jt residual plus instantaneous risk premium");
        assertEq(toUint256(state.ltLiquidityPremium), 2_499_999_999_999_999_999, "instantaneous lt liquidity premium");
    }

    /// the instantaneous branch caps hostile preview rates at the configured maximum yield shares
    function test_Sync_instantaneousPremiumCapsHostilePreviewRates() public {
        _seedAndInitAccrual();
        jtYDM.setPreviewYieldShareReturn(WAD);
        ltYDM.setPreviewYieldShareReturn(WAD);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 100e18));
        // Capped at maxJT 0.2e18 and maxLT 0.1e18 on the attributed senior gain 83333333333333333333:
        // jtPrem = 16666666666666666666, ltPrem = 8333333333333333333, jtEff = 200e18 + residual + jtPrem
        assertEq(toUint256(state.jtEffectiveNAV), 233_333_333_333_333_333_333, "jt premium capped at maxJTYieldShareWAD");
        assertEq(toUint256(state.ltLiquidityPremium), 8_333_333_333_333_333_333, "lt premium capped at maxLTYieldShareWAD");
    }

    /**
     * with an elapsed premium window the time-weighted accumulators price the premium and the hostile preview
     * rates are never consulted (they would cap to 0.2e18 / 0.1e18 if the instantaneous branch ran)
     * Derivation: rates 0.15e18 / 0.05e18 over 1000s: twJT = 150e18 on the attributed senior gain
     * 83333333333333333333: jtPrem = floor(deltaST * 150e18 / (1000 * 1e18)) = 12499999999999999999,
     * ltPrem = 4166666666666666666, jtEffectiveNAV = 200e18 + 16666666666666666667 + jtPrem = 229166666666666666666
     */
    function test_Sync_elapsedPremiumUsesTimeWeightedAccumulators() public {
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(0.15e18);
        ltYDM.setYieldShareReturn(0.05e18);
        jtYDM.setPreviewYieldShareReturn(WAD);
        ltYDM.setPreviewYieldShareReturn(WAD);
        vm.warp(block.timestamp + 1000);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 100e18));
        assertEq(toUint256(state.jtEffectiveNAV), 229_166_666_666_666_666_666, "time-weighted jt risk premium plus the residual");
        assertEq(toUint256(state.ltLiquidityPremium), 4_166_666_666_666_666_666, "time-weighted lt liquidity premium");
    }

    /**
     * the premiumsPaid gate is a strict dust comparison: a dust-sized senior gain still pays premium NAV but
     * takes no fees and leaves the accrual window intact, while one wei more takes fees and resets the window
     * Derivation with the single dust 70, rates 0.1e18 / 0.05e18 over 100s (twJT 10e18, twLT 5e18):
     *   gain +84 attributes deltaST = floor(84 * 5 / 6) = 70 exactly with JT residual 14 (at most dust, no fee):
     *   jtPrem = floor(70 * 10e18 / (100 * 1e18)) = 7, ltPrem = floor(70 * 5e18 / 100e18) = 3, no fees, no reset
     *   Then over a further 50s (tw compounds un-reset to 15e18 / 7.5e18, window 150s) a gain of +86 from the
     *   (1200e18 + 84) checkpoint attributes deltaST = floor(86 * (1000e18 + 63) / (1200e18 + 84)) = 71
     *   (one wei above dust) with JT residual 15:
     *   jtPrem = floor(71 * 15e18 / 150e18) = 7, ltPrem = floor(71 * 7.5e18 / 150e18) = 3,
     *   stFee = floor(61 * 0.1) = 6 (the jt and lt fee floors are 0 at this magnitude, the 15 wei jt residual
     *   is below dust so it takes no fee), accumulators reset and the premium clock advances to windowStart + 150
     */
    function test_Sync_premiumsPaidDustGateBothSides() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(70));
        _deploy(p);
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
        uint32 windowStart = uint32(block.timestamp);
        jtYDM.setYieldShareReturn(0.1e18);
        ltYDM.setYieldShareReturn(0.05e18);

        vm.warp(block.timestamp + 100);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 84));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF + 21, "dust-sized gain still pays the jt premium NAV plus the residual");
        assertEq(toUint256(state.ltLiquidityPremium), 3, "dust-sized gain still pays the lt premium NAV");
        assertEq(toUint256(state.stProtocolFee) + toUint256(state.jtProtocolFee) + toUint256(state.ltProtocolFee), 0, "no fees at or below dust");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.twJTYieldShareAccruedWAD, 10e18, "accumulator not reset at the dust boundary");
        assertEq(s.lastPremiumPaymentTimestamp, windowStart, "premium clock untouched at the dust boundary");

        vm.warp(block.timestamp + 50);
        state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 170));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_EFF + 43, "compounded window premium plus both jt residuals");
        assertEq(toUint256(state.ltLiquidityPremium), 3, "compounded window lt premium");
        assertEq(toUint256(state.stProtocolFee), 6, "st fee taken one wei above dust");
        s = accountant.getState();
        assertEq(s.twJTYieldShareAccruedWAD, 0, "jt accumulator reset once premiums are paid");
        assertEq(s.twLTYieldShareAccruedWAD, 0, "lt accumulator reset once premiums are paid");
        // The expected clock is derived from windowStart rather than read from block.timestamp: an identical
        // pre-warp uint32(block.timestamp) read exists above and via-ir legally CSEs TIMESTAMP within a frame
        assertEq(s.lastPremiumPaymentTimestamp, windowStart + 150, "premium clock advances on payment");
    }

    /**
     * premium floor exactness at awkward prime-adjacent values, pinned to hand-worked literals on a senior-only
     * market (jtEff 0) so the entire collateral delta is the attributed senior gain
     * The rate accrues time-weighted over a single window, so rate and window both carry the same
     * elapsed = 3607 (prime) and the ratio reduces exactly to floor(gain * rate / 1e18). Worked by hand
     * with gain 999_999_999_999_999_937 (prime) and both rates below their caps:
     *   999999999999999937 * 123456789012345677 = 123456789012345669_222222292222222349 -> jtPrem = 123_456_789_012_345_669
     *   999999999999999937 * 98765432109876543  =  98765432109876536_777777777077777791 -> ltPrem =  98_765_432_109_876_536
     * Both products leave a nonzero 18-digit fractional tail, so any rounding other than a floor
     * (ceil, half-up) would land exactly one wei high: the premiums must never round senior gain up
     */
    function test_Sync_premiumFloorExactnessAtAwkwardValues() public {
        _seedState(1000e18, 0, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(uint256(1000e18)));
        uint256 rateJT = 123_456_789_012_345_677;
        uint256 rateLT = 98_765_432_109_876_543;
        uint256 elapsed = 3607;
        uint256 gain = 999_999_999_999_999_937;
        jtYDM.setYieldShareReturn(rateJT);
        ltYDM.setYieldShareReturn(rateLT);
        vm.warp(block.timestamp + elapsed);
        // Hand-derived literals from the header derivation: the sub-wei tails (…349 and …791) are floored away
        uint256 expectedJTPremium = 123_456_789_012_345_669;
        uint256 expectedLTPremium = 98_765_432_109_876_536;
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(1000e18 + gain));
        assertEq(toUint256(state.jtEffectiveNAV), expectedJTPremium, "jt premium floors exactly");
        assertEq(toUint256(state.ltLiquidityPremium), expectedLTPremium, "lt premium floors exactly");
        // Senior residual by hand: 999_999_999_999_999_937 - 123_456_789_012_345_669 = 876_543_210_987_654_268
        // (only the jt premium leaves the senior side, the lt premium re-labels value that stays senior)
        assertEq(toUint256(state.stEffectiveNAV), 1000e18 + 876_543_210_987_654_268, "st keeps the residual plus the lt premium value retained senior");
    }

    /**
     * the zero-premium guards take their false arms independently: a zero jt premium skips the jt yield-share
     * fee entirely while a nonzero lt premium still pays, and vice versa. Probed on a senior-only market
     * (jtEff 0) so the deltas are pure senior gains with no jt residual muddying the fee fields
     */
    function test_Sync_zeroPremiumGuardBranchesBothSides() public {
        _seedState(1000e18, 0, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        // Side 1: jt rate 0, lt rate 0.05e18 on a 100e18 gain: ltPrem 5e18 (fee 0.5e18), stFee = floor(95e18 * 0.1) = 9.5e18
        jtYDM.setPreviewYieldShareReturn(0);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1100e18)));
        assertEq(toUint256(state.jtEffectiveNAV), 0, "zero jt premium leaves jt untouched");
        assertEq(toUint256(state.jtProtocolFee), 0, "no jt yield-share fee without a premium");
        assertEq(toUint256(state.ltLiquidityPremium), 5e18, "lt premium still paid");
        assertEq(toUint256(state.ltProtocolFee), 0.5e18, "lt fee on its premium");
        assertEq(toUint256(state.stProtocolFee), 9.5e18, "st fee on the retained gain");
        assertEq(toUint256(state.stEffectiveNAV), 1100e18, "st retains gain plus the lt share mint");
        // Side 2 (same block, fresh premium window): jt rate 0.1e18, lt rate 0 on another 100e18 gain
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0);
        state = kernel.doPreOp(toNAVUnits(uint256(1200e18)));
        assertEq(toUint256(state.jtEffectiveNAV), 10e18, "jt premium paid");
        assertEq(toUint256(state.jtProtocolFee), 1e18, "jt yield-share fee on its premium");
        assertEq(toUint256(state.ltLiquidityPremium), 0, "zero lt premium");
        assertEq(toUint256(state.ltProtocolFee), 0, "no lt fee without a premium");
        assertEq(toUint256(state.stProtocolFee), 9e18, "st fee on the 90e18 residual");
    }

    /**
     * LT premium coverage-neutrality: an identical market with a zero lt share produces byte-identical
     * senior and junior effective NAVs and coverage utilization: the premium only re-labels senior-retained value
     * Derivation (+50e18 gain, deltaST 41666666666666666666): factual ltPrem = 2083333333333333333 with
     * stFee = 3541666666666666666, counterfactual ltPrem = 0 with stFee = floor((deltaST - jtPrem) * 0.1)
     * = 3750000000000000000, both landing stEffectiveNAV 1037.5e18 / jtEffectiveNAV 212.5e18
     */
    function test_Sync_ltPremiumCoverageNeutralViaCounterfactual() public {
        _seedNoIL();
        SyncedAccountingState memory withLT = kernel.doPreOp(toNAVUnits(uint256(1250e18)));

        // Counterfactual: fresh identical deployment and seed with the lt share zeroed
        _deploy(_defaultParams());
        _seedAndInitAccrual();
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0);
        SyncedAccountingState memory withoutLT = kernel.doPreOp(toNAVUnits(uint256(1250e18)));

        assertEq(toUint256(withLT.stEffectiveNAV), toUint256(withoutLT.stEffectiveNAV), "st effective NAV identical: premium stays inside stEffectiveNAV");
        assertEq(toUint256(withLT.jtEffectiveNAV), toUint256(withoutLT.jtEffectiveNAV), "jt effective NAV untouched by the lt premium");
        assertEq(withLT.coverageUtilizationWAD, withoutLT.coverageUtilizationWAD, "coverage utilization identical");
        assertEq(toUint256(withLT.ltLiquidityPremium), 2_083_333_333_333_333_333, "factual lt premium paid");
        assertEq(toUint256(withoutLT.ltLiquidityPremium), 0, "counterfactual pays none");
        assertEq(toUint256(withLT.stProtocolFee), 3_541_666_666_666_666_666, "st fee shrinks by the premium value retained senior");
        assertEq(toUint256(withoutLT.stProtocolFee), 3_750_000_000_000_000_000, "counterfactual st fee on the full residual");
    }

    /// @dev Stratified hostile YDM output: a third sub-WAD, a third between WAD and 1e24, a third the uint256 maximum
    function _strataRate(uint256 _seed) internal pure returns (uint256) {
        uint256 strata = _seed % 3;
        if (strata == 0) return bound(_seed, 0, WAD);
        if (strata == 1) return bound(_seed, WAD, 1e24);
        return type(uint256).max;
    }

    /**
     * PREMIUMS_EXCEED_SENIOR_YIELD is unreachable: with the yield shares capped at accrual and the caps
     * summing to exactly WAD, hostile YDM outputs (up to uint256 max) can never push the combined premiums past
     * the senior gain on either the time-weighted or the instantaneous branch. Any revert here is a REAL divergence
     */
    function testFuzz_Sync_premiumsNeverExceedSeniorYield(uint256 _rateJT, uint256 _rateLT, uint256 _elapsed, uint256 _gain1, uint256 _gain2) public {
        // Deploy at the joint cap maxJT + maxLT == WAD, the tightest legal configuration
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.maxJTYieldShareWAD = 0.6e18;
        p.maxLTYieldShareWAD = 0.4e18;
        _deploy(p);
        // Rates stratified across three decades (sub-WAD, WAD..1e24, uint256 max) to include absurd outputs;
        // elapsed uniform up to a decade, gains uniform within the 1e30 strategy magnitude bound
        _rateJT = _strataRate(_rateJT);
        _rateLT = _strataRate(_rateLT);
        _elapsed = bound(_elapsed, 1, 3650 days);
        _gain1 = bound(_gain1, 1, 1e30);
        _gain2 = bound(_gain2, 1, 1e30);
        _seedAndInitAccrual();
        jtYDM.setRates(_rateJT);
        ltYDM.setRates(_rateLT);
        vm.warp(block.timestamp + _elapsed);

        // Time-weighted branch: the jt delta (residual plus premium) and the lt premium are bounded by the gain
        SyncedAccountingState memory first = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + _gain1));
        uint256 jtDelta = toUint256(first.jtEffectiveNAV) - SEED_JT_EFF;
        assertLe(jtDelta + toUint256(first.ltLiquidityPremium), _gain1, "time-weighted jt delta plus lt premium bounded by the gain");

        // Instantaneous branch: a second gain in the same block right after the premium payment
        SyncedAccountingState memory second = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + _gain1 + _gain2));
        uint256 jtDelta2 = toUint256(second.jtEffectiveNAV) - toUint256(first.jtEffectiveNAV);
        assertLe(jtDelta2 + toUint256(second.ltLiquidityPremium), _gain2, "instantaneous jt delta plus lt premium bounded by the gain");
    }

    /**
     * exact collateral NAV conservation on every committed sync from any reachable shifted checkpoint :
     * the NAV_CONSERVATION_VIOLATION revert arm is unreachable from conserved checkpoints (a revert or a drift
     * of even one wei here is a REAL divergence)
     */
    function testFuzz_Sync_conservationOnEveryCommittedSync(uint256 _stEff0, uint256 _jtEff0, uint256 _il0, uint256 _collateral1, uint256 _elapsed) public {
        // Bounds: effective NAVs within the 1e30 strategy magnitude bound; jtEff0 at least half of stEff0 and
        // the drawdown capped at half of jtEff0 keep the seeding loss fully covered and clear of the liquidation
        // and wipeout disjuncts; the fresh collateral sweeps [0, 2x] around the checkpoint; all uniform via bound
        _stEff0 = bound(_stEff0, 1e18, 1e30);
        _jtEff0 = bound(_jtEff0, _stEff0 / 2 + 1, 1e30);
        _il0 = bound(_il0, 0, _jtEff0 / 2);
        uint256 collateral0 = _stEff0 + _jtEff0;
        _collateral1 = bound(_collateral1, 0, collateral0 * 2);
        _elapsed = bound(_elapsed, 0, 365 days);
        _seedState(_stEff0, _jtEff0, _il0, SEED_LT_RAW, _il0 > 0 ? MarketState.FIXED_TERM : MarketState.PERPETUAL);
        jtYDM.setRates(0.2e18);
        ltYDM.setRates(0.1e18);
        vm.warp(block.timestamp + _elapsed);

        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(_collateral1));
        assertEq(toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV), _collateral1, "returned state conserves NAV exactly");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), _collateral1, "committed checkpoint conserves NAV exactly");
        assertEq(s.lastMarketState == MarketState.PERPETUAL, toUint256(s.lastJTImpermanentLoss) == 0, "il > 0 iff FIXED_TERM after every commit");
    }

    /**
     * Adversarial fee-floor dust griefing: a keeper who controls sync cadence splits a 90 wei collateral gain
     * into ten 9 wei syncs so every fee floors to zero: each sync's senior share is floor(9 * 5 / 6) = 7
     * (stFee floor(7 * 0.1) = 0) and its JT residual 2 (jtFee floor(2 * 0.1) = 0): while a single 90 wei sync
     * books floored fees on the 75/15 split (stFee 7, jtFee 1). Pins that the per-sync fee leakage is strictly
     * bounded by 1/feeRate - 1 wei per leg per sync, so dust-splitting cannot scale into a material fee theft,
     * and NAV itself is never leaked: conservation holds exactly on both paths while the split's flooring drift
     * shifts at most 5 wei of the split between the tranches (JT absorbs the per-sync rounding residual)
     */
    function test_Sync_FeeFloorDustGriefing_SplitGainsAvoidOnlyBoundedFee() public {
        _seedAndInitAccrual();
        jtYDM.setPreviewYieldShareReturn(0);
        ltYDM.setPreviewYieldShareReturn(0);
        uint256 totalFees;
        for (uint256 i = 1; i <= 10; ++i) {
            SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 9 * i));
            totalFees += toUint256(state.stProtocolFee) + toUint256(state.jtProtocolFee);
            assertEq(toUint256(state.stProtocolFee), 0, "each 9 wei gain floors its st fee to zero");
            assertEq(toUint256(state.jtProtocolFee), 0, "each 2 wei jt residual floors its fee to zero");
        }
        assertEq(totalFees, 0, "the ten-way split pays no fee at all");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV), SEED_ST_EFF + 70, "st accumulates ten 7 wei floored shares");
        assertEq(toUint256(s.lastJTEffectiveNAV), SEED_JT_EFF + 20, "jt accumulates ten 2 wei residuals");

        // Counterfactual: the identical 90 wei gain in one sync books the floored fees on the 75/15 split
        _deploy(_defaultParams());
        _seedAndInitAccrual();
        jtYDM.setPreviewYieldShareReturn(0);
        ltYDM.setPreviewYieldShareReturn(0);
        SyncedAccountingState memory single = kernel.doPreOp(toNAVUnits(SEED_COLLATERAL + 90));
        assertEq(toUint256(single.stProtocolFee), 7, "the single sync books the floored st fee");
        assertEq(toUint256(single.jtProtocolFee), 1, "the single sync books the floored jt fee");
        assertEq(toUint256(single.stEffectiveNAV) + toUint256(single.jtEffectiveNAV), SEED_COLLATERAL + 90, "identical conservation either way");
    }

    /**
     * Sync scenario (covered loss, then full recovery): the impermanent loss drawdown makes JT whole
     * Derivation: seed 1000e18/300e18 flat (collateral 1300e18), the -130e18 drop attributes
     * deltaST = -100e18 exact and deltaJT = -30e18: the JT loss books il 30e18 and coverage = 100e18 deepens
     * it to 130e18 with jtEffectiveNAV = 170e18, FIXED_TERM entry. On the full recovery
     * deltaST = floor(130e18 * 1000e18 / 1170e18) = 111111111111111111111 and JT's own residual
     * 18888888888888888889 recovers il to exactly deltaST, so the recovery consumes the entire senior gain:
     * stEffectiveNAV = 1000e18, jtEffectiveNAV = 300e18, il = 0, PERPETUAL. No fee books (restoration is
     * never fee'd), no senior yield remains so no premiums and no ST fee
     */
    function test_Sync_ImpermanentLoss_FullRecoveryMakesJTWhole() public {
        _seedSymmetric(1000e18, 300e18, 0);
        _runSyncVector(
            1170e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 170e18,
                il: 130e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
        _runSyncVector(
            1300e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 300e18,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }

    /**
     * Sync scenario (covered loss, deeper second leg, then full recovery): the impermanent loss tracks JT's
     * full drawdown through a second leg down and repays it exactly on recovery
     * Derivation: after the first drop (il 130e18, jtEffectiveNAV 170e18) a further -27e18 attributes
     * deltaST = -floor(27e18 * 1000e18 / 1170e18) = -23076923076923076923 and deltaJT = -3923076923076923077:
     * the JT loss deepens il to 133923076923076923077 and coverage takes it to 157e18, the full drawdown
     * 300e18 - jtEffectiveNAV 143e18. The full recovery (+157e18) attributes
     * deltaST = floor(157e18 * 1000e18 / 1143e18) = 137357830271216097987 and JT's own residual
     * 19642169728783902013 recovers il to exactly deltaST, so the recovery consumes the entire senior gain and
     * JT is made whole: 1000e18/300e18, il = 0, and no fee books since both legs were consumed by the recovery
     */
    function test_Sync_ImpermanentLoss_DeepensWithSecondLegAndRecoversWhole() public {
        _seedSymmetric(1000e18, 300e18, 0);
        _runSyncVector(
            1170e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 170e18,
                il: 130e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
        _runSyncVector(
            1143e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 143e18,
                il: 157e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEndTimestamp: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
        _runSyncVector(
            1300e18,
            ExpectedSync({
                stEffectiveNAV: 1000e18,
                jtEffectiveNAV: 300e18,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEndTimestamp: 0
            })
        );
    }
}
