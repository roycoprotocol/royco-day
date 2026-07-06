// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { stdError } from "../../lib/forge-std/src/StdError.sol";
import { Test, Vm } from "../../lib/forge-std/src/Test.sol";
import { Initializable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoycoDayAccountant } from "../../src/accountant/RoycoDayAccountant.sol";
import { IRoycoAuth } from "../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { MAX_NAV_UNITS, MAX_PROTOCOL_FEE_WAD, WAD, ZERO_NAV_UNITS } from "../../src/libraries/Constants.sol";
import { MarketState, Operation, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { ASSETS_MUST_BE_NON_NEGATIVE, NAV_UNIT, toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { RoycoTestMath } from "../base/math/RoycoTestMath.sol";

/*//////////////////////////////////////////////////////////////////////////
                            HARNESS — IN-FILE MOCKS
//////////////////////////////////////////////////////////////////////////*/

/// @notice ERC1967 proxy deployable without init data so tests can call initialize as a separate, observable external call
contract UninitializedERC1967Proxy is ERC1967Proxy {
    constructor(address _implementation) ERC1967Proxy(_implementation, "") { }

    function _unsafeAllowUninitialized() internal pure override(ERC1967Proxy) returns (bool) {
        return true;
    }
}

/// @notice Mock YDM with independently settable outputs, mutating-call argument recording, and revert modes
/// @dev The preview path is a staticcall from the accountant so preview arguments are asserted via vm.expectCall in tests, not recorded here
contract MockYDM is IYDM {
    error YDM_REVERTED();
    error YDM_INIT_REVERTED();

    uint256 public yieldShareReturn;
    uint256 public previewYieldShareReturn;
    bool public revertOnYieldShare;
    bool public revertOnPreviewYieldShare;
    bool public revertOnInitialize;

    uint256 public yieldShareCallCount;
    MarketState public lastYieldShareMarketState;
    uint256 public lastYieldShareUtilizationWAD;

    uint256 public initializeCallCount;
    bytes public lastInitializePayload;

    function setYieldShareReturn(uint256 _v) external {
        yieldShareReturn = _v;
    }

    function setPreviewYieldShareReturn(uint256 _v) external {
        previewYieldShareReturn = _v;
    }

    /// @dev Convenience setter for both the mutating and preview outputs
    function setRates(uint256 _v) external {
        yieldShareReturn = _v;
        previewYieldShareReturn = _v;
    }

    function setRevertOnYieldShare(bool _v) external {
        revertOnYieldShare = _v;
    }

    function setRevertOnPreviewYieldShare(bool _v) external {
        revertOnPreviewYieldShare = _v;
    }

    function setRevertOnInitialize(bool _v) external {
        revertOnInitialize = _v;
    }

    /// @dev Initialization entrypoint targeted by the accountant's raw-call YDM initialization
    function initializeModel(bytes calldata _payload) external {
        if (revertOnInitialize) revert YDM_INIT_REVERTED();
        initializeCallCount++;
        lastInitializePayload = _payload;
    }

    /// @inheritdoc IYDM
    function yieldShare(MarketState _marketState, uint256 _utilizationWAD) external override(IYDM) returns (uint256) {
        if (revertOnYieldShare) revert YDM_REVERTED();
        yieldShareCallCount++;
        lastYieldShareMarketState = _marketState;
        lastYieldShareUtilizationWAD = _utilizationWAD;
        return yieldShareReturn;
    }

    /// @inheritdoc IYDM
    function previewYieldShare(MarketState, uint256) external view override(IYDM) returns (uint256) {
        if (revertOnPreviewYieldShare) revert YDM_REVERTED();
        return previewYieldShareReturn;
    }
}

/// @notice Mock kernel giving the test full control over the accountant's onlyRoycoKernel surface
/// @dev Passthroughs make msg.sender the kernel, and syncTrancheAccounting supports NONE, SYNC, and REVERT modes with call counting and a pre-sync state snapshot
contract MockKernel {
    enum SyncMode {
        NONE,
        SYNC,
        REVERT
    }

    error KERNEL_SYNC_REVERTED();

    IRoycoDayAccountant public accountant;
    SyncMode public syncMode;
    uint256 public syncCallCount;
    NAV_UNIT public syncStRawNAV;
    NAV_UNIT public syncJTRawNAV;
    IRoycoDayAccountant.RoycoDayAccountantState internal _stateAtLastSync;

    function setAccountant(address _accountant) external {
        accountant = IRoycoDayAccountant(_accountant);
    }

    function setSyncMode(SyncMode _mode) external {
        syncMode = _mode;
    }

    /// @dev The NAVs a SYNC-mode syncTrancheAccounting will pre-op sync with
    function setSyncNAVs(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) external {
        syncStRawNAV = _stRawNAV;
        syncJTRawNAV = _jtRawNAV;
    }

    /// @dev The accountant state snapshotted at the moment of the last syncTrancheAccounting call
    function stateAtLastSync() external view returns (IRoycoDayAccountant.RoycoDayAccountantState memory) {
        return _stateAtLastSync;
    }

    /// @dev Mirror of IRoycoDayKernel.syncTrancheAccounting invoked by the accountant's withSyncedAccounting modifier and tolerated raw calls
    function syncTrancheAccounting() external returns (SyncedAccountingState memory state) {
        if (syncMode == SyncMode.REVERT) revert KERNEL_SYNC_REVERTED();
        syncCallCount++;
        _stateAtLastSync = accountant.getState();
        if (syncMode == SyncMode.SYNC) state = accountant.preOpSyncTrancheAccounting(syncStRawNAV, syncJTRawNAV);
    }

    /// @dev Passthrough so msg.sender == kernel for the pre-op sync
    function doPreOp(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) external returns (SyncedAccountingState memory) {
        return accountant.preOpSyncTrancheAccounting(_stRawNAV, _jtRawNAV);
    }

    /// @dev Passthrough so msg.sender == kernel for the LT raw NAV commit
    function doCommit(NAV_UNIT _ltRawNAV) external {
        accountant.commitLiquidityTrancheRawNAV(_ltRawNAV);
    }

    /// @dev Passthrough so msg.sender == kernel for the post-op sync
    function doPostOp(
        Operation _op,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _ltRawNAV,
        NAV_UNIT _stSelfLiquidationBonusNAV,
        bool _enforce
    )
        external
        returns (SyncedAccountingState memory)
    {
        return accountant.postOpSyncTrancheAccounting(_op, _stRawNAV, _jtRawNAV, _ltRawNAV, _stSelfLiquidationBonusNAV, _enforce);
    }
}

/// @title AccountantTest
/// @notice Standalone adversarial suite for RoycoDayAccountant (part 1 covers the harness plus groups A, B, C, and I)
contract AccountantTest is Test {
    /*//////////////////////////////////////////////////////////////////////
                        HARNESS — CONSTANTS AND STATE
    //////////////////////////////////////////////////////////////////////*/

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
    //   covUtil = ceil((1000e18 + 0) * 0.1e18 / 200e18) = 0.5e18 (exact division so ceil == floor)
    //   liqUtil = ceil(1000e18 * 0.05e18 / 100e18) = 0.5e18 (exact division)
    uint256 internal constant SEED_COV_UTIL_WAD = 0.5e18;
    uint256 internal constant SEED_LIQ_UTIL_WAD = 0.5e18;

    RoycoDayAccountant internal accountant;
    RoycoDayAccountant internal implementation;
    MockKernel internal kernel;
    MockYDM internal jtYDM;
    MockYDM internal ltYDM;
    AccessManager internal authority;
    address internal stranger;

    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(false, _defaultParams());
    }

    /*//////////////////////////////////////////////////////////////////////
                            HARNESS — DEPLOY HELPERS
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
        p.jtYDM = address(new MockYDM());
        p.ltYDM = address(new MockYDM());
    }

    /// @dev Deploys a fresh kernel, authority, implementation, and un-initialized ERC1967 proxy (RoycoBase disables initializers on the implementation)
    function _deployUninitialized(bool _jtCoinvested) internal returns (RoycoDayAccountant acct) {
        kernel = new MockKernel();
        authority = new AccessManager(address(this));
        implementation = new RoycoDayAccountant(address(kernel), _jtCoinvested);
        acct = RoycoDayAccountant(address(new UninitializedERC1967Proxy(address(implementation))));
        kernel.setAccountant(address(acct));
    }

    /**
     * @dev Full deployment helper used by every test: proxy, initialize, and mock wiring
     * @dev Null YDM slots in the params are filled with fresh MockYDM instances, otherwise the passed addresses are adopted as the harness mocks
     */
    function _deploy(bool _jtCoinvested, IRoycoDayAccountant.RoycoDayAccountantInitParams memory _params) internal returns (RoycoDayAccountant acct) {
        acct = _deployUninitialized(_jtCoinvested);
        if (_params.jtYDM == address(0)) _params.jtYDM = address(new MockYDM());
        if (_params.ltYDM == address(0)) _params.ltYDM = address(new MockYDM());
        jtYDM = MockYDM(_params.jtYDM);
        ltYDM = MockYDM(_params.ltYDM);
        acct.initialize(_params, address(authority));
        accountant = acct;
    }

    /*//////////////////////////////////////////////////////////////////////
                        HARNESS — STATE SEEDING HELPERS
    //////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Drives the accountant into an arbitrary committed checkpoint state through legal kernel calls only
     *
     * Routes (all in the current block, no warps):
     * 1. Symmetric states (stEff == stRaw): ST_DEPOSIT of stEff then JT_DEPOSIT of jtRaw via post-op syncs
     * 2. ST cross-claim states (stEff > stRaw, JT provided coverage): deposit ST = stEff and JT = jtRaw, then a
     *    pre-op loss sync of cross = stEff - stRaw. The loss is fully covered by JT so stEff is unchanged while
     *    stRaw, jtEff, and IL land exactly on target (conservation forces jtRaw = jtEff + cross)
     *    - il < cross is reached by splitting the loss in two: first a covered loss of (cross - il), then erasing
     *      that IL with the setFixedTermDuration(0) round-trip (erases IL, forces PERPETUAL, keeps effective NAVs),
     *      then a second covered loss of exactly il
     * 3. JT cross-claim states (jtEff > jtRaw, requires il == 0): pay the cross-claim p as a JT risk premium out of
     *    a synthetic senior gain g. Deposit ST = stRaw - g, then a flat first pre-op sync (initializes the accrual
     *    clock in this block), then a same-block gain sync of g which takes the instantaneous branch and pays
     *    jtRiskPremium = floor(g * maxJT / WAD) == p with the JT preview rate pinned above the cap
     *
     * Constraints (asserted): conservation on inputs, il <= cross for route 2, an il > effective dust target
     * requires targetState == FIXED_TERM (entry is forced by the loss sync), and jtEff == 0 with il > 0 is
     * unreachable (the wipeout disjunct erases IL). Route 3 requires g = p * WAD / maxJT to divide exactly
     */
    function _seedState(uint256 _stRaw, uint256 _jtRaw, uint256 _stEff, uint256 _jtEff, uint256 _il, uint256 _ltRaw, MarketState _targetState) internal {
        assertEq(_stRaw + _jtRaw, _stEff + _jtEff, "seed: conservation violated by target");

        if (_stEff >= _stRaw) {
            uint256 cross = _stEff - _stRaw;
            assertLe(_il, cross, "seed: il exceeds ST cross-claim");
            assertTrue(!(_jtEff == 0 && _il > 0), "seed: jtEff 0 with il > 0 unreachable");
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
        assertEq(toUint256(s.lastSTRawNAV), _stRaw, "seed: stRaw");
        assertEq(toUint256(s.lastJTRawNAV), _jtRaw, "seed: jtRaw");
        assertEq(toUint256(s.lastSTEffectiveNAV), _stEff, "seed: stEff");
        assertEq(toUint256(s.lastJTEffectiveNAV), _jtEff, "seed: jtEff");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), _il, "seed: il");
        assertEq(toUint256(s.lastLTRawNAV), _ltRaw, "seed: ltRaw");
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

    /*//////////////////////////////////////////////////////////////////////
                    A — CONSTRUCTION AND INITIALIZATION
    //////////////////////////////////////////////////////////////////////*/

    /// A1: a null kernel reverts in the constructor
    function test_Constructor_reverts_nullKernel() public {
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new RoycoDayAccountant(address(0), false);
    }

    /// A1: KERNEL and JT_COINVESTED are immutably set, both boolean values covered
    function test_Constructor_setsKernelAndCoinvestedImmutables() public {
        MockKernel freshKernel = new MockKernel();
        RoycoDayAccountant coinvested = new RoycoDayAccountant(address(freshKernel), true);
        assertEq(coinvested.KERNEL(), address(freshKernel), "kernel immutable");
        assertTrue(coinvested.JT_COINVESTED(), "coinvested true");
        RoycoDayAccountant notCoinvested = new RoycoDayAccountant(address(freshKernel), false);
        assertFalse(notCoinvested.JT_COINVESTED(), "coinvested false");
    }

    /// A2: each of the four fee params above MAX_PROTOCOL_FEE_WAD reverts independently
    function test_Initialize_reverts_stProtocolFeeAboveMax() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.stProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        acct.initialize(p, address(authority));
    }

    /// A2 vector 2
    function test_Initialize_reverts_jtProtocolFeeAboveMax() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.jtProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        acct.initialize(p, address(authority));
    }

    /// A2 vector 3
    function test_Initialize_reverts_jtYieldShareProtocolFeeAboveMax() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.jtYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        acct.initialize(p, address(authority));
    }

    /// A2 vector 4
    function test_Initialize_reverts_ltYieldShareProtocolFeeAboveMax() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.ltYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        acct.initialize(p, address(authority));
    }

    /// A2: all four fees at exactly MAX_PROTOCOL_FEE_WAD (100%) pass
    function test_Initialize_allFeesAtExactlyMax() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.stProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        p.jtProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        p.jtYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        p.ltYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        acct.initialize(p, address(authority));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = acct.getState();
        assertEq(s.stProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "st fee at max");
        assertEq(s.jtProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "jt fee at max");
        assertEq(s.jtYieldShareProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "jt ys fee at max");
        assertEq(s.ltYieldShareProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "lt ys fee at max");
    }

    /// A3: identical JT and LT YDMs revert
    function test_Initialize_reverts_identicalYDMs() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.ltYDM = p.jtYDM;
        vm.expectRevert(IRoycoDayAccountant.YDMS_CANNOT_BE_IDENTICAL.selector);
        acct.initialize(p, address(authority));
    }

    /// A4: minCoverage == WAD reverts
    function test_Initialize_reverts_minCoverageAtWAD() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.minCoverageWAD = uint64(WAD);
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        acct.initialize(p, address(authority));
    }

    /// A4: minCoverage > WAD reverts
    function test_Initialize_reverts_minCoverageAboveWAD() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.minCoverageWAD = uint64(WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        acct.initialize(p, address(authority));
    }

    /// A4: liquidation utilization == WAD reverts
    function test_Initialize_reverts_liquidationUtilizationAtWAD() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.coverageLiquidationUtilizationWAD = WAD;
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        acct.initialize(p, address(authority));
    }

    /// A4: liquidation utilization < WAD reverts
    function test_Initialize_reverts_liquidationUtilizationBelowWAD() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.coverageLiquidationUtilizationWAD = WAD - 1;
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        acct.initialize(p, address(authority));
    }

    /// A4: minCoverage = WAD - 1 with liquidation utilization = WAD + 1 passes (both boundaries)
    function test_Initialize_coverageConfigBoundariesPass() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.minCoverageWAD = uint64(WAD - 1);
        p.coverageLiquidationUtilizationWAD = WAD + 1;
        acct.initialize(p, address(authority));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = acct.getState();
        assertEq(s.minCoverageWAD, uint64(WAD - 1), "minCoverage boundary");
        assertEq(s.coverageLiquidationUtilizationWAD, WAD + 1, "liquidation utilization boundary");
    }

    /// A5: minLiquidity == WAD reverts
    function test_Initialize_reverts_minLiquidityAtWAD() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.minLiquidityWAD = uint64(WAD);
        vm.expectRevert(IRoycoDayAccountant.INVALID_LIQUIDITY_CONFIG.selector);
        acct.initialize(p, address(authority));
    }

    /// A5: minLiquidity = WAD - 1 passes
    function test_Initialize_minLiquidityBoundaryPasses() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.minLiquidityWAD = uint64(WAD - 1);
        acct.initialize(p, address(authority));
        assertEq(acct.getState().minLiquidityWAD, uint64(WAD - 1), "minLiquidity boundary");
    }

    /// A6: maxJT + maxLT > WAD reverts
    function test_Initialize_reverts_maxYieldSharesSumAboveWAD() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.maxJTYieldShareWAD = 0.6e18;
        p.maxLTYieldShareWAD = 0.4e18 + 1;
        vm.expectRevert(IRoycoDayAccountant.INVALID_MAX_YIELD_SHARE_CONFIG.selector);
        acct.initialize(p, address(authority));
    }

    /// A6: maxJT + maxLT == WAD passes
    function test_Initialize_maxYieldSharesSumAtWADPasses() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.maxJTYieldShareWAD = 0.6e18;
        p.maxLTYieldShareWAD = 0.4e18;
        acct.initialize(p, address(authority));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = acct.getState();
        assertEq(s.maxJTYieldShareWAD, 0.6e18, "maxJT written");
        assertEq(s.maxLTYieldShareWAD, 0.4e18, "maxLT written");
    }

    /// A7: a null JT YDM reverts
    function test_Initialize_reverts_nullJTYDM() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.jtYDM = address(0);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        acct.initialize(p, address(authority));
    }

    /// A7: a null LT YDM reverts
    function test_Initialize_reverts_nullLTYDM() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.ltYDM = address(0);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        acct.initialize(p, address(authority));
    }

    /// A8: non-empty init data is forwarded to each YDM verbatim
    function test_Initialize_ydmInitCalledWithNonEmptyData() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.jtYDMInitializationData = abi.encodeCall(MockYDM.initializeModel, (hex"1234"));
        p.ltYDMInitializationData = abi.encodeCall(MockYDM.initializeModel, (hex"5678"));
        acct.initialize(p, address(authority));
        assertEq(MockYDM(p.jtYDM).initializeCallCount(), 1, "jt ydm initialized once");
        assertEq(MockYDM(p.jtYDM).lastInitializePayload(), hex"1234", "jt ydm payload");
        assertEq(MockYDM(p.ltYDM).initializeCallCount(), 1, "lt ydm initialized once");
        assertEq(MockYDM(p.ltYDM).lastInitializePayload(), hex"5678", "lt ydm payload");
    }

    /// A8: empty init data makes no call to either YDM
    function test_Initialize_ydmInitSkippedWithEmptyData() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        acct.initialize(p, address(authority));
        assertEq(MockYDM(p.jtYDM).initializeCallCount(), 0, "jt ydm never called");
        assertEq(MockYDM(p.ltYDM).initializeCallCount(), 0, "lt ydm never called");
    }

    /// A8: a reverting JT YDM initialization bubbles the exact revert payload inside FAILED_TO_INITIALIZE_YDM
    function test_Initialize_reverts_jtYDMInitReverts() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        MockYDM(p.jtYDM).setRevertOnInitialize(true);
        p.jtYDMInitializationData = abi.encodeCall(MockYDM.initializeModel, (hex""));
        vm.expectRevert(
            abi.encodeWithSelector(IRoycoDayAccountant.FAILED_TO_INITIALIZE_YDM.selector, abi.encodeWithSelector(MockYDM.YDM_INIT_REVERTED.selector))
        );
        acct.initialize(p, address(authority));
    }

    /// A8: a reverting LT YDM initialization bubbles the exact revert payload inside FAILED_TO_INITIALIZE_YDM
    function test_Initialize_reverts_ltYDMInitReverts() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        MockYDM(p.ltYDM).setRevertOnInitialize(true);
        p.ltYDMInitializationData = abi.encodeCall(MockYDM.initializeModel, (hex""));
        vm.expectRevert(
            abi.encodeWithSelector(IRoycoDayAccountant.FAILED_TO_INITIALIZE_YDM.selector, abi.encodeWithSelector(MockYDM.YDM_INIT_REVERTED.selector))
        );
        acct.initialize(p, address(authority));
    }

    /**
     * A9: initialize emits the accountant's 13 configuration events with exact args in slot-grouped order
     * NOTE deviation from the map: the map says 17 init events, the accountant itself emits 13 (the other
     * observable logs are OZ's AuthorityUpdated and Initialized, which are not accountant configuration events)
     */
    function test_Initialize_emitsAllInitEvents() public {
        RoycoDayAccountant acct = _deployUninitialized(false);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.SeniorTrancheProtocolFeeUpdated(p.stProtocolFeeWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.JuniorTrancheProtocolFeeUpdated(p.jtProtocolFeeWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareProtocolFeeUpdated(p.jtYieldShareProtocolFeeWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.LiquidityTrancheYieldShareProtocolFeeUpdated(p.ltYieldShareProtocolFeeWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.CoverageUpdated(p.minCoverageWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.FixedTermDurationUpdated(p.fixedTermDurationSeconds);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.JuniorTrancheYDMUpdated(p.jtYDM);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.LiquidityTrancheYDMUpdated(p.ltYDM);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.LiquidityUpdated(p.minLiquidityWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.MaxYieldSharesUpdated(p.maxJTYieldShareWAD, p.maxLTYieldShareWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.LiquidationCoverageUtilizationUpdated(p.coverageLiquidationUtilizationWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.SeniorTrancheDustToleranceUpdated(p.stNAVDustTolerance);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.JuniorTrancheDustToleranceUpdated(p.jtNAVDustTolerance);
        acct.initialize(p, address(authority));
    }

    /// A10: getState after initialization returns every configured field exactly and zeroes all dynamic state
    function test_Initialize_stateMatchesParams() public {
        RoycoDayAccountant acct = _deployUninitialized(true);
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.minCoverageWAD = 0.123e18;
        p.coverageLiquidationUtilizationWAD = 1.7e18;
        p.minLiquidityWAD = 0.045e18;
        p.maxJTYieldShareWAD = 0.25e18;
        p.maxLTYieldShareWAD = 0.35e18;
        p.fixedTermDurationSeconds = 12_345;
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(4));
        p.stProtocolFeeWAD = 0.11e18;
        p.jtProtocolFeeWAD = 0.12e18;
        p.jtYieldShareProtocolFeeWAD = 0.13e18;
        p.ltYieldShareProtocolFeeWAD = 0.14e18;
        acct.initialize(p, address(authority));

        IRoycoDayAccountant.RoycoDayAccountantState memory s = acct.getState();
        assertEq(s.stProtocolFeeWAD, 0.11e18, "stProtocolFeeWAD");
        assertEq(s.jtProtocolFeeWAD, 0.12e18, "jtProtocolFeeWAD");
        assertEq(s.jtYieldShareProtocolFeeWAD, 0.13e18, "jtYieldShareProtocolFeeWAD");
        assertEq(s.ltYieldShareProtocolFeeWAD, 0.14e18, "ltYieldShareProtocolFeeWAD");
        assertEq(s.minCoverageWAD, 0.123e18, "minCoverageWAD");
        assertEq(s.fixedTermDurationSeconds, 12_345, "fixedTermDurationSeconds");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "lastMarketState");
        assertEq(s.fixedTermEndTimestamp, 0, "fixedTermEndTimestamp");
        assertEq(s.lastYieldShareAccrualTimestamp, 0, "lastYieldShareAccrualTimestamp");
        assertEq(s.lastPremiumPaymentTimestamp, 0, "lastPremiumPaymentTimestamp");
        assertEq(s.jtYDM, p.jtYDM, "jtYDM");
        assertEq(s.ltYDM, p.ltYDM, "ltYDM");
        assertEq(s.minLiquidityWAD, 0.045e18, "minLiquidityWAD");
        assertEq(s.twJTYieldShareAccruedWAD, 0, "twJTYieldShareAccruedWAD");
        assertEq(s.maxJTYieldShareWAD, 0.25e18, "maxJTYieldShareWAD");
        assertEq(s.twLTYieldShareAccruedWAD, 0, "twLTYieldShareAccruedWAD");
        assertEq(s.maxLTYieldShareWAD, 0.35e18, "maxLTYieldShareWAD");
        assertEq(s.coverageLiquidationUtilizationWAD, 1.7e18, "coverageLiquidationUtilizationWAD");
        assertEq(toUint256(s.lastSTRawNAV), 0, "lastSTRawNAV");
        assertEq(toUint256(s.lastJTRawNAV), 0, "lastJTRawNAV");
        assertEq(toUint256(s.lastSTEffectiveNAV), 0, "lastSTEffectiveNAV");
        assertEq(toUint256(s.lastJTEffectiveNAV), 0, "lastJTEffectiveNAV");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), 0, "lastJTCoverageImpermanentLoss");
        assertEq(toUint256(s.lastLTRawNAV), 0, "lastLTRawNAV");
        assertEq(toUint256(s.stNAVDustTolerance), 3, "stNAVDustTolerance");
        assertEq(toUint256(s.jtNAVDustTolerance), 4, "jtNAVDustTolerance");
        assertEq(toUint256(s.effectiveNAVDustTolerance), 7, "effectiveNAVDustTolerance == st + jt");
    }

    /// A11: a second initialize on the proxy reverts via the initializer guard
    function test_Initialize_reverts_secondInitialize() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        accountant.initialize(p, address(authority));
    }

    /// A11: the implementation contract itself can never be initialized (initializers disabled in the constructor)
    function test_Initialize_reverts_onImplementation() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(p, address(authority));
    }

    /*//////////////////////////////////////////////////////////////////////
                            B — ACCESS CONTROL
    //////////////////////////////////////////////////////////////////////*/

    /// B1: preOpSyncTrancheAccounting reverts for any non-kernel caller, including the admin
    function test_KernelGate_reverts_preOpFromNonKernel() public {
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.preOpSyncTrancheAccounting(toNAVUnits(uint256(1e18)), toNAVUnits(uint256(1e18)));
        vm.prank(stranger);
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.preOpSyncTrancheAccounting(toNAVUnits(uint256(1e18)), toNAVUnits(uint256(1e18)));
    }

    /// B1: commitLiquidityTrancheRawNAV reverts for any non-kernel caller, including the admin
    function test_KernelGate_reverts_commitFromNonKernel() public {
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.commitLiquidityTrancheRawNAV(toNAVUnits(uint256(1e18)));
        vm.prank(stranger);
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.commitLiquidityTrancheRawNAV(toNAVUnits(uint256(1e18)));
    }

    /// B1: postOpSyncTrancheAccounting reverts for any non-kernel caller, including the admin
    function test_KernelGate_reverts_postOpFromNonKernel() public {
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, toNAVUnits(uint256(1e18)), ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
        vm.prank(stranger);
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, toNAVUnits(uint256(1e18)), ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
    }

    /// B2: all 13 restricted setters (plus inherited pause/unpause) revert AccessManagedUnauthorized for a role-less caller
    function test_AccessControl_reverts_allSettersForStranger() public {
        bytes[] memory calls = new bytes[](15);
        bytes[] memory hardSync = _hardSyncSetterCalls();
        for (uint256 i; i < 11; ++i) {
            calls[i] = hardSync[i];
        }
        calls[11] = abi.encodeCall(IRoycoDayAccountant.setJuniorTrancheYDM, (address(0xBEEF), bytes("")));
        calls[12] = abi.encodeCall(IRoycoDayAccountant.setLiquidityTrancheYDM, (address(0xBEEF), bytes("")));
        calls[13] = abi.encodeCall(IRoycoAuth.pause, ());
        calls[14] = abi.encodeCall(IRoycoAuth.unpause, ());
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
            (bool success,) = address(accountant).call(calls[i]);
            success;
        }
    }

    /// B3: each of the 11 hard-sync setters calls the kernel sync BEFORE its body (snapshot taken at sync equals the pre-call state)
    function test_SetterSync_hardSyncSettersSyncBeforeBody() public {
        bytes[] memory calls = _hardSyncSetterCalls();
        for (uint256 i; i < calls.length; ++i) {
            uint256 countBefore = kernel.syncCallCount();
            bytes32 preHash = _stateHash();
            (bool success,) = address(accountant).call(calls[i]);
            assertTrue(success, "setter must succeed");
            assertEq(kernel.syncCallCount(), countBefore + 1, "kernel sync not attempted exactly once");
            assertEq(keccak256(abi.encode(kernel.stateAtLastSync())), preHash, "sync observed post-body state: body ran first");
            assertTrue(_stateHash() != preHash, "setter body must have mutated state");
        }
    }

    /// B3: a REVERT-mode kernel bricks all 11 hard-sync setters
    function test_SetterSync_revertingKernelBricksHardSyncSetters() public {
        kernel.setSyncMode(MockKernel.SyncMode.REVERT);
        bytes[] memory calls = _hardSyncSetterCalls();
        bytes32 preHash = _stateHash();
        for (uint256 i; i < calls.length; ++i) {
            vm.expectRevert(MockKernel.KERNEL_SYNC_REVERTED.selector);
            (bool success,) = address(accountant).call(calls[i]);
            success;
        }
        assertEq(_stateHash(), preHash, "no setter body may have executed");
    }

    /// B4: the two YDM setters tolerate a reverting kernel sync (the recovery path from a sync-bricking YDM)
    function test_SetterSync_ydmSettersTolerateRevertingKernel() public {
        kernel.setSyncMode(MockKernel.SyncMode.REVERT);
        MockYDM newJT = new MockYDM();
        accountant.setJuniorTrancheYDM(address(newJT), "");
        assertEq(accountant.getState().jtYDM, address(newJT), "jt ydm updated despite reverting kernel");
        MockYDM newLT = new MockYDM();
        accountant.setLiquidityTrancheYDM(address(newLT), "");
        assertEq(accountant.getState().ltYDM, address(newLT), "lt ydm updated despite reverting kernel");
    }

    /// B4: the tolerated kernel sync is still attempted by both YDM setters (counted in NONE mode)
    function test_SetterSync_ydmSettersAttemptKernelSync() public {
        uint256 countBefore = kernel.syncCallCount();
        MockYDM newJT = new MockYDM();
        accountant.setJuniorTrancheYDM(address(newJT), "");
        assertEq(kernel.syncCallCount(), countBefore + 1, "jt setter attempted the sync");
        MockYDM newLT = new MockYDM();
        accountant.setLiquidityTrancheYDM(address(newLT), "");
        assertEq(kernel.syncCallCount(), countBefore + 2, "lt setter attempted the sync");
    }

    /*//////////////////////////////////////////////////////////////////////
                        C — YIELD-SHARE ACCRUAL
    //////////////////////////////////////////////////////////////////////*/

    /// C1: the first-ever accrual initializes both timestamps, leaves the accumulators at zero, and never calls the YDMs
    function test_Accrual_firstSyncInitializesTimestampsWithoutYDMCalls() public {
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        jtYDM.setYieldShareReturn(0.15e18);
        ltYDM.setYieldShareReturn(0.05e18);
        vm.warp(block.timestamp + 123);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.lastYieldShareAccrualTimestamp, uint32(block.timestamp), "accrual timestamp initialized");
        assertEq(s.lastPremiumPaymentTimestamp, uint32(block.timestamp), "premium payment timestamp initialized");
        assertEq(s.twJTYieldShareAccruedWAD, 0, "jt accumulator untouched");
        assertEq(s.twLTYieldShareAccruedWAD, 0, "lt accumulator untouched");
        assertEq(jtYDM.yieldShareCallCount(), 0, "jt ydm not consulted on first accrual");
        assertEq(ltYDM.yieldShareCallCount(), 0, "lt ydm not consulted on first accrual");
    }

    /**
     * C1 nuance pinned — NOTE deviation from the map: the map claims no premium can be paid on the first sync,
     * but the first accrual sets lastPremiumPaymentTimestamp to now, so a gain in that same first sync takes the
     * instantaneous branch (elapsed forced to 1s) and pays premiums from the preview rates
     *
     * Derivation with gain g = 100e18, jt preview 0.1e18 (below the 0.2e18 cap), lt preview 0.05e18 (below the 0.1e18 cap):
     *   jtRiskPremium      = floor(100e18 * 0.1e18 / (1 * 1e18)) = 10e18
     *   ltLiquidityPremium = floor(100e18 * 0.05e18 / (1 * 1e18)) = 5e18
     *   jtEff = 200e18 + 10e18 = 210e18, stEff = 1000e18 + (100e18 - 10e18 - 5e18) + 5e18 = 1090e18
     */
    function test_Accrual_firstSyncGainPaysInstantaneousPremium() public {
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), 210e18, "jt premium paid via instantaneous branch");
        assertEq(toUint256(state.ltLiquidityPremium), 5e18, "lt premium paid via instantaneous branch");
        assertEq(toUint256(state.stEffectiveNAV), 1090e18, "st retains residual plus lt premium carve-out");
    }

    /// C2: a same-block re-accrual is a no-op — the YDMs are not called and the accumulators and timestamp are unchanged
    function test_Accrual_sameBlockReaccrualIsNoop() public {
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(0.15e18);
        ltYDM.setYieldShareReturn(0.05e18);
        vm.warp(block.timestamp + 1000);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        uint256 jtCalls = jtYDM.yieldShareCallCount();
        uint256 ltCalls = ltYDM.yieldShareCallCount();
        IRoycoDayAccountant.RoycoDayAccountantState memory before = accountant.getState();
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        IRoycoDayAccountant.RoycoDayAccountantState memory afterState = accountant.getState();
        assertEq(jtYDM.yieldShareCallCount(), jtCalls, "jt ydm not re-consulted in the same block");
        assertEq(ltYDM.yieldShareCallCount(), ltCalls, "lt ydm not re-consulted in the same block");
        assertEq(afterState.twJTYieldShareAccruedWAD, before.twJTYieldShareAccruedWAD, "jt accumulator unchanged");
        assertEq(afterState.twLTYieldShareAccruedWAD, before.twLTYieldShareAccruedWAD, "lt accumulator unchanged");
        assertEq(afterState.lastYieldShareAccrualTimestamp, before.lastYieldShareAccrualTimestamp, "accrual timestamp unchanged");
    }

    /**
     * C3: the accrual adds min(yieldShare, max) * elapsed to each accumulator
     * Derivation: jt rate 0.15e18 < max 0.2e18 so raw, lt rate 0.5e18 > max 0.1e18 so capped
     *   twJT = 0.15e18 * 3600 = 540e18, twLT = 0.1e18 * 3600 = 360e18
     */
    function test_Accrual_accruesTimeWeightedSharesWithCapBothSides() public {
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(0.15e18);
        ltYDM.setYieldShareReturn(0.5e18);
        vm.warp(block.timestamp + 3600);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.twJTYieldShareAccruedWAD, uint192(0.15e18 * 3600), "jt accrues its raw sub-cap rate");
        assertEq(s.twLTYieldShareAccruedWAD, uint192(0.1e18 * 3600), "lt rate capped at maxLTYieldShareWAD");
        assertEq(s.lastYieldShareAccrualTimestamp, uint32(block.timestamp), "accrual timestamp advanced");
    }

    /// C3: accumulators compound across windows when no premium is paid in between
    function test_Accrual_accumulatesAcrossWindowsWithoutPremiumPayment() public {
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(0.15e18);
        ltYDM.setYieldShareReturn(0.05e18);
        vm.warp(block.timestamp + 3600);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        jtYDM.setYieldShareReturn(0.02e18);
        ltYDM.setYieldShareReturn(0.01e18);
        vm.warp(block.timestamp + 100);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        // twJT = 0.15e18 * 3600 + 0.02e18 * 100, twLT = 0.05e18 * 3600 + 0.01e18 * 100
        assertEq(s.twJTYieldShareAccruedWAD, uint192(0.15e18 * 3600 + 0.02e18 * 100), "jt accumulator compounds");
        assertEq(s.twLTYieldShareAccruedWAD, uint192(0.05e18 * 3600 + 0.01e18 * 100), "lt accumulator compounds");
    }

    /// C3: the YDMs are consulted with the last market state and utilizations computed from the last-committed checkpoints
    function test_Accrual_ydmCalledWithLastCheckpointArgs() public {
        _seedAndInitAccrual();
        vm.warp(block.timestamp + 60);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(uint8(jtYDM.lastYieldShareMarketState()), uint8(MarketState.PERPETUAL), "jt ydm sees the last market state");
        assertEq(jtYDM.lastYieldShareUtilizationWAD(), SEED_COV_UTIL_WAD, "jt ydm sees the checkpoint coverage utilization");
        assertEq(uint8(ltYDM.lastYieldShareMarketState()), uint8(MarketState.PERPETUAL), "lt ydm sees the last market state");
        assertEq(ltYDM.lastYieldShareUtilizationWAD(), SEED_LIQ_UTIL_WAD, "lt ydm sees the checkpoint liquidity utilization");
    }

    /**
     * C3: in a FIXED_TERM market the accrual passes FIXED_TERM and the cross-claim checkpoint utilizations
     * Seed: deposits 1000e18/300e18 then a covered 100e18 loss lands (900e18, 300e18, 1000e18, 200e18, il 100e18)
     * Derivation: covUtil = ceil(900e18 * 0.1e18 / 200e18) = 0.45e18, liqUtil = ceil(1000e18 * 0.05e18 / 100e18) = 0.5e18
     */
    function test_Accrual_ydmSeesFixedTermStateAndCrossClaimUtilizations() public {
        _seedState(900e18, 300e18, 1000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        vm.warp(block.timestamp + 3600);
        kernel.doPreOp(toNAVUnits(uint256(900e18)), toNAVUnits(uint256(300e18)));
        assertEq(uint8(jtYDM.lastYieldShareMarketState()), uint8(MarketState.FIXED_TERM), "jt ydm sees FIXED_TERM");
        assertEq(jtYDM.lastYieldShareUtilizationWAD(), 0.45e18, "coverage utilization from cross-claim checkpoints");
        assertEq(ltYDM.lastYieldShareUtilizationWAD(), 0.5e18, "liquidity utilization from checkpoints");
    }

    /// C4: the accrual emits both yield-share events with the capped share and the new accumulator
    function test_Accrual_emitsYieldShareAccruedEvents() public {
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(0.9e18);
        ltYDM.setYieldShareReturn(0.04e18);
        vm.warp(block.timestamp + 500);
        // jt capped: min(0.9e18, 0.2e18) = 0.2e18, lt raw: 0.04e18 below the 0.1e18 cap
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareAccrued(0.2e18, 0.2e18 * 500);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheYieldShareAccrued(0.04e18, 0.04e18 * 500);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
    }

    /// C5: the mutating accrual calls yieldShare while the preview twin calls previewYieldShare and writes nothing
    function test_Accrual_mutatingCallsYieldShareAndPreviewIsPure() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.05e18);
        ltYDM.setRates(0.03e18);
        vm.warp(block.timestamp + 250);
        bytes32 preHash = _stateHash();
        vm.expectCall(address(jtYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.PERPETUAL, SEED_COV_UTIL_WAD)));
        vm.expectCall(address(ltYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.PERPETUAL, SEED_LIQ_UTIL_WAD)));
        accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(_stateHash(), preHash, "preview must not mutate storage");
        assertEq(jtYDM.yieldShareCallCount(), 0, "preview must not call the mutating yieldShare");
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(jtYDM.yieldShareCallCount(), 1, "mutating accrual calls yieldShare on the jt ydm");
        assertEq(ltYDM.yieldShareCallCount(), 1, "mutating accrual calls yieldShare on the lt ydm");
    }

    /**
     * C6: preview twin with lastUpdate == 0 returns (0, 0) accumulators so a previewed gain pays no premium
     * Derivation with gain 40e18: elapsed since the zero premium timestamp is nonzero so the instantaneous branch
     * is skipped, tw accumulators are (0, 0), both premiums floor to 0, stProtocolFee = floor(40e18 * 0.1e18 / 1e18) = 4e18
     */
    function test_Accrual_previewBeforeFirstAccrualPaysNoPremium() public {
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        jtYDM.setRates(0.2e18);
        ltYDM.setRates(0.1e18);
        vm.warp(block.timestamp + 100);
        SyncedAccountingState memory state = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_ST_RAW + 40e18), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW, "no jt premium from a zeroed accrual clock");
        assertEq(toUint256(state.ltLiquidityPremium), 0, "no lt premium from a zeroed accrual clock");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW + 40e18, "full gain retained by st");
        assertEq(toUint256(state.stProtocolFee), 4e18, "st fee on the retained gain");
    }

    /**
     * C6: preview twin with elapsed == 0 returns the stored accumulators, ignoring the live preview rates
     * Derivation: window of 1000s at jt rate 0.05e18 and lt rate 0.03e18 accrues tw = (5e19, 3e19), elapsed since
     * the premium clock is 1000s, so a previewed gain of 100e18 pays
     *   jtPrem = floor(100e18 * 5e19 / (1000 * 1e18)) = 5e18 and ltPrem = floor(100e18 * 3e19 / (1000 * 1e18)) = 3e18
     */
    function test_Accrual_previewSameBlockUsesStoredAccumulators() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.05e18);
        ltYDM.setRates(0.03e18);
        vm.warp(block.timestamp + 1000);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        // Hostile preview rates prove the elapsed == 0 arm ignores them in favor of the accumulators
        jtYDM.setPreviewYieldShareReturn(WAD);
        ltYDM.setPreviewYieldShareReturn(WAD);
        SyncedAccountingState memory state = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 5e18, "jt premium from stored accumulators only");
        assertEq(toUint256(state.ltLiquidityPremium), 3e18, "lt premium from stored accumulators only");
    }

    /**
     * C6: preview twin with elapsed > 0 returns accumulators plus capped share times elapsed
     * Derivation: window one accrues at (0.05e18, 0.03e18) for 1000s giving (5e19, 3e19), then preview rates change
     * to jt 0.08e18 and lt 0.2e18 (capped to 0.1e18) for a 500s un-accrued tail, so the preview accrual is
     *   twJT = 5e19 + 0.08e18 * 500 = 9e19 and twLT = 3e19 + 0.1e18 * 500 = 8e19
     * with elapsed since the premium clock 1500s, a previewed gain of 100e18 pays
     *   jtPrem = floor(100e18 * 9e19 / (1500 * 1e18)) = 6e18
     *   ltPrem = floor(100e18 * 8e19 / (1500 * 1e18)) = floor(16e18 / 3) = 5333333333333333333
     */
    function test_Accrual_previewElapsedAddsCappedShareTimesElapsed() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.05e18);
        ltYDM.setRates(0.03e18);
        vm.warp(block.timestamp + 1000);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        jtYDM.setPreviewYieldShareReturn(0.08e18);
        ltYDM.setPreviewYieldShareReturn(0.2e18);
        vm.warp(block.timestamp + 500);
        bytes32 preHash = _stateHash();
        SyncedAccountingState memory state = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 6e18, "jt premium from accumulator plus tail");
        assertEq(toUint256(state.ltLiquidityPremium), 5_333_333_333_333_333_333, "lt premium from capped tail rate");
        assertEq(_stateHash(), preHash, "preview must not mutate storage");
    }

    /// C6: same-block preview and pre-op sync agree field-by-field on identical inputs
    function test_Accrual_previewParityWithPreOpSameBlock() public {
        _seedAndInitAccrual();
        jtYDM.setRates(0.05e18);
        ltYDM.setRates(0.03e18);
        vm.warp(block.timestamp + 1000);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        SyncedAccountingState memory executed = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(executed)), "preview must match execution exactly");
    }

    /**
     * C7: the uint192 accumulators survive a 100-year window at a 100% yield share
     * Derivation: 1e18 * (100 * 365 days) = 1e18 * 3153600000 = 3.1536e27, far below 2^192
     */
    function test_Accrual_accumulatorNoOverflowAt100Years() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.maxJTYieldShareWAD = uint64(WAD);
        p.maxLTYieldShareWAD = 0;
        _deploy(false, p);
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(WAD);
        vm.warp(block.timestamp + 100 * 365 days);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(accountant.getState().twJTYieldShareAccruedWAD, uint192(uint256(1e18) * 3_153_600_000), "century-scale accumulator exact");
    }

    /**
     * C8: accrual-window contiguity over a fuzzed warp/sync/gain sequence, ghost-tracked
     * The accumulators reset iff premiums were paid, the premium timestamp updates iff they reset, and at all times
     * the accumulator equals cappedRate * (lastAccrualTimestamp - lastPremiumPaymentTimestamp)
     */
    function testFuzz_Accrual_windowContiguity(uint256 _rJT, uint256 _rLT, uint256 _seed) public {
        _rJT = bound(_rJT, 0, uint256(DEFAULT_MAX_JT_YIELD_SHARE_WAD) * 2);
        _rLT = bound(_rLT, 0, uint256(DEFAULT_MAX_LT_YIELD_SHARE_WAD) * 2);
        uint256 cappedJT = _rJT < DEFAULT_MAX_JT_YIELD_SHARE_WAD ? _rJT : DEFAULT_MAX_JT_YIELD_SHARE_WAD;
        uint256 cappedLT = _rLT < DEFAULT_MAX_LT_YIELD_SHARE_WAD ? _rLT : DEFAULT_MAX_LT_YIELD_SHARE_WAD;
        jtYDM.setRates(_rJT);
        ltYDM.setRates(_rLT);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        uint256 stRaw = SEED_ST_RAW;

        // Ghost model of the accrual window
        uint256 ghostTwJT;
        uint256 ghostTwLT;
        uint256 ghostLastPay;
        uint256 ghostLastAccrual;
        for (uint256 i; i < 8; ++i) {
            uint256 roll = uint256(keccak256(abi.encode(_seed, i)));
            uint256 action = roll % 3;
            if (action == 0) {
                vm.warp(block.timestamp + ((roll >> 8) % 3 days) + 1);
            } else {
                uint256 nowTs = block.timestamp;
                if (ghostLastAccrual == 0) {
                    ghostLastAccrual = nowTs;
                    ghostLastPay = nowTs;
                } else {
                    ghostTwJT += cappedJT * (nowTs - ghostLastAccrual);
                    ghostTwLT += cappedLT * (nowTs - ghostLastAccrual);
                    ghostLastAccrual = nowTs;
                }
                bool gain = action == 2;
                if (gain) stRaw += 1e18;
                kernel.doPreOp(toNAVUnits(stRaw), toNAVUnits(SEED_JT_RAW));
                if (gain) {
                    // A senior gain above the zero dust tolerance pays premiums, resetting the window
                    ghostTwJT = 0;
                    ghostTwLT = 0;
                    ghostLastPay = nowTs;
                }
                IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
                assertEq(uint256(s.twJTYieldShareAccruedWAD), ghostTwJT, "jt accumulator vs ghost");
                assertEq(uint256(s.twLTYieldShareAccruedWAD), ghostTwLT, "lt accumulator vs ghost");
                assertEq(uint256(s.lastPremiumPaymentTimestamp), ghostLastPay, "premium timestamp vs ghost");
                assertEq(uint256(s.lastYieldShareAccrualTimestamp), ghostLastAccrual, "accrual timestamp vs ghost");
                assertEq(uint256(s.twJTYieldShareAccruedWAD), cappedJT * (ghostLastAccrual - ghostLastPay), "jt window contiguity");
                assertEq(uint256(s.twLTYieldShareAccruedWAD), cappedLT * (ghostLastAccrual - ghostLastPay), "lt window contiguity");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                                I — SETTERS
    //////////////////////////////////////////////////////////////////////*/

    /// I1: ST protocol fee setter boundary, event, and write
    function test_SetSeniorTrancheProtocolFee_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        accountant.setSeniorTrancheProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD + 1));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.SeniorTrancheProtocolFeeUpdated(uint64(MAX_PROTOCOL_FEE_WAD));
        accountant.setSeniorTrancheProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD));
        assertEq(accountant.getState().stProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "st fee written at max boundary");
    }

    /// I1: JT protocol fee setter boundary, event, and write
    function test_SetJuniorTrancheProtocolFee_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        accountant.setJuniorTrancheProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD + 1));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheProtocolFeeUpdated(uint64(MAX_PROTOCOL_FEE_WAD));
        accountant.setJuniorTrancheProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD));
        assertEq(accountant.getState().jtProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "jt fee written at max boundary");
    }

    /// I1: JT yield-share protocol fee setter boundary, event, and write
    function test_SetJTYieldShareProtocolFee_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        accountant.setJTYieldShareProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD + 1));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareProtocolFeeUpdated(uint64(MAX_PROTOCOL_FEE_WAD));
        accountant.setJTYieldShareProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD));
        assertEq(accountant.getState().jtYieldShareProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "jt ys fee written at max boundary");
    }

    /// I1: LT yield-share protocol fee setter boundary, event, and write
    function test_SetLTYieldShareProtocolFee_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        accountant.setLTYieldShareProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD + 1));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheYieldShareProtocolFeeUpdated(uint64(MAX_PROTOCOL_FEE_WAD));
        accountant.setLTYieldShareProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD));
        assertEq(accountant.getState().ltYieldShareProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "lt ys fee written at max boundary");
    }

    /// I2: setMinCoverage reverts at exactly WAD and passes at WAD - 1 with event and write
    function test_SetMinCoverage_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        accountant.setMinCoverage(uint64(WAD));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.CoverageUpdated(uint64(WAD - 1));
        accountant.setMinCoverage(uint64(WAD - 1));
        assertEq(accountant.getState().minCoverageWAD, uint64(WAD - 1), "minCoverage written at boundary");
    }

    /// I2: setLiquidationCoverageUtilization reverts at exactly WAD and passes at WAD + 1 with event and write
    function test_SetLiquidationCoverageUtilization_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        accountant.setLiquidationCoverageUtilization(WAD);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidationCoverageUtilizationUpdated(WAD + 1);
        accountant.setLiquidationCoverageUtilization(WAD + 1);
        assertEq(accountant.getState().coverageLiquidationUtilizationWAD, WAD + 1, "liquidation utilization written at boundary");
    }

    /// I2: setMinLiquidity reverts at exactly WAD and passes at WAD - 1 with event and write
    function test_SetMinLiquidity_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.INVALID_LIQUIDITY_CONFIG.selector);
        accountant.setMinLiquidity(uint64(WAD));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityUpdated(uint64(WAD - 1));
        accountant.setMinLiquidity(uint64(WAD - 1));
        assertEq(accountant.getState().minLiquidityWAD, uint64(WAD - 1), "minLiquidity written at boundary");
    }

    /// I3: setMaxYieldShares reverts above a WAD sum and passes at exactly WAD with event and write
    function test_SetMaxYieldShares_boundaryEventWrite() public {
        vm.expectRevert(IRoycoDayAccountant.INVALID_MAX_YIELD_SHARE_CONFIG.selector);
        accountant.setMaxYieldShares(0.6e18, 0.4e18 + 1);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.MaxYieldSharesUpdated(0.6e18, 0.4e18);
        accountant.setMaxYieldShares(0.6e18, 0.4e18);
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.maxJTYieldShareWAD, 0.6e18, "maxJT written");
        assertEq(s.maxLTYieldShareWAD, 0.4e18, "maxLT written");
    }

    /// I4: a nonzero duration update mid-FIXED_TERM changes only the duration, leaving IL, state, and end timestamp intact
    function test_SetFixedTermDuration_nonzeroKeepsFixedTermState() public {
        _seedState(900e18, 300e18, 1000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        uint32 endBefore = accountant.getState().fixedTermEndTimestamp;
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermDurationUpdated(uint24(1_209_600));
        accountant.setFixedTermDuration(uint24(1_209_600));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.fixedTermDurationSeconds, 1_209_600, "duration written");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "market state untouched");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), 100e18, "il untouched");
        assertEq(s.fixedTermEndTimestamp, endBefore, "end timestamp untouched");
    }

    /// I4: a zero duration erases IL, forces PERPETUAL mid-FIXED_TERM, deletes the end timestamp, and the next sync stays perpetual
    function test_SetFixedTermDuration_zeroForcesPerpetualAndErasesIL() public {
        _seedState(900e18, 300e18, 1000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(100e18)));
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermDurationUpdated(0);
        accountant.setFixedTermDuration(0);
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.fixedTermDurationSeconds, 0, "duration zeroed");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "forced perpetual");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), 0, "il erased");
        assertEq(s.fixedTermEndTimestamp, 0, "end timestamp deleted");

        // A fresh covered loss on the next sync is erased on the spot and the market stays perpetual
        // Attribution: jtEff 200e18 < jtRaw 300e18 so all of the 50e18 ST raw loss lands on ST, is covered by JT,
        // and the permanently-perpetual branch erases the resulting 50e18 IL within the same sync
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(50e18)));
        kernel.doPreOp(toNAVUnits(uint256(850e18)), toNAVUnits(uint256(300e18)));
        s = accountant.getState();
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "sync respects permanently-perpetual");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), 0, "il erased on sync");
        assertEq(toUint256(s.lastJTEffectiveNAV), 150e18, "coverage still applied to jt");
    }

    /// I4: the IL reset event fires from the zero-duration setter even when the erased amount is zero
    function test_SetFixedTermDuration_zeroEmitsResetEventEvenWhenILZero() public {
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(ZERO_NAV_UNITS);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermDurationUpdated(0);
        accountant.setFixedTermDuration(0);
    }

    /// I5: each dust setter writes its tolerance, emits, and recomputes the cached effective sum
    function test_SetDustTolerances_recomputeEffectiveTolerance() public {
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.SeniorTrancheDustToleranceUpdated(toNAVUnits(uint256(5)));
        accountant.setSeniorTrancheDustTolerance(toNAVUnits(uint256(5)));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.stNAVDustTolerance), 5, "st dust written");
        assertEq(toUint256(s.effectiveNAVDustTolerance), 5, "effective dust recomputed after st update");
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheDustToleranceUpdated(toNAVUnits(uint256(7)));
        accountant.setJuniorTrancheDustTolerance(toNAVUnits(uint256(7)));
        s = accountant.getState();
        assertEq(toUint256(s.jtNAVDustTolerance), 7, "jt dust written");
        assertEq(toUint256(s.effectiveNAVDustTolerance), 12, "effective dust recomputed after jt update");
    }

    /**
     * I5: a raised dust tolerance changes the next sync's dust gate
     * Derivation: a 10 wei JT gain above a 0 dust tolerance takes jtProtocolFee = floor(10 * 0.1e18 / 1e18) = 1 wei,
     * and after raising the JT dust tolerance to 10 the identical gain equals the tolerance so no fee is taken
     */
    function test_SetDustTolerances_affectNextSyncDustGate() public {
        _seedAndInitAccrual();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 10));
        assertEq(toUint256(state.jtProtocolFee), 1, "fee taken above zero dust");
        accountant.setJuniorTrancheDustTolerance(toNAVUnits(uint256(10)));
        state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 20));
        assertEq(toUint256(state.jtProtocolFee), 0, "gain equal to dust takes no fee");
    }

    /// I6: setJuniorTrancheYDM rejects the current LT YDM
    function test_SetJuniorTrancheYDM_reverts_equalsLTYDM() public {
        vm.expectRevert(IRoycoDayAccountant.YDMS_CANNOT_BE_IDENTICAL.selector);
        accountant.setJuniorTrancheYDM(address(ltYDM), "");
    }

    /// I6 pin: only cross-identity is checked, so re-setting the current JT YDM is allowed
    function test_SetJuniorTrancheYDM_allowsCurrentJTYDM() public {
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheYDMUpdated(address(jtYDM));
        accountant.setJuniorTrancheYDM(address(jtYDM), "");
        assertEq(accountant.getState().jtYDM, address(jtYDM), "jt ydm unchanged");
    }

    /// I6: setJuniorTrancheYDM rejects the null address
    function test_SetJuniorTrancheYDM_reverts_null() public {
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        accountant.setJuniorTrancheYDM(address(0), "");
    }

    /// I6: setJuniorTrancheYDM initialization data paths (skipped when empty, forwarded verbatim, reverting payload bubbled)
    function test_SetJuniorTrancheYDM_initDataPaths() public {
        MockYDM silent = new MockYDM();
        accountant.setJuniorTrancheYDM(address(silent), "");
        assertEq(silent.initializeCallCount(), 0, "empty data makes no init call");

        MockYDM initialized = new MockYDM();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheYDMUpdated(address(initialized));
        accountant.setJuniorTrancheYDM(address(initialized), abi.encodeCall(MockYDM.initializeModel, (hex"abcd")));
        assertEq(initialized.initializeCallCount(), 1, "non-empty data initializes");
        assertEq(initialized.lastInitializePayload(), hex"abcd", "payload forwarded verbatim");
        assertEq(accountant.getState().jtYDM, address(initialized), "jt ydm written");

        MockYDM reverting = new MockYDM();
        reverting.setRevertOnInitialize(true);
        vm.expectRevert(
            abi.encodeWithSelector(IRoycoDayAccountant.FAILED_TO_INITIALIZE_YDM.selector, abi.encodeWithSelector(MockYDM.YDM_INIT_REVERTED.selector))
        );
        accountant.setJuniorTrancheYDM(address(reverting), abi.encodeCall(MockYDM.initializeModel, (hex"")));
    }

    /// I6 mirror: setLiquidityTrancheYDM rejects the current JT YDM
    function test_SetLiquidityTrancheYDM_reverts_equalsJTYDM() public {
        vm.expectRevert(IRoycoDayAccountant.YDMS_CANNOT_BE_IDENTICAL.selector);
        accountant.setLiquidityTrancheYDM(address(jtYDM), "");
    }

    /// I6 mirror pin: re-setting the current LT YDM is allowed
    function test_SetLiquidityTrancheYDM_allowsCurrentLTYDM() public {
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheYDMUpdated(address(ltYDM));
        accountant.setLiquidityTrancheYDM(address(ltYDM), "");
        assertEq(accountant.getState().ltYDM, address(ltYDM), "lt ydm unchanged");
    }

    /// I6 mirror: setLiquidityTrancheYDM rejects the null address
    function test_SetLiquidityTrancheYDM_reverts_null() public {
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        accountant.setLiquidityTrancheYDM(address(0), "");
    }

    /// I6 mirror: setLiquidityTrancheYDM initialization data paths
    function test_SetLiquidityTrancheYDM_initDataPaths() public {
        MockYDM silent = new MockYDM();
        accountant.setLiquidityTrancheYDM(address(silent), "");
        assertEq(silent.initializeCallCount(), 0, "empty data makes no init call");

        MockYDM initialized = new MockYDM();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheYDMUpdated(address(initialized));
        accountant.setLiquidityTrancheYDM(address(initialized), abi.encodeCall(MockYDM.initializeModel, (hex"beef")));
        assertEq(initialized.initializeCallCount(), 1, "non-empty data initializes");
        assertEq(initialized.lastInitializePayload(), hex"beef", "payload forwarded verbatim");
        assertEq(accountant.getState().ltYDM, address(initialized), "lt ydm written");

        MockYDM reverting = new MockYDM();
        reverting.setRevertOnInitialize(true);
        vm.expectRevert(
            abi.encodeWithSelector(IRoycoDayAccountant.FAILED_TO_INITIALIZE_YDM.selector, abi.encodeWithSelector(MockYDM.YDM_INIT_REVERTED.selector))
        );
        accountant.setLiquidityTrancheYDM(address(reverting), abi.encodeCall(MockYDM.initializeModel, (hex"")));
    }

    /*//////////////////////////////////////////////////////////////////////
                                D — WATERFALL
    //////////////////////////////////////////////////////////////////////*/

    /// @dev Fully hand-derived expectation for one sync vector, asserted field-by-field by _runSyncVector
    struct ExpectedSync {
        uint256 stEff;
        uint256 jtEff;
        uint256 il;
        uint256 ltPrem;
        uint256 stFee;
        uint256 jtFee;
        uint256 ltFee;
        MarketState marketState;
        uint32 fixedTermEnd;
    }

    /**
     * @dev Golden-vector runner: previews then executes the identical sync, asserts preview == execution
     * byte-for-byte (the one allowed both-sides-production assertion), asserts every returned field against the
     * hand-derived expectation, then re-reads the committed checkpoint and asserts exact NAV conservation plus
     * returned-vs-persisted equality
     *
     * The coverage utilization is asserted against the documented formula ceil(stRawNAV * minCoverage / jtEffectiveNAV)
     * evaluated with test-local math on the hand-derived jt effective NAV (JT_COINVESTED is false in every matrix deployment)
     */
    function _runSyncVector(uint256 _stRawNew, uint256 _jtRawNew, ExpectedSync memory _e) internal {
        IRoycoDayAccountant.RoycoDayAccountantState memory pre = accountant.getState();
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(_stRawNew), toNAVUnits(_jtRawNew));
        SyncedAccountingState memory executed = kernel.doPreOp(toNAVUnits(_stRawNew), toNAVUnits(_jtRawNew));
        assertEq(keccak256(abi.encode(previewed)), keccak256(abi.encode(executed)), "vector: preview must match execution exactly");

        assertEq(uint8(executed.marketState), uint8(_e.marketState), "vector: market state");
        assertEq(toUint256(executed.stRawNAV), _stRawNew, "vector: st raw NAV passthrough");
        assertEq(toUint256(executed.jtRawNAV), _jtRawNew, "vector: jt raw NAV passthrough");
        assertEq(toUint256(executed.ltRawNAV), 0, "vector: lt raw NAV placeholder");
        assertEq(toUint256(executed.stEffectiveNAV), _e.stEff, "vector: st effective NAV");
        assertEq(toUint256(executed.jtEffectiveNAV), _e.jtEff, "vector: jt effective NAV");
        assertEq(toUint256(executed.jtCoverageImpermanentLoss), _e.il, "vector: jt coverage impermanent loss");
        assertEq(toUint256(executed.ltLiquidityPremium), _e.ltPrem, "vector: lt liquidity premium");
        assertEq(toUint256(executed.stProtocolFee), _e.stFee, "vector: st protocol fee");
        assertEq(toUint256(executed.jtProtocolFee), _e.jtFee, "vector: jt protocol fee");
        assertEq(toUint256(executed.ltProtocolFee), _e.ltFee, "vector: lt protocol fee");
        assertEq(executed.coverageUtilizationWAD, _expectedCoverageUtilization(_stRawNew, _e.jtEff), "vector: coverage utilization");
        assertEq(executed.liquidityUtilizationWAD, 0, "vector: liquidity utilization placeholder");
        assertEq(executed.fixedTermEndTimestamp, _e.fixedTermEnd, "vector: fixed term end timestamp");

        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(
            toUint256(s.lastSTRawNAV) + toUint256(s.lastJTRawNAV),
            toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV),
            "vector: committed NAV conservation"
        );
        assertEq(toUint256(s.lastSTEffectiveNAV), _e.stEff, "vector: committed st effective NAV");
        assertEq(toUint256(s.lastJTEffectiveNAV), _e.jtEff, "vector: committed jt effective NAV");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), _e.il, "vector: committed il");
        assertEq(uint8(s.lastMarketState), uint8(_e.marketState), "vector: committed market state");
        assertEq(s.fixedTermEndTimestamp, _e.fixedTermEnd, "vector: committed fixed term end");

        _crossAssertWaterfallMirror(pre, _stRawNew, _jtRawNew, executed);
    }

    /**
     * @dev Builds the RoycoTestMath.WaterfallIn for one sync from the pre-sync committed checkpoint, mirroring
     * the P0 accrual test-side: when time elapsed since the last accrual, the mock YDMs' MUTATING rates (capped
     * at the configured maxima) are accrued onto the stored accumulators exactly as production does before the
     * waterfall consumes them. Same-block syncs pass the stored accumulators through unchanged
     */
    function _buildWaterfallIn(
        IRoycoDayAccountant.RoycoDayAccountantState memory _pre,
        uint256 _stRawNew,
        uint256 _jtRawNew
    )
        internal
        view
        returns (RoycoTestMath.WaterfallIn memory in_)
    {
        in_.stRawLast = toUint256(_pre.lastSTRawNAV);
        in_.jtRawLast = toUint256(_pre.lastJTRawNAV);
        in_.stEffLast = toUint256(_pre.lastSTEffectiveNAV);
        in_.jtEffLast = toUint256(_pre.lastJTEffectiveNAV);
        in_.jtCoverageILLast = toUint256(_pre.lastJTCoverageImpermanentLoss);
        in_.marketStateLast = RoycoTestMath.MarketState(uint8(_pre.lastMarketState));
        in_.fixedTermEndLast = _pre.fixedTermEndTimestamp;
        in_.stRawDelta = int256(_stRawNew) - int256(in_.stRawLast);
        in_.jtRawDelta = int256(_jtRawNew) - int256(in_.jtRawLast);
        // The kernel re-commits the unchanged LT mark after the sync in this harness
        in_.ltRawNew = toUint256(_pre.lastLTRawNAV);
        // Mirror-side P0 accrual: stored accumulators plus one capped mutating-rate window (first-ever accrual
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
        in_.jtCoinvested = accountant.JT_COINVESTED();
        in_.coverageLiquidationUtilizationWAD = _pre.coverageLiquidationUtilizationWAD;
        in_.effectiveDust = toUint256(_pre.effectiveNAVDustTolerance);
        in_.minLiquidityWAD = _pre.minLiquidityWAD;
    }

    /**
     * @dev Cross-asserts one executed sync against the independent RoycoTestMath.waterfall mirror field-by-field,
     * so every matrix vector is pinned by three sources at once: production, the hand-derived literal, and the
     * spec-12 mirror. Also asserts the premiumsPaid side effects (accumulator reset and premium-payment stamp)
     * against the committed state, then commits the unchanged LT mark and asserts the mirror's post-commit
     * ltRaw / liquidity-utilization view per spec 12 section 2.3
     */
    function _crossAssertWaterfallMirror(
        IRoycoDayAccountant.RoycoDayAccountantState memory _pre,
        uint256 _stRawNew,
        uint256 _jtRawNew,
        SyncedAccountingState memory _executed
    )
        internal
    {
        RoycoTestMath.WaterfallIn memory in_ = _buildWaterfallIn(_pre, _stRawNew, _jtRawNew);
        RoycoTestMath.WaterfallOut memory m = RoycoTestMath.waterfall(in_);

        assertEq(m.stRaw, toUint256(_executed.stRawNAV), "mirror: st raw NAV");
        assertEq(m.jtRaw, toUint256(_executed.jtRawNAV), "mirror: jt raw NAV");
        assertEq(m.stEff, toUint256(_executed.stEffectiveNAV), "mirror: st effective NAV");
        assertEq(m.jtEff, toUint256(_executed.jtEffectiveNAV), "mirror: jt effective NAV");
        assertEq(m.jtCoverageIL, toUint256(_executed.jtCoverageImpermanentLoss), "mirror: jt coverage impermanent loss");
        assertEq(m.ltLiquidityPremium, toUint256(_executed.ltLiquidityPremium), "mirror: lt liquidity premium");
        assertEq(m.stProtocolFee, toUint256(_executed.stProtocolFee), "mirror: st protocol fee");
        assertEq(m.jtProtocolFee, toUint256(_executed.jtProtocolFee), "mirror: jt protocol fee");
        assertEq(m.ltProtocolFee, toUint256(_executed.ltProtocolFee), "mirror: lt protocol fee");
        assertEq(m.coverageUtilizationWAD, _executed.coverageUtilizationWAD, "mirror: coverage utilization");
        assertEq(uint8(m.marketState), uint8(_executed.marketState), "mirror: market state");
        assertEq(m.fixedTermEnd, uint256(_executed.fixedTermEndTimestamp), "mirror: fixed term end");

        // premiumsPaid side effects (RDA:164-169): reset both accumulators and stamp the payment timestamp,
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

        // Post-commit view (spec 12 section 2.3): commit the unchanged LT mark, then the committed lastLTRawNAV
        // must equal the mirror's pass-through and the mirror's liquidity utilization is the RTM.liqUtil view
        kernel.doCommit(_pre.lastLTRawNAV);
        assertEq(toUint256(accountant.getState().lastLTRawNAV), m.ltRaw, "mirror: committed lt raw NAV pass-through");
        assertEq(m.liquidityUtilizationWAD, RoycoTestMath.liqUtil(m.stEff, in_.minLiquidityWAD, in_.ltRawNew), "mirror: post-commit liquidity utilization");
    }

    /// @dev Independent coverage utilization math: ceil(stRaw * 0.1e18 / jtEff) with the default minimum coverage and no co-investment
    function _expectedCoverageUtilization(uint256 _stRaw, uint256 _jtEff) internal pure returns (uint256) {
        uint256 requiredCoverageNAV = _stRaw * uint256(DEFAULT_MIN_COVERAGE_WAD);
        if (requiredCoverageNAV == 0) return 0;
        if (_jtEff == 0) return type(uint256).max;
        return (requiredCoverageNAV + _jtEff - 1) / _jtEff;
    }

    /**
     * @dev Matrix seed, IL == 0 regime: flat 1000e18/200e18 market, accrual clock initialized this block (so the
     * preview and execution both take the instantaneous premium branch on gains), preview rates jt 0.1e18 / lt 0.05e18
     */
    function _seedMatrixNoIL() internal {
        _seedAndInitAccrual();
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /**
     * @dev Matrix seed, 0 < IL <= dust regime: dust tolerances (st 3, jt 4, effective 7) and a persisted 5 wei
     * coverage impermanent loss in a PERPETUAL market (checkpoint 1000e18 / 200e18 / 1000e18+5 / 200e18-5)
     * @dev Claims at this checkpoint: stClaimOnJTRaw = 5 wei so a 20e18 JT delta attributes floor(20e18 * 5 / 200e18) = 0 to ST
     */
    function _seedMatrixDustIL() internal {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(4));
        _deploy(false, p);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW + 5, SEED_JT_RAW - 5, 5, SEED_LT_RAW, MarketState.PERPETUAL);
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /**
     * @dev Matrix seed, IL > dust regime: zero dust, FIXED_TERM cross-claim checkpoint 900e18 / 300e18 / 1000e18 / 200e18
     * with il 100e18 (fixed term end = now + default duration, committed during the seeding loss sync this block)
     * @dev Claims: stClaimOnSTRaw = 900e18 (full), stClaimOnJTRaw = 100e18, so a JT delta d attributes floor(d / 3) to ST
     */
    function _seedMatrixLargeIL() internal {
        _seedState(900e18, 300e18, 1000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /**
     * @dev Matrix seed, regime R2 (IL == 0, FIXED_TERM): checkpoint stRaw 1000e18-1, jtRaw 100e18, stEff 1000e18,
     * jtEff 100e18-1, il 0, zero dust, FIXED_TERM with end = seeding block + default duration (spec 12 section 4.2)
     *
     * Staging (accountant surface, all in this block): (1) symmetric 1000e18/200e18 seed with lastLTRawNAV 0,
     * (2) covered 1-wei loss sync enters FIXED_TERM (il 1 > dust 0) and initializes both premium timestamps,
     * (3) JT_REDEEM post-op of 100e18 floors the il to 0 via the RDA:279-282 scaling floor(1 * (100e18-1) /
     * (200e18-1)) = 0 while the market state stays FIXED_TERM (post-op never changes it), (4) commit lt 100e18.
     * Step 3 passes ltRaw 0 against the still-zero lastLTRawNAV so deltaLTRawNAV == 0 (POC item 2 of spec 12
     * section 4.7: the ordering commit-after-redeem does not trip INVALID_POST_OP_STATE, verified loud here)
     */
    function _seedMatrixNoILFixedTerm() internal {
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, 0, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW - 1), toNAVUnits(SEED_JT_RAW));
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW - 1), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
        kernel.doCommit(toNAVUnits(SEED_LT_RAW));

        // Self-verify the landed R2 checkpoint so staging misuse is loud
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTRawNAV), 1000e18 - 1, "seed R2: stRaw");
        assertEq(toUint256(s.lastJTRawNAV), 100e18, "seed R2: jtRaw");
        assertEq(toUint256(s.lastSTEffectiveNAV), 1000e18, "seed R2: stEff");
        assertEq(toUint256(s.lastJTEffectiveNAV), 100e18 - 1, "seed R2: jtEff");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), 0, "seed R2: il floored to 0");
        assertEq(toUint256(s.lastLTRawNAV), SEED_LT_RAW, "seed R2: ltRaw");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "seed R2: market state");
        assertEq(s.fixedTermEndTimestamp, uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS), "seed R2: fixed term end");

        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /**
     * @dev Matrix seed, regime R4 (0 < IL <= dust, FIXED_TERM): dust tolerances (st 3, jt 4, effective 7) and
     * checkpoint stRaw 1000e18-5, jtRaw 200e18, stEff 1000e18, jtEff 200e18-5, il 5, FIXED_TERM, end kept from
     * the entry sync (spec 12 section 4.4)
     *
     * Staging (all in this block): deploy with dust (3,4), symmetric seed, covered loss of 12 (> dust 7) enters
     * FIXED_TERM, then a partial-recovery sync of +7 is fully consumed by il recovery (rec = min(7, 12) = 7, no
     * premium block) leaving il 5 in (0, 7] with the initial state FIXED_TERM: the sticky-dust branch keeps the
     * term and the original end (RDA:688-696)
     */
    function _seedMatrixDustILFixedTerm() internal {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(4));
        _deploy(false, p);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW - 12), toNAVUnits(SEED_JT_RAW));
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW - 5), toNAVUnits(SEED_JT_RAW));
        kernel.doCommit(toNAVUnits(SEED_LT_RAW));

        // Self-verify the landed R4 checkpoint so staging misuse is loud
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTRawNAV), 1000e18 - 5, "seed R4: stRaw");
        assertEq(toUint256(s.lastJTRawNAV), 200e18, "seed R4: jtRaw");
        assertEq(toUint256(s.lastSTEffectiveNAV), 1000e18, "seed R4: stEff");
        assertEq(toUint256(s.lastJTEffectiveNAV), 200e18 - 5, "seed R4: jtEff");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), 5, "seed R4: sticky dust il");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "seed R4: market state");
        assertEq(s.fixedTermEndTimestamp, uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS), "seed R4: original end kept");

        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
    }

    /**
     * @dev Matrix seed, regime R5 (IL > dust, PERPETUAL): the R3 dust-IL checkpoint (1000e18 / 200e18 /
     * 1000e18+5 / 200e18-5, il 5, PERPETUAL) with both dust tolerances then shrunk to 0 via the setters, the
     * only reachable route to a committed PERPETUAL checkpoint whose persisted il exceeds the effective dust
     * (spec 12 sections 1.1-3 and 4.5). The kernel sync mode is NONE so withSyncedAccounting is a no-op
     *
     * Resolves POC item 1 of spec 12 section 4.7 empirically: the two dust setters must leave the committed
     * checkpoint (NAVs, il, market state, end, accrual and premium timestamps, accumulators) byte-identical,
     * changing only the dust fields
     */
    function _seedMatrixShrunkDustIL() internal {
        _seedMatrixDustIL();
        IRoycoDayAccountant.RoycoDayAccountantState memory before = accountant.getState();
        accountant.setSeniorTrancheDustTolerance(ZERO_NAV_UNITS);
        accountant.setJuniorTrancheDustTolerance(ZERO_NAV_UNITS);
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTRawNAV), toUint256(before.lastSTRawNAV), "seed R5: stRaw untouched");
        assertEq(toUint256(s.lastJTRawNAV), toUint256(before.lastJTRawNAV), "seed R5: jtRaw untouched");
        assertEq(toUint256(s.lastSTEffectiveNAV), toUint256(before.lastSTEffectiveNAV), "seed R5: stEff untouched");
        assertEq(toUint256(s.lastJTEffectiveNAV), toUint256(before.lastJTEffectiveNAV), "seed R5: jtEff untouched");
        assertEq(toUint256(s.lastJTCoverageImpermanentLoss), 5, "seed R5: il 5 persists");
        assertEq(toUint256(s.lastLTRawNAV), toUint256(before.lastLTRawNAV), "seed R5: ltRaw untouched");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "seed R5: market state untouched");
        assertEq(s.fixedTermEndTimestamp, before.fixedTermEndTimestamp, "seed R5: fixed term end untouched");
        assertEq(s.lastYieldShareAccrualTimestamp, before.lastYieldShareAccrualTimestamp, "seed R5: accrual timestamp untouched");
        assertEq(s.lastPremiumPaymentTimestamp, before.lastPremiumPaymentTimestamp, "seed R5: premium payment timestamp untouched");
        assertEq(uint256(s.twJTYieldShareAccruedWAD), uint256(before.twJTYieldShareAccruedWAD), "seed R5: jt accumulator untouched");
        assertEq(uint256(s.twLTYieldShareAccruedWAD), uint256(before.twLTYieldShareAccruedWAD), "seed R5: lt accumulator untouched");
        assertEq(toUint256(s.effectiveNAVDustTolerance), 0, "seed R5: effective dust shrunk to 0");
    }

    /*----------------------------------------------------------------------
                D2 matrix, IL == 0 (9 cells, zero dust tolerance)
    ----------------------------------------------------------------------*/

    /**
     * D2 cell 1 (ST loss, JT loss, IL 0): symmetric claims route each delta to its own tranche
     * Derivation: jtEff = 200e18 - 20e18 = 180e18, then coverage = min(50e18, 180e18) = 50e18 fully absorbs the
     * ST loss: jtEff = 130e18, il = 50e18, stEff unchanged. il > 0 dust forces FIXED_TERM entry (end = now + duration)
     * and zeroes all fees (none accrued anyway)
     */
    function test_Waterfall_matrixNoIL_stLoss_jtLoss() public {
        _seedMatrixNoIL();
        _runSyncVector(
            950e18,
            180e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 130e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * D2 cell 2 (ST loss, JT flat, IL 0)
     * Derivation: coverage = min(50e18, 200e18) = 50e18, jtEff = 150e18, il = 50e18, stEff unchanged, FIXED_TERM entry
     */
    function test_Waterfall_matrixNoIL_stLoss_jtFlat() public {
        _seedMatrixNoIL();
        _runSyncVector(
            950e18,
            200e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 150e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * D2 cell 3 (ST loss, JT gain, IL 0): the fee recomputation arm where coverage exceeds the JT gain
     * Derivation: jt gain 20e18 books jtFee = floor(20e18 * 0.1) = 2e18 and jtEff = 220e18, then coverage
     * = min(50e18, 220e18) = 50e18 recomputes jtNetGain = satSub(20e18 - 50e18) = 0 <= dust so jtFee = 0,
     * jtEff = 170e18, il = 50e18, stEff unchanged, FIXED_TERM entry (fees zeroed regardless)
     */
    function test_Waterfall_matrixNoIL_stLoss_jtGain() public {
        _seedMatrixNoIL();
        _runSyncVector(
            950e18,
            220e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 170e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * D2 cell 4 (ST flat, JT loss, IL 0): a pure JT loss reduces jt effective NAV exactly with no coverage or IL move
     * Derivation: jtEff = 200e18 - 20e18 = 180e18, market stays PERPETUAL
     */
    function test_Waterfall_matrixNoIL_stFlat_jtLoss() public {
        _seedMatrixNoIL();
        _runSyncVector(
            1000e18,
            180e18,
            ExpectedSync({ stEff: 1000e18, jtEff: 180e18, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEnd: 0 })
        );
    }

    /// D2 cell 5 (ST flat, JT flat, IL 0): the no-op sync leaves every field at the checkpoint (covUtil exactly 0.5e18)
    function test_Waterfall_matrixNoIL_stFlat_jtFlat() public {
        _seedMatrixNoIL();
        _runSyncVector(
            1000e18,
            200e18,
            ExpectedSync({ stEff: 1000e18, jtEff: 200e18, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEnd: 0 })
        );
        // Literal anchor for the independent ceil helper: 1000e18 * 0.1e18 / 200e18 divides exactly to 0.5e18
        assertEq(_expectedCoverageUtilization(1000e18, 200e18), 0.5e18, "anchor: exact-division coverage utilization");
    }

    /**
     * D2 cell 6 (ST flat, JT gain, IL 0): jt gain above dust takes the JT protocol fee and stays PERPETUAL
     * Derivation: jtNetGain = 20e18 > 0 dust so jtFee = floor(20e18 * 0.1e18 / 1e18) = 2e18, jtEff = 220e18
     */
    function test_Waterfall_matrixNoIL_stFlat_jtGain() public {
        _seedMatrixNoIL();
        _runSyncVector(
            1000e18,
            220e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 220e18,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 2e18,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * D2 cell 7 (ST gain, JT loss, IL 0): instantaneous premiums on the senior gain alongside a junior loss
     * Derivation: jtEff = 180e18 after the 20e18 JT loss. ST gain 50e18 with no IL to recover pays premiums via the
     * instantaneous branch (elapsed forced to 1s, preview rates 0.1e18 / 0.05e18):
     *   jtRiskPremium      = floor(50e18 * 0.1e18 / 1e18)  = 5e18   -> jtEff = 185e18, jt yield-share fee floor(5e18 * 0.1) = 0.5e18
     *   ltLiquidityPremium = floor(50e18 * 0.05e18 / 1e18) = 2.5e18 -> ltFee = floor(2.5e18 * 0.1) = 0.25e18
     *   st residual = 50e18 - 5e18 - 2.5e18 = 42.5e18 -> stFee = floor(42.5e18 * 0.1) = 4.25e18
     *   stEff = 1000e18 + 42.5e18 + 2.5e18 (premium stays a senior claim) = 1045e18
     */
    function test_Waterfall_matrixNoIL_stGain_jtLoss() public {
        _seedMatrixNoIL();
        _runSyncVector(
            1050e18,
            180e18,
            ExpectedSync({
                stEff: 1045e18,
                jtEff: 185e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 0.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * D2 cell 8 (ST gain, JT flat, IL 0)
     * Derivation: identical premium math to cell 7 on a 50e18 gain, jtEff = 200e18 + 5e18 = 205e18, stEff = 1045e18
     */
    function test_Waterfall_matrixNoIL_stGain_jtFlat() public {
        _seedMatrixNoIL();
        _runSyncVector(
            1050e18,
            200e18,
            ExpectedSync({
                stEff: 1045e18,
                jtEff: 205e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 0.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * D2 cell 9 (ST gain, JT gain, IL 0): the JT fee compounds the net-gain fee and the yield-share fee
     * Derivation: jt gain 20e18 -> jtFee = 2e18, jtEff = 220e18. ST gain 50e18 premium math as cell 7:
     * jtRiskPremium 5e18 adds floor(5e18 * 0.1) = 0.5e18 so jtFee = 2.5e18 total and jtEff = 225e18, stEff = 1045e18
     */
    function test_Waterfall_matrixNoIL_stGain_jtGain() public {
        _seedMatrixNoIL();
        _runSyncVector(
            1050e18,
            220e18,
            ExpectedSync({
                stEff: 1045e18,
                jtEff: 225e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 2.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /*----------------------------------------------------------------------
        D2 matrix, 0 < IL <= dust (9 cells, dust st 3 + jt 4 = 7, il = 5)
    ----------------------------------------------------------------------*/

    /**
     * D2 cell 10 (ST loss, JT loss, dust IL): attribution floors the 5 wei senior cross-claim out of the JT delta
     * Derivation: attrST(dJT) = -floor(20e18 * 5 / 200e18) = 0 so dJTEff = -20e18 and dSTEff = -50e18
     * jtEff = 200e18 - 5 - 20e18, coverage = 50e18: jtEff = 130e18 - 5, il = 5 + 50e18, stEff = 1000e18 + 5
     * il > dust 7 forces FIXED_TERM entry
     */
    function test_Waterfall_matrixDustIL_stLoss_jtLoss() public {
        _seedMatrixDustIL();
        _runSyncVector(
            950e18,
            180e18,
            ExpectedSync({
                stEff: 1000e18 + 5,
                jtEff: 130e18 - 5,
                il: 50e18 + 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * D2 cell 11 (ST loss, JT flat, dust IL)
     * Derivation: coverage = 50e18 on top of the persisted 5 wei il: jtEff = 150e18 - 5, il = 50e18 + 5, FIXED_TERM entry
     */
    function test_Waterfall_matrixDustIL_stLoss_jtFlat() public {
        _seedMatrixDustIL();
        _runSyncVector(
            950e18,
            200e18,
            ExpectedSync({
                stEff: 1000e18 + 5,
                jtEff: 150e18 - 5,
                il: 50e18 + 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * D2 cell 12 (ST loss, JT gain, dust IL): coverage exceeds the jt gain so the recomputed fee saturates to zero
     * Derivation: jt gain 20e18 > dust 7 books jtFee = 2e18, coverage 50e18 recomputes jtNetGain = satSub(20e18 - 50e18) = 0
     * so jtFee = 0, jtEff = 200e18 - 5 + 20e18 - 50e18 = 170e18 - 5, il = 50e18 + 5, FIXED_TERM entry
     */
    function test_Waterfall_matrixDustIL_stLoss_jtGain() public {
        _seedMatrixDustIL();
        _runSyncVector(
            950e18,
            220e18,
            ExpectedSync({
                stEff: 1000e18 + 5,
                jtEff: 170e18 - 5,
                il: 50e18 + 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * D2 cell 13 (ST flat, JT loss, dust IL): the dust il persists un-erased through a PERPETUAL sync (E5 tie-in)
     * Derivation: dJTEff = -20e18 (zero attribution to the 5 wei claim), jtEff = 180e18 - 5, il stays 5 <= dust 7
     */
    function test_Waterfall_matrixDustIL_stFlat_jtLoss() public {
        _seedMatrixDustIL();
        _runSyncVector(
            1000e18,
            180e18,
            ExpectedSync({
                stEff: 1000e18 + 5,
                jtEff: 180e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /// D2 cell 14 (ST flat, JT flat, dust IL): the checkpoint is untouched and the 5 wei dust il persists in PERPETUAL
    function test_Waterfall_matrixDustIL_stFlat_jtFlat() public {
        _seedMatrixDustIL();
        _runSyncVector(
            1000e18,
            200e18,
            ExpectedSync({
                stEff: 1000e18 + 5,
                jtEff: 200e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * D2 cell 15 (ST flat, JT gain, dust IL): the fee is kept in PERPETUAL and the dust il persists
     * Derivation: jtNetGain = 20e18 > dust 7 so jtFee = 2e18, jtEff = 220e18 - 5, il stays 5
     */
    function test_Waterfall_matrixDustIL_stFlat_jtGain() public {
        _seedMatrixDustIL();
        _runSyncVector(
            1000e18,
            220e18,
            ExpectedSync({
                stEff: 1000e18 + 5,
                jtEff: 220e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 2e18,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * D2 cell 16 (ST gain, JT loss, dust IL): dust il recovery first, then awkward premium floors on the 50e18 - 5 residual
     * Derivation: jtEff = 200e18 - 5 - 20e18, recovery = min(50e18, 5) = 5: il = 0, jtEff = 180e18, stGain = 50e18 - 5
     *   jtRiskPremium      = floor((50e18 - 5) * 0.1e18 / 1e18)  = floor(4999999999999999999.5)  = 5e18 - 1
     *   ltLiquidityPremium = floor((50e18 - 5) * 0.05e18 / 1e18) = floor(2499999999999999999.75) = 2.5e18 - 1
     *   jtFee = floor((5e18 - 1) * 0.1)   = 0.5e18 - 1, ltFee = floor((2.5e18 - 1) * 0.1) = 0.25e18 - 1
     *   st residual = (50e18 - 5) - (5e18 - 1) - (2.5e18 - 1) = 42.5e18 - 3 -> stFee = floor((42.5e18 - 3) * 0.1) = 4.25e18 - 1
     *   stEff = (1000e18 + 5) + (42.5e18 - 3) + (2.5e18 - 1) = 1045e18 + 1, jtEff = 180e18 + 5e18 - 1 = 185e18 - 1
     */
    function test_Waterfall_matrixDustIL_stGain_jtLoss() public {
        _seedMatrixDustIL();
        _runSyncVector(
            1050e18,
            180e18,
            ExpectedSync({
                stEff: 1045e18 + 1,
                jtEff: 185e18 - 1,
                il: 0,
                ltPrem: 2.5e18 - 1,
                stFee: 4.25e18 - 1,
                jtFee: 0.5e18 - 1,
                ltFee: 0.25e18 - 1,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * D2 cell 17 (ST gain, JT flat, dust IL)
     * Derivation: recovery 5 restores jtEff to 200e18, premium floors as cell 16, jtEff = 205e18 - 1, stEff = 1045e18 + 1
     */
    function test_Waterfall_matrixDustIL_stGain_jtFlat() public {
        _seedMatrixDustIL();
        _runSyncVector(
            1050e18,
            200e18,
            ExpectedSync({
                stEff: 1045e18 + 1,
                jtEff: 205e18 - 1,
                il: 0,
                ltPrem: 2.5e18 - 1,
                stFee: 4.25e18 - 1,
                jtFee: 0.5e18 - 1,
                ltFee: 0.25e18 - 1,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * D2 cell 18 (ST gain, JT gain, dust IL)
     * Derivation: jt gain 20e18 -> fee 2e18, recovery 5 -> jtEff = 220e18, premiums as cell 16 so
     * jtEff = 225e18 - 1, jtFee = 2e18 + (0.5e18 - 1) = 2.5e18 - 1, stEff = 1045e18 + 1
     */
    function test_Waterfall_matrixDustIL_stGain_jtGain() public {
        _seedMatrixDustIL();
        _runSyncVector(
            1050e18,
            220e18,
            ExpectedSync({
                stEff: 1045e18 + 1,
                jtEff: 225e18 - 1,
                il: 0,
                ltPrem: 2.5e18 - 1,
                stFee: 4.25e18 - 1,
                jtFee: 2.5e18 - 1,
                ltFee: 0.25e18 - 1,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /*----------------------------------------------------------------------
        D2 matrix, IL > dust (9 cells, cross-claim FIXED_TERM checkpoint)
    ----------------------------------------------------------------------*/

    /**
     * D2 cell 19 (ST loss, JT loss, large IL): cross-claim attribution splits the JT loss one third to ST
     * Derivation: attrST(dJT) = -floor(20e18 * 100e18 / 300e18) = -6666666666666666666
     *   dSTEff = -50e18 - 6666666666666666666 = -56666666666666666666, dJTEff = -70e18 - dSTEff = -13333333333333333334
     *   jtEff = 200e18 - 13333333333333333334 = 186666666666666666666, coverage = min(56.66e18, jtEff) fully covers:
     *   jtEff = 130e18, il = 100e18 + 56666666666666666666, stEff = 1000e18, market stays FIXED_TERM (original end kept)
     */
    function test_Waterfall_matrixLargeIL_stLoss_jtLoss() public {
        _seedMatrixLargeIL();
        _runSyncVector(
            850e18,
            280e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 130e18,
                il: 156_666_666_666_666_666_666,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * D2 cell 20 (ST loss, JT flat, large IL)
     * Derivation: full ST claim on its own raw NAV so dSTEff = -50e18, coverage 50e18: jtEff = 150e18, il = 150e18
     */
    function test_Waterfall_matrixLargeIL_stLoss_jtFlat() public {
        _seedMatrixLargeIL();
        _runSyncVector(
            850e18,
            300e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 150e18,
                il: 150e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * D2 cell 21 (ST loss, JT gain, large IL): the cross-claim variant of the coverage-exceeds-gain fee arm
     * Derivation: attrST(dJT) = +6666666666666666666 so dSTEff = -43333333333333333334 and
     *   dJTEff = -30e18 - dSTEff = +13333333333333333334: jtFee = floor(13333333333333333334 * 0.1) = 1333333333333333333
     *   coverage 43333333333333333334 recomputes jtNetGain = satSub to 0 -> jtFee = 0
     *   jtEff = 200e18 + 13333333333333333334 - 43333333333333333334 = 170e18, il = 143333333333333333334, stEff = 1000e18
     */
    function test_Waterfall_matrixLargeIL_stLoss_jtGain() public {
        _seedMatrixLargeIL();
        _runSyncVector(
            850e18,
            320e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 170e18,
                il: 143_333_333_333_333_333_334,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * D2 cell 22 (ST flat, JT loss, large IL): a pure JT loss still bleeds into ST via its cross-claim and gets covered
     * Derivation: dSTEff = -6666666666666666666, dJTEff = -13333333333333333334
     *   jtEff = 186666666666666666666, coverage = 6666666666666666666: jtEff = 180e18, il = 106666666666666666666
     */
    function test_Waterfall_matrixLargeIL_stFlat_jtLoss() public {
        _seedMatrixLargeIL();
        _runSyncVector(
            900e18,
            280e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 180e18,
                il: 106_666_666_666_666_666_666,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /// D2 cell 23 (ST flat, JT flat, large IL): the FIXED_TERM checkpoint persists unchanged, original end kept, no events
    function test_Waterfall_matrixLargeIL_stFlat_jtFlat() public {
        _seedMatrixLargeIL();
        _runSyncVector(
            900e18,
            300e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 200e18,
                il: 100e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * D2 cell 24 (ST flat, JT gain, large IL): ST's attributed share of the JT gain goes to il recovery, jt fee zeroed by FIXED_TERM
     * Derivation: dSTEff = +6666666666666666666, dJTEff = +13333333333333333334 (jtFee 1333333333333333333 pre-zeroing)
     *   recovery = min(6666666666666666666, 100e18): il = 93333333333333333334, jtEff = 200e18 + 13333333333333333334
     *   + 6666666666666666666 = 220e18, stGain = 0 so no premiums, stEff = 1000e18, FIXED_TERM zeroes the jt fee
     */
    function test_Waterfall_matrixLargeIL_stFlat_jtGain() public {
        _seedMatrixLargeIL();
        _runSyncVector(
            900e18,
            320e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 220e18,
                il: 93_333_333_333_333_333_334,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * D2 cell 25 (ST gain, JT loss, large IL): the cross-claim ST-gain/JT-loss cell, gain fully consumed by il recovery
     * Derivation: attrST(dJT) = -6666666666666666666 so dSTEff = 50e18 - 6666666666666666666 = 43333333333333333334
     *   dJTEff = 30e18 - dSTEff = -13333333333333333334: jtEff = 186666666666666666666
     *   recovery = min(43333333333333333334, 100e18) = full gain: il = 56666666666666666666, jtEff = 230e18, stGain = 0
     */
    function test_Waterfall_matrixLargeIL_stGain_jtLoss() public {
        _seedMatrixLargeIL();
        _runSyncVector(
            950e18,
            280e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 230e18,
                il: 56_666_666_666_666_666_666,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * D2 cell 26 (ST gain, JT flat, large IL): partial il recovery with no premium (gain < il)
     * Derivation: recovery = min(50e18, 100e18) = 50e18: il = 50e18, jtEff = 250e18, stGain = 0, stEff = 1000e18
     */
    function test_Waterfall_matrixLargeIL_stGain_jtFlat() public {
        _seedMatrixLargeIL();
        _runSyncVector(
            950e18,
            300e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 250e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * D2 cell 27 (ST gain, JT gain, large IL): the cross-claim ST-gain/JT-gain cell, jt fee zeroed by FIXED_TERM
     * Derivation: attrST(dJT) = +6666666666666666666 so dSTEff = 56666666666666666666 and dJTEff = 13333333333333333334
     *   jt gain books fee 1333333333333333333 (zeroed by FIXED_TERM), jtEff = 213333333333333333334
     *   recovery = full 56666666666666666666: il = 43333333333333333334, jtEff = 270e18, stGain = 0, stEff = 1000e18
     */
    function test_Waterfall_matrixLargeIL_stGain_jtGain() public {
        _seedMatrixLargeIL();
        _runSyncVector(
            950e18,
            320e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 270e18,
                il: 43_333_333_333_333_333_334,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /*----------------------------------------------------------------------
        D2 matrix, regime R2: IL == 0, FIXED_TERM (9 cells, W10-W18)
    ----------------------------------------------------------------------*/

    /*
     * Checkpoint stRaw 1000e18-1, jtRaw 100e18, stEff 1000e18, jtEff 100e18-1, il 0, zero dust, FIXED_TERM with
     * end T0+D. Claims: stClaimOnJTRaw = 1 wei, stClaimOnSTRaw = 1000e18-1 (= lastRaw so ST deltas attribute 1:1),
     * and a 20e18 JT delta attributes floor(20e18 * 1 / 100e18) = 0 to ST, so dSTEff = dST and dJTEff = dJT.
     */

    /**
     * W10 (ST loss, JT loss, IL 0, FIXED_TERM): coverage on top of a JT loss tips the small JT buffer past the
     * liquidation threshold, forcing PERPETUAL with full il erasure
     * Derivation: dST = -(50e18-1), dJT = -20e18. P4: jtEff = 100e18-1 - 20e18 = 80e18-1. P5: coverage
     * = min(50e18-1, 80e18-1) = 50e18-1 so jtEff = 30e18, would-be il = 50e18-1, stEff unchanged 1000e18.
     * P8: covUtil = ceil(950e18 * 0.1e18 / 30e18) = 3166666666666666667 >= liqThreshold 1.1e18 so the FORCED
     * PERPETUAL disjunct fires (spec 12 section 1 P8 disjunct 3): il ERASED (reset event 50e18-1), end deleted.
     * NOTE spec 12 section 4.2 erratum: its table says FT with end kept, missing its own section 1 P8
     * liquidation disjunct — the normative pipeline (which production and the RTM mirror both follow) governs
     */
    function test_Waterfall_matrixNoILFixedTerm_stLoss_jtLoss() public {
        _seedMatrixNoILFixedTerm();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(50e18 - 1)));
        _runSyncVector(
            950e18,
            80e18,
            ExpectedSync({ stEff: 1000e18, jtEff: 30e18, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEnd: 0 })
        );
    }

    /**
     * W11 (ST loss, JT flat, IL 0, FIXED_TERM): liquidation-forced PERPETUAL (spec 12 section 4.2 erratum, as W10)
     * Derivation: coverage = min(50e18-1, 100e18-1) = 50e18-1 so jtEff = 50e18, would-be il = 50e18-1, stEff
     * unchanged. P8: covUtil = ceil(950e18 * 0.1e18 / 50e18) = 1.9e18 >= 1.1e18 forces PERPETUAL, il erased
     */
    function test_Waterfall_matrixNoILFixedTerm_stLoss_jtFlat() public {
        _seedMatrixNoILFixedTerm();
        _runSyncVector(
            950e18,
            100e18,
            ExpectedSync({ stEff: 1000e18, jtEff: 50e18, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEnd: 0 })
        );
    }

    /**
     * W12 (ST loss, JT gain, IL 0, FIXED_TERM): fee-recompute arm plus the liquidation-forced PERPETUAL
     * (spec 12 section 4.2 erratum, as W10)
     * Derivation: P4 gain 20e18 books provisional jtFee 2e18, jtEff = 120e18-1. P5 coverage = 50e18-1 recomputes
     * jtNetGain = satSub(20e18 - (50e18-1)) = 0 <= dust so jtFee = 0, jtEff = 70e18, would-be il = 50e18-1.
     * P8: covUtil = ceil(950e18 * 0.1e18 / 70e18) = 1357142857142857143 >= 1.1e18 forces PERPETUAL, il erased
     */
    function test_Waterfall_matrixNoILFixedTerm_stLoss_jtGain() public {
        _seedMatrixNoILFixedTerm();
        _runSyncVector(
            950e18,
            120e18,
            ExpectedSync({ stEff: 1000e18, jtEff: 70e18, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEnd: 0 })
        );
    }

    /**
     * W13 (ST flat, JT loss, IL 0, FIXED_TERM): liquidation-forced PERPETUAL, not the il == 0 branch (spec 12
     * section 4.2 non-erratum note: W13 routes through the forced disjunct with an outcome identical to the table)
     * Derivation: dJT = -20e18 attributes 0 to the 1-wei cross-claim so jtEff = 80e18-1, il stays 0. P8 evaluates
     * the forced disjuncts first (RDA:666-669): covUtil = ceil((1000e18-1) * 0.1e18 / (80e18-1)) = 1.25e18 + 1 wei
     * >= 1.1e18, so PERPETUAL is FORCED with IL erasure before the il == 0 branch (RDA:683) is ever reached, the
     * erased il is already 0 (so no reset event), end deleted
     */
    function test_Waterfall_matrixNoILFixedTerm_stFlat_jtLoss() public {
        _seedMatrixNoILFixedTerm();
        _runSyncVector(
            1000e18 - 1,
            80e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 80e18 - 1,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * W14 (ST flat, JT flat, IL 0, FIXED_TERM): the pure state-machine cell — a flat sync exits the term
     * Derivation: zero deltas so no waterfall legs run, initial FIXED_TERM with il == 0 lands PERPETUAL
     * (RDA:683-686), end deleted, FixedTermEnded emitted, and NO il-reset event (nothing was erased)
     */
    function test_Waterfall_matrixNoILFixedTerm_stFlat_jtFlat() public {
        _seedMatrixNoILFixedTerm();
        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        _runSyncVector(
            1000e18 - 1,
            100e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 100e18 - 1,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
        assertEq(
            _countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset.selector),
            0,
            "flat term exit erases nothing"
        );
    }

    /**
     * W15 (ST flat, JT gain, IL 0, FIXED_TERM): the JT net-gain fee SURVIVES the term exit
     * Derivation: jtNetGain 20e18 > dust 0 books jtFee 2e18, jtEff = 120e18-1. il stays 0 so the market exits to
     * PERPETUAL, whose branch does NOT zero fees — pins that fee zeroing is a property of FIXED_TERM-committing
     * syncs only (spec 12 section 4.2 W15)
     */
    function test_Waterfall_matrixNoILFixedTerm_stFlat_jtGain() public {
        _seedMatrixNoILFixedTerm();
        _runSyncVector(
            1000e18 - 1,
            120e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 120e18 - 1,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 2e18,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * W16 (ST gain, JT loss, IL 0, FIXED_TERM): a +1 wei gain floor rides through the premium math intact
     * Derivation: dST = +(50e18+1) so stGain = 50e18+1 (no il to recover). Instantaneous premiums:
     *   jtRiskPremium = floor((50e18+1) * 0.1e18 / 1e18) = 5e18, ltLiquidityPremium = floor((50e18+1) * 0.05) = 2.5e18
     *   jtFee = floor(5e18 * 0.1) = 0.5e18, ltFee = 0.25e18, residual = 42.5e18+1, stFee = floor((42.5e18+1) * 0.1) = 4.25e18
     *   stEff = 1000e18 + (42.5e18+1) + 2.5e18 = 1045e18+1, jtEff = (100e18-1) - 20e18 + 5e18 = 85e18-1
     * Conservation: 1050e18 + 80e18 == (1045e18+1) + (85e18-1). il 0 exits to PERPETUAL with premiums and fees intact
     */
    function test_Waterfall_matrixNoILFixedTerm_stGain_jtLoss() public {
        _seedMatrixNoILFixedTerm();
        _runSyncVector(
            1050e18,
            80e18,
            ExpectedSync({
                stEff: 1045e18 + 1,
                jtEff: 85e18 - 1,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 0.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * W17 (ST gain, JT flat, IL 0, FIXED_TERM)
     * Derivation: identical premium math to W16, jtEff = (100e18-1) + 5e18 = 105e18-1, stEff = 1045e18+1
     */
    function test_Waterfall_matrixNoILFixedTerm_stGain_jtFlat() public {
        _seedMatrixNoILFixedTerm();
        _runSyncVector(
            1050e18,
            100e18,
            ExpectedSync({
                stEff: 1045e18 + 1,
                jtEff: 105e18 - 1,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 0.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * W18 (ST gain, JT gain, IL 0, FIXED_TERM): both JT fee parts accrue and survive the term exit
     * Derivation: P4 gain 20e18 books jtFee 2e18 (jtEff 120e18-1), premium math as W16 adds 0.5e18 so
     * jtFee = 2.5e18 total, jtEff = 125e18-1, stEff = 1045e18+1. Premiums imply PERPETUAL (spec 12 section 1.1)
     */
    function test_Waterfall_matrixNoILFixedTerm_stGain_jtGain() public {
        _seedMatrixNoILFixedTerm();
        _runSyncVector(
            1050e18,
            120e18,
            ExpectedSync({
                stEff: 1045e18 + 1,
                jtEff: 125e18 - 1,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 2.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /*----------------------------------------------------------------------
        D2 matrix, regime R4: 0 < IL <= dust, FIXED_TERM (9 cells, W28-W36)
    ----------------------------------------------------------------------*/

    /*
     * Checkpoint stRaw 1000e18-5, jtRaw 200e18, stEff 1000e18, jtEff 200e18-5, il 5, dust (st 3, jt 4, effective
     * 7), FIXED_TERM with end T0+D. Claims: stClaimOnJTRaw = 5, stClaimOnSTRaw = 1000e18-5 (= lastRaw so ST
     * deltas attribute 1:1), and a 20e18 JT delta attributes floor(20e18 * 5 / 200e18) = 0 to ST.
     */

    /**
     * W28 (ST loss, JT loss, dust IL, FIXED_TERM): staging offsets cancel to round outputs
     * Derivation: dST = -(50e18-5), dJT = -20e18. P4: jtEff = 180e18-5. P5: coverage = 50e18-5 so
     * jtEff = 130e18, il = 5 + (50e18-5) = 50e18, stEff unchanged. il 50e18 > dust 7: stays FIXED_TERM, end kept
     */
    function test_Waterfall_matrixDustILFixedTerm_stLoss_jtLoss() public {
        _seedMatrixDustILFixedTerm();
        _runSyncVector(
            950e18,
            180e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 130e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * W29 (ST loss, JT flat, dust IL, FIXED_TERM)
     * Derivation: coverage = 50e18-5 so jtEff = (200e18-5) - (50e18-5) = 150e18, il = 50e18, stEff unchanged
     */
    function test_Waterfall_matrixDustILFixedTerm_stLoss_jtFlat() public {
        _seedMatrixDustILFixedTerm();
        _runSyncVector(
            950e18,
            200e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 150e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * W30 (ST loss, JT gain, dust IL, FIXED_TERM): fee recompute saturates to zero inside the sticky term
     * Derivation: P4 gain 20e18 > dust 7 books jtFee 2e18 (jtEff 220e18-5), coverage 50e18-5 recomputes
     * jtNetGain = satSub(20e18 - (50e18-5)) = 0 so jtFee = 0, jtEff = 170e18, il = 50e18
     */
    function test_Waterfall_matrixDustILFixedTerm_stLoss_jtGain() public {
        _seedMatrixDustILFixedTerm();
        _runSyncVector(
            950e18,
            220e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 170e18,
                il: 50e18,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * W31 (ST flat, JT loss, dust IL, FIXED_TERM): dust il sticks and the term persists through a JT loss
     * Derivation: dJTEff = -20e18 (zero attribution to the 5-wei claim) so jtEff = 180e18-5, il stays 5 in
     * (0, dust 7] with initial FIXED_TERM: sticky branch keeps the term and the original end (RDA:688-696)
     */
    function test_Waterfall_matrixDustILFixedTerm_stFlat_jtLoss() public {
        _seedMatrixDustILFixedTerm();
        _runSyncVector(
            1000e18 - 5,
            180e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 180e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * W32 (ST flat, JT flat, dust IL, FIXED_TERM): the pure dust-IL stickiness cell (spec 12 section 4.4)
     * Derivation: zero deltas, il 5 in (0, 7] with initial FIXED_TERM stays FIXED_TERM with the ORIGINAL end,
     * all fee and premium fields zero (nothing accrued). Pins RDA:688-696 in isolation
     */
    function test_Waterfall_matrixDustILFixedTerm_stFlat_jtFlat() public {
        _seedMatrixDustILFixedTerm();
        _runSyncVector(
            1000e18 - 5,
            200e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 200e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * W33 (ST flat, JT gain, dust IL, FIXED_TERM): the sticky branch zeroes a LIVE jt fee — the only live arm
     * of the FIXED_TERM fee zeroing (spec 12 section 1.1)
     * Derivation: jtNetGain 20e18 > dust 7 books provisional jtFee 2e18, no ST move so il stays 5 and the
     * sticky-dust branch ZEROES the fee (RDA:694). jtEff = 220e18-5 (the gain NAV is kept, only the fee drops)
     */
    function test_Waterfall_matrixDustILFixedTerm_stFlat_jtGain() public {
        _seedMatrixDustILFixedTerm();
        _runSyncVector(
            1000e18 - 5,
            220e18,
            ExpectedSync({
                stEff: 1000e18,
                jtEff: 220e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * W34 (ST gain, JT loss, dust IL, FIXED_TERM): recovery-to-zero then premiums, exiting the term
     * Derivation: dST = +(50e18+5). P4: jtEff = 180e18-5. P6a: rec = min(50e18+5, 5) = 5 so il = 0,
     * jtEff = 180e18, stGain = 50e18 exactly (offsets cancel). Premiums and fees identical to W7:
     * jtPrem 5e18, ltPrem 2.5e18, jtFee 0.5e18, ltFee 0.25e18, stFee 4.25e18, stEff = 1045e18, jtEff = 185e18.
     * Conservation: 1050e18 + 180e18 == 1045e18 + 185e18. il 0 with initial FIXED_TERM: PERPETUAL, end deleted
     */
    function test_Waterfall_matrixDustILFixedTerm_stGain_jtLoss() public {
        _seedMatrixDustILFixedTerm();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        _runSyncVector(
            1050e18,
            180e18,
            ExpectedSync({
                stEff: 1045e18,
                jtEff: 185e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 0.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * W35 (ST gain, JT flat, dust IL, FIXED_TERM)
     * Derivation: rec 5 restores jtEff to 200e18, then jtPrem 5e18 lands jtEff = 205e18, stEff = 1045e18
     */
    function test_Waterfall_matrixDustILFixedTerm_stGain_jtFlat() public {
        _seedMatrixDustILFixedTerm();
        _runSyncVector(
            1050e18,
            200e18,
            ExpectedSync({
                stEff: 1045e18,
                jtEff: 205e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 0.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * W36 (ST gain, JT gain, dust IL, FIXED_TERM): both JT fee parts with recovery, exiting the term
     * Derivation: P4 gain 20e18 > 7 books jtFee 2e18 (jtEff 220e18-5), rec 5 lands 220e18, jtPrem 5e18 adds
     * 0.5e18 fee so jtFee = 2.5e18, jtEff = 225e18, stEff = 1045e18, PERPETUAL exit
     */
    function test_Waterfall_matrixDustILFixedTerm_stGain_jtGain() public {
        _seedMatrixDustILFixedTerm();
        _runSyncVector(
            1050e18,
            220e18,
            ExpectedSync({
                stEff: 1045e18,
                jtEff: 225e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 2.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /*----------------------------------------------------------------------
        D2 matrix, regime R5: IL > dust, PERPETUAL (9 cells, W37-W45)
    ----------------------------------------------------------------------*/

    /*
     * The R3 checkpoint (1000e18 / 200e18 / 1000e18+5 / 200e18-5, il 5, PERPETUAL) with both dust tolerances
     * shrunk to 0 by the setters, so the SAME persisted il 5 now EXCEEDS the effective dust. Claims and
     * attribution identical to R3 (dSTEff = dST, dJTEff = dJT). Fee dust gates now trigger at > 0 instead of
     * > 7 — same fee outcomes at these magnitudes.
     */

    /**
     * W37 (ST loss, JT loss, IL > dust, PERPETUAL)
     * Derivation: as W19 — jtEff = 200e18-5 - 20e18, coverage 50e18: jtEff = 130e18-5, il = 50e18+5,
     * stEff = 1000e18+5, FIXED_TERM entry (end = now + duration)
     */
    function test_Waterfall_matrixShrunkDustIL_stLoss_jtLoss() public {
        _seedMatrixShrunkDustIL();
        _runSyncVector(
            950e18,
            180e18,
            ExpectedSync({
                stEff: 1000e18 + 5,
                jtEff: 130e18 - 5,
                il: 50e18 + 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * W38 (ST loss, JT flat, IL > dust, PERPETUAL)
     * Derivation: coverage 50e18 on top of the persisted il 5: jtEff = 150e18-5, il = 50e18+5, FIXED_TERM entry
     */
    function test_Waterfall_matrixShrunkDustIL_stLoss_jtFlat() public {
        _seedMatrixShrunkDustIL();
        _runSyncVector(
            950e18,
            200e18,
            ExpectedSync({
                stEff: 1000e18 + 5,
                jtEff: 150e18 - 5,
                il: 50e18 + 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * W39 (ST loss, JT gain, IL > dust, PERPETUAL): fee recompute saturates to zero on the FIXED_TERM entry
     * Derivation: P4 gain 20e18 > dust 0 books jtFee 2e18, coverage 50e18 recomputes it to 0,
     * jtEff = 170e18-5, il = 50e18+5, FIXED_TERM entry
     */
    function test_Waterfall_matrixShrunkDustIL_stLoss_jtGain() public {
        _seedMatrixShrunkDustIL();
        _runSyncVector(
            950e18,
            220e18,
            ExpectedSync({
                stEff: 1000e18 + 5,
                jtEff: 170e18 - 5,
                il: 50e18 + 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * W40 (ST flat, JT loss, IL > dust, PERPETUAL): the re-classified il 5 tips the market into FIXED_TERM
     * Derivation: jtEff = 180e18-5, il stays 5 which now EXCEEDS dust 0, so the else-FIXED_TERM branch fires
     * from PERPETUAL: end = now + duration (contrast W22, where the same il 5 persisted in PERPETUAL)
     */
    function test_Waterfall_matrixShrunkDustIL_stFlat_jtLoss() public {
        _seedMatrixShrunkDustIL();
        _runSyncVector(
            1000e18,
            180e18,
            ExpectedSync({
                stEff: 1000e18 + 5,
                jtEff: 180e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * W41 (ST flat, JT flat, IL > dust, PERPETUAL): the regime's distinctive cell — a FLAT sync flips the state
     * Derivation: zero deltas, post-waterfall il 5 > dust 0 lands the else-FIXED_TERM branch, entering FROM
     * PERPETUAL so end = now + duration and FixedTermCommenced is emitted (RDA:697-706). The market flips on NO
     * PnL, purely because the dust setters re-classified the persisted il (spec 12 section 4.5)
     */
    function test_Waterfall_matrixShrunkDustIL_stFlat_jtFlat() public {
        _seedMatrixShrunkDustIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermCommenced(uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS));
        _runSyncVector(
            1000e18,
            200e18,
            ExpectedSync({
                stEff: 1000e18 + 5,
                jtEff: 200e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * W42 (ST flat, JT gain, IL > dust, PERPETUAL): the FIXED_TERM entry zeroes a live jt fee
     * Derivation: jtNetGain 20e18 > dust 0 books provisional jtFee 2e18, il stays 5 > 0 so the else-FIXED_TERM
     * branch zeroes it on entry. jtEff = 220e18-5 (gain NAV kept, fee dropped)
     */
    function test_Waterfall_matrixShrunkDustIL_stFlat_jtGain() public {
        _seedMatrixShrunkDustIL();
        _runSyncVector(
            1000e18,
            220e18,
            ExpectedSync({
                stEff: 1000e18 + 5,
                jtEff: 220e18 - 5,
                il: 5,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.FIXED_TERM,
                fixedTermEnd: uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS)
            })
        );
    }

    /**
     * W43 (ST gain, JT loss, IL > dust, PERPETUAL): recovery then the R3-identical awkward premium floors
     * Derivation: numbers match W25 exactly — the dust change is invisible since stGain 50e18-5 > 7 > 0:
     * rec 5 (il 0, jtEff 180e18), jtPrem = floor((50e18-5) * 0.1) = 5e18-1, ltPrem = 2.5e18-1,
     * jtFee = 0.5e18-1, ltFee = 0.25e18-1, residual 42.5e18-3, stFee = 4.25e18-1,
     * stEff = 1045e18+1, jtEff = 185e18-1, PERPETUAL
     */
    function test_Waterfall_matrixShrunkDustIL_stGain_jtLoss() public {
        _seedMatrixShrunkDustIL();
        _runSyncVector(
            1050e18,
            180e18,
            ExpectedSync({
                stEff: 1045e18 + 1,
                jtEff: 185e18 - 1,
                il: 0,
                ltPrem: 2.5e18 - 1,
                stFee: 4.25e18 - 1,
                jtFee: 0.5e18 - 1,
                ltFee: 0.25e18 - 1,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * W44 (ST gain, JT flat, IL > dust, PERPETUAL)
     * Derivation: as W26 — rec 5 restores jtEff to 200e18, premiums as W43, jtEff = 205e18-1, stEff = 1045e18+1
     */
    function test_Waterfall_matrixShrunkDustIL_stGain_jtFlat() public {
        _seedMatrixShrunkDustIL();
        _runSyncVector(
            1050e18,
            200e18,
            ExpectedSync({
                stEff: 1045e18 + 1,
                jtEff: 205e18 - 1,
                il: 0,
                ltPrem: 2.5e18 - 1,
                stFee: 4.25e18 - 1,
                jtFee: 0.5e18 - 1,
                ltFee: 0.25e18 - 1,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * W45 (ST gain, JT gain, IL > dust, PERPETUAL)
     * Derivation: as W27 — jt gain fee 2e18 plus the premium fee 0.5e18-1 so jtFee = 2.5e18-1,
     * jtEff = 225e18-1, stEff = 1045e18+1, PERPETUAL
     */
    function test_Waterfall_matrixShrunkDustIL_stGain_jtGain() public {
        _seedMatrixShrunkDustIL();
        _runSyncVector(
            1050e18,
            220e18,
            ExpectedSync({
                stEff: 1045e18 + 1,
                jtEff: 225e18 - 1,
                il: 0,
                ltPrem: 2.5e18 - 1,
                stFee: 4.25e18 - 1,
                jtFee: 2.5e18 - 1,
                ltFee: 0.25e18 - 1,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /*----------------------------------------------------------------------
        D2 auxiliary golden vectors W55-W60 (spec 12 section 4.8)
    ----------------------------------------------------------------------*/

    /**
     * W55 (loss past JT exhaustion with an uncovered residual + wipeout erasure): from the R1 checkpoint,
     * sync (700e18, 200e18)
     * Derivation: stLoss 300e18, coverage = min(300e18, 200e18) = 200e18 so jtEff = 0, would-be il 200e18,
     * residual 100e18 hits senior: stEff = 900e18. covUtil = uint256 max (jtEff == 0 against a positive
     * requirement), and the wipeout disjunct (jtEff == 0 with stEff > 0) forces PERPETUAL with the full il
     * ERASED (reset event 200e18), end 0. Conservation: 700e18 + 200e18 == 900e18 + 0.
     * Pins the spec 12 section 1 P5 lemma: an uncovered loss implies wipeout and can never commit FIXED_TERM
     */
    function test_Waterfall_W55_uncoveredResidualLossWipeoutForcesPerpetual() public {
        _seedMatrixNoIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(200e18)));
        _runSyncVector(
            700e18,
            200e18,
            ExpectedSync({ stEff: 900e18, jtEff: 0, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEnd: 0 })
        );
    }

    /**
     * W56 (exhaustion exactly at the boundary): from the R1 checkpoint, sync (800e18, 200e18)
     * Derivation: stLoss 200e18 == jtEff so coverage = 200e18, jtEff = 0, residual 0, stEff stays 1000e18,
     * would-be il 200e18 erased by the wipeout disjunct, PERPETUAL, end 0. Distinguishes "fully covered but
     * buffer emptied" (stEff intact) from W55's residual case
     */
    function test_Waterfall_W56_exhaustionAtExactBoundaryFullyCoveredWipeout() public {
        _seedMatrixNoIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(200e18)));
        _runSyncVector(
            800e18,
            200e18,
            ExpectedSync({ stEff: 1000e18, jtEff: 0, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEnd: 0 })
        );
    }

    /**
     * W57 (gain exactly == il, the recovery boundary with no premiums): from the R6 checkpoint,
     * sync (1000e18, 300e18)
     * Derivation: dST = +100e18, rec = min(100e18, il 100e18) = 100e18 so il = 0, jtEff = 300e18, stGain = 0
     * and the premium block is SKIPPED (premiumsPaid false, accumulators NOT reset — asserted by the runner's
     * premiumsPaid side-effect check). il 0 with initial FIXED_TERM: PERPETUAL, end 0, FixedTermEnded
     */
    function test_Waterfall_W57_gainExactlyEqualToILRecoveryBoundary() public {
        _seedMatrixLargeIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        _runSyncVector(
            1000e18,
            300e18,
            ExpectedSync({ stEff: 1000e18, jtEff: 300e18, il: 0, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEnd: 0 })
        );
    }

    /**
     * W58 (gain == il + 1 wei: 1-wei premium floors with premiumsPaid true): from the R6 checkpoint,
     * sync (1000e18 + 1, 300e18)
     * Derivation: rec = 100e18 leaves stGain = 1. premiumsPaid = (1 > dust 0) = true, yet every carve floors
     * to zero: jtPrem = floor(1 * 0.1) = 0, ltPrem = 0, stFee = floor(1 * 0.1) = 0. stEff = 1000e18+1,
     * jtEff = 300e18, PERPETUAL. Pins that premiumsPaid true with all-zero premiums and fees still resets the
     * accumulators and stamps lastPremiumPaymentTimestamp (RDA:164-169) — the runner's side-effect check
     * asserts the reset path was taken, and the mirror's premiumsPaid flag is pinned true below
     */
    function test_Waterfall_W58_gainOneWeiAboveILZeroPremiumsStillPay() public {
        _seedMatrixLargeIL();
        IRoycoDayAccountant.RoycoDayAccountantState memory pre = accountant.getState();
        _runSyncVector(
            1000e18 + 1,
            300e18,
            ExpectedSync({
                stEff: 1000e18 + 1,
                jtEff: 300e18,
                il: 0,
                ltPrem: 0,
                stFee: 0,
                jtFee: 0,
                ltFee: 0,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
        // Pin the mirror's dust-gate outcome explicitly: the 1-wei gain clears the zero dust tolerance
        RoycoTestMath.WaterfallOut memory m = RoycoTestMath.waterfall(_buildWaterfallIn(pre, 1000e18 + 1, 300e18));
        assertTrue(m.premiumsPaid, "one-wei gain above zero dust pays premiums");
    }

    /**
     * W59 (time-weighted twin of W8): R1 seed, mutating rates jt 0.1e18 / lt 0.05e18, warp +1 day, sync
     * (1050e18, 200e18) — identical outputs to W8 through the OTHER premium branch (real elapsed, RDA:624-625)
     * Derivation: accrual twJT = 0.1e18 * 86400 = 8640e18 and twLT = 0.05e18 * 86400 = 4320e18 (both events
     * asserted), elapsed = 86400 so jtPrem = floor(50e18 * 8640e18 / (86400 * 1e18)) = 5e18 and ltPrem = 2.5e18.
     * Fees as W8: jtFee 0.5e18, ltFee 0.25e18, stFee 4.25e18, stEff 1045e18, jtEff 205e18, PERPETUAL.
     * The runner's premiumsPaid check asserts both accumulators reset and the payment stamped at the warped time
     */
    function test_Waterfall_W59_timeWeightedPremiumBranchTwinOfW8() public {
        _seedMatrixNoIL();
        jtYDM.setYieldShareReturn(0.1e18);
        ltYDM.setYieldShareReturn(0.05e18);
        vm.warp(block.timestamp + 86_400);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareAccrued(0.1e18, 8640e18);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheYieldShareAccrued(0.05e18, 4320e18);
        _runSyncVector(
            1050e18,
            200e18,
            ExpectedSync({
                stEff: 1045e18,
                jtEff: 205e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4.25e18,
                jtFee: 0.5e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /**
     * W60 (two-window time-weighted averaging + the accrual-side cap): R1 seed, 12h at rate jt 0.1e18 accrued
     * by a flat sync (which pays nothing and does NOT reset), then 12h at a hostile jt rate 0.5e18 CAPPED to
     * maxJT 0.2e18 at accrual (RDA:759), then sync (1050e18, 200e18)
     * Derivation: twJT = 0.1e18 * 43200 + 0.2e18 * 43200 = 12960e18 over elapsed 86400 since the last payment
     * (the flat sync never stamps one), so jtPrem = floor(50e18 * 12960e18 / (86400 * 1e18)) = floor(50e18 * 0.15)
     * = 7.5e18. twLT = 0.05e18 * 86400 = 4320e18 so ltPrem = 2.5e18. jtFee = 0.75e18, ltFee = 0.25e18,
     * residual = 40e18 so stFee = 4e18, stEff = 1000e18 + 40e18 + 2.5e18 = 1042.5e18, jtEff = 207.5e18.
     * Conservation: 1050e18 + 200e18 == 1042.5e18 + 207.5e18. Pins the sum(share * dt) / elapsed averaging (F23)
     */
    function test_Waterfall_W60_twoWindowTimeWeightedAveragingWithAccrualCap() public {
        _seedMatrixNoIL();
        // Mutating and preview rates aligned so the preview-path accrual matches execution byte-for-byte
        jtYDM.setRates(0.1e18);
        ltYDM.setRates(0.05e18);
        // t0 read through an external call: a plain block.timestamp local is rematerialized at use-site by
        // via-ir and would read the warped time (the seed stamped this to the current block's timestamp)
        uint256 t0 = accountant.getState().lastPremiumPaymentTimestamp;
        assertEq(t0, block.timestamp, "seed stamped the premium payment clock this block");
        vm.warp(t0 + 43_200);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        // The flat sync accrues window 1 without paying or resetting: the payment window keeps running from t0
        IRoycoDayAccountant.RoycoDayAccountantState memory mid = accountant.getState();
        assertEq(uint256(mid.twJTYieldShareAccruedWAD), 0.1e18 * 43_200, "window 1 accrued");
        assertEq(uint256(mid.twLTYieldShareAccruedWAD), 0.05e18 * 43_200, "lt window 1 accrued");
        assertEq(uint256(mid.lastPremiumPaymentTimestamp), t0, "flat sync never stamps a premium payment");
        // Window 2 at a hostile mutating rate, clamped to the 0.2e18 max at accrual
        jtYDM.setRates(0.5e18);
        vm.warp(t0 + 86_400);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareAccrued(0.2e18, 12_960e18);
        _runSyncVector(
            1050e18,
            200e18,
            ExpectedSync({
                stEff: 1042.5e18,
                jtEff: 207.5e18,
                il: 0,
                ltPrem: 2.5e18,
                stFee: 4e18,
                jtFee: 0.75e18,
                ltFee: 0.25e18,
                marketState: MarketState.PERPETUAL,
                fixedTermEnd: 0
            })
        );
    }

    /*----------------------------------------------------------------------
                        D1 — PnL attribution
    ----------------------------------------------------------------------*/

    /**
     * D1a: with a JT cross-claim (jtEff > jtRaw from a paid risk premium), a senior raw loss is shared with JT
     * in proportion to its claim on the senior raw NAV
     * Seed (route 3): 1000e18 / 200e18 / 980e18 / 220e18 so jtClaimOnSTRaw = 20e18 and stClaimOnSTRaw = 980e18
     * Derivation for a 100e18 ST raw loss: attrST = -floor(100e18 * 980e18 / 1000e18) = -98e18, residual -2e18 to JT
     *   jtEff = 220e18 - 2e18 = 218e18, coverage = min(98e18, 218e18) = 98e18: jtEff = 120e18, il = 98e18, stEff = 980e18
     */
    function test_Waterfall_jtCrossClaimSharesSTRawLoss() public {
        _seedState(1000e18, 200e18, 980e18, 220e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(900e18)), toNAVUnits(uint256(200e18)));
        assertEq(toUint256(state.stEffectiveNAV), 980e18, "st keeps its cross-claim NAV under full coverage");
        assertEq(toUint256(state.jtEffectiveNAV), 120e18, "jt bears its attributed share plus the coverage");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 98e18, "il equals coverage applied to st's attributed loss");
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "covered loss forces fixed term");
    }

    /**
     * D1a: with a JT cross-claim, a senior raw gain is shared with JT in proportion to its claim
     * Derivation for a 100e18 ST raw gain: attrST = floor(100e18 * 980e18 / 1000e18) = 98e18, residual +2e18 to JT
     *   jt gain 2e18 -> jtFee = 0.2e18, jtEff = 222e18. ST gain 98e18 pays instantaneous premiums (rates 0.1e18 / 0.05e18):
     *   jtRiskPremium = 9.8e18 (jtFee += 0.98e18 = 1.18e18, jtEff = 231.8e18), ltLiquidityPremium = 4.9e18 (ltFee 0.49e18)
     *   st residual = 98e18 - 9.8e18 - 4.9e18 = 83.3e18 -> stFee = 8.33e18, stEff = 980e18 + 83.3e18 + 4.9e18 = 1068.2e18
     */
    function test_Waterfall_jtCrossClaimSharesSTRawGain() public {
        _seedState(1000e18, 200e18, 980e18, 220e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1100e18)), toNAVUnits(uint256(200e18)));
        assertEq(toUint256(state.stEffectiveNAV), 1068.2e18, "st effective NAV from attributed gain and premium carve-outs");
        assertEq(toUint256(state.jtEffectiveNAV), 231.8e18, "jt effective NAV from residual gain plus risk premium");
        assertEq(toUint256(state.ltLiquidityPremium), 4.9e18, "lt premium on st's attributed gain only");
        assertEq(toUint256(state.stProtocolFee), 8.33e18, "st fee on the retained residual");
        assertEq(toUint256(state.jtProtocolFee), 1.18e18, "jt fee compounds net-gain and yield-share fees");
        assertEq(toUint256(state.ltProtocolFee), 0.49e18, "lt fee on the liquidity premium");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "gain sync stays perpetual");
    }

    /**
     * D1b arm 1: lastSTRawNAV == 0 with stEffectiveNAV > 0 routes the entire senior raw delta to ST
     * Seed: 0 / 300e18 / 100e18 / 200e18 with il 100e18 (senior fully backed by the junior raw NAV)
     * Derivation for a 50e18 ST raw gain: routed to ST, so il recovery = 50e18 (il -> 50e18, jtEff -> 250e18) and
     * no jt fee — routing to JT instead would leave il at 100e18 and take a junior net-gain fee
     */
    function test_Waterfall_zeroLastSTRawRoutesDeltaToSTWhenSTEffPositive() public {
        _seedState(0, 300e18, 100e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(50e18)), toNAVUnits(uint256(300e18)));
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 50e18, "gain routed to st recovers il");
        assertEq(toUint256(state.jtEffectiveNAV), 250e18, "jt receives the recovery, not a raw gain");
        assertEq(toUint256(state.stEffectiveNAV), 100e18, "st effective NAV unchanged through recovery");
        assertEq(toUint256(state.jtProtocolFee), 0, "no junior net-gain fee: the delta was st's");
    }

    /**
     * D1b arm 2: lastSTRawNAV == 0 with stEffectiveNAV == 0 routes nothing to ST, the delta lands on JT as residual
     * Derivation for a 50e18 ST raw gain: jt net gain 50e18 -> jtFee = 5e18, jtEff = 250e18, stEff stays 0
     */
    function test_Waterfall_zeroLastSTRawRoutesDeltaToJTWhenSTEffZero() public {
        _seedState(0, 200e18, 0, 200e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(50e18)), toNAVUnits(uint256(200e18)));
        assertEq(toUint256(state.stEffectiveNAV), 0, "no live senior claims so st receives nothing");
        assertEq(toUint256(state.jtEffectiveNAV), 250e18, "residual delta lands on jt");
        assertEq(toUint256(state.jtProtocolFee), 5e18, "junior net-gain fee on the routed delta");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "no il so the market stays perpetual");
    }

    /// D1c: a zero delta on a cross-claim checkpoint short-circuits the attribution and the sync is a pure no-op
    function test_Waterfall_zeroDeltaShortCircuitsAttribution() public {
        _seedState(1000e18, 200e18, 980e18, 220e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1000e18)), toNAVUnits(uint256(200e18)));
        assertEq(toUint256(state.stEffectiveNAV), 980e18, "st effective NAV unchanged");
        assertEq(toUint256(state.jtEffectiveNAV), 220e18, "jt effective NAV unchanged");
        assertEq(toUint256(state.stProtocolFee) + toUint256(state.jtProtocolFee) + toUint256(state.ltProtocolFee), 0, "no fees on a flat sync");
    }

    /**
     * D1c: a junior raw delta against lastJTRawNAV == 0 short-circuits without a division-by-zero panic
     * NOTE the claim == 0 and lastRaw == 0 short-circuits coincide on the public surface: conservation bounds
     * stClaimOnJTRaw = stEff - stRaw = jtRaw - jtEff <= jtRaw, so a zero junior raw NAV forces a zero senior claim on it
     */
    function test_Waterfall_zeroLastJTRawShortCircuitsAttribution() public {
        _seedState(1000e18, 0, 1000e18, 0, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1000e18)), toNAVUnits(uint256(50e18)));
        assertEq(toUint256(state.stEffectiveNAV), 1000e18, "nothing attributed to st from the fresh junior value");
        assertEq(toUint256(state.jtEffectiveNAV), 50e18, "the junior delta lands wholly on jt");
        assertEq(toUint256(state.jtProtocolFee), 5e18, "junior net-gain fee taken");
    }

    /**
     * D1d: floor-split additivity on junior raw gains — ST takes exactly its floored proportional share of the
     * delta, JT absorbs the rounding residual, and the split always sums to the full delta
     */
    function testFuzz_Waterfall_attributionFloorSplitAdditivity_jtGain(uint256 _cross, uint256 _gain) public {
        // Bounds: the cross-claim spans [0, jtRaw/2] so the seeding loss stays fully covered and clear of the
        // liquidation disjunct, and the gain spans [0, 1e30] (the strategy magnitude bound); both uniform via bound
        _cross = bound(_cross, 0, 150e18);
        _gain = bound(_gain, 0, 1e30);
        uint256 stRaw = 1000e18;
        uint256 jtRaw = 300e18;
        _seedState(stRaw, jtRaw, stRaw + _cross, jtRaw - _cross, 0, SEED_LT_RAW, MarketState.PERPETUAL);

        // Independent floor math: ST's claim on the junior raw NAV is the cross-claim
        uint256 expectedAttrToST = (_gain * _cross) / jtRaw;

        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(stRaw), toNAVUnits(jtRaw + _gain));
        assertLe(expectedAttrToST, _gain, "attributed magnitude bounded by the delta");
        assertEq(toUint256(state.stEffectiveNAV), stRaw + _cross + expectedAttrToST, "st takes exactly its floored share");
        assertEq(toUint256(state.jtEffectiveNAV), jtRaw - _cross + (_gain - expectedAttrToST), "jt absorbs the rounding residual");
        assertEq(toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV), stRaw + jtRaw + _gain, "additivity: the split sums to the delta");
    }

    /*----------------------------------------------------------------------
                        D3 — JT leg
    ----------------------------------------------------------------------*/

    /**
     * D3a + D1d loss side: junior raw losses never underflow the junior effective NAV from any cross-claim
     * checkpoint — a panic anywhere in this sweep is a REAL finding — and the final NAVs match an independent
     * floor-and-min waterfall model
     */
    function testFuzz_Waterfall_jtLossAttributionNeverUnderflows(uint256 _cross, uint256 _loss) public {
        // Bounds: the cross-claim spans [0, jtRaw/2] to keep the seed reachable, the loss spans the entire junior
        // raw NAV [0, jtRaw] to probe the exhaustion boundary; both uniform via bound
        _cross = bound(_cross, 0, 150e18);
        _loss = bound(_loss, 0, 300e18);
        uint256 stRaw = 1000e18;
        uint256 jtRaw = 300e18;
        _seedState(stRaw, jtRaw, stRaw + _cross, jtRaw - _cross, _cross, SEED_LT_RAW, _cross > 0 ? MarketState.FIXED_TERM : MarketState.PERPETUAL);

        // Independent model: floored attribution, junior absorbs its residual loss, coverage = min(st loss, jt buffer)
        uint256 attrToST = (_loss * _cross) / jtRaw;
        uint256 jtResidualLoss = _loss - attrToST;
        uint256 jtEffAfterLoss = (jtRaw - _cross) - jtResidualLoss;
        uint256 coverageApplied = attrToST < jtEffAfterLoss ? attrToST : jtEffAfterLoss;
        uint256 expectedJTEff = jtEffAfterLoss - coverageApplied;
        uint256 expectedSTEff = (stRaw + _cross) - (attrToST - coverageApplied);

        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(stRaw), toNAVUnits(jtRaw - _loss));
        assertEq(toUint256(state.jtEffectiveNAV), expectedJTEff, "jt effective NAV vs independent model");
        assertEq(toUint256(state.stEffectiveNAV), expectedSTEff, "st effective NAV vs independent model");
        assertEq(toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV), stRaw + jtRaw - _loss, "conservation under junior losses");
    }

    /**
     * D3b: the junior net-gain fee gates on strict dust excess — a gain of exactly the effective dust tolerance
     * takes no fee, one wei more takes the floored fee
     * Derivation with dust tolerances st 30 + jt 40 = 70: gain 70 -> no fee, then gain 71 -> floor(71 * 0.1e18 / 1e18) = 7
     */
    function test_Waterfall_jtGainFeeDustBoundary() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(30));
        p.jtNAVDustTolerance = toNAVUnits(uint256(40));
        _deploy(false, p);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 70));
        assertEq(toUint256(state.jtProtocolFee), 0, "gain equal to the dust tolerance takes no fee");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 70, "gain NAV still booked");
        state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 141));
        assertEq(toUint256(state.jtProtocolFee), 7, "one wei above dust takes the floored fee");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 141, "gain NAV booked in full, fee not NAV-deducted");
    }

    /**
     * D3b: junior net-gain fee floor exactness at an awkward value
     * Derivation: floor(12345678901234567 * 0.1e18 / 1e18) = 1234567890123456 (the trailing 7 truncates)
     */
    function test_Waterfall_jtGainFeeFloorExactness() public {
        _seedAndInitAccrual();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 12_345_678_901_234_567));
        assertEq(toUint256(state.jtProtocolFee), 1_234_567_890_123_456, "fee floors the awkward product");
    }

    /*----------------------------------------------------------------------
                D4 — JT fee recomputation after coverage
    ----------------------------------------------------------------------*/

    /// @dev Deploys a permanently-perpetual market (zero fixed-term duration) so fee fields survive loss syncs observably
    function _deployPermanentlyPerpetual(uint256 _stDust, uint256 _jtDust) internal {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.fixedTermDurationSeconds = 0;
        p.stNAVDustTolerance = toNAVUnits(_stDust);
        p.jtNAVDustTolerance = toNAVUnits(_jtDust);
        _deploy(false, p);
    }

    /**
     * D4 arm 1: coverage eats part of the junior gain and the fee is recomputed on the reduced net gain
     * Derivation (permanently perpetual so the fee is observable): jt gain 50e18 books fee 5e18, coverage 20e18
     * recomputes jtNetGain = 30e18 > 0 dust so jtFee = floor(30e18 * 0.1e18 / 1e18) = 3e18; jtEff = 230e18, il erased
     */
    function test_Waterfall_jtFeeRecomputedOnReducedNetGain() public {
        _deployPermanentlyPerpetual(0, 0);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(20e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(980e18)), toNAVUnits(uint256(250e18)));
        assertEq(toUint256(state.jtProtocolFee), 3e18, "fee recomputed on the post-coverage net gain");
        assertEq(toUint256(state.jtEffectiveNAV), 230e18, "jt effective NAV nets the gain against coverage");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "permanently-perpetual erases the il");
    }

    /**
     * D4 arm 2: the recomputed net gain at or below dust zeroes the fee
     * Derivation with dust 30 + 40 = 70: jt gain 100 books fee 10, coverage 40 recomputes jtNetGain = 60 <= 70 -> fee 0
     */
    function test_Waterfall_jtFeeZeroedWhenReducedNetGainWithinDust() public {
        _deployPermanentlyPerpetual(30, 40);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW - 40), toNAVUnits(SEED_JT_RAW + 100));
        assertEq(toUint256(state.jtProtocolFee), 0, "fee zeroed once the reduced net gain is dust");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 60, "jt nets the gain against the covered loss");
    }

    /**
     * D4 arm 3: coverage exceeding the junior gain saturates the net gain to zero and zeroes the fee
     * Derivation: jt gain 20e18 books fee 2e18, coverage 50e18 saturates jtNetGain to 0 -> fee 0; jtEff = 170e18
     */
    function test_Waterfall_jtFeeZeroedWhenCoverageExceedsGain() public {
        _deployPermanentlyPerpetual(0, 0);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(950e18)), toNAVUnits(uint256(220e18)));
        assertEq(toUint256(state.jtProtocolFee), 0, "fee zeroed on a saturated net gain");
        assertEq(toUint256(state.jtEffectiveNAV), 170e18, "jt effective NAV nets gain against the larger coverage");
    }

    /**
     * D4 guard: with no fee booked on the junior gain (gain within dust), coverage skips the recomputation entirely
     * Derivation with dust 70: jt gain 50 books no fee, coverage 30 leaves the fee at zero; jtEff = 200e18 + 20
     */
    function test_Waterfall_jtFeeRecomputationSkippedWithoutPriorFee() public {
        _deployPermanentlyPerpetual(30, 40);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW - 30), toNAVUnits(SEED_JT_RAW + 50));
        assertEq(toUint256(state.jtProtocolFee), 0, "no prior fee so nothing to recompute");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 20, "gain netted against coverage");
    }

    /*----------------------------------------------------------------------
                D5 — ST loss coverage regimes
    ----------------------------------------------------------------------*/

    /**
     * D5: partial coverage with a residual senior loss — coverage is capped by the junior buffer
     * Derivation: st loss 250e18, coverage = min(250e18, 200e18) = 200e18 exhausts jt (jtEff = 0, il = 200e18),
     * residual 50e18 hits st (stEff = 950e18). The wipeout disjunct then forces PERPETUAL and erases the il
     */
    function test_Waterfall_partialCoverageResidualLossHitsST() public {
        _seedAndInitAccrual();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(200e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(750e18)), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.stEffectiveNAV), 950e18, "st bears only the uncovered residual");
        assertEq(toUint256(state.jtEffectiveNAV), 0, "jt buffer fully consumed");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il erased by the wipeout transition");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "wipeout forces perpetual");
    }

    /**
     * D5: a zero junior buffer provides no coverage — the coverageApplied != 0 guard takes the false arm
     * Derivation: jtEff 0, st loss 100e18 lands entirely on st (stEff = 900e18), il stays 0
     */
    function test_Waterfall_zeroJTBufferProvidesNoCoverage() public {
        _seedState(1000e18, 0, 1000e18, 0, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(900e18)), ZERO_NAV_UNITS);
        assertEq(toUint256(state.stEffectiveNAV), 900e18, "uncovered loss hits st in full");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "no coverage so no il accrues");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "market stays perpetual");
    }

    /*----------------------------------------------------------------------
                D6 — ST gain: recovery, premiums, fees
    ----------------------------------------------------------------------*/

    /**
     * D6a: a gain equal to the il recovers it exactly, pays no premium or fee, and ends the fixed term
     * Derivation: gain 100e18 == il 100e18 -> il = 0, jtEff = 300e18, residual gain 0 so the premium block is
     * skipped, and the organic recovery emits no il reset event (nothing is erased)
     */
    function test_Waterfall_ilRecoveryExactGainEndsFixedTerm() public {
        _seedMatrixLargeIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1000e18)), toNAVUnits(uint256(300e18)));
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il fully recovered");
        assertEq(toUint256(state.jtEffectiveNAV), 300e18, "recovery credited to jt");
        assertEq(toUint256(state.stEffectiveNAV), 1000e18, "st effective NAV unchanged");
        assertEq(toUint256(state.jtProtocolFee) + toUint256(state.stProtocolFee) + toUint256(state.ltProtocolFee), 0, "no fee on pure recovery");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "recovered market returns to perpetual");
    }

    /**
     * D6a + D6b: a gain above the il pays premiums only on the residual, via the instantaneous branch with the
     * FIXED_TERM initial state and last-committed checkpoint utilizations as the exact YDM preview arguments
     * Derivation: gain 150e18, recovery 100e18 leaves stGain 50e18; checkpoint utils covUtil = ceil(900e18 * 0.1e18
     * / 200e18) = 0.45e18 and liqUtil = ceil(1000e18 * 0.05e18 / 100e18) = 0.5e18; premiums 5e18 / 2.5e18, fees kept
     * because the recovered market lands PERPETUAL: jtFee 0.5e18, ltFee 0.25e18, stFee = floor(42.5e18 * 0.1) = 4.25e18
     */
    function test_Waterfall_ilRecoveryThenPremiumOnResidualWithExactYDMArgs() public {
        _seedMatrixLargeIL();
        vm.expectCall(address(jtYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.FIXED_TERM, 0.45e18)));
        vm.expectCall(address(ltYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.FIXED_TERM, 0.5e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(300e18)));
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il fully recovered first");
        assertEq(toUint256(state.jtEffectiveNAV), 305e18, "recovery plus the risk premium on the residual only");
        assertEq(toUint256(state.ltLiquidityPremium), 2.5e18, "liquidity premium on the residual only");
        assertEq(toUint256(state.stEffectiveNAV), 1045e18, "st retains residual plus the premium carve-out");
        assertEq(toUint256(state.jtProtocolFee), 0.5e18, "jt yield-share fee kept in the resulting perpetual state");
        assertEq(toUint256(state.ltProtocolFee), 0.25e18, "lt fee kept");
        assertEq(toUint256(state.stProtocolFee), 4.25e18, "st fee on the retained residual");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "full recovery ends the fixed term");
    }

    /**
     * D6b: the same-block instantaneous branch queries previewYieldShare with the initial market state and
     * last-committed checkpoint utilizations, and prices the premium at the preview rate over a forced 1s window
     * Derivation: gain 100e18 at preview rates 0.07e18 / 0.03e18 -> premiums 7e18 / 3e18
     */
    function test_Waterfall_instantaneousPremiumUsesPreviewRatesWithCheckpointArgs() public {
        _seedAndInitAccrual();
        jtYDM.setPreviewYieldShareReturn(0.07e18);
        ltYDM.setPreviewYieldShareReturn(0.03e18);
        vm.expectCall(address(jtYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.PERPETUAL, SEED_COV_UTIL_WAD)));
        vm.expectCall(address(ltYDM), abi.encodeCall(IYDM.previewYieldShare, (MarketState.PERPETUAL, SEED_LIQ_UTIL_WAD)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 7e18, "instantaneous jt risk premium");
        assertEq(toUint256(state.ltLiquidityPremium), 3e18, "instantaneous lt liquidity premium");
    }

    /// D6b: the instantaneous branch caps hostile preview rates at the configured maximum yield shares
    function test_Waterfall_instantaneousPremiumCapsHostilePreviewRates() public {
        _seedAndInitAccrual();
        jtYDM.setPreviewYieldShareReturn(WAD);
        ltYDM.setPreviewYieldShareReturn(WAD);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        // Capped at maxJT 0.2e18 and maxLT 0.1e18: premiums floor(100e18 * 0.2) = 20e18 and floor(100e18 * 0.1) = 10e18
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 20e18, "jt premium capped at maxJTYieldShareWAD");
        assertEq(toUint256(state.ltLiquidityPremium), 10e18, "lt premium capped at maxLTYieldShareWAD");
    }

    /**
     * D6b: with an elapsed premium window the time-weighted accumulators price the premium and the hostile preview
     * rates are never consulted (they would cap to 20e18 / 10e18 if the instantaneous branch ran)
     * Derivation: rates 0.15e18 / 0.05e18 over 1000s: twJT = 150e18, jtPrem = floor(100e18 * 150e18 / (1000 * 1e18)) = 15e18, ltPrem = 5e18
     */
    function test_Waterfall_elapsedPremiumUsesTimeWeightedAccumulators() public {
        _seedAndInitAccrual();
        jtYDM.setYieldShareReturn(0.15e18);
        ltYDM.setYieldShareReturn(0.05e18);
        jtYDM.setPreviewYieldShareReturn(WAD);
        ltYDM.setPreviewYieldShareReturn(WAD);
        vm.warp(block.timestamp + 1000);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 15e18, "time-weighted jt risk premium");
        assertEq(toUint256(state.ltLiquidityPremium), 5e18, "time-weighted lt liquidity premium");
    }

    /**
     * D6c: the premiumsPaid gate is a strict dust comparison — a dust-sized gain still pays premium NAV but takes
     * no fees and leaves the accrual window intact, while one wei more takes fees and resets the window
     * Derivation with dust 30 + 40 = 70, rates 0.1e18 / 0.05e18 over 100s (twJT 10e18, twLT 5e18):
     *   gain 70: jtPrem = floor(70 * 10e18 / (100 * 1e18)) = 7, ltPrem = floor(70 * 5e18 / 100e18) = 3, no fees, no reset
     *   The 7 wei phase-one premium leaves jtEff = jtRaw + 7, a 7 wei JT cross-claim on the senior raw NAV, so the
     *   next attribution floor skims 1 wei of the senior delta to JT: a raw gain of 72 attributes
     *   floor(72 * ((1000e18 + 70) - 7) / (1000e18 + 70)) = 71 to ST (the dust + 1 senior gain) and 1 wei to JT
     *   Then over a further 50s (tw compounds un-reset to 15e18 / 7.5e18, window 150s), senior gain 71:
     *   jtPrem = floor(71 * 15e18 / 150e18) = 7, ltPrem = floor(71 * 7.5e18 / 150e18) = 3, stFee = floor(61 * 0.1) = 6
     *   (the jt and lt fee floors are 0 at this magnitude, and the 1 wei jt gain is below dust so it takes no fee),
     *   jtEff = jtRaw + 7 + 1 + 7 = jtRaw + 15, accumulators reset and the premium clock advances to windowStart + 150
     */
    function test_Waterfall_premiumsPaidDustGateBothSides() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(30));
        p.jtNAVDustTolerance = toNAVUnits(uint256(40));
        _deploy(false, p);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        uint32 windowStart = uint32(block.timestamp);
        jtYDM.setYieldShareReturn(0.1e18);
        ltYDM.setYieldShareReturn(0.05e18);

        vm.warp(block.timestamp + 100);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 70), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 7, "dust-sized gain still pays the jt premium NAV");
        assertEq(toUint256(state.ltLiquidityPremium), 3, "dust-sized gain still pays the lt premium NAV");
        assertEq(toUint256(state.stProtocolFee) + toUint256(state.jtProtocolFee) + toUint256(state.ltProtocolFee), 0, "no fees at or below dust");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.twJTYieldShareAccruedWAD, 10e18, "accumulator not reset at the dust boundary");
        assertEq(s.lastPremiumPaymentTimestamp, windowStart, "premium clock untouched at the dust boundary");

        vm.warp(block.timestamp + 50);
        state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 142), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 15, "compounded window premium plus the attributed wei on the second gain");
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
     * D6d: premium floor exactness at awkward prime-adjacent values against independent 256-bit floor math
     * Derivation: prem = floor(gain * (rate * elapsed) / (elapsed * 1e18)) with gain 999999999999999937 (prime),
     * elapsed 3607 (prime), rates 123456789012345677 and 98765432109876543 (both below their caps)
     */
    function test_Waterfall_premiumFloorExactnessAtAwkwardValues() public {
        _seedAndInitAccrual();
        uint256 rateJT = 123_456_789_012_345_677;
        uint256 rateLT = 98_765_432_109_876_543;
        uint256 elapsed = 3607;
        uint256 gain = 999_999_999_999_999_937;
        jtYDM.setYieldShareReturn(rateJT);
        ltYDM.setYieldShareReturn(rateLT);
        vm.warp(block.timestamp + elapsed);
        uint256 expectedJTPremium = (gain * (rateJT * elapsed)) / (elapsed * WAD);
        uint256 expectedLTPremium = (gain * (rateLT * elapsed)) / (elapsed * WAD);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + gain), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + expectedJTPremium, "jt premium floors exactly");
        assertEq(toUint256(state.ltLiquidityPremium), expectedLTPremium, "lt premium floors exactly");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW + gain - expectedJTPremium, "st keeps the residual plus the lt premium carve-out");
    }

    /**
     * D6e: the zero-premium guards take their false arms independently — a zero jt premium skips the jt yield-share
     * fee entirely while a nonzero lt premium still pays, and vice versa
     */
    function test_Waterfall_zeroPremiumGuardBranchesBothSides() public {
        _seedAndInitAccrual();
        // Side 1: jt rate 0, lt rate 0.05e18 on a 100e18 gain: ltPrem 5e18 (fee 0.5e18), stFee = floor(95e18 * 0.1) = 9.5e18
        jtYDM.setPreviewYieldShareReturn(0);
        ltYDM.setPreviewYieldShareReturn(0.05e18);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1100e18)), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW, "zero jt premium leaves jt untouched");
        assertEq(toUint256(state.jtProtocolFee), 0, "no jt yield-share fee without a premium");
        assertEq(toUint256(state.ltLiquidityPremium), 5e18, "lt premium still paid");
        assertEq(toUint256(state.ltProtocolFee), 0.5e18, "lt fee on its premium");
        assertEq(toUint256(state.stProtocolFee), 9.5e18, "st fee on the retained gain");
        assertEq(toUint256(state.stEffectiveNAV), 1100e18, "st retains gain plus the lt carve-out");
        // Side 2 (same block, fresh premium window): jt rate 0.1e18, lt rate 0 on another 100e18 gain
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0);
        state = kernel.doPreOp(toNAVUnits(uint256(1200e18)), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 10e18, "jt premium paid");
        assertEq(toUint256(state.jtProtocolFee), 1e18, "jt yield-share fee on its premium");
        assertEq(toUint256(state.ltLiquidityPremium), 0, "zero lt premium");
        assertEq(toUint256(state.ltProtocolFee), 0, "no lt fee without a premium");
        assertEq(toUint256(state.stProtocolFee), 9e18, "st fee on the 90e18 residual");
    }

    /**
     * D6f: LT premium coverage-neutrality — an identical market with a zero lt share produces byte-identical
     * senior and junior effective NAVs and coverage utilization: the premium only re-labels senior-retained value
     */
    function test_Waterfall_ltPremiumCoverageNeutralViaCounterfactual() public {
        _seedMatrixNoIL();
        SyncedAccountingState memory withLT = kernel.doPreOp(toNAVUnits(uint256(1050e18)), toNAVUnits(SEED_JT_RAW));

        // Counterfactual: fresh identical deployment and seed with the lt share zeroed
        _deploy(false, _defaultParams());
        _seedAndInitAccrual();
        jtYDM.setPreviewYieldShareReturn(0.1e18);
        ltYDM.setPreviewYieldShareReturn(0);
        SyncedAccountingState memory withoutLT = kernel.doPreOp(toNAVUnits(uint256(1050e18)), toNAVUnits(SEED_JT_RAW));

        assertEq(toUint256(withLT.stEffectiveNAV), toUint256(withoutLT.stEffectiveNAV), "st effective NAV identical: premium stays inside stEff");
        assertEq(toUint256(withLT.jtEffectiveNAV), toUint256(withoutLT.jtEffectiveNAV), "jt effective NAV untouched by the lt premium");
        assertEq(withLT.coverageUtilizationWAD, withoutLT.coverageUtilizationWAD, "coverage utilization identical");
        assertEq(toUint256(withLT.ltLiquidityPremium), 2.5e18, "factual lt premium paid");
        assertEq(toUint256(withoutLT.ltLiquidityPremium), 0, "counterfactual pays none");
        assertEq(toUint256(withLT.stProtocolFee), 4.25e18, "st fee shrinks by the premium carve-out");
        assertEq(toUint256(withoutLT.stProtocolFee), 4.5e18, "counterfactual st fee on the full residual");
    }

    /// @dev Stratified hostile YDM output: a third sub-WAD, a third between WAD and 1e24, a third the uint256 maximum
    function _strataRate(uint256 _seed) internal pure returns (uint256) {
        uint256 strata = _seed % 3;
        if (strata == 0) return bound(_seed, 0, WAD);
        if (strata == 1) return bound(_seed, WAD, 1e24);
        return type(uint256).max;
    }

    /**
     * D6g: PREMIUMS_EXCEED_SENIOR_YIELD is unreachable — with the yield shares capped at accrual and the caps
     * summing to exactly WAD, hostile YDM outputs (up to uint256 max) can never push the combined premiums past
     * the senior gain on either the time-weighted or the instantaneous branch. Any revert here is a REAL finding
     */
    function testFuzz_Waterfall_premiumsNeverExceedSeniorYield(uint256 _rateJT, uint256 _rateLT, uint256 _elapsed, uint256 _gain1, uint256 _gain2) public {
        // Deploy at the joint cap maxJT + maxLT == WAD, the tightest legal configuration
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.maxJTYieldShareWAD = 0.6e18;
        p.maxLTYieldShareWAD = 0.4e18;
        _deploy(false, p);
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

        // Time-weighted branch
        SyncedAccountingState memory first = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + _gain1), toNAVUnits(SEED_JT_RAW));
        uint256 jtPremium = toUint256(first.jtEffectiveNAV) - SEED_JT_RAW;
        assertLe(jtPremium + toUint256(first.ltLiquidityPremium), _gain1, "time-weighted premiums bounded by the senior gain");

        // Instantaneous branch: a second gain in the same block right after the premium payment
        SyncedAccountingState memory second = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + _gain1 + _gain2), toNAVUnits(SEED_JT_RAW));
        uint256 jtPremium2 = toUint256(second.jtEffectiveNAV) - toUint256(first.jtEffectiveNAV);
        assertLe(jtPremium2 + toUint256(second.ltLiquidityPremium), _gain2, "instantaneous premiums bounded by the senior gain");
    }

    /**
     * D7: exact two-term NAV conservation on every committed sync from any reachable cross-claim checkpoint —
     * the NAV_CONSERVATION_VIOLATION revert arm is unreachable from conserved checkpoints (a revert or a drift
     * of even one wei here is a REAL finding)
     */
    function testFuzz_Waterfall_conservationOnEveryCommittedSync(
        uint256 _stRaw0,
        uint256 _jtRaw0,
        uint256 _cross,
        uint256 _stRaw1,
        uint256 _jtRaw1,
        uint256 _elapsed
    )
        public
    {
        // Bounds: raw NAVs within the 1e30 strategy magnitude bound; jtRaw0 at least half of stRaw0 and the
        // cross-claim capped at half of jtRaw0 keep the seeding loss fully covered and clear of the liquidation
        // and wipeout disjuncts; the fresh NAVs sweep [0, 2x] around the checkpoint; all uniform via bound
        _stRaw0 = bound(_stRaw0, 1e18, 1e30);
        _jtRaw0 = bound(_jtRaw0, _stRaw0 / 2 + 1, 1e30);
        _cross = bound(_cross, 0, _jtRaw0 / 2);
        _stRaw1 = bound(_stRaw1, 0, _stRaw0 * 2);
        _jtRaw1 = bound(_jtRaw1, 0, _jtRaw0 * 2);
        _elapsed = bound(_elapsed, 0, 365 days);
        _seedState(_stRaw0, _jtRaw0, _stRaw0 + _cross, _jtRaw0 - _cross, _cross, SEED_LT_RAW, _cross > 0 ? MarketState.FIXED_TERM : MarketState.PERPETUAL);
        jtYDM.setRates(0.2e18);
        ltYDM.setRates(0.1e18);
        vm.warp(block.timestamp + _elapsed);

        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(_stRaw1), toNAVUnits(_jtRaw1));
        assertEq(toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV), _stRaw1 + _jtRaw1, "returned state conserves NAV exactly");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV), _stRaw1 + _jtRaw1, "committed checkpoint conserves NAV exactly");
    }

    /*//////////////////////////////////////////////////////////////////////
                            E — STATE MACHINE
    //////////////////////////////////////////////////////////////////////*/

    /// @dev Counts logs emitted by the accountant whose topic0 matches the given event selector
    function _countAccountantLogs(Vm.Log[] memory _logs, bytes32 _topic0) internal view returns (uint256 count) {
        for (uint256 i; i < _logs.length; ++i) {
            if (_logs[i].emitter == address(accountant) && _logs[i].topics.length > 0 && _logs[i].topics[0] == _topic0) count++;
        }
    }

    /**
     * E1: a zero fixed-term duration configured at initialization keeps the market permanently perpetual — a
     * covered loss with il far above dust is erased on the sync with an exact reset event and never commences a term
     */
    function test_StateMachine_zeroDurationConfigNeverEntersFixedTerm() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.fixedTermDurationSeconds = 0;
        _deploy(false, p);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(50e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(950e18)), toNAVUnits(SEED_JT_RAW));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "permanently perpetual despite the covered loss");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il erased on the sync");
        assertEq(toUint256(state.jtEffectiveNAV), 150e18, "coverage still applied to jt");
        assertEq(state.fixedTermEndTimestamp, 0, "no fixed term end stamped");
        assertEq(_countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.FixedTermCommenced.selector), 0, "no term ever commences");
    }

    /**
     * E2: the fixed term ends at the exact end == now boundary — the disjunct is an inclusive comparison
     * Events in emission order: FixedTermEnded from the transition, then the il reset of the full 100e18
     */
    function test_StateMachine_fixedTermEndsAtExactBoundary() public {
        _seedMatrixLargeIL();
        uint32 end = uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS);
        vm.warp(end);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(100e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(900e18)), toNAVUnits(uint256(300e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "term ends exactly at its end timestamp");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il erased when the term elapses");
        assertEq(state.fixedTermEndTimestamp, 0, "end timestamp deleted");
        assertEq(accountant.getState().fixedTermEndTimestamp, 0, "committed end timestamp deleted");
    }

    /// E2: one second before the end the fixed term persists with the il and end timestamp intact
    function test_StateMachine_fixedTermPersistsJustBeforeEnd() public {
        _seedMatrixLargeIL();
        uint32 end = uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS);
        vm.warp(end - 1);
        vm.recordLogs();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(900e18)), toNAVUnits(uint256(300e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "term persists one second before its end");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 100e18, "il persists through the term");
        assertEq(state.fixedTermEndTimestamp, end, "end timestamp unchanged");
        assertEq(_countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.FixedTermEnded.selector), 0, "no end event before the boundary");
    }

    /// E2: well beyond the end timestamp the elapsed-term disjunct still fires
    function test_StateMachine_fixedTermEndsBeyondBoundary() public {
        _seedMatrixLargeIL();
        vm.warp(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS + 12_345);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(900e18)), toNAVUnits(uint256(300e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "term ended after the end timestamp passed");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il erased");
        assertEq(state.fixedTermEndTimestamp, 0, "end timestamp deleted");
    }

    /**
     * E3: the liquidation disjunct fires at exactly covUtil == threshold, crafted with an exact division
     * Derivation: a 130e18 senior raw loss is fully covered so jtEff = 70e18 and stRaw = 770e18:
     * covUtil = ceil(770e18 * 0.1e18 / 70e18) = 1.1e18 exactly (77 / 70 divides at WAD precision), so the
     * would-be il of 230e18 is erased and the market is forced perpetual mid fixed term
     */
    function test_StateMachine_liquidationUtilizationExactBoundaryForcesPerpetual() public {
        _seedMatrixLargeIL();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(230e18)));
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(770e18)), toNAVUnits(uint256(300e18)));
        assertEq(state.coverageUtilizationWAD, DEFAULT_LIQUIDATION_UTILIZATION_WAD, "coverage utilization lands exactly on the threshold");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "liquidation breach forces perpetual");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il erased even mid fixed term");
        assertEq(toUint256(state.jtEffectiveNAV), 70e18, "coverage applied before the transition");
        assertEq(toUint256(state.stEffectiveNAV), 1000e18, "st fully covered");
        assertEq(state.fixedTermEndTimestamp, 0, "end timestamp deleted");
    }

    /**
     * E3: just below the liquidation threshold the fixed term persists
     * Derivation: a 120e18 covered loss leaves jtEff = 80e18 and covUtil = ceil(780e18 * 0.1e18 / 80e18) = 0.975e18 < 1.1e18
     */
    function test_StateMachine_belowLiquidationThresholdStaysFixedTerm() public {
        _seedMatrixLargeIL();
        uint32 end = uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(780e18)), toNAVUnits(uint256(300e18)));
        assertEq(state.coverageUtilizationWAD, 0.975e18, "coverage utilization below the threshold");
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "term persists below the liquidation threshold");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 220e18, "il accumulates instead of erasing");
        assertEq(state.fixedTermEndTimestamp, end, "end timestamp kept");
    }

    /**
     * E4: the wipeout disjunct in true isolation — the senior raw NAV collapses to zero so the coverage
     * utilization reads 0 (no exposure) and cannot be the trigger, leaving jtEff == 0 && stEff > 0 as the only
     * firing disjunct
     * Derivation from checkpoint (0, 300e18, 100e18, 200e18, il 100e18) with jtRaw -> 1 wei:
     *   attrST = -floor(299999999999999999999 / 3) = -99999999999999999999, jt residual loss = 200e18 exactly
     *   so jtEff = 0, the 99999999999999999999 st loss is uncovered leaving stEff = 1 wei
     */
    function test_StateMachine_wipeoutDisjunctInIsolation() public {
        _seedState(0, 300e18, 100e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(toNAVUnits(uint256(100e18)));
        SyncedAccountingState memory state = kernel.doPreOp(ZERO_NAV_UNITS, toNAVUnits(uint256(1)));
        assertEq(toUint256(state.stEffectiveNAV), 1, "st retains a single wei of live claim");
        assertEq(toUint256(state.jtEffectiveNAV), 0, "jt wiped out");
        assertEq(state.coverageUtilizationWAD, 0, "no exposure so the liquidation disjunct cannot be the trigger");
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "wipeout alone forces perpetual");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il erased");
    }

    /**
     * E4 pin: a fully empty market (both effective NAVs zero) does NOT trip the wipeout disjunct — with il above
     * dust the other branches keep it in FIXED_TERM
     */
    function test_StateMachine_emptyMarketDoesNotForcePerpetual() public {
        _seedState(0, 300e18, 100e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        uint32 end = uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS);
        SyncedAccountingState memory state = kernel.doPreOp(ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        assertEq(toUint256(state.stEffectiveNAV), 0, "st effective NAV empties");
        assertEq(toUint256(state.jtEffectiveNAV), 0, "jt effective NAV empties");
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "empty market stays in its term");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 100e18, "il persists in the empty market");
        assertEq(state.fixedTermEndTimestamp, end, "end timestamp kept");
    }

    /**
     * E5: a dust-sized il in a PERPETUAL market persists un-erased across syncs and recovers organically on the
     * next gain without any reset event
     */
    function test_StateMachine_dustILPersistsInPerpetualAndRecovers() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(30));
        p.jtNAVDustTolerance = toNAVUnits(uint256(40));
        _deploy(false, p);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        // Covered loss of 50 wei: il = 50 <= dust 70 stays PERPETUAL with the il persisted for later recovery
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW - 50), toNAVUnits(SEED_JT_RAW));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "dust il never enters a fixed term");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 50, "dust il persists, not erased");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW - 50, "coverage applied");
        // Organic recovery on the next gain, with no il reset event
        vm.recordLogs();
        state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "dust il recovered by the gain");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW, "jt made whole");
        assertEq(
            _countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset.selector),
            0,
            "organic recovery is not an il reset"
        );
    }

    /**
     * E5: a FIXED_TERM market that recovers down to 0 < il <= dust stays FIXED_TERM (stickiness) with fees and
     * the lt premium zeroed, then transitions to PERPETUAL with FixedTermEnded only once the il reaches exactly zero
     * Derivation (dust 30 + 40 = 70): a covered 100e18 loss enters the term; then a mixed sync with
     * dST = +(90e18 - 50) and dJT = +20e18 attributes floor(20e18 * 100e18 / 200e18) = 10e18 of the jt gain to st,
     * so the st-side gain is exactly 100e18 - 50 and recovery leaves il = 50 (jt keeps its 10e18 residual gain,
     * fee zeroed); a final 50 wei gain zeroes the il and ends the term
     */
    function test_StateMachine_fixedTermStickyWithDustILThenEndsAtZero() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(30));
        p.jtNAVDustTolerance = toNAVUnits(uint256(40));
        _deploy(false, p);
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        // Enter the fixed term on a covered 100e18 loss
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(900e18)), toNAVUnits(SEED_JT_RAW));
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "loss above dust enters the term");
        uint32 end = state.fixedTermEndTimestamp;
        // Recover into the dust band: stays FIXED_TERM, jt gain NAV kept, its fee zeroed
        state = kernel.doPreOp(toNAVUnits(uint256(990e18 - 50)), toNAVUnits(uint256(220e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "dust il keeps the term sticky");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 50, "il recovered into the dust band");
        assertEq(toUint256(state.jtEffectiveNAV), 210e18 - 50, "recovery plus the jt residual gain");
        assertEq(toUint256(state.jtProtocolFee), 0, "jt fee zeroed while the term is sticky");
        assertEq(state.fixedTermEndTimestamp, end, "end timestamp kept");
        // Full recovery to exactly zero il ends the term
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermEnded();
        state = kernel.doPreOp(toNAVUnits(uint256(990e18)), toNAVUnits(uint256(220e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "zero il ends the sticky term");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "il fully recovered");
        assertEq(state.fixedTermEndTimestamp, 0, "end timestamp deleted");
    }

    /**
     * E6: fixed-term entry stamps end = now + duration with an exact FixedTermCommenced, and a re-sync inside the
     * term keeps the ORIGINAL end with no transition event even as the il deepens
     */
    function test_StateMachine_fixedTermEntrySetsEndOnceAndKeepsOriginal() public {
        _seedAndInitAccrual();
        uint32 expectedEnd = uint32(block.timestamp + DEFAULT_FIXED_TERM_DURATION_SECONDS);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.FixedTermCommenced(expectedEnd);
        kernel.doPreOp(toNAVUnits(uint256(950e18)), toNAVUnits(SEED_JT_RAW));
        assertEq(accountant.getState().fixedTermEndTimestamp, expectedEnd, "entry stamps now plus duration");
        // A deeper covered loss 1000 seconds later keeps the original end and emits no transition event
        vm.warp(block.timestamp + 1000);
        vm.recordLogs();
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(940e18)), toNAVUnits(SEED_JT_RAW));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 0, "no re-entry event inside the term");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 0, "no exit event inside the term");
        assertEq(state.fixedTermEndTimestamp, expectedEnd, "original end kept on re-sync");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 60e18, "il deepened inside the term");
    }

    /**
     * E7: the FIXED_TERM zeroing asymmetry — a junior net gain earned in the term-entering sync keeps its full
     * NAV in jtEff (including the value the protocol would have fee'd) while the protocol fee itself is zeroed
     *
     * NOTE map correction: a nonzero jtRiskPremium in a FIXED_TERM-landing sync is unreachable — any premium
     * requires a residual senior gain, which requires the coverage impermanent loss to have fully recovered to
     * zero, which lands the sync in PERPETUAL where fees are kept. The kept-NAV / zeroed-fee asymmetry is
     * therefore pinned via the junior net gain, the only premium-like NAV that can coexist with a resulting term
     */
    function test_StateMachine_fixedTermZeroingKeepsJTGainNAVWhileZeroingFee() public {
        _seedAndInitAccrual();
        // dST = -10e18, dJT = +50e18: the jt fee books 5e18 and recomputes to 4e18 on the post-coverage 40e18 net
        // gain, then the FIXED_TERM entry zeroes it while jtEff keeps the full 50e18 gain less the 10e18 coverage
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(990e18)), toNAVUnits(uint256(250e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "covered loss enters the term");
        assertEq(toUint256(state.jtEffectiveNAV), 240e18, "jt keeps its full gain NAV including the would-be fee");
        assertEq(toUint256(state.jtProtocolFee), 0, "jt protocol fee zeroed in the term");
        assertEq(toUint256(state.stProtocolFee), 0, "st protocol fee zeroed in the term");
        assertEq(toUint256(state.ltProtocolFee), 0, "lt protocol fee zeroed in the term");
        assertEq(toUint256(state.ltLiquidityPremium), 0, "lt premium zeroed in the term");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 10e18, "coverage il booked");
    }

    /// E8: transition events fire exactly once per edge and never on the PERPETUAL->PERPETUAL or FIXED->FIXED self-edges
    function test_StateMachine_transitionEventsExactlyOncePerEdge() public {
        _seedAndInitAccrual();
        // PERPETUAL -> FIXED_TERM
        vm.recordLogs();
        kernel.doPreOp(toNAVUnits(uint256(950e18)), toNAVUnits(SEED_JT_RAW));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 1, "entry edge emits exactly one commencement");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 0, "entry edge emits no end");
        // FIXED_TERM -> FIXED_TERM
        vm.recordLogs();
        kernel.doPreOp(toNAVUnits(uint256(940e18)), toNAVUnits(SEED_JT_RAW));
        logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 0, "self-edge emits no commencement");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 0, "self-edge emits no end");
        // FIXED_TERM -> PERPETUAL via full recovery
        vm.recordLogs();
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 0, "exit edge emits no commencement");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 1, "exit edge emits exactly one end");
        // PERPETUAL -> PERPETUAL
        vm.recordLogs();
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        logs = vm.getRecordedLogs();
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermCommenced.selector), 0, "perpetual self-edge emits no commencement");
        assertEq(_countAccountantLogs(logs, IRoycoDayAccountant.FixedTermEnded.selector), 0, "perpetual self-edge emits no end");
    }

    /**
     * E9: the premium accrual window resets on payment independently of the market state at the start of the sync
     *
     * NOTE map correction: premiumsPaid with a RESULTING fixed term is unreachable (premiums require the il to
     * have fully recovered to zero, which lands PERPETUAL), so the reset-regardless property is pinned on a
     * premium-paying sync that starts in FIXED_TERM and crosses to PERPETUAL
     * Derivation: from the 100e18-il term checkpoint, rates 0.05e18 / 0.02e18 over 500s give tw = (25e18, 10e18);
     * a 150e18 gain recovers the il and pays on the 50e18 residual: jtPrem = floor(50e18 * 25e18 / (500 * 1e18))
     * = 2.5e18, ltPrem = 1e18, fees kept in the resulting PERPETUAL: jtFee 0.25e18, ltFee 0.1e18,
     * stFee = floor(46.5e18 * 0.1) = 4.65e18
     */
    function test_StateMachine_premiumWindowResetOnFixedTermExit() public {
        _seedMatrixLargeIL();
        uint32 windowStart = uint32(block.timestamp);
        jtYDM.setYieldShareReturn(0.05e18);
        ltYDM.setYieldShareReturn(0.02e18);
        vm.warp(block.timestamp + 500);
        SyncedAccountingState memory state = kernel.doPreOp(toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(300e18)));
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "recovered market exits the term");
        assertEq(toUint256(state.jtEffectiveNAV), 302.5e18, "recovery plus the time-weighted risk premium");
        assertEq(toUint256(state.ltLiquidityPremium), 1e18, "time-weighted liquidity premium");
        assertEq(toUint256(state.stEffectiveNAV), 1047.5e18, "st residual plus the premium carve-out");
        assertEq(toUint256(state.jtProtocolFee), 0.25e18, "jt yield-share fee kept");
        assertEq(toUint256(state.ltProtocolFee), 0.1e18, "lt fee kept");
        assertEq(toUint256(state.stProtocolFee), 4.65e18, "st fee kept");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(s.twJTYieldShareAccruedWAD, 0, "jt accumulator reset on payment");
        assertEq(s.twLTYieldShareAccruedWAD, 0, "lt accumulator reset on payment");
        // The expected clock is derived from windowStart rather than read from block.timestamp: the identical
        // pre-warp uint32(block.timestamp) read above gets CSE'd with a post-warp read under via-ir (TIMESTAMP is
        // frame-constant in the real EVM, so the optimizer may legally merge the reads across a vm.warp)
        assertEq(s.lastPremiumPaymentTimestamp, windowStart + 500, "premium clock advances on payment");
        assertGt(uint256(s.lastPremiumPaymentTimestamp), uint256(windowStart), "the window genuinely moved");
    }

    /*//////////////////////////////////////////////////////////////////////
                        HARNESS — PART 3 SHARED HELPERS
    //////////////////////////////////////////////////////////////////////*/

    /// @dev Ceiling division of a raw product, the test-local mirror for the ceil-rounded utilization formulas
    function _ceilDiv(uint256 _num, uint256 _den) internal pure returns (uint256) {
        return _num == 0 ? 0 : ((_num - 1) / _den) + 1;
    }

    /**
     * @dev Independent mirror of the spec coverage utilization formula (testing-strategy F7):
     * ceil((stRaw + (coinvested ? jtRaw : 0)) * minCoverage / jtEff), 0 when the minimum coverage or the
     * exposure is zero, uint256 max when the junior buffer is zero against live exposure
     */
    function _specCoverageUtilization(
        uint256 _stRaw,
        uint256 _jtRaw,
        bool _coinvested,
        uint256 _minCoverageWAD,
        uint256 _jtEff
    )
        internal
        pure
        returns (uint256)
    {
        uint256 exposure = _stRaw + (_coinvested ? _jtRaw : 0);
        if (_minCoverageWAD == 0 || exposure == 0) return 0;
        if (_jtEff == 0) return type(uint256).max;
        return _ceilDiv(exposure * _minCoverageWAD, _jtEff);
    }

    /**
     * @dev Independent mirror of the spec liquidity utilization formula (testing-strategy F8):
     * ceil(stEff * minLiquidity / ltRaw), 0 when the senior effective NAV or the minimum liquidity is zero,
     * uint256 max when the market-making inventory is zero against a live requirement
     */
    function _specLiquidityUtilization(uint256 _stEff, uint256 _minLiquidityWAD, uint256 _ltRaw) internal pure returns (uint256) {
        if (_stEff == 0 || _minLiquidityWAD == 0) return 0;
        if (_ltRaw == 0) return type(uint256).max;
        return _ceilDiv(_stEff * _minLiquidityWAD, _ltRaw);
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
            toUint256(s.lastSTRawNAV), toUint256(s.lastJTRawNAV), accountant.JT_COINVESTED(), s.minCoverageWAD, toUint256(s.lastJTEffectiveNAV)
        );
        st.liquidityUtilizationWAD = _specLiquidityUtilization(toUint256(s.lastSTEffectiveNAV), s.minLiquidityWAD, toUint256(s.lastLTRawNAV));
        st.fixedTermEndTimestamp = s.fixedTermEndTimestamp;
        st.minCoverageWAD = s.minCoverageWAD;
        st.jtCoinvested = accountant.JT_COINVESTED();
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
        bool _coinvested,
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
        st.jtCoinvested = _coinvested;
        st.minCoverageWAD = _minCoverageWAD;
        st.minLiquidityWAD = _minLiquidityWAD;
        st.coverageLiquidationUtilizationWAD = type(uint256).max;
    }

    /// @dev Seeds the default flat 1000e18/200e18 market with the specified committed liquidity tranche raw NAV
    function _seedFlatWithLT(uint256 _ltRaw) internal {
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, _ltRaw, MarketState.PERPETUAL);
    }

    /*//////////////////////////////////////////////////////////////////////
                                F POST-OP
    //////////////////////////////////////////////////////////////////////*/

    /// F1: an ST deposit adds its senior raw NAV delta to the senior effective NAV and commits the checkpoint
    function test_PostOp_stDeposit_addsDeltaToSTEffective() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 123e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW + 123e18, "st effective NAV grows by the deposited value");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW, "jt effective NAV untouched");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTRawNAV), SEED_ST_RAW + 123e18, "st raw NAV committed");
        assertEq(toUint256(s.lastSTEffectiveNAV), SEED_ST_RAW + 123e18, "st effective NAV committed");
    }

    /// F1: an ST deposit with a zero senior raw NAV delta violates the shape require
    function test_PostOp_reverts_stDepositZeroSTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// F1: an ST deposit with a negative senior raw NAV delta violates the shape require
    function test_PostOp_reverts_stDepositNegativeSTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW - 1), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// F1: an ST deposit with a positive junior raw NAV delta violates the shape require
    function test_PostOp_reverts_stDepositPositiveJTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW + 1), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// F1: an ST deposit with a negative junior raw NAV delta violates the shape require
    function test_PostOp_reverts_stDepositNegativeJTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW - 1), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// F1: an ST deposit with a nonzero liquidity raw NAV delta violates the shape require in both directions
    function test_PostOp_reverts_stDepositNonzeroLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// F1: an ST deposit with a nonzero self-liquidation bonus value violates the shape require
    function test_PostOp_reverts_stDepositNonzeroBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(1)), false);
    }

    /// F2: a JT deposit adds its junior raw NAV delta to the junior effective NAV and commits the checkpoint
    function test_PostOp_jtDeposit_addsDeltaToJTEffective() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 45e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 45e18, "jt effective NAV grows by the deposited value");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW, "st effective NAV untouched");
        assertEq(toUint256(accountant.getState().lastJTEffectiveNAV), SEED_JT_RAW + 45e18, "jt effective NAV committed");
    }

    /// F2: a JT deposit with a zero junior raw NAV delta violates the shape require
    function test_PostOp_reverts_jtDepositZeroJTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// F2: a JT deposit with a negative junior raw NAV delta violates the shape require
    function test_PostOp_reverts_jtDepositNegativeJTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - 1), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// F2: a JT deposit with a positive senior raw NAV delta violates the shape require
    function test_PostOp_reverts_jtDepositPositiveSTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW + 1), toNAVUnits(SEED_JT_RAW + 10e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// F2: a JT deposit with a negative senior raw NAV delta violates the shape require
    function test_PostOp_reverts_jtDepositNegativeSTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW - 1), toNAVUnits(SEED_JT_RAW + 10e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// F2: a JT deposit with a nonzero liquidity raw NAV delta violates the shape require in both directions
    function test_PostOp_reverts_jtDepositNonzeroLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 10e18), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 10e18), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// F2: a JT deposit with a nonzero self-liquidation bonus value violates the shape require
    function test_PostOp_reverts_jtDepositNonzeroBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 10e18), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(1)), false);
    }

    /// F3: a BPT-only LT deposit (zero senior delta) books the liquidity raw NAV and leaves both effective NAVs untouched
    function test_PostOp_ltDepositBPTOnly_leavesEffectiveNAVsUntouched() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW + 30e18), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW, "st effective NAV untouched by the pure BPT leg");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW, "jt effective NAV untouched");
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW + 30e18, "lt raw NAV reflects the deposit");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), SEED_LT_RAW + 30e18, "lt raw NAV committed");
    }

    /// F3: a multi-asset LT deposit (positive senior delta) adds the freshly minted senior value to the senior effective NAV
    function test_PostOp_ltDepositMultiAsset_addsSTDeltaToSTEffective() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW + 50e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW + 20e18), ZERO_NAV_UNITS, false
        );
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW + 50e18, "st effective NAV grows by the minted senior value");
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW + 20e18, "lt raw NAV reflects the joined BPT value");
        assertEq(toUint256(accountant.getState().lastSTEffectiveNAV), SEED_ST_RAW + 50e18, "st effective NAV committed");
    }

    /// F3: an LT deposit with a zero liquidity raw NAV delta violates the shape require
    function test_PostOp_reverts_ltDepositZeroLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// F3: an LT deposit with a negative liquidity raw NAV delta violates the shape require
    function test_PostOp_reverts_ltDepositNegativeLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// F3: an LT deposit with a negative senior raw NAV delta violates the shape require
    function test_PostOp_reverts_ltDepositNegativeSTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW - 1), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW + 10e18), ZERO_NAV_UNITS, false);
    }

    /// F3: an LT deposit with a nonzero junior raw NAV delta violates the shape require in both directions
    function test_PostOp_reverts_ltDepositNonzeroJTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW + 1), toNAVUnits(SEED_LT_RAW + 10e18), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - 1), toNAVUnits(SEED_LT_RAW + 10e18), ZERO_NAV_UNITS, false);
    }

    /// F3: an LT deposit with a nonzero self-liquidation bonus value violates the shape require
    function test_PostOp_reverts_ltDepositNonzeroBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_DEPOSIT));
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW + 10e18), toNAVUnits(uint256(1)), false);
    }

    /// F4: an ST redemption without a bonus reduces the senior effective NAV by the full redeemed value
    function test_PostOp_stRedeem_reducesSTEffectiveWithoutBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW - 50e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW - 50e18, "st effective NAV bears the full redemption");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW, "jt effective NAV untouched without a bonus");
    }

    /**
     * F4: an ST redemption with a self-liquidation bonus reduces the junior effective NAV by exactly the bonus
     * and the senior effective NAV by the total redeemed value minus the bonus
     * Derivation: total = 50e18 + 5e18 = 55e18, jtEff = 200e18 - 5e18, stEff = 1000e18 - (55e18 - 5e18)
     */
    function test_PostOp_stRedeem_bonusSplitsAcrossJTAndST() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW - 50e18), toNAVUnits(SEED_JT_RAW - 5e18), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(5e18)), false
        );
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW - 5e18, "jt effective NAV funds exactly the bonus");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW - 50e18, "st effective NAV bears the redemption net of the bonus");
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(
            toUint256(s.lastSTRawNAV) + toUint256(s.lastJTRawNAV),
            toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV),
            "conservation holds through the bonus split"
        );
    }

    /// F7: a bonus exactly equal to the total redeemed value draws everything from JT and leaves the senior effective NAV unchanged
    function test_PostOp_stRedeem_bonusEqualToTotalDrawsAllFromJT() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - 10e18), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(10e18)), false
        );
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW, "st effective NAV untouched when the bonus covers the total");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW - 10e18, "jt effective NAV funds the entire redemption");
    }

    /// F4: an ST redemption with a nonzero liquidity raw NAV delta violates the shape require in both directions
    function test_PostOp_reverts_stRedeemNonzeroLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_REDEEM));
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW - 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_REDEEM));
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW - 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// F4: an ST redemption with a zero total redeemed value violates the shape require
    function test_PostOp_reverts_stRedeemZeroTotal() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_REDEEM));
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /**
     * F4: a positive junior raw NAV delta during an ST redemption reverts inside toNAVUnits(int256) with
     * ASSETS_MUST_BE_NON_NEGATIVE (Units.sol:94-98), NOT with INVALID_POST_OP_STATE — the total redeemed
     * value is computed before the shape require can run
     */
    function test_PostOp_reverts_stRedeemPositiveJTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(ASSETS_MUST_BE_NON_NEGATIVE.selector);
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW - 10e18), toNAVUnits(SEED_JT_RAW + 1), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// F4: a positive senior raw NAV delta during an ST redemption reverts identically in toNAVUnits(int256)
    function test_PostOp_reverts_stRedeemPositiveSTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(ASSETS_MUST_BE_NON_NEGATIVE.selector);
        kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW + 1), toNAVUnits(SEED_JT_RAW - 10e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /**
     * F7: a bonus exceeding the junior effective NAV underflows the raw NAV_UNIT subtraction at :267 with an
     * arithmetic panic (0x11), not a custom error — the junior buffer is debited before the senior leg
     */
    function test_PostOp_reverts_stRedeemBonusExceedsJTEffective() public {
        _seedState(SEED_ST_RAW, 5e18, SEED_ST_RAW, 5e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPostOp(
            Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW - 10e18), toNAVUnits(uint256(5e18)), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(6e18)), false
        );
    }

    /**
     * F7: a bonus exceeding the total redeemed value (while within the junior buffer) underflows the
     * total-minus-bonus subtraction at :269 with an arithmetic panic (0x11)
     */
    function test_PostOp_reverts_stRedeemBonusExceedsTotal() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPostOp(
            Operation.ST_REDEEM, toNAVUnits(SEED_ST_RAW - 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(11e18)), false
        );
    }

    /// F5: an in-kind LT redemption (negative liquidity delta alone, zero total) passes and books only the liquidity mark
    function test_PostOp_ltRedeem_negativeLTDeltaAlonePasses() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW - 40e18), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW - 40e18, "lt raw NAV reflects the burned BPT slice");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW, "st effective NAV untouched");
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW, "jt effective NAV untouched");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), SEED_LT_RAW - 40e18, "lt raw NAV committed");
    }

    /**
     * F5: an LT redemption with a zero liquidity delta but a positive total passes — the idle-premium-share-only
     * leg, where the redeemer takes staged senior shares without touching the BPT
     * NOTE: this pins the fix for the edge testing-strategy Appendix B flagged (a zero-BPT-slice in-kind LT
     * redemption formerly tripped INVALID_POST_OP_STATE)
     */
    function test_PostOp_ltRedeem_zeroLTDeltaWithPositiveTotalPasses() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW - 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW - 10e18, "st effective NAV bears the idle-share redemption");
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW, "lt raw NAV untouched by the idle-share-only leg");
    }

    /// F5: a multi-asset LT redemption with both a negative liquidity delta and a positive total passes
    function test_PostOp_ltRedeem_bothLegsPass() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW - 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW - 40e18), ZERO_NAV_UNITS, false
        );
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW - 10e18, "st effective NAV bears the unwound senior leg");
        assertEq(toUint256(state.ltRawNAV), SEED_LT_RAW - 40e18, "lt raw NAV reflects the burned BPT slice");
    }

    /// F5: an LT redemption with a zero liquidity delta and a zero total violates the shape require
    function test_PostOp_reverts_ltRedeemZeroLTDeltaZeroTotal() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_REDEEM));
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// F5: an LT redemption with a positive liquidity delta violates the shape require
    function test_PostOp_reverts_ltRedeemPositiveLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_REDEEM));
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
    }

    /// F6: a JT redemption reduces the junior effective NAV by the total redeemed value and leaves a zero IL untouched
    function test_PostOp_jtRedeem_reducesJTEffectiveWithZeroILUntouched() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - 50e18), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW - 50e18, "jt effective NAV bears the redemption");
        assertEq(toUint256(state.stEffectiveNAV), SEED_ST_RAW, "st effective NAV untouched");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 0, "zero il stays zero through the redemption");
        assertEq(toUint256(accountant.getState().lastJTCoverageImpermanentLoss), 0, "committed il untouched");
    }

    /**
     * F6: a JT redemption floor-scales a live coverage impermanent loss by the junior effective NAV ratio and
     * persists it immediately, compounding across successive redemptions
     * Derivation from the (900e18, 300e18, 1000e18, 200e18, il 100e18) fixed-term checkpoint:
     *   redeem 60e18: jtEff = 140e18, il = floor(100e18 * 140e18 / 200e18) = 70e18
     *   then redeem 7 wei: jtEff = 140e18 - 7, il = floor(70e18 * (140e18 - 7) / 140e18) = floor(70e18 - 3.5) = 70e18 - 4
     */
    function test_PostOp_jtRedeem_scalesILImmediatelyWithFloor() public {
        _seedState(900e18, 300e18, 1000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(uint256(900e18)), toNAVUnits(uint256(240e18)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.jtEffectiveNAV), 140e18, "jt effective NAV bears the redemption");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 70e18, "il floor-scaled by the effective NAV ratio");
        assertEq(toUint256(accountant.getState().lastJTCoverageImpermanentLoss), 70e18, "scaled il persisted immediately");

        state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(uint256(900e18)), toNAVUnits(uint256(240e18 - 7)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 70e18 - 4, "second scaling floors the awkward wei ratio");
        assertEq(toUint256(accountant.getState().lastJTCoverageImpermanentLoss), 70e18 - 4, "compounded il persisted immediately");
    }

    /// F6: a JT redemption with a nonzero liquidity raw NAV delta violates the shape require in both directions
    function test_PostOp_reverts_jtRedeemNonzeroLTDelta() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEEM));
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - 10e18), toNAVUnits(SEED_LT_RAW + 1), ZERO_NAV_UNITS, false);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEEM));
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - 10e18), toNAVUnits(SEED_LT_RAW - 1), ZERO_NAV_UNITS, false);
    }

    /// F6: a JT redemption with a zero total redeemed value violates the shape require
    function test_PostOp_reverts_jtRedeemZeroTotal() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEEM));
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
    }

    /// F6: a JT redemption with a nonzero self-liquidation bonus value violates the shape require
    function test_PostOp_reverts_jtRedeemNonzeroBonus() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEEM));
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - 10e18), toNAVUnits(SEED_LT_RAW), toNAVUnits(uint256(1)), false);
    }

    /**
     * F8: from any conserved flat checkpoint, every valid post-op shape commits without reverting and the
     * committed checkpoint conserves NAV exactly — the NAV_CONSERVATION_VIOLATION arm at :286 is unreachable
     * from conserved checkpoints (any revert or wei of drift here is a REAL finding)
     */
    function testFuzz_PostOp_conservationHoldsForValidShapes(uint256 _stRaw0, uint256 _jtRaw0, uint256 _lt0, uint256 _value, uint256 _opSeed) public {
        // Bounds: checkpoint raw NAVs uniform in [1e18, 1e30] (the strategy magnitude bound), the committed
        // liquidity value uniform in [2, 1e30] so an LT redemption always has a withdrawable wei, the op value
        // uniform in [1, 1e18] so redemptions stay inside every tranche, and the op uniform across all six members
        _stRaw0 = bound(_stRaw0, 1e18, 1e30);
        _jtRaw0 = bound(_jtRaw0, 1e18, 1e30);
        _lt0 = bound(_lt0, 2, 1e30);
        _value = bound(_value, 1, 1e18);
        Operation op = Operation(bound(_opSeed, 0, 5));
        _seedState(_stRaw0, _jtRaw0, _stRaw0, _jtRaw0, 0, _lt0, MarketState.PERPETUAL);

        uint256 stRaw1 = _stRaw0;
        uint256 jtRaw1 = _jtRaw0;
        uint256 lt1 = _lt0;
        NAV_UNIT bonus = ZERO_NAV_UNITS;
        if (op == Operation.ST_DEPOSIT) {
            stRaw1 = _stRaw0 + _value;
        } else if (op == Operation.ST_REDEEM) {
            // Redeem the value from senior and half the value from junior, the junior slice provided as a bonus
            stRaw1 = _stRaw0 - _value;
            jtRaw1 = _jtRaw0 - (_value / 2);
            bonus = toNAVUnits(_value / 2);
        } else if (op == Operation.JT_DEPOSIT) {
            jtRaw1 = _jtRaw0 + _value;
        } else if (op == Operation.JT_REDEEM) {
            jtRaw1 = _jtRaw0 - _value;
        } else if (op == Operation.LT_DEPOSIT) {
            lt1 = _lt0 + _value;
            stRaw1 = _stRaw0 + (_value / 2);
        } else {
            lt1 = _lt0 - (_value < _lt0 ? _value : _lt0 - 1);
        }
        kernel.doPostOp(op, toNAVUnits(stRaw1), toNAVUnits(jtRaw1), toNAVUnits(lt1), bonus, false);

        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(
            toUint256(s.lastSTRawNAV) + toUint256(s.lastJTRawNAV),
            toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV),
            "committed checkpoint conserves NAV exactly"
        );
        assertEq(toUint256(s.lastSTRawNAV), stRaw1, "st raw NAV committed");
        assertEq(toUint256(s.lastJTRawNAV), jtRaw1, "jt raw NAV committed");
        assertEq(toUint256(s.lastLTRawNAV), lt1, "lt raw NAV committed");
    }

    /**
     * F9: the post-op writes all five NAV checkpoints including lastLTRawNAV, never touches the market state
     * or the stored fixed-term end, performs no yield-share accrual, emits no sync event, and returns zero
     * fees and premium with fresh utilizations plus the fixed-term end passthrough
     */
    function test_PostOp_writesAllCheckpointsAndPreservesMarketState() public {
        _seedState(900e18, 300e18, 1000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
        uint32 end = accountant.getState().fixedTermEndTimestamp;
        assertGt(uint256(end), 0, "seed committed a live fixed-term end");
        uint256 jtCallsBefore = jtYDM.yieldShareCallCount();
        uint256 ltCallsBefore = ltYDM.yieldShareCallCount();
        vm.recordLogs();
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(uint256(900e18)), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(130e18)), ZERO_NAV_UNITS, false);

        // Returned state: passthroughs, zero fees and premium, fresh utilizations
        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "market state passthrough");
        assertEq(toUint256(state.stRawNAV), 900e18, "st raw NAV passthrough");
        assertEq(toUint256(state.jtRawNAV), 300e18, "jt raw NAV passthrough");
        assertEq(toUint256(state.ltRawNAV), 130e18, "lt raw NAV passthrough");
        assertEq(toUint256(state.stEffectiveNAV), 1000e18, "st effective NAV unchanged by the BPT-only deposit");
        assertEq(toUint256(state.jtEffectiveNAV), 200e18, "jt effective NAV unchanged");
        assertEq(toUint256(state.jtCoverageImpermanentLoss), 100e18, "il passthrough");
        assertEq(toUint256(state.ltLiquidityPremium), 0, "no premium accrues on an operation");
        assertEq(toUint256(state.stProtocolFee), 0, "no st fee on an operation");
        assertEq(toUint256(state.jtProtocolFee), 0, "no jt fee on an operation");
        assertEq(toUint256(state.ltProtocolFee), 0, "no lt fee on an operation");
        assertEq(
            state.coverageUtilizationWAD,
            _specCoverageUtilization(900e18, 300e18, false, DEFAULT_MIN_COVERAGE_WAD, 200e18),
            "fresh coverage utilization, not a placeholder"
        );
        assertEq(
            state.liquidityUtilizationWAD, _specLiquidityUtilization(1000e18, DEFAULT_MIN_LIQUIDITY_WAD, 130e18), "fresh liquidity utilization on the new mark"
        );
        assertEq(state.fixedTermEndTimestamp, end, "fixed-term end passthrough");

        // Committed checkpoints: all five NAVs written, market state and end timestamp untouched
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastSTRawNAV), 900e18, "st raw NAV committed");
        assertEq(toUint256(s.lastJTRawNAV), 300e18, "jt raw NAV committed");
        assertEq(toUint256(s.lastLTRawNAV), 130e18, "lt raw NAV committed");
        assertEq(toUint256(s.lastSTEffectiveNAV), 1000e18, "st effective NAV committed");
        assertEq(toUint256(s.lastJTEffectiveNAV), 200e18, "jt effective NAV committed");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "market state never changes in a post-op");
        assertEq(s.fixedTermEndTimestamp, end, "stored fixed-term end untouched");
        assertEq(jtYDM.yieldShareCallCount(), jtCallsBefore, "no jt accrual in a post-op");
        assertEq(ltYDM.yieldShareCallCount(), ltCallsBefore, "no lt accrual in a post-op");
        assertEq(_countAccountantLogs(vm.getRecordedLogs(), IRoycoDayAccountant.TrancheAccountingSynced.selector), 0, "post-op emits no sync event");
    }

    /**
     * F10: enforce = false skips both gates for every operation from a doubly-breached market
     * Breach seed: covUtil = ceil(1000e18 * 0.1e18 / 50e18) = 2e18 and liqUtil = ceil(1000e18 * 0.05e18 / 10e18) = 5e18
     */
    function test_PostOp_enforceFalseSkipsBothGatesForEveryOp() public {
        _seedState(SEED_ST_RAW, 50e18, SEED_ST_RAW, 50e18, 0, 10e18, MarketState.PERPETUAL);
        // ST_DEPOSIT deepens the coverage breach and still passes
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(1100e18)), toNAVUnits(uint256(50e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached after the st deposit");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached after the st deposit");
        // ST_REDEEM
        state =
            kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(50e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the st redemption");
        // JT_DEPOSIT
        state =
            kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(60e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the jt deposit");
        // JT_REDEEM deepens the coverage breach and still passes
        state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(50e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached after the jt redemption");
        // LT_DEPOSIT under a persisting liquidity breach still passes
        state =
            kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(50e18)), toNAVUnits(uint256(15e18)), ZERO_NAV_UNITS, false);
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity still breached after the lt deposit");
        // LT_REDEEM deepens the liquidity breach and still passes
        state = kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(uint256(1050e18)), toNAVUnits(uint256(50e18)), toNAVUnits(uint256(5e18)), ZERO_NAV_UNITS, false);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage still breached at the end");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity still breached at the end");
    }

    /**
     * F10: the coverage gate for ST_DEPOSIT passes at coverage utilization exactly WAD and fires at WAD + 1
     * Arithmetic: with jtEff 200e18 and minCoverage 0.1e18, depositing to stRaw 2000e18 gives
     * covUtil = ceil(2000e18 * 0.1e18 / 200e18) = 1e18 exactly (exact division), while one more wei gives
     * ceil((2000e18 + 1) * 0.1e18 / 200e18) = 1e18 + 1 since the product gains a 1e17 remainder
     */
    function test_PostOp_coverageGate_stDepositExactBoundary() public {
        _seedFlatWithLT(200e18);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(200e18)), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "coverage utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18 + 1)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(200e18)), ZERO_NAV_UNITS, true);
    }

    /**
     * F10: the coverage gate for LT_DEPOSIT (multi-asset, senior-minting) passes at exactly WAD and fires at WAD + 1
     * Arithmetic: minting senior to stRaw 2000e18 against jtEff 200e18 gives covUtil exactly 1e18, the follow-up
     * wei of senior against a fresh BPT wei gives ceil((2000e18 + 1) * 0.1e18 / 200e18) = 1e18 + 1
     */
    function test_PostOp_coverageGate_ltDepositExactBoundary() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(uint256(2000e18)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(150e18)), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "coverage utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(uint256(2000e18 + 1)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(150e18 + 1)), ZERO_NAV_UNITS, true);
    }

    /**
     * F10: the coverage gate for JT_REDEEM passes at exactly WAD and fires at WAD + 1
     * Arithmetic: redeeming junior to jtEff 100e18 gives covUtil = 1e38 / 1e20 = 1e18 exactly, while one more
     * wei gives ceil(1e38 / (1e20 - 1)) = 1e18 + 1 since 1e38 = (1e20 - 1) * 1e18 + 1e18
     */
    function test_PostOp_coverageGate_jtRedeemExactBoundary() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(uint256(100e18)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "coverage utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(uint256(100e18 - 1)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true);
    }

    /**
     * F10: the liquidity gate for ST_DEPOSIT passes at liquidity utilization exactly WAD and fires at WAD + 1
     * Arithmetic: with ltRaw 100e18 and minLiquidity 0.05e18, depositing to stEff 2000e18 gives
     * liqUtil = ceil(2000e18 * 0.05e18 / 100e18) = 1e18 exactly, one more wei adds a 5e16 remainder so the
     * ceil lands on 1e18 + 1 (the 300e18 junior buffer keeps covUtil at 666666666666666667, clear of its gate)
     */
    function test_PostOp_liquidityGate_stDepositExactBoundary() public {
        _seedState(SEED_ST_RAW, 300e18, SEED_ST_RAW, 300e18, 0, 100e18, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18)), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "liquidity utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18 + 1)), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true);
    }

    /**
     * F10: the liquidity gate for LT_DEPOSIT (multi-asset) passes at exactly WAD and fires at WAD + 1
     * Arithmetic: minting senior to stEff 2020e18 against ltRaw 101e18 gives liqUtil = ceil(2020e18 * 0.05e18
     * / 101e18) = 1e18 exactly. The follow-up deposit adds 21 wei of senior against one BPT wei, so the
     * numerator grows by 21 * 5e16 = 1.05e18 while the denominator threshold grows by only 1e18, landing the
     * ceil exactly on 1e18 + 1 (covUtil stays near 0.6733e18 against the 300e18 junior buffer)
     */
    function test_PostOp_liquidityGate_ltDepositExactBoundary() public {
        _seedState(SEED_ST_RAW, 300e18, SEED_ST_RAW, 300e18, 0, 100e18, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(uint256(2020e18)), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(101e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "liquidity utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(
            Operation.LT_DEPOSIT, toNAVUnits(uint256(2020e18 + 21)), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(101e18 + 1)), ZERO_NAV_UNITS, true
        );
    }

    /**
     * F10: the liquidity gate for LT_REDEEM passes at exactly WAD and fires at WAD + 1
     * Arithmetic: redeeming BPT down to ltRaw 50e18 gives liqUtil = ceil(1000e18 * 0.05e18 / 50e18) = 1e18
     * exactly, one more redeemed wei gives ceil(5e37 / (5e19 - 1)) = 1e18 + 1 since 5e37 = (5e19 - 1) * 1e18 + 1e18
     */
    function test_PostOp_liquidityGate_ltRedeemExactBoundary() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(50e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "liquidity utilization lands exactly on WAD and passes");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(50e18 - 1)), ZERO_NAV_UNITS, true);
    }

    /**
     * F10 + REAL FINDING (spec conflict, behavior pinned, adjudication needed): an in-kind BPT-only LT deposit
     * that IMPROVES a breached liquidity utilization but does not fully heal it reverts under enforcement
     *
     * CLAUDE.md's redemption-gate section and invariants state "Deposits are never liquidity-gated ... an LT
     * deposit only raises ltRawNAV ... so no deposit is ever blocked on liquidity", yet the implementation
     * gates LT_DEPOSIT (and ST_DEPOSIT) on the liquidity requirement. CLAUDE.md is internally inconsistent:
     * its own product-requirements section demands a "minimum percentage of liquidity required for senior
     * tranche deposits" and maxSTDeposit's documented liquidity leg (testing-strategy F15) exists solely to
     * bound deposits by liquidity. The sharp consequence pinned here is that enforcement blocks the exact
     * restoring force (external LT deposits) the spec relies on to heal a breach, unless the kernel passes
     * enforce = false for LT deposits. Severity rests on the kernel's flag choice — flagged for adjudication
     */
    function test_PostOp_liquidityGate_blocksHealingLTDepositUnderBreach() public {
        _seedState(SEED_ST_RAW, SEED_JT_RAW, SEED_ST_RAW, SEED_JT_RAW, 0, 10e18, MarketState.PERPETUAL);
        // A BPT-only deposit lifting ltRaw from 10e18 to 25e18 improves liqUtil from 5e18 to 2e18 yet reverts
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(25e18)), ZERO_NAV_UNITS, true);
        // Healing the breach entirely (ltRaw 50e18 puts liqUtil at exactly WAD) is the only enforced way in
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(50e18)), ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, WAD, "a fully healing lt deposit passes at exactly WAD");
    }

    /**
     * F10 exemptions: ST_REDEEM and JT_DEPOSIT pass BOTH breached gates with enforcement on
     * NOTE an ST redemption with a bonus consumes the junior buffer and can worsen coverage, but the
     * accountant exempts it by design — the kernel bounds the bonus to be utilization-neutral (F19)
     */
    function test_PostOp_gateExemptions_stRedeemAndJTDepositPassBothBreaches() public {
        _seedState(SEED_ST_RAW, 50e18, SEED_ST_RAW, 50e18, 0, 10e18, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_REDEEM, toNAVUnits(uint256(990e18)), toNAVUnits(uint256(50e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, true);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the st redemption passed");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached yet the st redemption passed");
        state = kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(uint256(990e18)), toNAVUnits(uint256(51e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, true);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the jt deposit passed");
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached yet the jt deposit passed");
    }

    /// F10 exemption: JT_REDEEM passes an enforced liquidity breach because a junior redemption cannot reduce pooled depth
    function test_PostOp_gateExemptions_jtRedeemPassesLiquidityBreach() public {
        _seedFlatWithLT(10e18);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(uint256(150e18)), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS, true);
        assertGt(state.liquidityUtilizationWAD, WAD, "liquidity breached yet the jt redemption passed");
        assertLe(state.coverageUtilizationWAD, WAD, "its own coverage gate was satisfied");
    }

    /// F10 exemption: LT_REDEEM passes an enforced coverage breach because a liquidity redemption cannot add senior exposure
    function test_PostOp_gateExemptions_ltRedeemPassesCoverageBreach() public {
        _seedState(SEED_ST_RAW, 50e18, SEED_ST_RAW, 50e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(uint256(50e18)), toNAVUnits(uint256(60e18)), ZERO_NAV_UNITS, true);
        assertGt(state.coverageUtilizationWAD, WAD, "coverage breached yet the lt redemption passed");
        assertLe(state.liquidityUtilizationWAD, WAD, "its own liquidity gate was satisfied");
    }

    /// F11: commitLiquidityTrancheRawNAV writes the committed liquidity raw NAV with its exact event
    function test_Commit_writesLastLTRawNAVWithEvent() public {
        _seedFlatWithLT(SEED_LT_RAW);
        vm.expectEmit(true, true, true, true, address(accountant));
        emit IRoycoDayAccountant.LiquidityTrancheRawNAVCommitted(toNAVUnits(uint256(77e18)));
        kernel.doCommit(toNAVUnits(uint256(77e18)));
        assertEq(toUint256(accountant.getState().lastLTRawNAV), 77e18, "lt raw NAV committed");
    }

    /**
     * F11: the committed liquidity raw NAV drives the next accrual's liquidity utilization and the
     * maxSTDeposit liquidity leg
     * Derivation: liqUtil = ceil(1000e18 * 0.05e18 / 77e18) = 649350649350649351 (remainder forces the ceil up)
     * and the liquidity leg is floor(77e18 * 1e18 / 0.05e18) - 1000e18 = 540e18 against a 1000e18 coverage leg
     */
    function test_Commit_affectsNextAccrualUtilizationAndMaxSTDeposit() public {
        _seedAndInitAccrual();
        kernel.doCommit(toNAVUnits(uint256(77e18)));
        vm.warp(block.timestamp + 100);
        kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(ltYDM.lastYieldShareUtilizationWAD(), 649_350_649_350_649_351, "lt ydm consulted with the committed-lt liquidity utilization");
        assertEq(toUint256(accountant.maxSTDeposit(_checkpointState())), 540e18, "liquidity leg reflects the committed lt raw NAV");
    }

    /*//////////////////////////////////////////////////////////////////////
                                G UTILIZATION
    //////////////////////////////////////////////////////////////////////*/

    /**
     * G1 + G2: zero minimum requirements short-circuit both utilizations to 0 before any max edge can fire —
     * a live senior exposure against a zero junior buffer and zero market-making inventory reads (0, 0), so
     * the fully enforced deposit passes both gates
     */
    function test_Utilization_bothZeroWhenMinimumRequirementsZero() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.minCoverageWAD = 0;
        p.minLiquidityWAD = 0;
        _deploy(false, p);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, 0, "zero minimum coverage short-circuits before the empty-buffer max edge");
        assertEq(state.liquidityUtilizationWAD, 0, "zero minimum liquidity short-circuits before the empty-inventory max edge");
    }

    /**
     * G1 + G2: a zero covered exposure reads a zero coverage utilization and a zero senior effective NAV reads
     * a zero liquidity utilization, each taking precedence over its own zero-denominator max edge
     */
    function test_Utilization_zeroExposureAndZeroSTEffectivePrecedeMaxEdges() public {
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.JT_DEPOSIT, ZERO_NAV_UNITS, toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, 0, "no covered exposure so coverage utilization is zero despite the live buffer");
        assertEq(state.liquidityUtilizationWAD, 0, "zero senior effective NAV precedes the zero-inventory max edge");
    }

    /**
     * G1 + G2: live exposure against a zero junior buffer reads a uint256 max coverage utilization, and live
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
     * G1 + G2: ceil bias exactness on awkward values against independent math — each utilization matches the
     * spec formula and satisfies util * denominator >= product > (util - 1) * denominator
     */
    function test_Utilization_ceilBiasExactness() public {
        _seedState(SEED_ST_RAW, 300e18, SEED_ST_RAW, 300e18, 0, 100e18, MarketState.PERPETUAL);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 7), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, false);
        uint256 covUtil = state.coverageUtilizationWAD;
        uint256 covProduct = (SEED_ST_RAW + 7) * uint256(DEFAULT_MIN_COVERAGE_WAD);
        assertEq(covUtil, _specCoverageUtilization(SEED_ST_RAW + 7, 300e18, false, DEFAULT_MIN_COVERAGE_WAD, 300e18), "coverage matches the independent ceil");
        assertGe(covUtil * 300e18, covProduct, "coverage ceil bias covers the exact product");
        assertLt((covUtil - 1) * 300e18, covProduct, "coverage ceil tightness, one less would under-cover");
        uint256 liqUtil = state.liquidityUtilizationWAD;
        uint256 liqProduct = (SEED_ST_RAW + 7) * uint256(DEFAULT_MIN_LIQUIDITY_WAD);
        assertEq(liqUtil, _specLiquidityUtilization(SEED_ST_RAW + 7, DEFAULT_MIN_LIQUIDITY_WAD, 100e18), "liquidity matches the independent ceil");
        assertGe(liqUtil * 100e18, liqProduct, "liquidity ceil bias covers the exact product");
        assertLt((liqUtil - 1) * 100e18, liqProduct, "liquidity ceil tightness, one less would under-cover");
    }

    /**
     * G1: the JT_COINVESTED immutable toggles the junior raw NAV in the coverage numerator
     * Derivation: after a 50e18 junior deposit, coinvested reads ceil((1000e18 + 250e18) * 0.1e18 / 250e18)
     * = 0.5e18 while the risk-free-junior twin reads ceil(1000e18 * 0.1e18 / 250e18) = 0.4e18
     */
    function test_Utilization_coverageCoinvestedIncludesJTRaw() public {
        _deploy(true, _defaultParams());
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory coinvested =
            kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(uint256(250e18)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(coinvested.coverageUtilizationWAD, 0.5e18, "coinvested numerator includes the junior raw NAV");

        _deploy(false, _defaultParams());
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory riskFree =
            kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_ST_RAW), toNAVUnits(uint256(250e18)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(riskFree.coverageUtilizationWAD, 0.4e18, "risk-free-junior numerator excludes the junior raw NAV");
    }

    /**
     * G2: a zero minimum liquidity reads zero even against a zero market-making inventory, taking precedence
     * over the zero-inventory max edge, so the enforced senior deposit passes its liquidity gate
     */
    function test_Utilization_liquidityZeroWhenMinLiquidityZero() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.minLiquidityWAD = 0;
        _deploy(false, p);
        _seedFlatWithLT(0);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 100e18), toNAVUnits(SEED_JT_RAW), ZERO_NAV_UNITS, ZERO_NAV_UNITS, true);
        assertEq(state.liquidityUtilizationWAD, 0, "zero minimum liquidity precedes the zero-inventory max edge");
        assertLe(state.coverageUtilizationWAD, WAD, "coverage gate satisfied on its own terms");
    }

    /// G2: a zero market-making inventory against a live requirement reads uint256 max and fires the enforced liquidity gate
    function test_Utilization_liquidityMaxWhenLTRawZero() public {
        _seedFlatWithLT(0);
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW), ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
        assertEq(state.liquidityUtilizationWAD, type(uint256).max, "zero inventory against a live requirement reads max");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 11e18), toNAVUnits(SEED_JT_RAW), ZERO_NAV_UNITS, ZERO_NAV_UNITS, true);
    }

    /**
     * G3: the pre-op returned state carries zero placeholders for the liquidity raw NAV and utilization (the
     * kernel refreshes them after committing the fresh mark) without clobbering the committed liquidity mark,
     * while the post-op returns the fresh real values
     */
    function test_Utilization_preOpPlaceholdersAndPostOpFreshValues() public {
        _seedFlatWithLT(SEED_LT_RAW);
        SyncedAccountingState memory preOpState = kernel.doPreOp(toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(preOpState.ltRawNAV), 0, "pre-op lt raw NAV is a zero placeholder");
        assertEq(preOpState.liquidityUtilizationWAD, 0, "pre-op liquidity utilization is a zero placeholder");
        assertEq(toUint256(accountant.getState().lastLTRawNAV), SEED_LT_RAW, "the placeholder never clobbers the committed lt mark");

        // The post-op returns the freshly marked liquidity values: liqUtil = ceil(1010e18 * 0.05e18 / 100e18) = 0.505e18
        SyncedAccountingState memory postOpState =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + 10e18), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, false);
        assertEq(toUint256(postOpState.ltRawNAV), SEED_LT_RAW, "post-op returns the real lt raw NAV");
        assertEq(postOpState.liquidityUtilizationWAD, 0.505e18, "post-op returns the fresh liquidity utilization");
    }

    /*//////////////////////////////////////////////////////////////////////
                                H MAX OPERATIONS
    //////////////////////////////////////////////////////////////////////*/

    /// H1: with both minimum requirements zero the senior deposit capacity is unbounded (MAX_NAV_UNITS)
    function test_MaxSTDeposit_unboundedWhenBothRequirementsZero() public view {
        SyncedAccountingState memory st = _bareState(1000e18, 200e18, 100e18, 1000e18, 200e18, false, 0, 0);
        assertEq(toUint256(accountant.maxSTDeposit(st)), toUint256(MAX_NAV_UNITS), "no requirement leaves senior capacity unbounded");
    }

    /**
     * H1: with a zero minimum liquidity the result is the coverage leg alone:
     * floor(jtEff * WAD / minCoverage) - ((coinvested ? jtRaw : 0) + jtDust + stRaw + stDust)
     * Derivation: floor(200e18 * 1e18 / 0.1e18) = 2000e18, minus (0 + 7 + 1000e18 + 3) = 1000e18 - 10, and the
     * 500e18 junior raw NAV is correctly excluded from the subtrahend when not coinvested
     *
     * Pinned quirk (map H1, RoycoDayAccountant.sol:367): jtNAVDustTolerance is subtracted REGARDLESS of
     * state.jtCoinvested even though jtRaw itself is excluded when not coinvested. Judged against the F15 spec
     * intent (dust slack rounds in the protocol's favor): the unconditional jtDust only shrinks reported
     * capacity by at most jtDust wei and can never admit a deposit that would breach the enforced coverage
     * gate, so it is intentional conservatism guarding junior-side NAV rounding drift in the jtEff denominator,
     * not a defect. The cost is that the view under-reports senior capacity by jtDust when JT sits in the RFR
     */
    function test_MaxSTDeposit_coverageLegExactWithJTDustRegardlessOfCoinvestment() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(7));
        _deploy(false, p);
        SyncedAccountingState memory st = _bareState(1000e18, 500e18, 0, 1000e18, 200e18, false, 0.1e18, 0);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 1000e18 - 10, "coverage leg exact, jtDust included despite no coinvestment");
    }

    /**
     * H1: the coinvested coverage leg additionally subtracts the junior raw NAV
     * Derivation: 2000e18 - (500e18 + 7 + 1000e18 + 3) = 500e18 - 10
     * NOTE the view honors state.jtCoinvested rather than the immutable — the kernel always marshals the state
     * from the immutable so they coincide in production, pinned here by toggling only the state field
     */
    function test_MaxSTDeposit_coinvestedAddsJTRawToCoverageLeg() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(7));
        _deploy(false, p);
        SyncedAccountingState memory st = _bareState(1000e18, 500e18, 0, 1000e18, 200e18, true, 0.1e18, 0);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 500e18 - 10, "coinvested coverage leg subtracts the junior raw NAV too");
    }

    /**
     * H1: with a zero minimum coverage the result is the liquidity leg alone:
     * floor(ltRaw * WAD / minLiquidity) - (stEff + stDust)
     * Derivation with zero dust: floor(123e18 * 1e18 / 0.05e18) = 2460e18, minus (1000e18 + 7) = 1460e18 - 7
     */
    function test_MaxSTDeposit_liquidityLegExactWhenMinCoverageZero() public view {
        SyncedAccountingState memory st = _bareState(900e18, 200e18, 123e18, 1000e18 + 7, 200e18, false, 0, 0.05e18);
        assertEq(toUint256(accountant.maxSTDeposit(st)), 1460e18 - 7, "liquidity leg exact against the senior effective NAV");
    }

    /// H1: each leg saturates to zero instead of underflowing when the requirement already binds
    function test_MaxSTDeposit_legsSaturateToZero() public view {
        // Coverage leg: the junior buffer covers only 500e18 against a 1000e18 senior raw NAV
        SyncedAccountingState memory covBound = _bareState(1000e18, 0, 0, 1000e18, 50e18, false, 0.1e18, 0);
        assertEq(toUint256(accountant.maxSTDeposit(covBound)), 0, "over-deployed coverage saturates to zero");
        // Liquidity leg: the inventory supports only 100e18 of senior value against a live 1000e18
        SyncedAccountingState memory liqBound = _bareState(1000e18, 0, 10e18, 1000e18, 200e18, false, 0, 0.1e18);
        assertEq(toUint256(accountant.maxSTDeposit(liqBound)), 0, "over-deployed liquidity saturates to zero");
    }

    /**
     * H1: the result is the minimum of the two legs, exercised in both directions
     * Derivation: the coverage leg is 2000e18 - 1000e18 = 1000e18 in both states, while the liquidity leg is
     * floor(80e18 / 0.05) - 1000e18 = 600e18 in the first and floor(200e18 / 0.05) - 1000e18 = 3000e18 in the second
     */
    function test_MaxSTDeposit_returnsMinOfBothLegs() public view {
        SyncedAccountingState memory liquidityBinds = _bareState(1000e18, 0, 80e18, 1000e18, 200e18, false, 0.1e18, 0.05e18);
        assertEq(toUint256(accountant.maxSTDeposit(liquidityBinds)), 600e18, "liquidity leg binds");
        SyncedAccountingState memory coverageBinds = _bareState(1000e18, 0, 200e18, 1000e18, 200e18, false, 0.1e18, 0.05e18);
        assertEq(toUint256(accountant.maxSTDeposit(coverageBinds)), 1000e18, "coverage leg binds");
    }

    /**
     * H2: coverage-binding inversion with zero dust — depositing exactly maxSTDeposit passes the enforced
     * gates landing coverage utilization exactly on WAD, and one more wei violates
     * Legs at the seed: coverage = floor(200e18 * 1e18 / 0.1e18) - 1000e18 = 1000e18 and
     * liquidity = floor(1000e18 * 1e18 / 0.05e18) - 1000e18 = 19000e18, so coverage binds with zero slack
     */
    function test_MaxSTDeposit_inversionCoverageBinding() public {
        _seedFlatWithLT(1000e18);
        NAV_UNIT max = accountant.maxSTDeposit(_checkpointState());
        assertEq(toUint256(max), 1000e18, "coverage leg binds at the independently derived value");
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + toUint256(max)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(1000e18)), ZERO_NAV_UNITS, true
        );
        assertEq(state.coverageUtilizationWAD, WAD, "the exact max lands coverage utilization on WAD");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(
            Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + toUint256(max) + 1), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(1000e18)), ZERO_NAV_UNITS, true
        );
    }

    /**
     * H2: liquidity-binding inversion with zero dust — the exact max lands liquidity utilization on WAD and
     * one more wei violates the liquidity requirement
     * Legs at the seed: coverage = floor(300e18 / 0.1) - 1000e18 = 2000e18 and liquidity = floor(100e18 / 0.05)
     * - 1000e18 = 1000e18, so liquidity binds with zero slack
     */
    function test_MaxSTDeposit_inversionLiquidityBinding() public {
        _seedState(SEED_ST_RAW, 300e18, SEED_ST_RAW, 300e18, 0, 100e18, MarketState.PERPETUAL);
        NAV_UNIT max = accountant.maxSTDeposit(_checkpointState());
        assertEq(toUint256(max), 1000e18, "liquidity leg binds at the independently derived value");
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + toUint256(max)), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true
        );
        assertEq(state.liquidityUtilizationWAD, WAD, "the exact max lands liquidity utilization on WAD");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(
            Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + toUint256(max) + 1), toNAVUnits(uint256(300e18)), toNAVUnits(uint256(100e18)), ZERO_NAV_UNITS, true
        );
    }

    /**
     * H2: the dust slack boundary — with st dust 3 and jt dust 7 the reported max under-shoots the true
     * coverage boundary by exactly the 10 wei slack, so max passes, max + slack still passes (landing exactly
     * on WAD), and max + slack + 1 violates
     */
    function test_MaxSTDeposit_inversionDustSlackBoundary() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(7));
        _deploy(false, p);
        _seedFlatWithLT(1000e18);
        NAV_UNIT max = accountant.maxSTDeposit(_checkpointState());
        assertEq(toUint256(max), 1000e18 - 10, "coverage leg minus the combined dust slack");
        // Deposit exactly the reported max
        kernel.doPostOp(
            Operation.ST_DEPOSIT, toNAVUnits(SEED_ST_RAW + toUint256(max)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(1000e18)), ZERO_NAV_UNITS, true
        );
        // Consume the 10 wei dust slack, landing coverage utilization exactly on WAD
        SyncedAccountingState memory state =
            kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(1000e18)), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "the slack consumed lands exactly on WAD");
        // One wei beyond max + slack violates
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(uint256(2000e18 + 1)), toNAVUnits(SEED_JT_RAW), toNAVUnits(uint256(1000e18)), ZERO_NAV_UNITS, true);
    }

    /**
     * H3: the flat-market closed form with zero dust — surplus = jtEff - ceil(stRaw * minCoverage / WAD) - 2,
     * the claim fractions are (0, WAD), retention is WAD when not coinvested, so the split is (0, surplus)
     * Derivation: (0, 200e18 - 100e18 - 2)
     */
    function test_MaxJTWithdrawal_flatMarketClosedForm() public view {
        SyncedAccountingState memory st = _bareState(1000e18, 200e18, 100e18, 1000e18, 200e18, false, 0.1e18, DEFAULT_MIN_LIQUIDITY_WAD);
        (NAV_UNIT stW, NAV_UNIT jtW) = accountant.maxJTWithdrawal(st);
        assertEq(toUint256(stW), 0, "flat market claims nothing from the senior raw NAV");
        assertEq(toUint256(jtW), 100e18 - 2, "junior withdrawable equals the surplus minus the 2 wei fudge");
    }

    /**
     * H3: the surplus early-out boundary — a junior buffer of exactly the required value plus the 2 wei fudge
     * reports (0, 0), and one more wei reports (0, 1)
     */
    function test_MaxJTWithdrawal_zeroAtSurplusBoundary() public view {
        SyncedAccountingState memory atBoundary = _bareState(1000e18, 100e18 + 2, 0, 1000e18, 100e18 + 2, false, 0.1e18, 0);
        (NAV_UNIT stW, NAV_UNIT jtW) = accountant.maxJTWithdrawal(atBoundary);
        assertEq(toUint256(stW) + toUint256(jtW), 0, "the 2 wei fudge makes the surplus exactly zero");
        SyncedAccountingState memory oneAbove = _bareState(1000e18, 100e18 + 3, 0, 1000e18, 100e18 + 3, false, 0.1e18, 0);
        (stW, jtW) = accountant.maxJTWithdrawal(oneAbove);
        assertEq(toUint256(stW), 0, "still nothing from the senior raw NAV");
        assertEq(toUint256(jtW), 1, "one wei above the fudge boundary is withdrawable");
    }

    /**
     * H3: the totalJTClaims == 0 early-out returns (0, 0)
     * NOTE (map correction): under NAV conservation totalJTClaims always equals jtEffectiveNAV, and a zero
     * junior effective NAV is already caught by the surplus early-out, so this branch is reachable only with a
     * non-conserved state — it is a defensive arm, exercised here with a deliberately non-conserved input.
     * NOTE (map correction): the totalNAVClaimable == 0 early-out at :436 is fully unreachable — with a
     * positive surplus, mulDiv(surplus, WAD, retention) >= surplus >= 1 because retention is in [1, WAD]
     */
    function test_MaxJTWithdrawal_zeroWhenTotalJTClaimsZero() public view {
        SyncedAccountingState memory st = _bareState(0, 10e18, 0, 10e18, 10e18, false, 0.1e18, 0);
        (NAV_UNIT stW, NAV_UNIT jtW) = accountant.maxJTWithdrawal(st);
        assertEq(toUint256(stW) + toUint256(jtW), 0, "zero total junior claims early-outs to nothing withdrawable");
    }

    /**
     * H3: the cross-claim fraction split matches the independent floor-by-floor mirror
     * State: (stRaw 1000e18, jtRaw 200e18, stEff 980e18, jtEff 220e18) so the junior claims are 20e18 on the
     * senior raw NAV and 200e18 on its own, not coinvested, minCoverage 0.1e18, zero dust
     */
    function test_MaxJTWithdrawal_crossClaimFractionSplitExact() public view {
        SyncedAccountingState memory st = _bareState(1000e18, 200e18, SEED_LT_RAW, 980e18, 220e18, false, 0.1e18, DEFAULT_MIN_LIQUIDITY_WAD);
        (NAV_UNIT stW, NAV_UNIT jtW) = accountant.maxJTWithdrawal(st);
        // Mirror: required = ceil(1000e18 * 0.1e18 / 1e18) = 100e18, surplus = 220e18 - 100e18 - 2
        uint256 surplus = 220e18 - 100e18 - 2;
        // Claims per F14: jtClaimOnST = satSub(220e18 - 200e18) = 20e18 and jtClaimOnJT = 200e18 - satSub(980e18 - 1000e18) = 200e18
        uint256 fracST = (uint256(20e18) * WAD) / 220e18;
        uint256 fracJT = (uint256(200e18) * WAD) / 220e18;
        // Not coinvested, so only the senior-claim fraction erodes coverage per withdrawn NAV unit
        uint256 retention = WAD - ((uint256(0.1e18) * fracST) / WAD);
        uint256 claimable = (surplus * WAD) / retention;
        assertEq(toUint256(stW), (claimable * fracST) / WAD, "senior-side withdrawable value floors exactly");
        assertEq(toUint256(jtW), (claimable * fracJT) / WAD, "junior-side withdrawable value floors exactly");
        assertLe(toUint256(stW) + toUint256(jtW), claimable, "compounded floors keep the split within the claimable total");
    }

    /**
     * H3: coinvestment toggles the required value (adds jtRaw), the dust term (adds jtDust — note the mirror
     * asymmetry with maxSTDeposit, which always includes jtDust), and the retention fraction (adds the
     * junior-claim fraction), all pinned against the independent mirror on one deployment
     */
    function test_MaxJTWithdrawal_coinvestedTogglesRequiredDustAndRetention() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        p.jtNAVDustTolerance = toNAVUnits(uint256(7));
        _deploy(false, p);
        // Coinvested flat state: required = ceil(1200e18 * 0.1) = 120e18, surplus = 200e18 - (120e18 + 3 + 7 + 2),
        // retention = 1e18 - floor(0.1e18 * (0 + 1e18) / 1e18) = 0.9e18, claimable = floor(surplus * 1e18 / 0.9e18)
        SyncedAccountingState memory coinvested = _bareState(1000e18, 200e18, 0, 1000e18, 200e18, true, 0.1e18, 0);
        (NAV_UNIT stW, NAV_UNIT jtW) = accountant.maxJTWithdrawal(coinvested);
        uint256 surplus = 200e18 - (120e18 + 3 + 7 + 2);
        uint256 claimable = (surplus * WAD) / 0.9e18;
        assertEq(toUint256(stW), 0, "flat claims put nothing on the senior raw NAV");
        assertEq(toUint256(jtW), claimable, "coinvested junior withdrawable grossed up by the retention");
        // Risk-free twin on the same deployment: required = 100e18, jtDust excluded, retention = WAD
        SyncedAccountingState memory riskFree = _bareState(1000e18, 200e18, 0, 1000e18, 200e18, false, 0.1e18, 0);
        (stW, jtW) = accountant.maxJTWithdrawal(riskFree);
        assertEq(toUint256(stW), 0, "flat claims put nothing on the senior raw NAV");
        assertEq(toUint256(jtW), 100e18 - 5, "risk-free junior withdrawable excludes jtDust from the slack");
    }

    /**
     * H4: the +2 wei fudge boundary — redeeming exactly maxJTWithdrawal passes the enforced coverage gate, the
     * two fudge wei can still be withdrawn one at a time (coverage utilization stays at WAD by ceil), and the
     * third extra wei is the first to violate
     * Arithmetic: max leaves jtEff at 1e20 + 2 where ceil(1e38 / (1e20 + k)) = 1e18 for k in {0, 1, 2} while
     * ceil(1e38 / (1e20 - 1)) = 1e18 + 1
     */
    function test_MaxJTWithdrawal_inversionFudgeBoundary() public {
        _seedFlatWithLT(SEED_LT_RAW);
        (NAV_UNIT stW, NAV_UNIT jtW) = accountant.maxJTWithdrawal(_checkpointState());
        assertEq(toUint256(stW), 0, "flat market withdraws from the junior raw NAV only");
        assertEq(toUint256(jtW), 100e18 - 2, "max reported with the 2 wei fudge");
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW - toUint256(jtW)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true
        );
        assertEq(state.coverageUtilizationWAD, WAD, "the exact max lands coverage utilization on WAD");
        state = kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(uint256(100e18 + 1)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "max + 1 still passes inside the fudge");
        state = kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(uint256(100e18)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true);
        assertEq(state.coverageUtilizationWAD, WAD, "max + 2 exhausts the fudge exactly at WAD");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(Operation.JT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(uint256(100e18 - 1)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true);
    }

    /**
     * H4: cross-claim inversion — redeeming exactly the (stW, jtW) split from a JT-cross-claim checkpoint
     * passes the enforced coverage gate, and a further 1000 wei violates
     * Slack anatomy for this vector: the 2 wei fudge, up to ~3 wei of compounded mulDiv floors, and — the
     * dominant term — the floored claim fractions summing to 1e18 - 1 rather than 1e18, which strands about
     * claimable / 1e18 (~121 wei here) of the claimable total un-split, so the probe uses a 1000 wei margin
     */
    function test_MaxJTWithdrawal_inversionCrossClaim() public {
        _seedState(1000e18, 200e18, 980e18, 220e18, 0, SEED_LT_RAW, MarketState.PERPETUAL);
        (NAV_UNIT stW, NAV_UNIT jtW) = accountant.maxJTWithdrawal(_checkpointState());
        assertGt(toUint256(stW), 0, "the cross-claim state withdraws from the senior raw NAV too");
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.JT_REDEEM, toNAVUnits(1000e18 - toUint256(stW)), toNAVUnits(200e18 - toUint256(jtW)), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true
        );
        assertLe(state.coverageUtilizationWAD, WAD, "the exact cross-claim max clears the enforced coverage gate");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(
            Operation.JT_REDEEM, toNAVUnits(1000e18 - toUint256(stW)), toNAVUnits(200e18 - toUint256(jtW) - 1000), toNAVUnits(SEED_LT_RAW), ZERO_NAV_UNITS, true
        );
    }

    /// H5: with a zero minimum liquidity the entire liquidity raw NAV is withdrawable
    function test_MaxLTWithdrawal_fullLTRawWhenMinLiquidityZero() public view {
        SyncedAccountingState memory st = _bareState(1000e18, 200e18, 77e18, 1000e18, 200e18, false, 0.1e18, 0);
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 77e18, "no requirement leaves the full inventory withdrawable");
    }

    /**
     * H5: a coverage utilization at or above the liquidation threshold unlocks the entire liquidity raw NAV,
     * inclusive at the exact boundary and at the uint256 max wipeout reading, while one below stays restricted
     */
    function test_MaxLTWithdrawal_fullLTRawAtLiquidationBoundary() public view {
        SyncedAccountingState memory st = _bareState(1000e18, 200e18, 100e18, 1000e18, 200e18, false, 0.1e18, 0.05e18);
        st.coverageLiquidationUtilizationWAD = DEFAULT_LIQUIDATION_UTILIZATION_WAD;
        st.coverageUtilizationWAD = DEFAULT_LIQUIDATION_UTILIZATION_WAD;
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 100e18, "the exact liquidation boundary unlocks the full inventory");
        st.coverageUtilizationWAD = type(uint256).max;
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 100e18, "a wipeout-grade utilization unlocks the full inventory");
        st.coverageUtilizationWAD = DEFAULT_LIQUIDATION_UTILIZATION_WAD - 1;
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 50e18, "one below the boundary stays requirement-restricted");
    }

    /**
     * H5: the closed form ceils the required depth and saturates to zero
     * Derivation: required = ceil((1000e18 + 7) * 0.05e18 / 1e18) = 50e18 + 1 (the 0.35 wei product remainder
     * rounds up), so 100e18 of inventory leaves 50e18 - 1 withdrawable, an inventory of 40e18 saturates to
     * zero, and an st dust of 3 shrinks the withdrawable to 50e18 - 4
     */
    function test_MaxLTWithdrawal_closedFormCeilAndSaturation() public {
        SyncedAccountingState memory st = _bareState(1000e18, 200e18, 100e18, 1000e18 + 7, 200e18, false, 0.1e18, 0.05e18);
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 50e18 - 1, "inner ceil rounds the required depth up");
        st.ltRawNAV = toNAVUnits(uint256(40e18));
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 0, "under-provisioned inventory saturates to zero");
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stNAVDustTolerance = toNAVUnits(uint256(3));
        _deploy(false, p);
        st.ltRawNAV = toNAVUnits(uint256(100e18));
        assertEq(toUint256(accountant.maxLTWithdrawal(st)), 50e18 - 4, "st dust tolerance shrinks the withdrawable depth");
    }

    /**
     * H5: inversion against the LT_REDEEM liquidity gate — redeeming exactly maxLTWithdrawal passes with
     * enforcement landing liquidity utilization exactly on WAD, and one more wei violates
     * Derivation: max = 100e18 - ceil(1000e18 * 0.05e18 / 1e18) = 50e18 with zero dust
     */
    function test_MaxLTWithdrawal_inversionExactBoundary() public {
        _seedFlatWithLT(SEED_LT_RAW);
        NAV_UNIT max = accountant.maxLTWithdrawal(_checkpointState());
        assertEq(toUint256(max), 50e18, "closed form at the flat seed");
        SyncedAccountingState memory state = kernel.doPostOp(
            Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW - toUint256(max)), ZERO_NAV_UNITS, true
        );
        assertEq(state.liquidityUtilizationWAD, WAD, "the exact max lands liquidity utilization on WAD");
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        kernel.doPostOp(
            Operation.LT_REDEEM, toNAVUnits(SEED_ST_RAW), toNAVUnits(SEED_JT_RAW), toNAVUnits(SEED_LT_RAW - toUint256(max) - 1), ZERO_NAV_UNITS, true
        );
    }

    // Part 4 appends below this line, before the closing brace
}
