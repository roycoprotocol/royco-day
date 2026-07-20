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
 * @dev Checkpoints are always constructed through legal kernel calls (post-op deposits, pre-op syncs, LT
 *      commits), never through storage writes, so every seeded state is a state production can actually reach
 */
abstract contract AccountantTestBase is Test {
    // Default init params (boundary probing tests deploy with their own params)
    uint64 internal constant DEFAULT_MIN_COVERAGE_WAD = 0.1e18;
    uint256 internal constant DEFAULT_LIQUIDATION_UTILIZATION_WAD = 1.1e18;
    uint64 internal constant DEFAULT_MIN_LIQUIDITY_WAD = 0.05e18;
    uint64 internal constant DEFAULT_MAX_JT_YIELD_SHARE_WAD = 0.2e18;
    uint64 internal constant DEFAULT_MAX_LT_YIELD_SHARE_WAD = 0.1e18;
    uint24 internal constant DEFAULT_FIXED_TERM_DURATION_SECONDS = 604_800;
    uint64 internal constant DEFAULT_PROTOCOL_FEE_WAD = 0.1e18;

    // Default flat seed used by the accrual tests
    uint256 internal constant SEED_ST_RAW = 1000e18;
    uint256 internal constant SEED_JT_RAW = 200e18;
    uint256 internal constant SEED_LT_RAW = 100e18;
    // Expected utilizations at the default flat seed, computed independently:
    //   coverageUtilization = ceil((1000e18 + 200e18) * 0.1e18 / 200e18) = 0.6e18 (exact division so ceil == floor)
    //   liquidityUtilization = ceil(1000e18 * 0.05e18 / 100e18) = 0.5e18 (exact division)
    uint256 internal constant SEED_COVERAGE_UTILIZATION_WAD = 0.6e18;
    uint256 internal constant SEED_LIQUIDITY_UTILIZATION_WAD = 0.5e18;

    RoycoDayAccountant internal accountant;
    RoycoDayAccountant internal implementation;
    MockAccountantKernel internal kernel;
    MockRecordingYDM internal jtYDM;
    MockRecordingYDM internal ltYDM;
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
        p.ltYDM = address(0);
        p.ltYDMInitializationData = "";
        p.maxJTYieldShareWAD = DEFAULT_MAX_JT_YIELD_SHARE_WAD;
        p.maxLTYieldShareWAD = DEFAULT_MAX_LT_YIELD_SHARE_WAD;
        p.fixedTermDurationSeconds = DEFAULT_FIXED_TERM_DURATION_SECONDS;
        p.stNAVDustTolerance = ZERO_NAV_UNITS;
        p.jtNAVDustTolerance = ZERO_NAV_UNITS;
        p.stProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        p.jtProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        p.jtYieldShareProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        p.ltYieldShareProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
    }

    /// @dev Default init params with two fresh mock YDMs pre-filled (for direct initialize tests)
    function _paramsWithFreshYDMs() internal returns (IRoycoDayAccountant.RoycoDayAccountantInitParams memory p) {
        p = _defaultParams();
        p.jtYDM = address(new MockRecordingYDM());
        p.ltYDM = address(new MockRecordingYDM());
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
        if (_params.ltYDM == address(0)) _params.ltYDM = address(new MockRecordingYDM());
        jtYDM = MockRecordingYDM(_params.jtYDM);
        ltYDM = MockRecordingYDM(_params.ltYDM);
        acct.initialize(_params, address(authority));
        accountant = acct;
    }

    /*//////////////////////////////////////////////////////////////////////
                            CHECKPOINT SEEDING HELPERS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Drives the accountant into an arbitrary committed checkpoint state through legal kernel calls only
     *
     * Routes (all in the current block, no warps):
     * 1. Symmetric states (stEffectiveNAV == stRawNAV): ST_DEPOSIT of stEffectiveNAV then JT_DEPOSIT of jtRawNAV via post-op syncs
     * 2. ST cross-claim states (stEffectiveNAV > stRawNAV, JT provided coverage): deposit ST = stEffectiveNAV and JT = jtRawNAV, then a
     *    pre-op loss sync of cross = stEffectiveNAV - stRawNAV. The loss is fully covered by JT so stEffectiveNAV is unchanged while
     *    stRawNAV, jtEffectiveNAV, and IL land exactly on target (conservation forces jtRawNAV = jtEffectiveNAV + cross)
     *    - il < cross is reached by splitting the loss in two: first a covered loss of (cross - il), then erasing
     *      that IL with the setFixedTermDuration(0) round-trip (erases IL, forces PERPETUAL, keeps effective NAVs),
     *      then a second covered loss of exactly il
     * 3. JT cross-claim states (jtEffectiveNAV > jtRawNAV, requires il == 0): pay the cross-claim p as a JT risk premium out of
     *    a synthetic senior gain g. Deposit ST = stRawNAV - g, then a flat first pre-op sync (initializes the accrual
     *    clock in this block), then a same-block gain sync of g which takes the instantaneous branch and pays
     *    jtRiskPremium = floor(g * maxJT / WAD) == p with the JT preview rate pinned above the cap
     *
     * Constraints (asserted): conservation on inputs, il <= cross for route 2, an il > effective dust target
     * requires targetState == FIXED_TERM (entry is forced by the loss sync), and jtEffectiveNAV == 0 with il > 0 is
     * unreachable (the wipeout disjunct erases IL). Route 3 requires g = p * WAD / maxJT to divide exactly
     */
    function _seedState(uint256 _stRaw, uint256 _jtRaw, uint256 _stEff, uint256 _jtEff, uint256 _il, uint256 _ltRaw, MarketState _targetState) internal {
        assertEq(_stRaw + _jtRaw, _stEff + _jtEff, "seed: conservation violated by target");

        if (_stEff >= _stRaw) {
            uint256 cross = _stEff - _stRaw;
            assertLe(_il, cross, "seed: il exceeds ST cross-claim");
            assertTrue(!(_jtEff == 0 && _il > 0), "seed: jtEffectiveNAV 0 with il > 0 unreachable");
            if (_stEff > 0) kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(_stEff), ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
            if (_jtRaw > 0) kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(_stEff), toNAVUnits(_jtRaw), ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
            if (cross > 0) {
                if (_il < cross) {
                    // Covered loss of (cross - il) then erase its IL via the permanently-perpetual setter round-trip
                    kernel.doPreOp(toNAVUnits(_stEff - (cross - _il)), toNAVUnits(_jtRaw));
                    uint24 duration = accountant.getState().fixedTermDurationSeconds;
                    accountant.setFixedTermDuration(0);
                    accountant.setFixedTermDuration(duration);
                    // Second covered loss of exactly il
                    if (_il > 0) kernel.doPreOp(toNAVUnits(_stRaw), toNAVUnits(_jtRaw));
                } else {
                    kernel.doPreOp(toNAVUnits(_stRaw), toNAVUnits(_jtRaw));
                }
            }
        } else {
            // JT holds a claim on ST raw NAV: pay it as a risk premium out of a synthetic senior gain
            assertEq(_il, 0, "seed: il unsupported with JT cross-claim");
            uint256 p = _stRaw - _stEff;
            uint256 maxJT = accountant.getState().maxJTYieldShareWAD;
            assertGt(maxJT, 0, "seed: maxJT must be nonzero for a JT cross-claim");
            uint256 g = (p * WAD) / maxJT;
            assertEq((g * maxJT) / WAD, p, "seed: premium not exactly representable, pick divisible values");
            assertGt(_stRaw, g, "seed: gain must leave a positive initial ST deposit");
            uint256 initialSTDeposit = _stRaw - g;
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(initialSTDeposit), ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
            if (_jtRaw > 0) kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(initialSTDeposit), toNAVUnits(_jtRaw), ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
            // Flat first sync initializes the accrual clock so the gain sync below takes the instantaneous branch
            kernel.doPreOp(toNAVUnits(initialSTDeposit), toNAVUnits(_jtRaw));
            uint256 savedJTPreview = jtYDM.previewYieldShareReturn();
            uint256 savedLTPreview = ltYDM.previewYieldShareReturn();
            jtYDM.setPreviewYieldShareReturn(type(uint256).max);
            ltYDM.setPreviewYieldShareReturn(0);
            kernel.doPreOp(toNAVUnits(_stRaw), toNAVUnits(_jtRaw));
            jtYDM.setPreviewYieldShareReturn(savedJTPreview);
            ltYDM.setPreviewYieldShareReturn(savedLTPreview);
        }

        kernel.doCommit(toNAVUnits(_ltRaw));

        // Self-verify the landed checkpoint so misuse is loud
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTRawNAV), _stRaw, "seed: stRawNAV");
        assertEq(toUint256(s.lastJTRawNAV), _jtRaw, "seed: jtRawNAV");
        assertEq(toUint256(s.lastSTEffectiveNAV), _stEff, "seed: stEffectiveNAV");
        assertEq(toUint256(s.lastJTEffectiveNAV), _jtEff, "seed: jtEffectiveNAV");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), _il, "seed: il");
        assertEq(toUint256(s.lastLTRawNAV), _ltRaw, "seed: ltRawNAV");
        assertEq(uint8(s.lastMarketState), uint8(_targetState), "seed: market state");
    }

    /// @dev Seeds the default flat market and performs the first sync so the accrual clock is initialized in this block
    function _seedAndInitAccrual() internal {
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
    }

    /// @dev Hash of the accountant's full persisted state for storage-mutation checks
    function _stateHash() internal view returns (bytes32) {
        return keccak256(abi.encode(accountant.getState()));
    }

    /// @dev Calldata for the 11 hard-sync setters (restricted + withSyncedAccounting), each changing state vs the defaults
    function _hardSyncSetterCalls() internal pure returns (bytes[] memory calls) {
        calls = new bytes[](11);
        calls[0] = abi.encodeCall(IRoycoDayAccountant.setSeniorTrancheProtocolFee, (uint64(0.2e18)));
        calls[1] = abi.encodeCall(IRoycoDayAccountant.setJuniorTrancheProtocolFee, (uint64(0.2e18)));
        calls[2] = abi.encodeCall(IRoycoDayAccountant.setJTYieldShareProtocolFee, (uint64(0.2e18)));
        calls[3] = abi.encodeCall(IRoycoDayAccountant.setLTYieldShareProtocolFee, (uint64(0.2e18)));
        calls[4] = abi.encodeCall(IRoycoDayAccountant.setMinCoverage, (uint64(0.3e18)));
        calls[5] = abi.encodeCall(IRoycoDayAccountant.setLiquidationCoverageUtilization, (uint256(1.5e18)));
        calls[6] = abi.encodeCall(IRoycoDayAccountant.setMinLiquidity, (uint64(0.06e18)));
        calls[7] = abi.encodeCall(IRoycoDayAccountant.setMaxYieldShares, (uint64(0.3e18), uint64(0.2e18)));
        calls[8] = abi.encodeCall(IRoycoDayAccountant.setFixedTermDuration, (uint24(1_209_600)));
        calls[9] = abi.encodeCall(IRoycoDayAccountant.setSeniorTrancheDustTolerance, (toNAVUnits(uint256(5))));
        calls[10] = abi.encodeCall(IRoycoDayAccountant.setJuniorTrancheDustTolerance, (toNAVUnits(uint256(6))));
    }

    /// @dev Seeds a symmetric committed checkpoint (stEffectiveNAV == stRawNAV, jtEffectiveNAV == jtRawNAV, IL 0, PERPETUAL)
    function _seedSymmetric(uint256 _stRaw, uint256 _jtRaw, uint256 _ltRaw) internal {
        _seedState(_stRaw, _jtRaw, _stRaw, _jtRaw, 0, _ltRaw, MarketState.PERPETUAL);
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
        ltYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /**
     * @dev Regime seed, 0 < IL <= dust regime: dust tolerances (st 3, jt 4, effective 7) and a persisted 5 wei
     * coverage impermanent loss in a PERPETUAL market (checkpoint 1000e18 / 200e18 / 1000e18+5 / 200e18-5)
     * @dev Claims at this checkpoint: stClaimOnJTRaw = 5 wei so a 20e18 JT delta attributes floor(20e18 * 5 / 200e18) = 0 to ST
     */
    function _seedDustIL() internal {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(4));
        _deploy(p);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW + 5, SEED_JT_RAW - 5, 5, SEED_LT_RAW, MarketState.PERPETUAL);
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /**
     * @dev Regime seed, IL > dust regime: zero dust, FIXED_TERM cross-claim checkpoint 900e18 / 300e18 / 1000e18 / 200e18
     * with il 100e18 (fixed term end = now + default duration, committed during the seeding loss sync this block)
     * @dev Claims: stClaimOnSTRaw = 900e18 (full), stClaimOnJTRaw = 100e18, so a JT delta d attributes floor(d / 3) to ST
     */
    function _seedLargeIL() internal {
        _seedState(900e18, 300e18, 1000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /**
     * @dev Regime seed (IL == 0, FIXED_TERM): checkpoint stRawNAV 1000e18-1, jtRawNAV 100e18, stEffectiveNAV 1000e18,
     * jtEffectiveNAV 100e18-1, il 0, zero dust, FIXED_TERM with end = seeding block + default duration
     *
     * Staging (accountant surface, all in this block): (1) symmetric 1000e18/200e18 seed with lastLTRawNAV 0,
     * (2) covered 1-wei loss sync enters FIXED_TERM (il 1 > dust 0) and initializes both premium timestamps,
     * (3) JT_REDEEM post-op of 100e18 floors the il to 0 via the RoycoDayAccountant scaling floor(1 * (100e18-1) /
     * (200e18-1)) = 0 while the market state stays FIXED_TERM (post-op never changes it), (4) commit lt 100e18.
     * Step 3 passes ltRawNAV 0 against the still-zero lastLTRawNAV so deltaLTRawNAV == 0 (the commit-after-redeem
     * ordering does not trip INVALID_POST_OP_STATE, verified loud here)
     */
    function _seedNoILFixedTerm() internal {
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, 0, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW - 1), toNAVUnits(SEED_JT_RAW));
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW - 1), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
        kernel.doCommit(toNAVUnits(SEED_LT_RAW));

        // Self-verify the landed checkpoint so staging misuse is loud
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTRawNAV), 1000e18 - 1, "seed fixed-term no-IL: stRawNAV");
        assertEq(toUint256(s.lastJTRawNAV), 100e18, "seed fixed-term no-IL: jtRawNAV");
        assertEq(toUint256(s.lastSTEffectiveNAV), 1000e18, "seed fixed-term no-IL: stEffectiveNAV");
        assertEq(toUint256(s.lastJTEffectiveNAV), 100e18 - 1, "seed fixed-term no-IL: jtEffectiveNAV");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), 0, "seed fixed-term no-IL: il floored to 0");
        assertEq(toUint256(s.lastLTRawNAV), SEED_LT_RAW, "seed fixed-term no-IL: ltRawNAV");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "seed fixed-term no-IL: market state");
        assertEq(s.fixedTermEndTimestamp, uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS), "seed fixed-term no-IL: fixed term end");

        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /**
     * @dev Regime seed (0 < IL <= dust, FIXED_TERM): dust tolerances (st 3, jt 4, effective 7) and
     * checkpoint stRawNAV 1000e18-5, jtRawNAV 200e18, stEffectiveNAV 1000e18, jtEffectiveNAV 200e18-5, il 5, FIXED_TERM, end kept from
     * the entry sync
     *
     * Staging (all in this block): deploy with dust (3,4), symmetric seed, covered loss of 12 (> dust 7) enters
     * FIXED_TERM, then a partial-recovery sync of +7 is fully consumed by il recovery (rec = min(7, 12) = 7, no
     * premium block) leaving il 5 in (0, 7] with the initial state FIXED_TERM: the sticky-dust branch keeps the
     * term and the original end (RoycoDayAccountant)
     */
    function _seedDustILFixedTerm() internal {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(4));
        _deploy(p);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW - 12), toNAVUnits(SEED_JT_RAW));
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW - 5), toNAVUnits(SEED_JT_RAW));
        kernel.doCommit(toNAVUnits(SEED_LT_RAW));

        // Self-verify the landed checkpoint so staging misuse is loud
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTRawNAV), 1000e18 - 5, "seed fixed-term dust-IL: stRawNAV");
        assertEq(toUint256(s.lastJTRawNAV), 200e18, "seed fixed-term dust-IL: jtRawNAV");
        assertEq(toUint256(s.lastSTEffectiveNAV), 1000e18, "seed fixed-term dust-IL: stEffectiveNAV");
        assertEq(toUint256(s.lastJTEffectiveNAV), 200e18 - 5, "seed fixed-term dust-IL: jtEffectiveNAV");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), 5, "seed fixed-term dust-IL: sticky dust il");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "seed fixed-term dust-IL: market state");
        assertEq(s.fixedTermEndTimestamp, uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS), "seed fixed-term dust-IL: original end kept");

        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /**
     * @dev Regime seed (IL > dust, PERPETUAL): the dust-IL perpetual checkpoint (1000e18 / 200e18 /
     * 1000e18+5 / 200e18-5, il 5, PERPETUAL) with both dust tolerances then shrunk to 0 via the setters, the
     * only reachable route to a committed PERPETUAL checkpoint whose persisted il exceeds the effective
     * dust. The kernel sync mode is NONE so withSyncedAccounting is a no-op
     *
     * Verifies empirically that the two dust setters must leave the committed
     * checkpoint (NAVs, il, market state, end, accrual and premium timestamps, accumulators) byte-identical,
     * changing only the dust fields
     */
    function _seedShrunkDustIL() internal {
        _seedDustIL();
        IRoycoDayAccountant.RoycoDayAccountantState memory before = accountant.getState();
        accountant.setSeniorTrancheDustTolerance(ZERO_NAV_UNITS);
        accountant.setJuniorTrancheDustTolerance(ZERO_NAV_UNITS);
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTRawNAV), toUint256(before.lastSTRawNAV), "seed shrunk-dust: stRawNAV untouched");
        assertEq(toUint256(s.lastJTRawNAV), toUint256(before.lastJTRawNAV), "seed shrunk-dust: jtRawNAV untouched");
        assertEq(toUint256(s.lastSTEffectiveNAV), toUint256(before.lastSTEffectiveNAV), "seed shrunk-dust: stEffectiveNAV untouched");
        assertEq(toUint256(s.lastJTEffectiveNAV), toUint256(before.lastJTEffectiveNAV), "seed shrunk-dust: jtEffectiveNAV untouched");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), 5, "seed shrunk-dust: il 5 persists");
        assertEq(toUint256(s.lastLTRawNAV), toUint256(before.lastLTRawNAV), "seed shrunk-dust: ltRawNAV untouched");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "seed shrunk-dust: market state untouched");
        assertEq(s.fixedTermEndTimestamp, before.fixedTermEndTimestamp, "seed shrunk-dust: fixed term end untouched");
        assertEq(s.lastYieldShareAccrualTimestamp, before.lastYieldShareAccrualTimestamp, "seed shrunk-dust: accrual timestamp untouched");
        assertEq(s.lastPremiumPaymentTimestamp, before.lastPremiumPaymentTimestamp, "seed shrunk-dust: premium payment timestamp untouched");
        assertEq(uint256(s.twJTYieldShareAccruedWAD), uint256(before.twJTYieldShareAccruedWAD), "seed shrunk-dust: jt accumulator untouched");
        assertEq(uint256(s.twLTYieldShareAccruedWAD), uint256(before.twLTYieldShareAccruedWAD), "seed shrunk-dust: lt accumulator untouched");
        assertEq(toUint256(s.effectiveNAVDustTolerance), 0, "seed shrunk-dust: effective dust shrunk to 0");
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
     * ceil((stRawNAV + jtRawNAV) * minCoverage / jtEffectiveNAV), 0 when the minimum coverage or the
     * exposure is zero, uint256 max when the junior buffer is zero against live exposure
     * @dev Forwards to the suite's single utilization mirror (RoycoTestMath, 512-bit mulDiv) so every caller
     * shares one overflow surface, a raw-multiply duplicate that overflowed at exposure x minCoverage >= 2^256
     * used to live here and was deleted in favor of this forward
     */
    function _specCoverageUtilization(
        uint256 _stRaw,
        uint256 _jtRaw,
        uint256 _minCoverageWAD,
        uint256 _jtEff
    )
        internal
        pure
        returns (uint256)
    {
        return RoycoTestMath.computeCoverageUtilization(_stRaw, _jtRaw, _minCoverageWAD, _jtEff);
    }

    /**
     * @dev Independent liquidity utilization expectation:
     * ceil(stEffectiveNAV * minLiquidity / ltRawNAV), 0 when the senior effective NAV or the minimum liquidity is zero,
     * uint256 max when the market-making inventory is zero against a live requirement
     * @dev Forwards to the suite's single utilization mirror (RoycoTestMath, 512-bit mulDiv), see
     * _specCoverageUtilization for why the raw-multiply duplicate was deleted
     */
    function _specLiquidityUtilization(uint256 _stEff, uint256 _minLiquidityWAD, uint256 _ltRaw) internal pure returns (uint256) {
        return RoycoTestMath.computeLiquidityUtilization(_stEff, _minLiquidityWAD, _ltRaw);
    }

    /**
     * @dev Marshals the committed checkpoint into the synced accounting state the kernel would pass to the
     * max* views, with both utilizations recomputed from the independent spec formulas
     */
    function _checkpointState() internal view returns (SyncedAccountingState memory st) {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        st.marketState = s.lastMarketState;
        st.stRawNAV = s.lastSTRawNAV;
        st.jtRawNAV = s.lastJTRawNAV;
        st.ltRawNAV = s.lastLTRawNAV;
        st.stEffectiveNAV = s.lastSTEffectiveNAV;
        st.jtEffectiveNAV = s.lastJTEffectiveNAV;
        st.jtCoverageImpermanentLoss = s.lastJTCoverageImpermanentLoss;
        st.coverageUtilizationWAD = _specCoverageUtilization(
            toUint256(s.lastSTRawNAV), toUint256(s.lastJTRawNAV), s.minCoverageWAD, toUint256(s.lastJTEffectiveNAV)
        );
        st.liquidityUtilizationWAD = _specLiquidityUtilization(toUint256(s.lastSTEffectiveNAV), s.minLiquidityWAD, toUint256(s.lastLTRawNAV));
        st.fixedTermEndTimestamp = s.fixedTermEndTimestamp;
        st.minCoverageWAD = s.minCoverageWAD;
        st.coverageLiquidationUtilizationWAD = s.coverageLiquidationUtilizationWAD;
        st.minLiquidityWAD = s.minLiquidityWAD;
    }

    /**
     * @dev Builds a bare synced accounting state for direct max* closed-form probing
     * @dev Only the fields the max* views read are populated, and the liquidation threshold defaults to the
     * uint256 maximum so the maxLTWithdrawal liquidation shortcut stays un-triggered unless a test arms it
     */
    function _bareState(
        uint256 _stRaw,
        uint256 _jtRaw,
        uint256 _ltRaw,
        uint256 _stEff,
        uint256 _jtEff,
        uint256 _minCoverageWAD,
        uint256 _minLiquidityWAD
    )
        internal
        pure
        returns (SyncedAccountingState memory st)
    {
        st.stRawNAV = toNAVUnits(_stRaw);
        st.jtRawNAV = toNAVUnits(_jtRaw);
        st.ltRawNAV = toNAVUnits(_ltRaw);
        st.stEffectiveNAV = toNAVUnits(_stEff);
        st.jtEffectiveNAV = toNAVUnits(_jtEff);
        st.minCoverageWAD = _minCoverageWAD;
        st.minLiquidityWAD = _minLiquidityWAD;
        st.coverageLiquidationUtilizationWAD = type(uint256).max;
    }

    /// @dev Seeds the default flat 1000e18/200e18 market with the specified committed liquidity tranche raw NAV
    function _seedFlatWithLT(uint256 _ltRaw) internal {
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, _ltRaw, MarketState.PERPETUAL);
    }
}
