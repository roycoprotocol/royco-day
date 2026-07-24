// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test, Vm } from "../../lib/forge-std/src/Test.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { RoycoDayAccountant } from "../../src/accountant/RoycoDayAccountant.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { WAD, ZERO_NAV_UNITS } from "../../src/libraries/Constants.sol";
import { MarketState, Operation, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { MockAccountantKernel } from "../mocks/MockAccountantKernel.sol";
import { MockRecordingYDM } from "../mocks/MockRecordingYDM.sol";
import { UninitializedERC1967Proxy } from "../mocks/UninitializedERC1967Proxy.sol";
import { RoycoTestMath } from "./RoycoTestMath.sol";

/**
 * @title AccountantTestBase
 * @notice Shared mock-kernel base for every RoycoDayAccountant test suite: the default init params, the
 *         proxy deploy path, checkpoint seeding through legal kernel calls only, the regime seeds for the
 *         tranche accounting sync scenarios, and the committed-checkpoint marshallers for the max* views
 * @dev Checkpoints are always constructed through legal kernel calls (post-op deposits, pre-op syncs, LPT
 *      commits), never through storage writes, so every seeded state is a state production can actually reach
 */
abstract contract AccountantTestBase is Test {
    // Default init params (boundary probing tests deploy with their own params)
    uint64 internal constant DEFAULT_MIN_COVERAGE_WAD = 0.1e18;
    uint256 internal constant DEFAULT_LIQUIDATION_UTILIZATION_WAD = 1.1e18;
    uint64 internal constant DEFAULT_MIN_LIQUIDITY_WAD = 0.05e18;
    uint64 internal constant DEFAULT_MAX_JT_YIELD_SHARE_WAD = 0.2e18;
    uint64 internal constant DEFAULT_MAX_LPT_YIELD_SHARE_WAD = 0.1e18;
    uint24 internal constant DEFAULT_FIXED_TERM_DURATION_SECONDS = 604_800;
    uint64 internal constant DEFAULT_PROTOCOL_FEE_WAD = 0.1e18;

    // Default flat seed used by the accrual tests (effective NAVs, the collateral NAV is their sum under conservation)
    uint256 internal constant SEED_ST_EFF = 1000e18;
    uint256 internal constant SEED_JT_EFF = 200e18;
    uint256 internal constant SEED_LPT_RAW = 100e18;
    // Expected utilizations at the default flat seed, computed independently:
    //   coverageUtilization = ceil(1200e18 * 0.1e18 / 200e18) = 0.6e18 (exact division so ceil == floor)
    //   liquidityUtilization = ceil(1000e18 * 0.05e18 / 100e18) = 0.5e18 (exact division)
    uint256 internal constant SEED_COVERAGE_UTILIZATION_WAD = 0.6e18;
    uint256 internal constant SEED_LIQUIDITY_UTILIZATION_WAD = 0.5e18;

    RoycoDayAccountant internal accountant;
    RoycoDayAccountant internal implementation;
    MockAccountantKernel internal kernel;
    MockRecordingYDM internal jtYDM;
    MockRecordingYDM internal lptYDM;
    AccessManager internal authority;
    address internal stranger;

    /*//////////////////////////////////////////////////////////////////////
                            DEPLOY HELPERS
    //////////////////////////////////////////////////////////////////////*/

    /// @dev Default init params with null YDM slots that _deploy fills with fresh mocks
    function _defaultParams() internal pure returns (IRoycoDayAccountant.RoycoDayAccountantInitParams memory p) {
        p.minCoverageWAD = DEFAULT_MIN_COVERAGE_WAD;
        p.coverageLiquidationUtilizationWAD = DEFAULT_LIQUIDATION_UTILIZATION_WAD;
        p.minLiquidityWAD = DEFAULT_MIN_LIQUIDITY_WAD;
        p.jtYDM = address(0);
        p.jtYDMInitializationData = "";
        p.lptYDM = address(0);
        p.lptYDMInitializationData = "";
        p.maxJTYieldShareWAD = DEFAULT_MAX_JT_YIELD_SHARE_WAD;
        p.maxLPTYieldShareWAD = DEFAULT_MAX_LPT_YIELD_SHARE_WAD;
        p.fixedTermDurationSeconds = DEFAULT_FIXED_TERM_DURATION_SECONDS;
        p.dustTolerance = ZERO_NAV_UNITS;
        p.stProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        p.jtProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        p.jtYieldShareProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        p.lptYieldShareProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
    }

    /// @dev Default init params with two fresh mock YDMs pre-filled (for direct initialize tests)
    function _paramsWithFreshYDMs() internal returns (IRoycoDayAccountant.RoycoDayAccountantInitParams memory p) {
        p = _defaultParams();
        p.jtYDM = address(new MockRecordingYDM());
        p.lptYDM = address(new MockRecordingYDM());
    }

    /// @dev Deploys a fresh kernel, authority, implementation, and un-initialized ERC1967 proxy (RoycoBase disables initializers on the implementation)
    function _deployUninitialized() internal returns (RoycoDayAccountant acct) {
        kernel = new MockAccountantKernel();
        authority = new AccessManager(address(this));
        implementation = new RoycoDayAccountant(address(kernel));
        acct = RoycoDayAccountant(address(new UninitializedERC1967Proxy(address(implementation))));
        kernel.setAccountant(address(acct));
    }

    /**
     * @dev Full deployment helper used by every test: proxy, initialize, and mock wiring
     * @dev Null YDM slots in the params are filled with fresh MockRecordingYDM instances, otherwise the passed addresses are adopted as the suite's mocks
     */
    function _deploy(IRoycoDayAccountant.RoycoDayAccountantInitParams memory _params) internal returns (RoycoDayAccountant acct) {
        acct = _deployUninitialized();
        if (_params.jtYDM == address(0)) _params.jtYDM = address(new MockRecordingYDM());
        if (_params.lptYDM == address(0)) _params.lptYDM = address(new MockRecordingYDM());
        jtYDM = MockRecordingYDM(_params.jtYDM);
        lptYDM = MockRecordingYDM(_params.lptYDM);
        acct.initialize(_params, address(authority));
        accountant = acct;
    }

    /*//////////////////////////////////////////////////////////////////////
                            CHECKPOINT SEEDING HELPERS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Drives the accountant into an arbitrary committed checkpoint state through legal kernel calls only
     *
     * Route (all in the current block, no warps): ST_DEPOSIT of stEffectiveNAV then JT_DEPOSIT of (jtEffectiveNAV + il)
     * via post-op syncs, then a pre-op loss sync of exactly il. Under the single-collateral attribution the loss
     * splits pro-rata but JT absorbs its own leg as IL and covers the ST leg (also booked as IL), so the whole
     * loss lands on jtEffectiveNAV with stEffectiveNAV unchanged and il exactly equal to the loss
     *
     * Constraints (asserted): jtEffectiveNAV == 0 with il > 0 is unreachable (the wipeout disjunct erases IL),
     * and a nonzero il target must exceed the dust tolerance and pair with FIXED_TERM: il > 0 and FIXED_TERM are
     * biconditional (every PERPETUAL commit erases the IL, and a dust loss from a perpetual state never locks),
     * verified loud by the self-check below
     */
    function _seedState(uint256 _stEff, uint256 _jtEff, uint256 _il, uint256 _lptRaw, MarketState _targetState) internal {
        assertTrue(!(_jtEff == 0 && _il > 0), "seed: jtEffectiveNAV 0 with il > 0 unreachable");

        if (_stEff > 0) kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(_stEff), ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
        if (_jtEff + _il > 0) kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(_stEff + _jtEff + _il), ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
        // Covered loss of exactly il: JT absorbs both attribution legs so the effective NAVs land on target
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

    /// @dev Seeds the default flat market and performs the first sync so the accrual clock is initialized in this block
    function _seedAndInitAccrual() internal {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(SEED_ST_EFF + SEED_JT_EFF));
    }

    /// @dev Hash of the accountant's full persisted state for storage-mutation checks
    function _stateHash() internal view returns (bytes32) {
        return keccak256(abi.encode(accountant.getState()));
    }

    /// @dev Calldata for the 10 hard-sync setters (restricted + withSyncedAccounting), each changing state vs the defaults
    function _hardSyncSetterCalls() internal pure returns (bytes[] memory calls) {
        calls = new bytes[](10);
        calls[0] = abi.encodeCall(IRoycoDayAccountant.setSeniorTrancheProtocolFee, (uint64(0.2e18)));
        calls[1] = abi.encodeCall(IRoycoDayAccountant.setJuniorTrancheProtocolFee, (uint64(0.2e18)));
        calls[2] = abi.encodeCall(IRoycoDayAccountant.setJTYieldShareProtocolFee, (uint64(0.2e18)));
        calls[3] = abi.encodeCall(IRoycoDayAccountant.setLPTYieldShareProtocolFee, (uint64(0.2e18)));
        calls[4] = abi.encodeCall(IRoycoDayAccountant.setMinCoverage, (uint64(0.3e18)));
        calls[5] = abi.encodeCall(IRoycoDayAccountant.setLiquidationCoverageUtilization, (uint256(1.5e18)));
        calls[6] = abi.encodeCall(IRoycoDayAccountant.setMinLiquidity, (uint64(0.06e18)));
        calls[7] = abi.encodeCall(IRoycoDayAccountant.setMaxYieldShares, (uint64(0.3e18), uint64(0.2e18)));
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
     * @dev Regime seed, IL == 0 regime: flat 1000e18/200e18 market, accrual clock initialized this block (so the
     * preview and execution both take the instantaneous premium branch on gains), preview rates jt 0.1e18 / lt 0.05e18
     */
    function _seedNoIL() internal {
        _seedAndInitAccrual();
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        lptYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /**
     * @dev Regime seed, IL > dust regime: zero dust, FIXED_TERM checkpoint stEffectiveNAV 1000e18, jtEffectiveNAV 200e18,
     * collateralNAV 1200e18 with il 100e18 (fixed term end = now + default duration, committed during the seeding loss sync this block)
     * @dev Attribution at this checkpoint: a collateral delta d attributes floor(|d| * 1000e18 / 1200e18) = floor(5d / 6) to ST
     */
    function _seedLargeIL() internal {
        _seedState(1000e18, 200e18, 100e18, SEED_LPT_RAW, MarketState.FIXED_TERM);
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        lptYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /**
     * @dev Regime seed (0 < IL <= dust, FIXED_TERM): dust tolerance 7 and checkpoint collateralNAV 1200e18-5,
     * stEffectiveNAV 1000e18, jtEffectiveNAV 200e18-5, il 5, FIXED_TERM, end kept from the entry sync
     *
     * Staging (all in this block): deploy with dust 7, flat seed, loss sync of 12 (> dust 7) enters FIXED_TERM
     * (the junior buffer absorbs the whole 12 wei loss, il 12, stEffectiveNAV unchanged), landing il just above
     * the dust tolerance: a FIXED_TERM checkpoint carrying il <= dust is unrepresentable because the dust
     * disjunct erases it at commit (RoycoDayAccountant)
     */
    function _seedDustILFixedTerm() internal {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(7));
        _deploy(p);
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, SEED_LPT_RAW, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(SEED_ST_EFF + SEED_JT_EFF - 12));
        kernel.doCommit(toNAVUnits(SEED_LPT_RAW));

        // Self-verify the landed checkpoint so staging misuse is loud
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastCollateralNAV), 1200e18 - 12, "seed fixed-term dust-IL: collateralNAV");
        assertEq(toUint256(s.lastSTEffectiveNAV), 1000e18, "seed fixed-term dust-IL: stEffectiveNAV");
        assertEq(toUint256(s.lastJTEffectiveNAV), 200e18 - 12, "seed fixed-term dust-IL: jtEffectiveNAV");
        assertEq(toUint256(s.lastJTImpermanentLoss), 12, "seed fixed-term dust-IL: above-dust il");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "seed fixed-term dust-IL: market state");
        assertEq(s.fixedTermEndTimestamp, uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS), "seed fixed-term dust-IL: original end kept");

        jtYDM.setPreviewYieldShareReturn(0.1e18);
        lptYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /*//////////////////////////////////////////////////////////////////////
                            STATE MARSHALLING AND LOG HELPERS
    //////////////////////////////////////////////////////////////////////*/

    /// @dev Counts logs emitted by the accountant whose topic0 matches the given event selector
    function _countAccountantLogs(Vm.Log[] memory _logs, bytes32 _topic0) internal view returns (uint256 count) {
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].emitter == address(accountant) && _logs[i].topics.length > 0 && _logs[i].topics[0] == _topic0) count++;
        }
    }

    /**
     * @dev Independent coverage utilization expectation:
     * ceil(collateralNAV * minCoverage / jtEffectiveNAV), 0 when the minimum coverage or the
     * collateral is zero, uint256 max when the junior buffer is zero against live collateral
     * @dev Forwards to the suite's single utilization mirror (RoycoTestMath, 512-bit mulDiv) so every caller
     * shares one overflow surface, a raw-multiply duplicate that overflowed at collateral x minCoverage >= 2^256
     * used to live here and was deleted in favor of this forward
     */
    function _specCoverageUtilization(uint256 _collateralNAV, uint256 _minCoverageWAD, uint256 _jtEff) internal pure returns (uint256) {
        return RoycoTestMath.computeCoverageUtilization(_collateralNAV, _minCoverageWAD, _jtEff);
    }

    /**
     * @dev Independent liquidity utilization expectation:
     * ceil(stEffectiveNAV * minLiquidity / lptRawNAV), 0 when the senior effective NAV or the minimum liquidity is zero,
     * uint256 max when the market-making inventory is zero against a live requirement
     * @dev Forwards to the suite's single utilization mirror (RoycoTestMath, 512-bit mulDiv), see
     * _specCoverageUtilization for why the raw-multiply duplicate was deleted
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

    /**
     * @dev Builds a bare synced accounting state for direct max* closed-form probing
     * @dev Only the fields the max* views read are populated, and the liquidation threshold defaults to the
     * uint256 maximum so the maxLPTWithdrawal liquidation shortcut stays un-triggered unless a test arms it
     */
    function _bareState(
        uint256 _collateralNAV,
        uint256 _lptRaw,
        uint256 _stEff,
        uint256 _jtEff,
        uint256 _minCoverageWAD,
        uint256 _minLiquidityWAD
    )
        internal
        pure
        returns (SyncedAccountingState memory st)
    {
        st.collateralNAV = toNAVUnits(_collateralNAV);
        st.lptRawNAV = toNAVUnits(_lptRaw);
        st.stEffectiveNAV = toNAVUnits(_stEff);
        st.jtEffectiveNAV = toNAVUnits(_jtEff);
        st.minCoverageWAD = _minCoverageWAD;
        st.minLiquidityWAD = _minLiquidityWAD;
        st.coverageLiquidationUtilizationWAD = type(uint256).max;
    }

    /// @dev Seeds the default flat 1000e18/200e18 market with the specified committed liquidity provider tranche raw NAV
    function _seedFlatWithLPT(uint256 _lptRaw) internal {
        _seedState(SEED_ST_EFF, SEED_JT_EFF, 0, _lptRaw, MarketState.PERPETUAL);
    }
}
