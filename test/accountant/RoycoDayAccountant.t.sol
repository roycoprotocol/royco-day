// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test, Vm } from "../../lib/forge-std/src/Test.sol";
import { Initializable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
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
                stEff: 1000e18, jtEff: 220e18, il: 0, ltPrem: 0, stFee: 0, jtFee: 2e18, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEnd: 0
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
                stEff: 1000e18 + 5, jtEff: 180e18 - 5, il: 5, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEnd: 0
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
                stEff: 1000e18 + 5, jtEff: 200e18 - 5, il: 5, ltPrem: 0, stFee: 0, jtFee: 0, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEnd: 0
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
                stEff: 1000e18 + 5, jtEff: 220e18 - 5, il: 5, ltPrem: 0, stFee: 0, jtFee: 2e18, ltFee: 0, marketState: MarketState.PERPETUAL, fixedTermEnd: 0
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
     *   then over a further 50s (tw compounds to 15e18 / 7.5e18, window 150s), gain 71:
     *   jtPrem = floor(71 * 15e18 / 150e18) = 7, ltPrem = floor(71 * 7.5e18 / 150e18) = 3, stFee = floor(61 * 0.1) = 6
     *   (the jt and lt fee floors are 0 at this magnitude), accumulators reset and the premium clock advances
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
        state = kernel.doPreOp(toNAVUnits(SEED_ST_RAW + 141), toNAVUnits(SEED_JT_RAW));
        assertEq(toUint256(state.jtEffectiveNAV), SEED_JT_RAW + 14, "compounded window premium on the second gain");
        assertEq(toUint256(state.ltLiquidityPremium), 3, "compounded window lt premium");
        assertEq(toUint256(state.stProtocolFee), 6, "st fee taken one wei above dust");
        s = accountant.getState();
        assertEq(s.twJTYieldShareAccruedWAD, 0, "jt accumulator reset once premiums are paid");
        assertEq(s.twLTYieldShareAccruedWAD, 0, "lt accumulator reset once premiums are paid");
        assertEq(s.lastPremiumPaymentTimestamp, uint32(block.timestamp), "premium clock advances on payment");
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
        assertEq(s.lastPremiumPaymentTimestamp, uint32(block.timestamp), "premium clock advances on payment");
        assertGt(uint256(s.lastPremiumPaymentTimestamp), uint256(windowStart), "the window genuinely moved");
    }

    // Parts 3-4 append below this line, before the closing brace
}
