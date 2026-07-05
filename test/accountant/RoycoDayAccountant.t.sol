// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Initializable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { RoycoDayAccountant } from "../../src/accountant/RoycoDayAccountant.sol";
import { IRoycoAuth } from "../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { MAX_PROTOCOL_FEE_WAD, WAD, ZERO_NAV_UNITS } from "../../src/libraries/Constants.sol";
import { MarketState, Operation, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";

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
    uint256 internal constant SEED_ST_RAW = 1_000e18;
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
    function _seedState(
        uint256 _stRaw,
        uint256 _jtRaw,
        uint256 _stEff,
        uint256 _jtEff,
        uint256 _il,
        uint256 _ltRaw,
        MarketState _targetState
    )
        internal
    {
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
        assertEq(toUint256(state.stEffectiveNAV), 1_090e18, "st retains residual plus lt premium carve-out");
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
        _seedState(900e18, 300e18, 1_000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
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
        _seedState(900e18, 300e18, 1_000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
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
        _seedState(900e18, 300e18, 1_000e18, 200e18, 100e18, SEED_LT_RAW, MarketState.FIXED_TERM);
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

    // Parts 2-4 append below this line, before the closing brace
}
