// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test, Vm } from "../../lib/forge-std/src/Test.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoDayFixedRateAccountant } from "../../src/accountant/RoycoDayFixedRateAccountant.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/accountant/IRoycoDayAccountant.sol";
import { IRoycoDayFixedRateAccountant } from "../../src/interfaces/accountant/IRoycoDayFixedRateAccountant.sol";
import { WAD, ZERO_NAV_UNITS } from "../../src/libraries/Constants.sol";
import { MarketState, Operation, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { MockFixedRateAccountantKernel } from "../mocks/MockFixedRateAccountantKernel.sol";
import { MockRecordingYDM } from "../mocks/MockRecordingYDM.sol";
import { UninitializedERC1967Proxy } from "../mocks/UninitializedERC1967Proxy.sol";
import { RoycoTestMath } from "./RoycoTestMath.sol";

/**
 * @title FixedRateAccountantTestBase
 * @notice Shared mock-kernel base for every RoycoDayFixedRateAccountant test suite: the default init params, the
 *         proxy deploy path, checkpoint seeding through legal kernel calls only, the regime seeds for the
 *         tranche accounting sync scenarios, and the independent coupon expectation math
 * @dev Checkpoints are always constructed through legal kernel calls (post-op deposits, pre-op syncs, LPT
 *      commits), never through storage writes, so every seeded state is a state production can actually reach
 * @dev Seeding stays inside the deploy block: the coupon accrual window opens at initialization, so any seeding
 *      pre-op sync settles a zero coupon and every test's first warp starts a clean window from a known clock
 */
abstract contract FixedRateAccountantTestBase is Test {
    // Default init params (boundary probing tests deploy with their own params)
    uint64 internal constant DEFAULT_MIN_COVERAGE_WAD = 0.1e18;
    uint256 internal constant DEFAULT_LIQUIDATION_UTILIZATION_WAD = 1.1e18;
    uint64 internal constant DEFAULT_MIN_LIQUIDITY_WAD = 0.05e18;
    uint64 internal constant DEFAULT_MAX_LPT_YIELD_SHARE_WAD = 0.1e18;
    uint24 internal constant DEFAULT_FIXED_TERM_DURATION_SECONDS = 604_800;
    uint64 internal constant DEFAULT_PROTOCOL_FEE_WAD = 0.1e18;
    // The default senior fixed rate: 1e9 WAD per second (a 1e-9 fraction of the senior effective NAV each second),
    // chosen so hand-derived vectors stay exact: coupon = stEffectiveNAV * 1e9 * elapsed / 1e18
    uint64 internal constant DEFAULT_ST_FIXED_RATE_PER_SECOND_WAD = 1e9;

    // Default flat seed used by the accrual tests (effective NAVs, the collateral NAV is their sum under conservation)
    uint256 internal constant SEED_ST_EFF = 1000e18;
    uint256 internal constant SEED_JT_EFF = 200e18;
    uint256 internal constant SEED_LPT_RAW = 100e18;
    uint256 internal constant SEED_COLLATERAL = SEED_ST_EFF + SEED_JT_EFF;
    // Expected utilizations at the default flat seed, computed independently:
    //   coverageUtilization = ceil(1200e18 * 0.1e18 / 200e18) = 0.6e18 (exact division so ceil == floor)
    //   liquidityUtilization = ceil(1000e18 * 0.05e18 / 100e18) = 0.5e18 (exact division)
    uint256 internal constant SEED_COVERAGE_UTILIZATION_WAD = 0.6e18;
    uint256 internal constant SEED_LIQUIDITY_UTILIZATION_WAD = 0.5e18;

    RoycoDayFixedRateAccountant internal accountant;
    RoycoDayFixedRateAccountant internal implementation;
    MockFixedRateAccountantKernel internal kernel;
    MockRecordingYDM internal lptYDM;
    AccessManager internal authority;
    address internal stranger;

    /// @dev The fixed-term grace period the next `_deploy` initializes the accountant with
    uint24 internal fixedTermGracePeriodSeconds;

    /*//////////////////////////////////////////////////////////////////////
                            DEPLOY HELPERS
    //////////////////////////////////////////////////////////////////////*/

    /// @dev Default init params with null kernel and YDM slots that the deploy helpers fill in
    /// @dev The junior tranche protocol fee is zero by requirement: the fixed rate accountant pins the unbound knob at initialization
    function _defaultParams() internal pure returns (IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p) {
        p.standardParams.kernel = address(0);
        p.standardParams.initialAuthority = address(0);
        p.standardParams.fixedTermGracePeriodSeconds = 0;
        p.standardParams.minCoverageWAD = DEFAULT_MIN_COVERAGE_WAD;
        p.standardParams.coverageLiquidationUtilizationWAD = DEFAULT_LIQUIDATION_UTILIZATION_WAD;
        p.standardParams.minLiquidityWAD = DEFAULT_MIN_LIQUIDITY_WAD;
        p.stFixedRatePerSecondWAD = DEFAULT_ST_FIXED_RATE_PER_SECOND_WAD;
        p.lptYDM = address(0);
        p.lptYDMInitializationData = "";
        p.maxLPTYieldShareWAD = DEFAULT_MAX_LPT_YIELD_SHARE_WAD;
        p.standardParams.fixedTermDurationSeconds = DEFAULT_FIXED_TERM_DURATION_SECONDS;
        p.standardParams.dustTolerance = ZERO_NAV_UNITS;
        p.standardParams.stProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        p.standardParams.jtProtocolFeeWAD = 0;
        p.standardParams.jtYieldShareProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        p.standardParams.lptYieldShareProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
    }

    /// @dev Default init params with a fresh mock YDM and the suite's kernel pre-filled (for direct initialize tests)
    function _paramsWithFreshYDM() internal returns (IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p) {
        p = _defaultParams();
        p.standardParams.kernel = address(kernel);
        p.lptYDM = address(new MockRecordingYDM());
    }

    /// @dev Deploys a fresh kernel, authority, implementation, and un-initialized ERC1967 proxy (RoycoBase disables initializers on the implementation)
    function _deployUninitialized() internal returns (RoycoDayFixedRateAccountant acct) {
        return _deployUninitializedWithGrace(0);
    }

    /// @dev As _deployUninitialized, but records a nonzero fixed-term grace period so the young-market lock-out is
    ///      exercisable. The grace period is an initialization parameter, so it is applied when the proxy is
    ///      initialized, and the anchor is the initializing block's timestamp
    function _deployUninitializedWithGrace(uint24 _fixedTermGracePeriodSeconds) internal returns (RoycoDayFixedRateAccountant acct) {
        kernel = new MockFixedRateAccountantKernel();
        authority = new AccessManager(address(this));
        implementation = new RoycoDayFixedRateAccountant();
        fixedTermGracePeriodSeconds = _fixedTermGracePeriodSeconds;
        acct = RoycoDayFixedRateAccountant(address(new UninitializedERC1967Proxy(address(implementation))));
        kernel.setAccountant(address(acct));
    }

    /**
     * @dev Full deployment helper used by every test: proxy, initialize, and mock wiring
     * @dev A null YDM slot in the params is filled with a fresh MockRecordingYDM instance, otherwise the passed address is adopted as the suite's mock
     */
    function _deploy(IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory _params) internal returns (RoycoDayFixedRateAccountant acct) {
        return _deployWithGrace(_params, 0);
    }

    /// @dev As _deploy, but with a nonzero fixed-term grace period applied at initialization
    function _deployWithGrace(
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory _params,
        uint24 _fixedTermGracePeriodSeconds
    )
        internal
        returns (RoycoDayFixedRateAccountant acct)
    {
        acct = _deployUninitializedWithGrace(_fixedTermGracePeriodSeconds);
        if (_params.lptYDM == address(0)) _params.lptYDM = address(new MockRecordingYDM());
        lptYDM = MockRecordingYDM(_params.lptYDM);
        // The kernel and the grace period are initialization parameters, not implementation immutables
        _params.standardParams.kernel = address(kernel);
        _params.standardParams.initialAuthority = address(authority);
        _params.standardParams.fixedTermGracePeriodSeconds = _fixedTermGracePeriodSeconds;
        acct.initialize(_params);
        accountant = acct;
    }

    /*//////////////////////////////////////////////////////////////////////
                            CHECKPOINT SEEDING HELPERS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Drives the accountant into an arbitrary committed checkpoint state through legal kernel calls only
     *
     * Route (all in the deploy block, no warps, so the coupon window has zero elapsed time and every seeding
     * sync settles a zero coupon): ST_DEPOSIT of stEffectiveNAV then JT_DEPOSIT of (jtEffectiveNAV + il) via
     * post-op syncs, then a pre-op loss sync of exactly il. The junior buffer absorbs the whole loss as IL
     * with stEffectiveNAV unchanged, so the effective NAVs land on target with il exactly equal to the loss
     *
     * Constraints (asserted): jtEffectiveNAV == 0 with il > 0 is unreachable (the wipeout disjunct erases IL),
     * and a nonzero il target must exceed the dust tolerance and pair with FIXED_TERM: il > 0 and FIXED_TERM are
     * biconditional (every PERPETUAL commit erases the IL, and a dust loss from a perpetual state never locks),
     * verified loud by the self-check below
     */
    function _seedState(uint256 _stEff, uint256 _jtEff, uint256 _il, uint256 _lptRaw, MarketState _targetState) internal {
        assertTrue(!(_jtEff == 0 && _il > 0), "seed: jtEffectiveNAV 0 with il > 0 unreachable");

        if (_stEff > 0) kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(_stEff), ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        if (_jtEff + _il > 0) kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(_stEff + _jtEff + _il), ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        // Covered loss of exactly il: the junior buffer absorbs the whole loss so the effective NAVs land on target
        if (_il > 0) kernel.doPreOp(toNAVUnits(_stEff + _jtEff));

        kernel.doCommit(toNAVUnits(_lptRaw));

        // Self-verify the landed checkpoint so misuse is loud
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastCollateralNAV), _stEff + _jtEff, "seed: collateralNAV");
        assertEq(toUint256(s.lastSTEffectiveNAV), _stEff, "seed: stEffectiveNAV");
        assertEq(toUint256(s.lastJTEffectiveNAV), _jtEff, "seed: jtEffectiveNAV");
        assertEq(toUint256(s.lastJTImpermanentLoss), _il, "seed: il");
        assertEq(toUint256(s.lastLPTRawNAV), _lptRaw, "seed: lptRawNAV");
        assertEq(uint8(s.lastMarketState), uint8(_targetState), "seed: market state");
    }

    /// @dev Seeds the default flat market and performs the first sync so the yield share accrual clock is initialized in this block
    function _seedAndInitAccrual() internal {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(SEED_COLLATERAL));
    }

    /// @dev Hash of the accountant's full persisted state (the shared and fixed rate structs) for storage-mutation checks
    function _stateHash() internal view returns (bytes32) {
        return keccak256(abi.encode(accountant.getState(), accountant.getRoycoDayFixedRateAccountantState()));
    }

    /// @dev Calldata for the 10 hard-sync setters (restricted + withSyncedAccounting), each changing state vs the defaults
    /// @dev setJuniorTrancheProtocolFee is excluded: the fixed rate accountant rejects it unconditionally to keep the unbound knob pinned at zero
    function _hardSyncSetterCalls() internal pure returns (bytes[] memory calls) {
        calls = new bytes[](10);
        calls[0] = abi.encodeCall(IRoycoDayAccountant.setSeniorTrancheProtocolFee, (uint64(0.2e18)));
        calls[1] = abi.encodeCall(IRoycoDayAccountant.setJTYieldShareProtocolFee, (uint64(0.2e18)));
        calls[2] = abi.encodeCall(IRoycoDayAccountant.setLPTYieldShareProtocolFee, (uint64(0.2e18)));
        calls[3] = abi.encodeCall(IRoycoDayAccountant.setMinCoverage, (uint64(0.3e18)));
        calls[4] = abi.encodeCall(IRoycoDayAccountant.setLiquidationCoverageUtilization, (uint256(1.5e18)));
        calls[5] = abi.encodeCall(IRoycoDayAccountant.setMinLiquidity, (uint64(0.06e18)));
        calls[6] = abi.encodeCall(IRoycoDayFixedRateAccountant.setSeniorTrancheFixedRate, (uint64(2e9)));
        calls[7] = abi.encodeCall(IRoycoDayFixedRateAccountant.setMaxLPTYieldShare, (uint64(0.2e18)));
        calls[8] = abi.encodeCall(IRoycoDayAccountant.setFixedTermDuration, (uint24(1_209_600)));
        calls[9] = abi.encodeCall(IRoycoDayAccountant.setDustTolerance, (toNAVUnits(uint256(5))));
    }

    /// @dev Seeds a flat committed checkpoint (no IL, PERPETUAL) at the specified effective NAVs
    function _seedSymmetric(uint256 _stEff, uint256 _jtEff, uint256 _lptRaw) internal {
        _seedState(_stEff, _jtEff, 0, _lptRaw, MarketState.PERPETUAL);
    }

    /*//////////////////////////////////////////////////////////////////////
                            SYNC SCENARIO REGIME SEEDS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Regime seed, IL == 0 regime: flat 1000e18/200e18 market, yield share accrual clock initialized this
     * block (so the preview and execution both take the instantaneous premium branch on gains), preview rate lt 0.05e18
     */
    function _seedNoIL() internal {
        _seedAndInitAccrual();
        lptYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /**
     * @dev Regime seed, IL > dust regime: zero dust, FIXED_TERM checkpoint stEffectiveNAV 1000e18, jtEffectiveNAV 200e18,
     * collateralNAV 1200e18 with il 100e18 (fixed term end = now + default duration, committed during the seeding loss sync this block)
     */
    function _seedLargeIL() internal {
        _seedState(1000e18, 200e18, 100e18, SEED_LPT_RAW, MarketState.FIXED_TERM);
        lptYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /*//////////////////////////////////////////////////////////////////////
                            COUPON AND STATE EXPECTATION HELPERS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Independent coupon expectation: the fixed rate applied linearly to the senior effective NAV over the
     * elapsed window, floored in favor of the junior loss-absorption buffer
     */
    function _specCoupon(uint256 _stEff, uint256 _ratePerSecondWAD, uint256 _elapsed) internal pure returns (uint256) {
        return Math.mulDiv(_stEff, _ratePerSecondWAD * _elapsed, WAD);
    }

    /// @dev The committed coupon accrual window's opening timestamp
    function _couponWindowStart() internal view returns (uint256) {
        return accountant.getRoycoDayFixedRateAccountantState().lastCouponSettlementTimestamp;
    }

    /**
     * @dev Independent coverage utilization expectation, forwarded to the suite's single utilization mirror
     * (RoycoTestMath, 512-bit mulDiv) so every caller shares one overflow surface
     */
    function _specCoverageUtilization(uint256 _collateralNAV, uint256 _minCoverageWAD, uint256 _jtEff) internal pure returns (uint256) {
        return RoycoTestMath.computeCoverageUtilization(_collateralNAV, _minCoverageWAD, _jtEff);
    }

    /**
     * @dev Independent liquidity utilization expectation, forwarded to the suite's single utilization mirror
     * (RoycoTestMath, 512-bit mulDiv) so every caller shares one overflow surface
     */
    function _specLiquidityUtilization(uint256 _stEff, uint256 _minLiquidityWAD, uint256 _lptRaw) internal pure returns (uint256) {
        return RoycoTestMath.computeLiquidityUtilization(_stEff, _minLiquidityWAD, _lptRaw);
    }

    /**
     * @dev Marshals the committed checkpoint into the synced accounting state the kernel would pass to the
     * max* views, with both utilizations recomputed from the independent spec formulas
     */
    function _checkpointState() internal view returns (SyncedAccountingState memory st) {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        st.marketState = s.lastMarketState;
        st.collateralNAV = s.lastCollateralNAV;
        st.lptRawNAV = s.lastLPTRawNAV;
        st.stEffectiveNAV = s.lastSTEffectiveNAV;
        st.jtEffectiveNAV = s.lastJTEffectiveNAV;
        st.jtImpermanentLoss = s.lastJTImpermanentLoss;
        st.coverageUtilizationWAD = _specCoverageUtilization(toUint256(s.lastCollateralNAV), s.minCoverageWAD, toUint256(s.lastJTEffectiveNAV));
        st.liquidityUtilizationWAD = _specLiquidityUtilization(toUint256(s.lastSTEffectiveNAV), s.minLiquidityWAD, toUint256(s.lastLPTRawNAV));
        st.fixedTermEndTimestamp = s.fixedTermEndTimestamp;
        st.minCoverageWAD = s.minCoverageWAD;
        st.coverageLiquidationUtilizationWAD = s.coverageLiquidationUtilizationWAD;
        st.minLiquidityWAD = s.minLiquidityWAD;
    }

    /// @dev Counts logs emitted by the accountant whose topic0 matches the given event selector
    function _countAccountantLogs(Vm.Log[] memory _logs, bytes32 _topic0) internal view returns (uint256 count) {
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].emitter == address(accountant) && _logs[i].topics.length > 0 && _logs[i].topics[0] == _topic0) count++;
        }
    }
}
