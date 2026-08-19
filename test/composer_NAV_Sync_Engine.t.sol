// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManager } from "../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ReentrancyGuardTransient } from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import { Math } from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { stdError } from "../lib/forge-std/src/StdError.sol";
import { Test } from "../lib/forge-std/src/Test.sol";

import { RoycoDayAccountant } from "../src/accountant/RoycoDayAccountant.sol";
import { IRoycoAuth } from "../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../src/interfaces/IRoycoDayAccountant.sol";
import { IYDM } from "../src/interfaces/IYDM.sol";
import { MAX_PROTOCOL_FEE_WAD, WAD, ZERO_NAV_UNITS } from "../src/libraries/Constants.sol";
import { AssetClaims, MarketState, Operation, SyncedAccountingState } from "../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../src/libraries/Units.sol";

import { MockAccountantKernel } from "./mocks/MockAccountantKernel.sol";
import { MockRecordingYDM } from "./mocks/MockRecordingYDM.sol";
import { SelfLiquidationHarness } from "./mocks/SelfLiquidationHarness.sol";
import { UninitializedERC1967Proxy } from "./mocks/UninitializedERC1967Proxy.sol";

contract AccountantHarness is RoycoDayAccountant { }

contract GuardedMockKernel is MockAccountantKernel, ReentrancyGuardTransient {
    function guardedPreOp(NAV_UNIT _collateralNAV) external nonReentrant returns (SyncedAccountingState memory) {
        return accountant.preOpSyncTrancheAccounting(_collateralNAV);
    }

    function guardedPostOp(
        Operation _op,
        NAV_UNIT _collateralNAV,
        NAV_UNIT _lptRawNAV,
        NAV_UNIT _bonus
    )
        external
        nonReentrant
        returns (SyncedAccountingState memory)
    {
        return accountant.postOpSyncTrancheAccounting(_op, _collateralNAV, _lptRawNAV, _bonus);
    }
}

contract EchoUtilizationYDM is IYDM {
    function previewYieldShare(MarketState, uint256 _utilizationWAD) external pure override(IYDM) returns (uint256) {
        return _utilizationWAD;
    }

    function yieldShare(MarketState, uint256 _utilizationWAD) external pure override(IYDM) returns (uint256) {
        return _utilizationWAD;
    }
}

contract KernelReentrantYDM is IYDM {
    address public target;
    bytes public payload;
    bool public armed;
    bool public attempted;
    bool public reentrySucceeded;
    bytes4 public reentryRevertSelector;

    function arm(address _target, bytes calldata _payload) external {
        target = _target;
        payload = _payload;
        armed = true;
    }

    function previewYieldShare(MarketState, uint256) external pure override(IYDM) returns (uint256) {
        return 0;
    }

    function yieldShare(MarketState, uint256) external override(IYDM) returns (uint256) {
        if (armed) {
            armed = false;
            attempted = true;
            (bool ok, bytes memory ret) = target.call(payload);
            reentrySucceeded = ok;
            if (!ok && ret.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(ret, 0x20))
                }
                reentryRevertSelector = sel;
            }
        }
        return 0;
    }
}

contract Test_RoycoDayAccountant_NavSyncEngine is Test {
    uint64 internal constant MIN_COVERAGE = 0.1e18;
    uint256 internal constant LIQ_UTIL = 1.1e18;
    uint64 internal constant MIN_LIQUIDITY = 0.05e18;
    uint64 internal constant MAX_JT_SHARE = 0.2e18;
    uint64 internal constant MAX_LPT_SHARE = 0.1e18;
    uint24 internal constant TERM = 604_800;
    uint64 internal constant FEE = 0.1e18;

    uint256 internal constant SEED_ST = 1000e18;
    uint256 internal constant SEED_JT = 200e18;
    uint256 internal constant SEED_C = 1200e18;
    uint256 internal constant SEED_LPT = 100e18;

    RoycoDayAccountant internal accountant;
    GuardedMockKernel internal kernel;
    MockRecordingYDM internal jtYDM;
    MockRecordingYDM internal lptYDM;
    AccessManager internal authority;

    function setUp() public {
        vm.warp(1_000_000);
    }

    function _defaultParams() internal pure returns (IRoycoDayAccountant.RoycoDayAccountantInitParams memory p) {
        p.minCoverageWAD = MIN_COVERAGE;
        p.coverageLiquidationUtilizationWAD = LIQ_UTIL;
        p.minLiquidityWAD = MIN_LIQUIDITY;
        p.maxJTYieldShareWAD = MAX_JT_SHARE;
        p.maxLPTYieldShareWAD = MAX_LPT_SHARE;
        p.fixedTermDurationSeconds = TERM;
        p.dustTolerance = ZERO_NAV_UNITS;
        p.stProtocolFeeWAD = FEE;
        p.jtProtocolFeeWAD = FEE;
        p.jtYieldShareProtocolFeeWAD = FEE;
        p.lptYieldShareProtocolFeeWAD = FEE;
    }

    function _baseParams(address _jt, address _lpt) internal view returns (IRoycoDayAccountant.RoycoDayAccountantInitParams memory p) {
        p = _defaultParams();
        p.kernel = address(kernel);
        p.initialAuthority = address(authority);
        p.jtYDM = _jt;
        p.lptYDM = _lpt;
    }

    function _deployUninitialized() internal returns (RoycoDayAccountant acct) {
        kernel = new GuardedMockKernel();
        authority = new AccessManager(address(this));
        AccountantHarness impl = new AccountantHarness();
        acct = RoycoDayAccountant(address(new UninitializedERC1967Proxy(address(impl))));
        kernel.setAccountant(address(acct));
    }

    function _deploy(IRoycoDayAccountant.RoycoDayAccountantInitParams memory _p) internal returns (RoycoDayAccountant acct) {
        return _deployWithGrace(_p, 0);
    }

    function _deployWithGrace(
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory _p,
        uint24 _grace
    )
        internal
        returns (RoycoDayAccountant acct)
    {
        acct = _deployUninitialized();
        if (_p.jtYDM == address(0)) _p.jtYDM = address(new MockRecordingYDM());
        if (_p.lptYDM == address(0)) _p.lptYDM = address(new MockRecordingYDM());
        jtYDM = MockRecordingYDM(_p.jtYDM);
        lptYDM = MockRecordingYDM(_p.lptYDM);
        _p.kernel = address(kernel);
        _p.initialAuthority = address(authority);
        _p.fixedTermGracePeriodSeconds = _grace;
        acct.initialize(_p);
        accountant = acct;
    }

    function _seedState(uint256 _st, uint256 _jt, uint256 _il, uint256 _lpt, MarketState _target) internal {
        if (_st > 0) kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(_st), ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        if (_jt + _il > 0) kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(_st + _jt + _il), ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        if (_il > 0) kernel.doPreOp(toNAVUnits(_st + _jt));
        kernel.doCommit(toNAVUnits(_lpt));

        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(toUint256(s.lastCollateralNAV), _st + _jt, "seed: collateralNAV");
        assertEq(toUint256(s.lastSTEffectiveNAV), _st, "seed: stEffectiveNAV");
        assertEq(toUint256(s.lastJTEffectiveNAV), _jt, "seed: jtEffectiveNAV");
        assertEq(toUint256(s.lastJTImpermanentLoss), _il, "seed: il");
        assertEq(toUint256(s.lastLPTRawNAV), _lpt, "seed: lptRawNAV");
        assertEq(uint8(s.lastMarketState), uint8(_target), "seed: marketState");
    }

    function _seedFlat() internal {
        _seedState(SEED_ST, SEED_JT, 0, SEED_LPT, MarketState.PERPETUAL);
    }

    function _seedFixedTerm() internal {
        _deploy(_defaultParams());
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C - 10e18));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = accountant.getState();
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "seedFixedTerm: state");
        assertEq(toUint256(s.lastJTImpermanentLoss), 10e18, "seedFixedTerm: il");
    }

    /// @dev Advance the clock by `_dt` seconds and prove the advance actually took effect
    function _advance(uint256 _dt) internal {
        uint256 target = block.timestamp + _dt;
        vm.warp(target);
        assertEq(block.timestamp, target, "clock advance");
    }

    function _snap() internal view returns (IRoycoDayAccountant.RoycoDayAccountantState memory) {
        return accountant.getState();
    }

    function _stateHash() internal view returns (bytes32) {
        return keccak256(abi.encode(accountant.getState()));
    }

    function _covUtil(uint256 _c, uint256 _minCov, uint256 _jt) internal pure returns (uint256) {
        if (_minCov == 0 || _c == 0) return 0;
        if (_jt == 0) return type(uint256).max;
        return Math.mulDiv(_c, _minCov, _jt, Math.Rounding.Ceil);
    }

    function _liqUtil(uint256 _st, uint256 _minLiq, uint256 _lpt) internal pure returns (uint256) {
        if (_st == 0 || _minLiq == 0) return 0;
        if (_lpt == 0) return type(uint256).max;
        return Math.mulDiv(_st, _minLiq, _lpt, Math.Rounding.Ceil);
    }

    function _rate(uint256 _premium, uint256 _stGain) internal pure returns (uint256) {
        return _stGain == 0 ? 0 : Math.mulDiv(_premium, WAD, _stGain, Math.Rounding.Floor);
    }

    /// @dev The combined JT risk premium + LPT liquidity premium a sync paid, recovered from the returned state.
    ///      Valid whenever the pre-state carries no impermanent loss (pure-gain syncs).
    function _premiumOf(uint256 _st0, uint256 _jt0, uint256 _gain, SyncedAccountingState memory _s) internal pure returns (uint256) {
        uint256 c0 = _st0 + _jt0;
        uint256 stGain = Math.mulDiv(_gain, _st0, c0, Math.Rounding.Floor);
        uint256 jtGain = _gain - stGain;
        return (toUint256(_s.jtEffectiveNAV) - _jt0 - jtGain) + toUint256(_s.lptLiquidityPremium);
    }

    function _assertStorageConservation(string memory _tag) internal view {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = _snap();
        assertEq(
            toUint256(s.lastCollateralNAV),
            toUint256(s.lastSTEffectiveNAV) + toUint256(s.lastJTEffectiveNAV),
            string.concat(_tag, ": storage conservation")
        );
    }

    function _assertReturnedConservation(SyncedAccountingState memory _st, string memory _tag) internal pure {
        assertEq(
            toUint256(_st.collateralNAV), toUint256(_st.stEffectiveNAV) + toUint256(_st.jtEffectiveNAV), string.concat(_tag, ": returned conservation")
        );
    }

    function _assertConfigBounds(string memory _tag) internal view {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = _snap();
        assertTrue(s.kernel != address(0), string.concat(_tag, ": kernel"));
        assertLt(uint256(s.minCoverageWAD), WAD, string.concat(_tag, ": minCoverage"));
        assertLt(uint256(s.minLiquidityWAD), WAD, string.concat(_tag, ": minLiquidity"));
        assertGt(s.coverageLiquidationUtilizationWAD, WAD, string.concat(_tag, ": liqUtil"));
        assertLe(uint256(s.stProtocolFeeWAD), MAX_PROTOCOL_FEE_WAD, string.concat(_tag, ": stFee"));
        assertLe(uint256(s.jtProtocolFeeWAD), MAX_PROTOCOL_FEE_WAD, string.concat(_tag, ": jtFee"));
        assertLe(uint256(s.jtYieldShareProtocolFeeWAD), MAX_PROTOCOL_FEE_WAD, string.concat(_tag, ": jtYsFee"));
        assertLe(uint256(s.lptYieldShareProtocolFeeWAD), MAX_PROTOCOL_FEE_WAD, string.concat(_tag, ": lptYsFee"));
        assertLe(uint256(s.maxJTYieldShareWAD) + uint256(s.maxLPTYieldShareWAD), WAD, string.concat(_tag, ": maxShares"));
        assertTrue(s.jtYDM != address(0) && s.lptYDM != address(0), string.concat(_tag, ": ydm non-zero"));
        assertTrue(s.jtYDM != s.lptYDM, string.concat(_tag, ": ydm distinct"));
    }

    function _assertPerpetualBiconditional(string memory _tag) internal view {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = _snap();
        bool perpetual = (s.lastMarketState == MarketState.PERPETUAL);
        assertEq(perpetual, toUint256(s.lastJTImpermanentLoss) == 0, string.concat(_tag, ": PERPETUAL <-> il == 0"));
        assertEq(perpetual, s.fixedTermEndTimestamp == 0, string.concat(_tag, ": PERPETUAL <-> no term stamp"));
    }

    function _assertAccrualWindowBound(string memory _tag) internal view {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = _snap();
        if (s.lastYieldShareAccrualTimestamp == 0) {
            assertEq(uint256(s.twJTYieldShareAccruedWAD), 0, string.concat(_tag, ": unset clock twJT"));
            assertEq(uint256(s.twLPTYieldShareAccruedWAD), 0, string.concat(_tag, ": unset clock twLPT"));
            assertEq(uint256(s.lastPremiumPaymentTimestamp), 0, string.concat(_tag, ": unset clock premiumTs"));
            return;
        }
        assertLe(uint256(s.lastPremiumPaymentTimestamp), uint256(s.lastYieldShareAccrualTimestamp), string.concat(_tag, ": premiumTs <= accrualTs"));
        assertLe(uint256(s.lastYieldShareAccrualTimestamp), block.timestamp, string.concat(_tag, ": accrualTs <= now"));
        uint256 window = uint256(s.lastYieldShareAccrualTimestamp) - uint256(s.lastPremiumPaymentTimestamp);
        assertLe(
            uint256(s.twJTYieldShareAccruedWAD) + uint256(s.twLPTYieldShareAccruedWAD),
            WAD * window,
            string.concat(_tag, ": accumulators within window")
        );
    }

    function _assertNoDistribution(SyncedAccountingState memory _st, string memory _tag) internal pure {
        assertEq(toUint256(_st.lptLiquidityPremium), 0, string.concat(_tag, ": lptLiquidityPremium"));
        assertEq(toUint256(_st.stProtocolFee), 0, string.concat(_tag, ": stProtocolFee"));
        assertEq(toUint256(_st.jtProtocolFee), 0, string.concat(_tag, ": jtProtocolFee"));
        assertEq(toUint256(_st.lptProtocolFee), 0, string.concat(_tag, ": lptProtocolFee"));
    }

    function _assertMirrorsCheckpoint(SyncedAccountingState memory _st, string memory _tag) internal view {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = _snap();
        assertEq(uint8(_st.marketState), uint8(s.lastMarketState), string.concat(_tag, ": marketState"));
        assertEq(toUint256(_st.collateralNAV), toUint256(s.lastCollateralNAV), string.concat(_tag, ": collateralNAV"));
        assertEq(toUint256(_st.stEffectiveNAV), toUint256(s.lastSTEffectiveNAV), string.concat(_tag, ": stEffectiveNAV"));
        assertEq(toUint256(_st.jtEffectiveNAV), toUint256(s.lastJTEffectiveNAV), string.concat(_tag, ": jtEffectiveNAV"));
        assertEq(toUint256(_st.jtImpermanentLoss), toUint256(s.lastJTImpermanentLoss), string.concat(_tag, ": jtImpermanentLoss"));
        assertEq(uint256(_st.fixedTermEndTimestamp), uint256(s.fixedTermEndTimestamp), string.concat(_tag, ": fixedTermEndTimestamp"));
        assertEq(_st.minCoverageWAD, uint256(s.minCoverageWAD), string.concat(_tag, ": minCoverageWAD"));
        assertEq(_st.minLiquidityWAD, uint256(s.minLiquidityWAD), string.concat(_tag, ": minLiquidityWAD"));
        assertEq(
            _st.coverageLiquidationUtilizationWAD, s.coverageLiquidationUtilizationWAD, string.concat(_tag, ": coverageLiquidationUtilizationWAD")
        );
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 1 - nav_conservation_wei_exact
    //////////////////////////////////////////////////////////////////////*/

    function test_NAVConservationHoldsFromInitialize() public {
        _deploy(_defaultParams());
        _assertStorageConservation("init");

        _seedFlat();
        _assertStorageConservation("seeded");

        SyncedAccountingState memory st = kernel.doPreOp(toNAVUnits(SEED_C + 33e18));
        _assertReturnedConservation(st, "preOp gain");
        _assertStorageConservation("preOp gain");

        st = kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(toUint256(_snap().lastCollateralNAV) + 7e18), _snap().lastLPTRawNAV, ZERO_NAV_UNITS);
        _assertReturnedConservation(st, "postOp deposit");
        _assertStorageConservation("postOp deposit");

        kernel.doCommit(toNAVUnits(uint256(123e18)));
        _assertStorageConservation("commit");

        accountant.setSeniorTrancheProtocolFee(0.2e18);
        _assertStorageConservation("setST");
        accountant.setJuniorTrancheProtocolFee(0.2e18);
        _assertStorageConservation("setJT");
        accountant.setJTYieldShareProtocolFee(0.2e18);
        _assertStorageConservation("setJTYS");
        accountant.setLPTYieldShareProtocolFee(0.2e18);
        _assertStorageConservation("setLPTYS");
        accountant.setMinCoverage(0.3e18);
        _assertStorageConservation("setMinCov");
        accountant.setLiquidationCoverageUtilization(1.5e18);
        _assertStorageConservation("setLiqUtil");
        accountant.setMinLiquidity(0.06e18);
        _assertStorageConservation("setMinLiq");
        accountant.setMaxYieldShares(0.3e18, 0.2e18);
        _assertStorageConservation("setMaxShares");
        accountant.setFixedTermDuration(1_209_600);
        _assertStorageConservation("setTerm");
        accountant.setDustTolerance(toNAVUnits(uint256(5)));
        _assertStorageConservation("setDust");
    }

    function testFuzz_NAVConservationWeiExact(uint256 _st0, uint256 _jt0, uint256 _c1, uint256 _c2) public {
        _st0 = bound(_st0, 1e18, 1e30);
        _jt0 = bound(_jt0, 1e18, 1e30);
        _c1 = bound(_c1, 0, 1e33);
        _c2 = bound(_c2, 0, 1e33);

        _deploy(_defaultParams());
        _seedState(_st0, _jt0, 0, SEED_LPT, MarketState.PERPETUAL);
        _assertStorageConservation("seed");

        SyncedAccountingState memory st = kernel.doPreOp(toNAVUnits(_c1));
        _assertReturnedConservation(st, "sync1");
        _assertStorageConservation("sync1");

        _advance(100);
        st = kernel.doPreOp(toNAVUnits(_c2));
        _assertReturnedConservation(st, "sync2");
        _assertStorageConservation("sync2");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 2 - perpetual_iff_zero_impermanent_loss_and_term
    //////////////////////////////////////////////////////////////////////*/

    function testFuzz_PerpetualIffZeroILAndZeroTermStamp(uint256 _c1, uint256 _c2, uint256 _c3, uint256 _dt) public {
        _c1 = bound(_c1, 0, 3000e18);
        _c2 = bound(_c2, 0, 3000e18);
        _c3 = bound(_c3, 0, 3000e18);
        _dt = bound(_dt, 0, 2_000_000);

        _deploy(_defaultParams());
        _assertPerpetualBiconditional("fresh");
        _seedFlat();
        _assertPerpetualBiconditional("seeded");

        kernel.doPreOp(toNAVUnits(_c1));
        _assertPerpetualBiconditional("sync1");

        _advance(_dt);
        kernel.doPreOp(toNAVUnits(_c2));
        _assertPerpetualBiconditional("sync2");

        kernel.doPreOp(toNAVUnits(_c3));
        _assertPerpetualBiconditional("sync3");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 3 - accountant_config_bounds_always_valid
    //////////////////////////////////////////////////////////////////////*/

    function test_ConfigBoundsValidAfterInitAndEverySetter() public {
        _deploy(_defaultParams());
        _assertConfigBounds("init");

        accountant.setSeniorTrancheProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD));
        _assertConfigBounds("stFee");
        accountant.setJuniorTrancheProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD));
        _assertConfigBounds("jtFee");
        accountant.setJTYieldShareProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD));
        _assertConfigBounds("jtYsFee");
        accountant.setLPTYieldShareProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD));
        _assertConfigBounds("lptYsFee");
        accountant.setMinCoverage(uint64(WAD - 1));
        _assertConfigBounds("minCov");
        accountant.setLiquidationCoverageUtilization(WAD + 1);
        _assertConfigBounds("liqUtil");
        accountant.setMinLiquidity(uint64(WAD - 1));
        _assertConfigBounds("minLiq");
        accountant.setMaxYieldShares(uint64(WAD), 0);
        _assertConfigBounds("maxShares");
        accountant.setFixedTermDuration(0);
        _assertConfigBounds("term");
        accountant.setDustTolerance(toNAVUnits(uint256(type(uint128).max)));
        _assertConfigBounds("dust");

        MockRecordingYDM freshJT = new MockRecordingYDM();
        accountant.setJuniorTrancheYDM(address(freshJT), "");
        _assertConfigBounds("jtYDM");
        MockRecordingYDM freshLPT = new MockRecordingYDM();
        accountant.setLiquidityProviderTrancheYDM(address(freshLPT), "");
        _assertConfigBounds("lptYDM");
    }

    function test_RevertWhen_ConfigBoundsViolated() public {
        RoycoDayAccountant acct = _deployUninitialized();
        MockRecordingYDM a = new MockRecordingYDM();
        MockRecordingYDM b = new MockRecordingYDM();

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory q;

        q = _baseParams(address(a), address(b));
        q.kernel = address(0);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        acct.initialize(q);

        q = _baseParams(address(a), address(b));
        q.stProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        acct.initialize(q);

        q = _baseParams(address(a), address(a));
        vm.expectRevert(IRoycoDayAccountant.YDMS_CANNOT_BE_IDENTICAL.selector);
        acct.initialize(q);

        q = _baseParams(address(a), address(b));
        q.minCoverageWAD = uint64(WAD);
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        acct.initialize(q);

        q = _baseParams(address(a), address(b));
        q.coverageLiquidationUtilizationWAD = WAD;
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        acct.initialize(q);

        q = _baseParams(address(a), address(b));
        q.minLiquidityWAD = uint64(WAD);
        vm.expectRevert(IRoycoDayAccountant.INVALID_LIQUIDITY_CONFIG.selector);
        acct.initialize(q);

        q = _baseParams(address(a), address(b));
        q.maxJTYieldShareWAD = uint64(WAD);
        q.maxLPTYieldShareWAD = 1;
        vm.expectRevert(IRoycoDayAccountant.INVALID_MAX_YIELD_SHARE_CONFIG.selector);
        acct.initialize(q);

        q = _baseParams(address(a), address(b));
        acct.initialize(q);
        accountant = acct;
        jtYDM = a;
        lptYDM = b;
        _assertConfigBounds("valid init");

        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        accountant.setMinCoverage(uint64(WAD));
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        accountant.setLiquidationCoverageUtilization(WAD);
        vm.expectRevert(IRoycoDayAccountant.INVALID_LIQUIDITY_CONFIG.selector);
        accountant.setMinLiquidity(uint64(WAD));
        vm.expectRevert(IRoycoDayAccountant.INVALID_MAX_YIELD_SHARE_CONFIG.selector);
        accountant.setMaxYieldShares(uint64(WAD), 1);
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        accountant.setSeniorTrancheProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD + 1));
        vm.expectRevert(IRoycoDayAccountant.YDMS_CANNOT_BE_IDENTICAL.selector);
        accountant.setJuniorTrancheYDM(address(b), "");

        _assertConfigBounds("after failed setters");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 4 - yield_share_accrual_window_bound
    //////////////////////////////////////////////////////////////////////*/

    function test_AccrualClocksAndAccumulatorsZeroBeforeFirstSync() public {
        _deploy(_defaultParams());
        _assertAccrualWindowBound("fresh");
        _seedFlat();
        assertEq(uint256(_snap().lastYieldShareAccrualTimestamp), 0, "clock unset after post-op seeding");
        _assertAccrualWindowBound("seeded");

        kernel.doPreOp(toNAVUnits(SEED_C));
        assertEq(uint256(_snap().lastYieldShareAccrualTimestamp), block.timestamp, "clock initialized");
        assertEq(uint256(_snap().lastPremiumPaymentTimestamp), block.timestamp, "premium clock initialized");
        _assertAccrualWindowBound("bootstrapped");
    }

    function testFuzz_YieldShareAccrualWindowBound(uint256 _rateIn, uint256 _dt1, uint256 _dt2, uint256 _gain) public {
        _dt1 = bound(_dt1, 0, 1_000_000);
        _dt2 = bound(_dt2, 0, 1_000_000);
        _gain = bound(_gain, 0, 100e18);

        _deploy(_defaultParams());
        _seedFlat();
        jtYDM.setRates(_rateIn);
        lptYDM.setRates(_rateIn);

        kernel.doPreOp(toNAVUnits(SEED_C));
        _assertAccrualWindowBound("bootstrap");

        _advance(_dt1);
        kernel.doPreOp(toNAVUnits(SEED_C));
        _assertAccrualWindowBound("accrue1");

        _advance(_dt2);
        kernel.doPreOp(toNAVUnits(SEED_C + _gain));
        _assertAccrualWindowBound("accrue2 + pay");

        _advance(_dt1);
        kernel.doPreOp(toNAVUnits(SEED_C + _gain));
        _assertAccrualWindowBound("accrue3");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 5 - lpt_raw_nav_isolated_from_waterfall
    //////////////////////////////////////////////////////////////////////*/

    function test_PreOpNeverWritesLPTRawNAV() public {
        _deploy(_defaultParams());
        _seedFlat();
        assertEq(toUint256(_snap().lastLPTRawNAV), SEED_LPT, "seeded lpt mark");

        kernel.doPreOp(toNAVUnits(SEED_C + 50e18));
        assertEq(toUint256(_snap().lastLPTRawNAV), SEED_LPT, "gain sync must not write lpt mark");

        kernel.doPreOp(toNAVUnits(SEED_C - 50e18));
        assertEq(toUint256(_snap().lastLPTRawNAV), SEED_LPT, "loss sync must not write lpt mark");

        kernel.doCommit(toNAVUnits(uint256(777e18)));
        assertEq(toUint256(_snap().lastLPTRawNAV), 777e18, "commit writes lpt mark");

        uint256 c = toUint256(_snap().lastCollateralNAV);
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(c), toNAVUnits(uint256(500e18)), ZERO_NAV_UNITS);
        assertEq(toUint256(_snap().lastLPTRawNAV), 500e18, "post-op writes lpt mark");
    }

    function test_LPTRawNAVDoesNotInfluenceWaterfall() public {
        EchoUtilizationYDM e1 = new EchoUtilizationYDM();
        EchoUtilizationYDM e2 = new EchoUtilizationYDM();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.jtYDM = address(e1);
        p.lptYDM = address(e2);
        _deploy(p);
        _seedState(SEED_ST, SEED_JT, 0, SEED_LPT, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(1000);
        SyncedAccountingState memory sA = kernel.doPreOp(toNAVUnits(SEED_C + 60e18));
        IRoycoDayAccountant.RoycoDayAccountantState memory stA = _snap();

        EchoUtilizationYDM e3 = new EchoUtilizationYDM();
        EchoUtilizationYDM e4 = new EchoUtilizationYDM();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p2 = _defaultParams();
        p2.jtYDM = address(e3);
        p2.lptYDM = address(e4);
        _deploy(p2);
        _seedState(SEED_ST, SEED_JT, 0, SEED_LPT * 40, MarketState.PERPETUAL);
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(1000);
        SyncedAccountingState memory sB = kernel.doPreOp(toNAVUnits(SEED_C + 60e18));
        IRoycoDayAccountant.RoycoDayAccountantState memory stB = _snap();

        assertEq(toUint256(sA.stEffectiveNAV), toUint256(sB.stEffectiveNAV), "lpt mark must not move stEffectiveNAV");
        assertEq(toUint256(sA.jtEffectiveNAV), toUint256(sB.jtEffectiveNAV), "lpt mark must not move jtEffectiveNAV");
        assertEq(toUint256(sA.jtImpermanentLoss), toUint256(sB.jtImpermanentLoss), "lpt mark must not move jtImpermanentLoss");
        assertEq(toUint256(stA.lastSTEffectiveNAV), toUint256(stB.lastSTEffectiveNAV), "committed st");
        assertEq(toUint256(stA.lastJTEffectiveNAV), toUint256(stB.lastJTEffectiveNAV), "committed jt");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 6 - sync_entrypoints_kernel_only
    //////////////////////////////////////////////////////////////////////*/

    function testFuzz_SyncEntrypointsRevertForNonKernel(address _caller, uint256 _nav, uint256 _bonus) public {
        _deploy(_defaultParams());
        _seedFlat();
        vm.assume(_caller != address(kernel));
        vm.assume(_caller != address(0));
        _nav = bound(_nav, 0, 1e30);
        _bonus = bound(_bonus, 0, 1e30);

        authority.grantRole(1, _caller, 0);

        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        vm.prank(_caller);
        accountant.preOpSyncTrancheAccounting(toNAVUnits(_nav));

        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        vm.prank(_caller);
        accountant.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, toNAVUnits(_nav), ZERO_NAV_UNITS, toNAVUnits(_bonus));

        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        vm.prank(_caller);
        accountant.commitLiquidityProviderTrancheRawNAV(toNAVUnits(_nav));

        kernel.doCommit(toNAVUnits(_nav));
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 7 - loss_absorbed_junior_first
    //////////////////////////////////////////////////////////////////////*/

    function testFuzz_LossAbsorbedJuniorFirst(uint256 _st0, uint256 _jt0, uint256 _loss) public {
        _st0 = bound(_st0, 1e18, 1e27);
        _jt0 = bound(_jt0, 1e18, 1e27);
        uint256 c0 = _st0 + _jt0;
        _loss = bound(_loss, 1, c0);

        _deploy(_defaultParams());
        _seedState(_st0, _jt0, 0, SEED_LPT, MarketState.PERPETUAL);

        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(c0 - _loss));

        uint256 absorbed = _loss < _jt0 ? _loss : _jt0;
        assertEq(toUint256(s.jtEffectiveNAV), _jt0 - absorbed, "jt absorbs first");
        assertEq(toUint256(s.stEffectiveNAV), _st0 - (_loss - absorbed), "st only takes the residual");
        if (toUint256(s.stEffectiveNAV) != _st0) assertEq(toUint256(s.jtEffectiveNAV), 0, "senior shrank while junior buffer alive");
        if (s.marketState == MarketState.FIXED_TERM) {
            assertEq(toUint256(s.jtImpermanentLoss), absorbed, "il == absorbed");
        } else {
            assertEq(toUint256(s.jtImpermanentLoss), 0, "perpetual erases il");
        }
        _assertReturnedConservation(s, "loss");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 8 - impermanent_loss_repayment_precedes_and_is_never_feed
    //////////////////////////////////////////////////////////////////////*/

    function testFuzz_ILRepaymentPrecedesAndIsNeverFeeable(uint256 _il, uint256 _gain) public {
        _il = bound(_il, 1, 150e18);
        _gain = bound(_gain, 1, _il);

        _deploy(_defaultParams());
        jtYDM.setRates(0.2e18);
        lptYDM.setRates(0.1e18);
        _seedState(SEED_ST, SEED_JT, _il, SEED_LPT, MarketState.FIXED_TERM);
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(1000);

        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(SEED_C + _gain));

        assertEq(toUint256(s.jtImpermanentLoss), s.marketState == MarketState.PERPETUAL ? 0 : _il - _gain, "il repaid off the top");
        assertEq(toUint256(s.jtEffectiveNAV), SEED_JT + _gain, "junior credited the repayment");
        assertEq(toUint256(s.stEffectiveNAV), SEED_ST, "senior untouched by restoration");
        _assertNoDistribution(s, "restoration is never yield");
        _assertReturnedConservation(s, "restoration");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 9 - gain_fully_distributed_within_senior_slice
    //////////////////////////////////////////////////////////////////////*/

    function testFuzz_GainFullyDistributedWithinSeniorSlice(uint256 _gain) public {
        _gain = bound(_gain, 1, 1e24);

        _deploy(_defaultParams());
        jtYDM.setRates(0.2e18);
        lptYDM.setRates(0.1e18);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(1000);

        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(SEED_C + _gain));

        uint256 s1 = toUint256(s.stEffectiveNAV);
        uint256 j1 = toUint256(s.jtEffectiveNAV);
        assertEq((s1 + j1) - (SEED_ST + SEED_JT), _gain, "the whole gain is distributed");
        assertGe(j1, SEED_JT, "junior claim never decreases on a gain");

        uint256 stGain = Math.mulDiv(_gain, SEED_ST, SEED_C, Math.Rounding.Floor);
        uint256 jtGain = _gain - stGain;
        uint256 jtRiskPremium = j1 - SEED_JT - jtGain;
        uint256 lptLiquidityPremium = toUint256(s.lptLiquidityPremium);
        assertLe(jtRiskPremium + lptLiquidityPremium, stGain, "premiums never exceed the senior attributed gain");
        assertEq(jtRiskPremium, Math.mulDiv(stGain, MAX_JT_SHARE, WAD, Math.Rounding.Floor), "risk premium is a slice of stGain");
        assertEq(lptLiquidityPremium, Math.mulDiv(stGain, MAX_LPT_SHARE, WAD, Math.Rounding.Floor), "liquidity premium is a slice of stGain");
    }

    function test_LiquidityPremiumStaysInsideSeniorClaim() public {
        _deploy(_defaultParams());
        jtYDM.setRates(0.2e18);
        lptYDM.setRates(0);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(1000);
        SyncedAccountingState memory a = kernel.doPreOp(toNAVUnits(SEED_C + 120e18));

        _deploy(_defaultParams());
        jtYDM.setRates(0.2e18);
        lptYDM.setRates(0.1e18);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(1000);
        SyncedAccountingState memory b = kernel.doPreOp(toNAVUnits(SEED_C + 120e18));

        assertEq(toUint256(a.lptLiquidityPremium), 0, "control has no liquidity premium");
        assertGt(toUint256(b.lptLiquidityPremium), 0, "treatment has a liquidity premium");
        assertEq(toUint256(a.stEffectiveNAV), toUint256(b.stEffectiveNAV), "liquidity premium stays inside stEffectiveNAV");
        assertEq(toUint256(a.jtEffectiveNAV), toUint256(b.jtEffectiveNAV), "liquidity premium must not move the junior claim");
        assertEq(a.coverageUtilizationWAD, b.coverageUtilizationWAD, "liquidity premium is coverage neutral");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 10 - ydm_outputs_clamped_at_configured_max
    //////////////////////////////////////////////////////////////////////*/

    function test_YDMOutputsClampedAtConfiguredMax() public {
        _deploy(_defaultParams());
        jtYDM.setRates(type(uint256).max);
        lptYDM.setRates(type(uint256).max);
        _seedFlat();

        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(50);
        kernel.doPreOp(toNAVUnits(SEED_C));

        assertEq(uint256(_snap().twJTYieldShareAccruedWAD), uint256(MAX_JT_SHARE) * 50, "twJT clamped");
        assertEq(uint256(_snap().twLPTYieldShareAccruedWAD), uint256(MAX_LPT_SHARE) * 50, "twLPT clamped");
        _assertAccrualWindowBound("clamped accrual");

        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(SEED_C + 12e18));
        uint256 stGain = Math.mulDiv(12e18, SEED_ST, SEED_C, Math.Rounding.Floor);
        uint256 jtGain = 12e18 - stGain;
        uint256 jtRiskPremium = toUint256(s.jtEffectiveNAV) - SEED_JT - jtGain;
        assertEq(jtRiskPremium, Math.mulDiv(stGain, MAX_JT_SHARE, WAD, Math.Rounding.Floor), "accrued risk premium clamped at maxJT");
        assertEq(
            toUint256(s.lptLiquidityPremium),
            Math.mulDiv(stGain, MAX_LPT_SHARE, WAD, Math.Rounding.Floor),
            "accrued liquidity premium clamped at maxLPT"
        );
        assertEq(uint256(_snap().twJTYieldShareAccruedWAD), 0, "accumulators reset on payment");
        assertEq(uint256(_snap().twLPTYieldShareAccruedWAD), 0, "accumulators reset on payment");

        uint256 st1 = toUint256(s.stEffectiveNAV);
        uint256 jt1 = toUint256(s.jtEffectiveNAV);
        uint256 c1 = st1 + jt1;
        SyncedAccountingState memory s2 = kernel.doPreOp(toNAVUnits(c1 + 12e18));
        uint256 stGain2 = Math.mulDiv(12e18, st1, c1, Math.Rounding.Floor);
        uint256 jtGain2 = 12e18 - stGain2;
        uint256 jtRiskPremium2 = toUint256(s2.jtEffectiveNAV) - jt1 - jtGain2;
        assertEq(jtRiskPremium2, Math.mulDiv(stGain2, MAX_JT_SHARE, WAD, Math.Rounding.Floor), "instantaneous risk premium clamped at maxJT");
        assertEq(
            toUint256(s2.lptLiquidityPremium),
            Math.mulDiv(stGain2, MAX_LPT_SHARE, WAD, Math.Rounding.Floor),
            "instantaneous liquidity premium clamped"
        );
        _assertAccrualWindowBound("after instantaneous");
        _assertReturnedConservation(s2, "clamped sync");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 11 - no_premium_or_protocol_fee_during_fixed_term
    //////////////////////////////////////////////////////////////////////*/

    function test_NoPremiumOrProtocolFeeDuringFixedTerm() public {
        _deploy(_defaultParams());
        jtYDM.setRates(0.2e18);
        lptYDM.setRates(0.1e18);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(5000);

        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(SEED_C - 40e18));
        assertEq(uint8(s.marketState), uint8(MarketState.FIXED_TERM), "loss opens the fixed term");
        _assertNoDistribution(s, "fixed term entry");

        _advance(5000);
        SyncedAccountingState memory s2 = kernel.doPreOp(toNAVUnits(SEED_C - 20e18));
        assertEq(uint8(s2.marketState), uint8(MarketState.FIXED_TERM), "still recovering");
        _assertNoDistribution(s2, "fixed term recovery");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 12 - fixed_term_entry_conditions_are_exhaustive
    //////////////////////////////////////////////////////////////////////*/

    function test_FixedTermEntryConditionsAreExhaustive() public {
        _deploy(_defaultParams());
        _seedFlat();
        assertEq(uint8(kernel.doPreOp(toNAVUnits(SEED_C - 10e18)).marketState), uint8(MarketState.FIXED_TERM), "baseline enters fixed term");

        _deploy(_defaultParams());
        _seedFlat();
        accountant.setFixedTermDuration(0);
        assertEq(uint8(kernel.doPreOp(toNAVUnits(SEED_C - 10e18)).marketState), uint8(MarketState.PERPETUAL), "zero duration forces perpetual");

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(20e18));
        _deploy(p);
        _seedFlat();
        assertEq(uint8(kernel.doPreOp(toNAVUnits(SEED_C - 10e18)).marketState), uint8(MarketState.PERPETUAL), "dust il forces perpetual");

        _deploy(_defaultParams());
        _seedState(0, SEED_JT, 0, SEED_LPT, MarketState.PERPETUAL);
        assertEq(uint8(kernel.doPreOp(toNAVUnits(SEED_JT - 10e18)).marketState), uint8(MarketState.PERPETUAL), "no senior capital forces perpetual");

        _deploy(_defaultParams());
        _seedFlat();
        SyncedAccountingState memory wiped = kernel.doPreOp(toNAVUnits(SEED_ST));
        assertEq(toUint256(wiped.jtEffectiveNAV), 0, "junior wiped");
        assertEq(uint8(wiped.marketState), uint8(MarketState.PERPETUAL), "wiped junior forces perpetual");

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory pc = _defaultParams();
        pc.minCoverageWAD = 0.5e18;
        pc.coverageLiquidationUtilizationWAD = 1.05e18;
        _deploy(pc);
        _seedState(1000e18, 1000e18, 0, SEED_LPT, MarketState.PERPETUAL);
        assertEq(
            uint8(kernel.doPreOp(toNAVUnits(uint256(1950e18))).marketState), uint8(MarketState.FIXED_TERM), "sub-threshold loss opens the term"
        );

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory pc2 = _defaultParams();
        pc2.minCoverageWAD = 0.5e18;
        pc2.coverageLiquidationUtilizationWAD = 1.05e18;
        _deploy(pc2);
        _seedState(1000e18, 1000e18, 0, SEED_LPT, MarketState.PERPETUAL);
        SyncedAccountingState memory breached = kernel.doPreOp(toNAVUnits(uint256(1900e18)));
        assertGe(breached.coverageUtilizationWAD, pc2.coverageLiquidationUtilizationWAD, "threshold breached");
        assertEq(uint8(breached.marketState), uint8(MarketState.PERPETUAL), "liquidation breach forces perpetual");

        _deployWithGrace(_defaultParams(), 100_000);
        _seedFlat();
        assertEq(uint8(kernel.doPreOp(toNAVUnits(SEED_C - 10e18)).marketState), uint8(MarketState.PERPETUAL), "grace period forces perpetual");
        _advance(200_000);
        assertEq(uint8(kernel.doPreOp(toNAVUnits(SEED_C - 20e18)).marketState), uint8(MarketState.FIXED_TERM), "term opens once the grace elapses");

        _seedFixedTerm();
        uint32 fte = _snap().fixedTermEndTimestamp;
        vm.warp(uint256(fte) + 1);
        assertEq(uint8(kernel.doPreOp(_snap().lastCollateralNAV).marketState), uint8(MarketState.PERPETUAL), "expired term forces perpetual");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 13 - forced_perpetual_erases_il_without_moving_navs
    //////////////////////////////////////////////////////////////////////*/

    function test_ForcedPerpetualErasesILWithoutMovingNAVs() public {
        _seedFixedTerm();
        IRoycoDayAccountant.RoycoDayAccountantState memory before = _snap();
        vm.warp(uint256(before.fixedTermEndTimestamp) + 1);
        SyncedAccountingState memory s = kernel.doPreOp(before.lastCollateralNAV);

        assertEq(uint8(s.marketState), uint8(MarketState.PERPETUAL), "term expiry forces perpetual");
        assertEq(toUint256(s.jtImpermanentLoss), 0, "il erased");
        assertEq(uint256(s.fixedTermEndTimestamp), 0, "term stamp cleared");
        assertEq(toUint256(s.collateralNAV), toUint256(before.lastCollateralNAV), "erasure moves no collateral");
        assertEq(toUint256(s.stEffectiveNAV), toUint256(before.lastSTEffectiveNAV), "erasure moves no senior claim");
        assertEq(toUint256(s.jtEffectiveNAV), toUint256(before.lastJTEffectiveNAV), "erasure moves no junior claim");
        assertEq(uint256(_snap().fixedTermEndTimestamp), 0, "committed term stamp cleared");

        SyncedAccountingState memory s2 = kernel.doPreOp(toNAVUnits(toUint256(before.lastCollateralNAV) + 5e18));
        assertEq(toUint256(s2.jtImpermanentLoss), 0, "erased il stays erased on a gain");
        assertGt(toUint256(s2.jtEffectiveNAV), toUint256(before.lastJTEffectiveNAV), "the gain splits pro-rata instead of repaying");

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.minCoverageWAD = 0.5e18;
        p.coverageLiquidationUtilizationWAD = 1.05e18;
        _deploy(p);
        _seedState(1000e18, 1000e18, 0, SEED_LPT, MarketState.PERPETUAL);
        SyncedAccountingState memory b = kernel.doPreOp(toNAVUnits(uint256(1900e18)));
        assertEq(uint8(b.marketState), uint8(MarketState.PERPETUAL), "breach forces perpetual");
        assertEq(toUint256(b.jtImpermanentLoss), 0, "breach erases il");
        assertEq(uint256(b.fixedTermEndTimestamp), 0, "breach clears the term stamp");
        assertEq(toUint256(b.stEffectiveNAV), 1000e18, "erasure did not touch the senior claim");
        assertEq(toUint256(b.jtEffectiveNAV), 900e18, "erasure did not touch the junior claim");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 14 - fixed_term_end_never_extended
    //////////////////////////////////////////////////////////////////////*/

    function test_FixedTermEndNeverExtended() public {
        _seedFixedTerm();
        uint32 fte = _snap().fixedTermEndTimestamp;
        assertEq(uint256(fte), block.timestamp + TERM, "stamped on the transition");

        for (uint256 i; i < 4; ++i) {
            _advance(1000);
            SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(toUint256(_snap().lastCollateralNAV) - 1e18));
            assertEq(uint8(s.marketState), uint8(MarketState.FIXED_TERM), "still in the term");
            assertEq(uint256(s.fixedTermEndTimestamp), uint256(fte), "returned term stamp never moves");
            assertEq(uint256(_snap().fixedTermEndTimestamp), uint256(fte), "committed term stamp never moves");
        }

        SyncedAccountingState memory s2 = kernel.doPreOp(_snap().lastCollateralNAV);
        assertEq(uint256(s2.fixedTermEndTimestamp), uint256(fte), "no-op sync never moves the stamp");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 15 - postop_is_strictly_delta_interpretation
    //////////////////////////////////////////////////////////////////////*/

    function test_PostOpIsStrictlyDeltaInterpretation() public {
        _deploy(_defaultParams());
        jtYDM.setRates(0.2e18);
        lptYDM.setRates(0.1e18);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(500);
        kernel.doPreOp(toNAVUnits(SEED_C - 10e18));
        IRoycoDayAccountant.RoycoDayAccountantState memory a = _snap();
        assertEq(uint8(a.lastMarketState), uint8(MarketState.FIXED_TERM), "fixed term armed");
        assertGt(uint256(a.twJTYieldShareAccruedWAD), 0, "accumulators armed");

        uint256 c = toUint256(a.lastCollateralNAV);
        SyncedAccountingState memory s = kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(c + 25e18), a.lastLPTRawNAV, ZERO_NAV_UNITS);
        IRoycoDayAccountant.RoycoDayAccountantState memory b = _snap();

        assertEq(uint8(b.lastMarketState), uint8(a.lastMarketState), "marketState untouched");
        assertEq(toUint256(b.lastJTImpermanentLoss), toUint256(a.lastJTImpermanentLoss), "il untouched");
        assertEq(uint256(b.fixedTermEndTimestamp), uint256(a.fixedTermEndTimestamp), "term stamp untouched");
        assertEq(uint256(b.lastYieldShareAccrualTimestamp), uint256(a.lastYieldShareAccrualTimestamp), "accrual clock untouched");
        assertEq(uint256(b.lastPremiumPaymentTimestamp), uint256(a.lastPremiumPaymentTimestamp), "premium clock untouched");
        assertEq(uint256(b.twJTYieldShareAccruedWAD), uint256(a.twJTYieldShareAccruedWAD), "twJT untouched");
        assertEq(uint256(b.twLPTYieldShareAccruedWAD), uint256(a.twLPTYieldShareAccruedWAD), "twLPT untouched");
        assertEq(
            keccak256(
                abi.encode(
                    b.stProtocolFeeWAD,
                    b.jtProtocolFeeWAD,
                    b.jtYieldShareProtocolFeeWAD,
                    b.lptYieldShareProtocolFeeWAD,
                    b.minCoverageWAD,
                    b.minLiquidityWAD,
                    b.fixedTermDurationSeconds,
                    b.jtYDM,
                    b.lptYDM,
                    b.maxJTYieldShareWAD,
                    b.maxLPTYieldShareWAD,
                    b.kernel,
                    b.fixedTermCommenceableAtTimestamp,
                    b.coverageLiquidationUtilizationWAD,
                    b.dustTolerance
                )
            ),
            keccak256(
                abi.encode(
                    a.stProtocolFeeWAD,
                    a.jtProtocolFeeWAD,
                    a.jtYieldShareProtocolFeeWAD,
                    a.lptYieldShareProtocolFeeWAD,
                    a.minCoverageWAD,
                    a.minLiquidityWAD,
                    a.fixedTermDurationSeconds,
                    a.jtYDM,
                    a.lptYDM,
                    a.maxJTYieldShareWAD,
                    a.maxLPTYieldShareWAD,
                    a.kernel,
                    a.fixedTermCommenceableAtTimestamp,
                    a.coverageLiquidationUtilizationWAD,
                    a.dustTolerance
                )
            ),
            "configuration untouched"
        );
        _assertNoDistribution(s, "post-op");
        assertEq(toUint256(b.lastCollateralNAV), c + 25e18, "collateral checkpoint written");
        assertEq(toUint256(b.lastJTEffectiveNAV), toUint256(a.lastJTEffectiveNAV) + 25e18, "junior checkpoint written");
        assertEq(toUint256(b.lastSTEffectiveNAV), toUint256(a.lastSTEffectiveNAV), "senior checkpoint unchanged");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 16 - postop_operation_shape_validation
    //////////////////////////////////////////////////////////////////////*/

    function _expectShapeRevert(Operation _op) internal {
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, _op));
    }

    function test_RevertWhen_PostOpOperationShapeInvalid() public {
        _deploy(_defaultParams());
        _seedFlat();
        uint256 c = SEED_C;
        NAV_UNIT lpt = toNAVUnits(SEED_LPT);

        _expectShapeRevert(Operation.ST_DEPOSIT);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(c - 1e18), lpt, ZERO_NAV_UNITS);
        _expectShapeRevert(Operation.ST_DEPOSIT);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(c), lpt, ZERO_NAV_UNITS);
        _expectShapeRevert(Operation.ST_DEPOSIT);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(c + 1e18), toNAVUnits(SEED_LPT + 1), ZERO_NAV_UNITS);
        _expectShapeRevert(Operation.ST_DEPOSIT);
        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(c + 1e18), lpt, toNAVUnits(uint256(1)));

        _expectShapeRevert(Operation.ST_REDEMPTION);
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(c + 1e18), lpt, ZERO_NAV_UNITS);
        _expectShapeRevert(Operation.ST_REDEMPTION);
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(c - 1e18), toNAVUnits(SEED_LPT + 1), ZERO_NAV_UNITS);

        _expectShapeRevert(Operation.JT_DEPOSIT);
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(c - 1e18), lpt, ZERO_NAV_UNITS);
        _expectShapeRevert(Operation.JT_DEPOSIT);
        kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(c + 1e18), lpt, toNAVUnits(uint256(1)));

        _expectShapeRevert(Operation.JT_REDEMPTION);
        kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(c + 1e18), lpt, ZERO_NAV_UNITS);
        _expectShapeRevert(Operation.JT_REDEMPTION);
        kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(c - 1e18), lpt, toNAVUnits(uint256(1)));

        _expectShapeRevert(Operation.LPT_DEPOSIT);
        kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(c), toNAVUnits(SEED_LPT - 1), ZERO_NAV_UNITS);
        _expectShapeRevert(Operation.LPT_DEPOSIT);
        kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(c + 1e18), toNAVUnits(SEED_LPT + 1), ZERO_NAV_UNITS);
        _expectShapeRevert(Operation.LPT_DEPOSIT);
        kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(c), toNAVUnits(SEED_LPT + 1), toNAVUnits(uint256(1)));

        _expectShapeRevert(Operation.LPT_REDEMPTION);
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(c), toNAVUnits(SEED_LPT + 1), ZERO_NAV_UNITS);
        _expectShapeRevert(Operation.LPT_REDEMPTION);
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(c - 1e18), toNAVUnits(SEED_LPT - 1), ZERO_NAV_UNITS);
        _expectShapeRevert(Operation.LPT_REDEMPTION);
        kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(c), toNAVUnits(SEED_LPT - 1), toNAVUnits(uint256(1)));

        kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(c + 1e18), lpt, ZERO_NAV_UNITS);
        _assertStorageConservation("valid shape");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 17 - self_liquidation_bonus_bounded_and_junior_sourced
    //////////////////////////////////////////////////////////////////////*/

    function test_SelfLiquidationBonusBoundedAndJuniorSourced() public {
        _deploy(_defaultParams());
        _seedFlat();

        SyncedAccountingState memory s =
            kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_C - 100e18), toNAVUnits(SEED_LPT), toNAVUnits(uint256(30e18)));
        assertEq(toUint256(s.jtEffectiveNAV), SEED_JT - 30e18, "bonus debited from the junior claim");
        assertEq(toUint256(s.stEffectiveNAV), SEED_ST - (100e18 - 30e18), "bonus credits the senior redemption");
        assertEq(
            (SEED_ST + SEED_JT) - (toUint256(s.stEffectiveNAV) + toUint256(s.jtEffectiveNAV)), 100e18, "value only leaves via the redemption"
        );
        _assertReturnedConservation(s, "bonus");

        _deploy(_defaultParams());
        _seedFlat();
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_C - 300e18), toNAVUnits(SEED_LPT), toNAVUnits(uint256(201e18)));

        vm.expectRevert(stdError.arithmeticError);
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_C - 50e18), toNAVUnits(SEED_LPT), toNAVUnits(uint256(60e18)));

        _deploy(_defaultParams());
        _seedState(10e18, SEED_JT, 0, SEED_LPT, MarketState.PERPETUAL);
        vm.expectRevert(stdError.arithmeticError);
        kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(uint256(110e18)), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS);
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 18 - postop_moves_only_the_operating_tranche
    //////////////////////////////////////////////////////////////////////*/

    function testFuzz_PostOpMovesOnlyTheOperatingTranche(uint256 _amt) public {
        _amt = bound(_amt, 1, 100e18);

        _deploy(_defaultParams());
        _seedFlat();
        SyncedAccountingState memory s = kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_C + _amt), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS);
        assertEq(toUint256(s.stEffectiveNAV), SEED_ST + _amt, "st deposit moves st");
        assertEq(toUint256(s.jtEffectiveNAV), SEED_JT, "st deposit leaves jt");
        s = kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_C), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS);
        assertEq(toUint256(s.stEffectiveNAV), SEED_ST, "st redemption moves st");
        assertEq(toUint256(s.jtEffectiveNAV), SEED_JT, "st redemption leaves jt");

        s = kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(SEED_C + _amt), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS);
        assertEq(toUint256(s.jtEffectiveNAV), SEED_JT + _amt, "jt deposit moves jt");
        assertEq(toUint256(s.stEffectiveNAV), SEED_ST, "jt deposit leaves st");
        s = kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(SEED_C), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS);
        assertEq(toUint256(s.jtEffectiveNAV), SEED_JT, "jt redemption moves jt");
        assertEq(toUint256(s.stEffectiveNAV), SEED_ST, "jt redemption leaves st");

        s = kernel.doPostOp(Operation.LPT_DEPOSIT, toNAVUnits(SEED_C), toNAVUnits(SEED_LPT + _amt), ZERO_NAV_UNITS);
        assertEq(toUint256(s.stEffectiveNAV), SEED_ST, "lpt deposit leaves st");
        assertEq(toUint256(s.jtEffectiveNAV), SEED_JT, "lpt deposit leaves jt");
        s = kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_C), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS);
        assertEq(toUint256(s.stEffectiveNAV), SEED_ST, "lpt redemption leaves st");
        assertEq(toUint256(s.jtEffectiveNAV), SEED_JT, "lpt redemption leaves jt");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 19 - preop_returns_zero_lpt_placeholders
    //////////////////////////////////////////////////////////////////////*/

    function testFuzz_PreOpReturnsZeroLPTPlaceholders(uint256 _c1) public {
        _c1 = bound(_c1, 0, 5000e18);
        _deploy(_defaultParams());
        _seedFlat();

        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(_c1));
        assertEq(toUint256(s.lptRawNAV), 0, "lptRawNAV placeholder");
        assertEq(s.liquidityUtilizationWAD, 0, "liquidityUtilization placeholder");
        assertEq(
            s.coverageUtilizationWAD,
            _covUtil(toUint256(s.collateralNAV), MIN_COVERAGE, toUint256(s.jtEffectiveNAV)),
            "coverage utilization at the post-sync values"
        );
        assertEq(toUint256(_snap().lastLPTRawNAV), SEED_LPT, "committed mark untouched");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 20 - sync_no_op_stability_and_same_block_idempotency
    //////////////////////////////////////////////////////////////////////*/

    function test_SyncNoOpStabilityAndSameBlockIdempotency() public {
        _deploy(_defaultParams());
        jtYDM.setRates(0.2e18);
        lptYDM.setRates(0.1e18);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(10_000);

        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(SEED_C));
        assertEq(toUint256(s.stEffectiveNAV), SEED_ST, "no-op leaves st");
        assertEq(toUint256(s.jtEffectiveNAV), SEED_JT, "no-op leaves jt");
        _assertNoDistribution(s, "no-op");

        IRoycoDayAccountant.RoycoDayAccountantState memory a = _snap();
        SyncedAccountingState memory s2 = kernel.doPreOp(toNAVUnits(SEED_C));
        IRoycoDayAccountant.RoycoDayAccountantState memory b = _snap();
        _assertNoDistribution(s2, "no-op repeat");
        assertEq(toUint256(b.lastCollateralNAV), toUint256(a.lastCollateralNAV), "collateral checkpoint stable");
        assertEq(toUint256(b.lastSTEffectiveNAV), toUint256(a.lastSTEffectiveNAV), "senior checkpoint stable");
        assertEq(toUint256(b.lastJTEffectiveNAV), toUint256(a.lastJTEffectiveNAV), "junior checkpoint stable");
        assertEq(toUint256(b.lastLPTRawNAV), toUint256(a.lastLPTRawNAV), "lpt checkpoint stable");
        assertEq(toUint256(b.lastJTImpermanentLoss), toUint256(a.lastJTImpermanentLoss), "il stable");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 21 - preview_sync_equals_executed_sync
    //////////////////////////////////////////////////////////////////////*/

    function _assertPacketsEqual(SyncedAccountingState memory _a, SyncedAccountingState memory _b, string memory _tag) internal pure {
        assertEq(uint8(_a.marketState), uint8(_b.marketState), string.concat(_tag, ": marketState"));
        assertEq(toUint256(_a.collateralNAV), toUint256(_b.collateralNAV), string.concat(_tag, ": collateralNAV"));
        assertEq(toUint256(_a.lptRawNAV), toUint256(_b.lptRawNAV), string.concat(_tag, ": lptRawNAV"));
        assertEq(toUint256(_a.stEffectiveNAV), toUint256(_b.stEffectiveNAV), string.concat(_tag, ": stEffectiveNAV"));
        assertEq(toUint256(_a.jtEffectiveNAV), toUint256(_b.jtEffectiveNAV), string.concat(_tag, ": jtEffectiveNAV"));
        assertEq(toUint256(_a.jtImpermanentLoss), toUint256(_b.jtImpermanentLoss), string.concat(_tag, ": jtImpermanentLoss"));
        assertEq(toUint256(_a.lptLiquidityPremium), toUint256(_b.lptLiquidityPremium), string.concat(_tag, ": lptLiquidityPremium"));
        assertEq(toUint256(_a.stProtocolFee), toUint256(_b.stProtocolFee), string.concat(_tag, ": stProtocolFee"));
        assertEq(toUint256(_a.jtProtocolFee), toUint256(_b.jtProtocolFee), string.concat(_tag, ": jtProtocolFee"));
        assertEq(toUint256(_a.lptProtocolFee), toUint256(_b.lptProtocolFee), string.concat(_tag, ": lptProtocolFee"));
        assertEq(_a.coverageUtilizationWAD, _b.coverageUtilizationWAD, string.concat(_tag, ": coverageUtilizationWAD"));
        assertEq(_a.liquidityUtilizationWAD, _b.liquidityUtilizationWAD, string.concat(_tag, ": liquidityUtilizationWAD"));
        assertEq(uint256(_a.fixedTermEndTimestamp), uint256(_b.fixedTermEndTimestamp), string.concat(_tag, ": fixedTermEndTimestamp"));
        assertEq(_a.minCoverageWAD, _b.minCoverageWAD, string.concat(_tag, ": minCoverageWAD"));
        assertEq(
            _a.coverageLiquidationUtilizationWAD, _b.coverageLiquidationUtilizationWAD, string.concat(_tag, ": coverageLiquidationUtilizationWAD")
        );
        assertEq(_a.minLiquidityWAD, _b.minLiquidityWAD, string.concat(_tag, ": minLiquidityWAD"));
    }

    /// @notice The steady-state half of `preview_sync_equals_executed_sync`: once the accrual clocks are
    ///         initialized the preview is field-for-field identical to the executed sync and writes no storage.
    function testFuzz_PreviewSyncEqualsExecutedSync(uint256 _c1, uint256 _dt) public {
        _c1 = bound(_c1, 0, 5000e18);
        _dt = bound(_dt, 1, 100_000);

        _deploy(_defaultParams());
        jtYDM.setRates(0.2e18);
        lptYDM.setRates(0.1e18);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(_dt);

        bytes32 hashBefore = _stateHash();
        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(_c1));
        assertEq(_stateHash(), hashBefore, "preview must write no storage");

        SyncedAccountingState memory executed = kernel.doPreOp(toNAVUnits(_c1));
        _assertPacketsEqual(previewed, executed, "preview vs execute");
    }

    /// @notice KNOWN LIMITATION DEMONSTRATION for `preview_sync_equals_executed_sync`.
    /// @dev This test PASSES in the current (divergent) implementation: it pins the exact bootstrap-case
    ///      divergence rather than asserting the desired equality. On the very first sync the accrual clocks
    ///      are unset; `preOpSyncTrancheAccounting` calls `_accruePremiumYieldShares`, which stamps
    ///      `lastPremiumPaymentTimestamp = block.timestamp`, so the premium window is zero and the sync takes
    ///      the instantaneous YDM branch. `previewSyncTrancheAccounting` calls the view-only
    ///      `_previewPremiumYieldShareAccrual`, which returns early without stamping, so the premium window
    ///      is `block.timestamp - 0` and no premium is charged. Preview and settlement therefore disagree by
    ///      20e18 of senior NAV on the very first sync. WHEN THIS IS FIXED THIS TEST MUST BE INVERTED to
    ///      `_assertPacketsEqual(previewed, executed)`.
    function test_KnownLimitation_PreviewDivergesFromExecutionOnBootstrapClocks() public {
        _deploy(_defaultParams());
        jtYDM.setRates(0.2e18);
        lptYDM.setRates(0.1e18);
        _seedFlat();
        assertEq(uint256(_snap().lastYieldShareAccrualTimestamp), 0, "clocks unset");
        assertEq(uint256(_snap().lastPremiumPaymentTimestamp), 0, "premium clock unset");

        SyncedAccountingState memory previewed = accountant.previewSyncTrancheAccounting(toNAVUnits(SEED_C + 120e18));
        SyncedAccountingState memory executed = kernel.doPreOp(toNAVUnits(SEED_C + 120e18));

        assertEq(toUint256(previewed.lptLiquidityPremium), 0, "preview charges no liquidity premium on the bootstrap sync");
        assertEq(toUint256(previewed.stEffectiveNAV), 1100e18, "preview senior claim");
        assertEq(toUint256(previewed.jtEffectiveNAV), 220e18, "preview junior claim");
        assertEq(toUint256(executed.lptLiquidityPremium), 10e18, "execution charges the instantaneous liquidity premium");
        assertEq(toUint256(executed.stEffectiveNAV), 1080e18, "execution senior claim");
        assertEq(toUint256(executed.jtEffectiveNAV), 240e18, "execution junior claim");
        assertEq(toUint256(previewed.stEffectiveNAV) - toUint256(executed.stEffectiveNAV), 20e18, "bootstrap preview/execution divergence");
        _assertReturnedConservation(previewed, "bootstrap preview");
        _assertReturnedConservation(executed, "bootstrap execute");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 22 - preop_sync_cannot_brick
    //////////////////////////////////////////////////////////////////////*/

    function testFuzz_PreOpSyncCannotBrick(uint256 _st0, uint256 _jt0, uint256 _c1, uint256 _c2, uint256 _c3, uint256 _dt) public {
        _st0 = bound(_st0, 1e18, 1e30);
        _jt0 = bound(_jt0, 1e18, 1e30);
        _c1 = bound(_c1, 0, 1e34);
        _c2 = bound(_c2, 0, 1e34);
        _c3 = bound(_c3, 0, 1e34);
        _dt = bound(_dt, 0, 1_000_000);

        _deploy(_defaultParams());
        jtYDM.setRates(type(uint256).max);
        lptYDM.setRates(type(uint256).max);
        _seedState(_st0, _jt0, 0, SEED_LPT, MarketState.PERPETUAL);

        kernel.doPreOp(toNAVUnits(_c1));
        _advance(_dt);
        kernel.doPreOp(toNAVUnits(_c2));
        _advance(_dt);
        kernel.doPreOp(toNAVUnits(_c3));
        kernel.doPreOp(toNAVUnits(_c3));
        _assertStorageConservation("no brick");
        _assertAccrualWindowBound("no brick");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 23 - dust_gated_protocol_fee_avoidance
    //////////////////////////////////////////////////////////////////////*/

    /// @notice KNOWN VULNERABILITY DEMONSTRATION for `dust_gated_protocol_fee_avoidance`.
    /// @dev This test PASSES in the current (vulnerable) implementation: the assertions pin the exact
    ///      exposure rather than asserting the desired invariance. Protocol fees are gated on
    ///      `attributedGain > dustTolerance`, so an actor able to trigger frequent syncs settles the same
    ///      12e18 appreciation in 12 sub-dust increments and pays ZERO protocol fee where a single
    ///      settlement pays 1.2e18. WHEN THIS IS FIXED THIS TEST MUST BE INVERTED to
    ///      `assertEq(splitFees, singleFees)`.
    function test_KnownVuln_DustGatedProtocolFeeAvoidance() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(1e18));

        _deploy(p);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(1);
        SyncedAccountingState memory single = kernel.doPreOp(toNAVUnits(SEED_C + 12e18));
        assertEq(toUint256(single.stProtocolFee), 1e18, "10% of the 10e18 senior residual");
        assertEq(toUint256(single.jtProtocolFee), 0.2e18, "10% of the 2e18 junior attributed gain");
        assertEq(toUint256(single.lptProtocolFee), 0, "no liquidity premium so no lpt fee");
        uint256 singleFees = 1.2e18;

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p2 = _defaultParams();
        p2.dustTolerance = toNAVUnits(uint256(1e18));
        _deploy(p2);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(1);
        uint256 splitFees;
        for (uint256 i = 1; i <= 12; ++i) {
            SyncedAccountingState memory step = kernel.doPreOp(toNAVUnits(SEED_C + i * 1e18));
            splitFees += toUint256(step.stProtocolFee) + toUint256(step.jtProtocolFee) + toUint256(step.lptProtocolFee);
        }

        assertEq(splitFees, 0, "sub-dust slicing pays no protocol fee at all");
        assertEq(toUint256(_snap().lastCollateralNAV), SEED_C + 12e18, "the same total appreciation was settled");
        assertGt(singleFees, splitFees, "the dust gate is avoidable: identical total yield, zero protocol revenue");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 24 - premium_paid_without_accrual_window_reset
    //////////////////////////////////////////////////////////////////////*/

    /// @notice The attack cannot occur: the premium is a fraction of each sync's OWN senior gain, sized at the
    ///         window-average rate, so reusing an unreset accrual window across N sub-dust gains charges the
    ///         same total the single settlement of the same total gain would have charged (never more).
    function test_PremiumWindowReuseCannotOverchargeSenior() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.dustTolerance = toNAVUnits(uint256(1e18));

        _deploy(p);
        jtYDM.setRates(0.1e18);
        lptYDM.setRates(0.05e18);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(1000);
        SyncedAccountingState memory single = kernel.doPreOp(toNAVUnits(SEED_C + 5e18));
        uint256 stGainA = Math.mulDiv(5e18, SEED_ST, SEED_C, Math.Rounding.Floor);
        uint256 premiumA = _premiumOf(SEED_ST, SEED_JT, 5e18, single);
        assertEq(premiumA, Math.mulDiv(stGainA, 0.1e18, WAD, Math.Rounding.Floor) + Math.mulDiv(stGainA, 0.05e18, WAD, Math.Rounding.Floor));

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p2 = _defaultParams();
        p2.dustTolerance = toNAVUnits(uint256(1e18));
        _deploy(p2);
        jtYDM.setRates(0.1e18);
        lptYDM.setRates(0.05e18);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(1000);

        uint256 c = SEED_C;
        uint256 st = SEED_ST;
        uint256 jt = SEED_JT;
        uint256 premiumB;
        uint256 stGainB;
        uint256 expectedB;
        for (uint256 i; i < 10; ++i) {
            uint256 stGainI = Math.mulDiv(0.5e18, st, c, Math.Rounding.Floor);
            SyncedAccountingState memory step = kernel.doPreOp(toNAVUnits(c + 0.5e18));
            assertEq(toUint256(step.stProtocolFee), 0, "sub-dust gain takes no senior protocol fee");
            premiumB += _premiumOf(st, jt, 0.5e18, step);
            expectedB += Math.mulDiv(stGainI, 0.1e18, WAD, Math.Rounding.Floor) + Math.mulDiv(stGainI, 0.05e18, WAD, Math.Rounding.Floor);
            stGainB += stGainI;
            c += 0.5e18;
            st = toUint256(step.stEffectiveNAV);
            jt = toUint256(step.jtEffectiveNAV);
        }

        assertEq(premiumB, expectedB, "each sub-dust premium is sized at the configured yield-share rate, never compounded");
        assertEq(c, SEED_C + 5e18, "same total appreciation");
        assertLe(premiumB, premiumA, "reusing the unreset window cannot overcharge the senior tranche");
        assertApproxEqRel(premiumB, premiumA, 0.001e18, "and it charges essentially the same total");
        assertLe(stGainB, stGainA + 1, "same total senior attribution");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 25 - same_block_gain_splitting_changes_premium
    //////////////////////////////////////////////////////////////////////*/

    /// @notice KNOWN VULNERABILITY DEMONSTRATION for `same_block_gain_splitting_changes_premium`.
    /// @dev This test PASSES in the current (vulnerable) implementation. Both arms start from an identical
    ///      market and an identical accrual history: 100s accrued at a 0.04/0.02 yield share then 100s at
    ///      0.16/0.08, so the time-weighted window average is 0.10/0.05 while the instantaneous reading is
    ///      0.16/0.08. Settling the whole 12e18 gain once pays the window average (1.5e18). Chopping it into
    ///      four same-block syncs pays the window average on the first slice and then, because paying a
    ///      premium resets `lastPremiumPaymentTimestamp` to the current block, the INSTANTANEOUS rate over a
    ///      forced 1-second window on the remaining three - inflating the total premium a keeper who controls
    ///      sync timing extracts from the senior tranche. WHEN THIS IS FIXED THIS TEST MUST BE INVERTED to
    ///      `assertEq(premiumB, premiumA)`.
    function test_KnownVuln_SameBlockGainSplittingChangesPremium() public {
        // Path A: settle the whole gain in one sync
        _deploy(_defaultParams());
        jtYDM.setRates(0.04e18);
        lptYDM.setRates(0.02e18);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(100);
        kernel.doPreOp(toNAVUnits(SEED_C));
        jtYDM.setRates(0.16e18);
        lptYDM.setRates(0.08e18);
        _advance(100);
        SyncedAccountingState memory single = kernel.doPreOp(toNAVUnits(SEED_C + 12e18));
        uint256 premiumA = _premiumOf(SEED_ST, SEED_JT, 12e18, single);
        assertEq(Math.mulDiv(12e18, SEED_ST, SEED_C, Math.Rounding.Floor), 10e18, "senior attributed gain");
        assertEq(premiumA, 1.5e18, "one settlement pays the 10%/5% window average on the whole senior gain");
        assertEq(toUint256(_snap().lastCollateralNAV), SEED_C + 12e18, "path A settled the whole gain");

        // Path B: identical market and identical accrual history, the same gain chopped into four same-block syncs
        _deploy(_defaultParams());
        jtYDM.setRates(0.04e18);
        lptYDM.setRates(0.02e18);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(100);
        kernel.doPreOp(toNAVUnits(SEED_C));
        jtYDM.setRates(0.16e18);
        lptYDM.setRates(0.08e18);
        _advance(100);

        uint256 c = SEED_C;
        uint256 st = SEED_ST;
        uint256 jt = SEED_JT;
        uint256 premiumB;
        uint256 expectedB;
        for (uint256 i; i < 4; ++i) {
            uint256 stGainI = Math.mulDiv(3e18, st, c, Math.Rounding.Floor);
            SyncedAccountingState memory step = kernel.doPreOp(toNAVUnits(c + 3e18));
            premiumB += _premiumOf(st, jt, 3e18, step);
            uint256 jtRateI = i == 0 ? uint256(0.1e18) : uint256(0.16e18);
            uint256 lptRateI = i == 0 ? uint256(0.05e18) : uint256(0.08e18);
            expectedB += Math.mulDiv(stGainI, jtRateI, WAD, Math.Rounding.Floor) + Math.mulDiv(stGainI, lptRateI, WAD, Math.Rounding.Floor);
            c += 3e18;
            st = toUint256(step.stEffectiveNAV);
            jt = toUint256(step.jtEffectiveNAV);
        }
        assertEq(premiumB, expectedB, "the split premium follows the accrued-then-instantaneous mix exactly");
        assertEq(c, SEED_C + 12e18, "same total appreciation");
        assertEq(toUint256(_snap().lastCollateralNAV), SEED_C + 12e18, "path B settled the same gain");
        assertGt(premiumB, premiumA, "splitting one senior gain across same-block syncs inflates the total premium charged");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 26 - single_instantaneous_reading_applied_over_whole_window
    //////////////////////////////////////////////////////////////////////*/

    /// @notice KNOWN VULNERABILITY DEMONSTRATION for `single_instantaneous_reading_applied_over_whole_window`.
    /// @dev This test PASSES in the current (vulnerable) implementation. Both arms run an identical 1e6-second
    ///      window whose honest utilizations (12% coverage, 5% liquidity) sit strictly below the configured
    ///      caps, so the clamp does not bind in the control. The treatment arm spikes utilization only in the
    ///      final instant (a dust junior redemption plus a 1-wei venue mark) immediately before the sync; the
    ///      accrual multiplies that single reading by the WHOLE elapsed window, lifting the effective risk
    ///      premium rate from 12% to the 20% cap and the liquidity premium rate from 5% to the 10% cap. The
    ///      configured maxima are the only thing bounding the transfer. WHEN THIS IS FIXED THIS TEST MUST BE
    ///      INVERTED to assert the two effective rates are equal.
    function test_KnownVuln_SpikedUtilizationRetroactivelyInflatesPremium() public {
        uint256 window = 1_000_000;

        EchoUtilizationYDM c1 = new EchoUtilizationYDM();
        EchoUtilizationYDM c2 = new EchoUtilizationYDM();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory pc = _defaultParams();
        pc.minCoverageWAD = 0.02e18;
        pc.minLiquidityWAD = 0.005e18;
        pc.jtYDM = address(c1);
        pc.lptYDM = address(c2);
        _deploy(pc);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        assertEq(_covUtil(SEED_C, 0.02e18, SEED_JT), 0.12e18, "unspiked coverage utilization is below maxJT");
        assertEq(_liqUtil(SEED_ST, 0.005e18, SEED_LPT), 0.05e18, "unspiked liquidity utilization is below maxLPT");
        _advance(window);
        SyncedAccountingState memory ctrl = kernel.doPreOp(toNAVUnits(SEED_C + 50e18));
        uint256 stGainC = Math.mulDiv(50e18, SEED_ST, SEED_C, Math.Rounding.Floor);
        uint256 jtPremC = toUint256(ctrl.jtEffectiveNAV) - SEED_JT - (50e18 - stGainC);
        uint256 lptPremC = toUint256(ctrl.lptLiquidityPremium);
        assertEq(jtPremC, Math.mulDiv(stGainC, 0.12e18, WAD, Math.Rounding.Floor), "control risk premium at the honest 12% rate");
        assertEq(lptPremC, Math.mulDiv(stGainC, 0.05e18, WAD, Math.Rounding.Floor), "control liquidity premium at the honest 5% rate");

        EchoUtilizationYDM t1 = new EchoUtilizationYDM();
        EchoUtilizationYDM t2 = new EchoUtilizationYDM();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory pt = _defaultParams();
        pt.minCoverageWAD = 0.02e18;
        pt.minLiquidityWAD = 0.005e18;
        pt.jtYDM = address(t1);
        pt.lptYDM = address(t2);
        _deploy(pt);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(window);
        kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(SEED_C - (SEED_JT - 1e18)), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS);
        kernel.doCommit(toNAVUnits(uint256(1)));

        uint256 c0 = toUint256(_snap().lastCollateralNAV);
        uint256 st0 = toUint256(_snap().lastSTEffectiveNAV);
        uint256 jt0 = toUint256(_snap().lastJTEffectiveNAV);
        assertGt(_covUtil(c0, 0.02e18, jt0), MAX_JT_SHARE, "coverage utilization spiked past the cap");
        assertGt(_liqUtil(st0, 0.005e18, 1), MAX_LPT_SHARE, "liquidity utilization spiked past the cap");

        SyncedAccountingState memory trt = kernel.doPreOp(toNAVUnits(c0 + 50e18));
        uint256 stGainT = Math.mulDiv(50e18, st0, c0, Math.Rounding.Floor);
        uint256 jtPremT = toUint256(trt.jtEffectiveNAV) - jt0 - (50e18 - stGainT);
        uint256 lptPremT = toUint256(trt.lptLiquidityPremium);

        assertEq(jtPremT, Math.mulDiv(stGainT, MAX_JT_SHARE, WAD, Math.Rounding.Floor), "spiked risk premium pinned at maxJT");
        assertEq(lptPremT, Math.mulDiv(stGainT, MAX_LPT_SHARE, WAD, Math.Rounding.Floor), "spiked liquidity premium pinned at maxLPT");
        assertApproxEqAbs(_rate(jtPremC, stGainC), 0.12e18, 2, "honest risk premium rate");
        assertApproxEqAbs(_rate(jtPremT, stGainT), uint256(MAX_JT_SHARE), 2, "spiked risk premium rate is the configured maximum");
        assertGt(_rate(jtPremT, stGainT), _rate(jtPremC, stGainC), "the final-instant spike reprices the whole accrual window");
        assertGt(_rate(lptPremT, stGainT), _rate(lptPremC, stGainC), "and the same for the liquidity premium");
        assertLe(jtPremT + lptPremT, stGainT, "the clamp keeps both premiums inside the senior slice");
        _assertReturnedConservation(trt, "spiked window");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 27 - postop_without_preop_misattributes_pnl
    //////////////////////////////////////////////////////////////////////*/

    /// @notice `postop_without_preop_misattributes_pnl`, scoped to the accountant.
    /// @dev The accountant is delta-only by design (see `test_PostOpIsStrictlyDeltaInterpretation` for
    ///      property 15), so it cannot itself detect a missing pre-op: it measures against `lastCollateralNAV`
    ///      and books the difference to the operating tranche. This test pins both frames side by side to
    ///      quantify the exposure the ordering guarantee is protecting: with the pre-op the junior tranche
    ///      keeps its 1.666e18 pro-rata share of the 10e18 of unrealized PnL; without it, the full 15e18 is
    ///      booked to the senior deposit and the junior share is silently diverted.
    ///      EXPLICIT LIMITATION: the ordering itself (preOp -> operation -> postOp inside one `nonReentrant`
    ///      frame) lives in `RoycoDayBalancerV3Kernel`, outside the NAV Sync Engine component under test, so
    ///      it is not asserted here; it must be covered by a kernel-level test.
    function test_PostOpDeltaBookingRequiresKernelPreOpOrdering() public {
        _deploy(_defaultParams());
        _seedFlat();
        SyncedAccountingState memory pre = kernel.doPreOp(toNAVUnits(SEED_C + 10e18));
        assertEq(toUint256(pre.stEffectiveNAV), 1008333333333333333333, "pre-op senior share of the PnL");
        assertEq(toUint256(pre.jtEffectiveNAV), 201666666666666666667, "pre-op junior share of the PnL");
        SyncedAccountingState memory postA = kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_C + 15e18), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS);
        assertEq(toUint256(postA.stEffectiveNAV), 1013333333333333333333, "ordered frame: senior gets PnL share + deposit");
        assertEq(toUint256(postA.jtEffectiveNAV), 201666666666666666667, "ordered frame: junior keeps its PnL share");

        _deploy(_defaultParams());
        _seedFlat();
        SyncedAccountingState memory postB = kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_C + 15e18), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS);
        assertEq(toUint256(postB.stEffectiveNAV), 1015e18, "stale frame: the whole 15e18 is booked to the senior tranche");
        assertEq(toUint256(postB.jtEffectiveNAV), SEED_JT, "stale frame: the junior tranche receives none of the PnL");

        assertEq(
            toUint256(postA.jtEffectiveNAV) - toUint256(postB.jtEffectiveNAV),
            1666666666666666667,
            "junior PnL share at risk if a frame ever settles a post-op without a fresh pre-op"
        );
        _assertReturnedConservation(postA, "ordered");
        _assertReturnedConservation(postB, "stale");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 28 - lpt_mark_commit_ordering
    //////////////////////////////////////////////////////////////////////*/

    /// @notice `lpt_mark_commit_ordering`, scoped to the accountant's inertness half.
    /// @dev What is asserted here: the commit writes exactly `lastLPTRawNAV` and no other ledger field; a
    ///      post-op's returned `liquidityUtilizationWAD` (the senior-liquidity gate input) is computed from
    ///      the mark that call settles, never from the stored one; and an arbitrarily wrong stored mark can
    ///      never move the senior or junior claims through the waterfall.
    ///      EXPLICIT LIMITATION: the ordering claim proper - that the mark is committed strictly AFTER the
    ///      sync's fee and liquidity-premium senior share mints, so it prices the post-mint senior share rate
    ///      - is sequenced in `RoycoDayBalancerV3Kernel` (`accountant.preOpSync` -> fee/premium mints ->
    ///      `commitLiquidityProviderTrancheRawNAV`), outside the NAV Sync Engine component under test. The
    ///      accountant accepts any value at any time from the kernel and cannot enforce that sequencing, so
    ///      it must be covered by a kernel-level call-order test.
    function test_LPTMarkCommitIsInertWithinTheAccountant() public {
        _deploy(_defaultParams());
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));

        IRoycoDayAccountant.RoycoDayAccountantState memory a = _snap();
        kernel.doCommit(toNAVUnits(uint256(999e18)));
        IRoycoDayAccountant.RoycoDayAccountantState memory b = _snap();

        assertEq(toUint256(b.lastLPTRawNAV), 999e18, "the commit writes exactly the supplied mark");
        a.lastLPTRawNAV = b.lastLPTRawNAV;
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), "the commit touches no other field of the ledger");

        uint256 c = toUint256(b.lastCollateralNAV);
        SyncedAccountingState memory s = kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(c), toNAVUnits(uint256(10e18)), ZERO_NAV_UNITS);
        assertEq(
            s.liquidityUtilizationWAD,
            _liqUtil(toUint256(s.stEffectiveNAV), MIN_LIQUIDITY, 10e18),
            "the senior-liquidity gate input is the fresh mark, not the committed one"
        );
        assertTrue(s.liquidityUtilizationWAD != _liqUtil(toUint256(s.stEffectiveNAV), MIN_LIQUIDITY, 999e18), "the stale mark is not used");

        uint256 st0 = toUint256(_snap().lastSTEffectiveNAV);
        uint256 jt0 = toUint256(_snap().lastJTEffectiveNAV);
        kernel.doCommit(toNAVUnits(uint256(1)));
        SyncedAccountingState memory s2 = kernel.doPreOp(_snap().lastCollateralNAV);
        assertEq(toUint256(s2.stEffectiveNAV), st0, "a wildly stale mark cannot move the senior claim");
        assertEq(toUint256(s2.jtEffectiveNAV), jt0, "a wildly stale mark cannot move the junior claim");
        assertEq(toUint256(_snap().lastLPTRawNAV), 1, "and the pre-op never rewrites the mark");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 29 - ydm_revert_freezes_all_syncs
    //////////////////////////////////////////////////////////////////////*/

    function test_YDMRevertIsRecoverableViaYDMSwap() public {
        _deploy(_defaultParams());
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(100);

        jtYDM.setRevertOnYieldShare(true);
        vm.expectRevert(MockRecordingYDM.YDM_REVERTED.selector);
        kernel.doPreOp(toNAVUnits(SEED_C + 1e18));

        kernel.setSyncMode(MockAccountantKernel.SyncMode.SYNC);
        kernel.setSyncNAV(toNAVUnits(SEED_C + 1e18));
        MockRecordingYDM healthy = new MockRecordingYDM();
        accountant.setJuniorTrancheYDM(address(healthy), "");
        assertEq(_snap().jtYDM, address(healthy), "ydm swapped while syncs were bricked");

        kernel.setSyncMode(MockAccountantKernel.SyncMode.NONE);
        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(SEED_C + 1e18));
        _assertReturnedConservation(s, "post recovery");
        _assertConfigBounds("post recovery");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 30 - ydm_reentrancy_during_accrual
    //////////////////////////////////////////////////////////////////////*/

    function test_YDMReentrancyDuringAccrualIsBlockedByKernelGuard() public {
        KernelReentrantYDM evil = new KernelReentrantYDM();
        MockRecordingYDM benign = new MockRecordingYDM();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.jtYDM = address(evil);
        p.lptYDM = address(benign);
        _deploy(p);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(100);
        assertGt(block.timestamp, uint256(_snap().lastYieldShareAccrualTimestamp), "an accrual window is open so the YDM is invoked");

        evil.arm(
            address(kernel),
            abi.encodeCall(GuardedMockKernel.guardedPostOp, (Operation.ST_DEPOSIT, toNAVUnits(SEED_C + 5e18), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS))
        );
        SyncedAccountingState memory guarded = kernel.guardedPreOp(toNAVUnits(SEED_C + 20e18));

        assertTrue(evil.attempted(), "the malicious YDM ran inside the accrual window");
        assertFalse(evil.reentrySucceeded(), "the kernel guard blocked the reentrant operation");
        assertEq(evil.reentryRevertSelector(), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector, "blocked by the reentrancy guard");
        assertEq(toUint256(guarded.collateralNAV), SEED_C + 20e18, "guarded sync settled at the fresh mark");
        assertEq(toUint256(guarded.stEffectiveNAV), 1016666666666666666666, "guarded senior claim");
        assertEq(toUint256(guarded.jtEffectiveNAV), 203333333333333333334, "guarded junior claim");
        _assertStorageConservation("guarded reentrancy");

        KernelReentrantYDM evil2 = new KernelReentrantYDM();
        MockRecordingYDM benign2 = new MockRecordingYDM();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p2 = _defaultParams();
        p2.jtYDM = address(evil2);
        p2.lptYDM = address(benign2);
        _deploy(p2);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(100);
        assertGt(block.timestamp, uint256(_snap().lastYieldShareAccrualTimestamp), "an accrual window is open so the YDM is invoked");

        evil2.arm(
            address(kernel),
            abi.encodeCall(MockAccountantKernel.doPostOp, (Operation.ST_DEPOSIT, toNAVUnits(SEED_C + 5e18), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS))
        );
        SyncedAccountingState memory unguarded = kernel.doPreOp(toNAVUnits(SEED_C + 20e18));

        assertTrue(evil2.attempted(), "the malicious YDM ran inside the accrual window");
        assertTrue(evil2.reentrySucceeded(), "without the kernel guard the reentrant operation settles");
        assertTrue(
            toUint256(unguarded.stEffectiveNAV) != toUint256(guarded.stEffectiveNAV),
            "the kernel's nonReentrant is the control that makes the guarded outcome correct"
        );
        _assertStorageConservation("unguarded reentrancy");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 31 - unbounded_dust_tolerance_disables_recovery_and_fees
    //////////////////////////////////////////////////////////////////////*/

    /// @notice KNOWN VULNERABILITY DEMONSTRATION for `unbounded_dust_tolerance_disables_recovery_and_fees`.
    /// @dev This test PASSES in the current (vulnerable) implementation. `setDustTolerance` accepts an
    ///      arbitrarily large NAV-unit value under a separate operational role and every configuration bound
    ///      still holds afterwards. With a huge tolerance `jtImpermanentLoss <= dustTolerance` is always true,
    ///      so every sync forces PERPETUAL and erases the junior recovery claim as a realized loss, and every
    ///      protocol fee leg is suppressed. A closed dip/recover cycle therefore permanently shrinks the
    ///      junior claim from 200e18 to 156.5e18 with zero net collateral PnL and zero protocol revenue.
    ///      WHEN THIS IS FIXED THIS TEST MUST BE INVERTED to `assertEq(rec.jtEffectiveNAV, SEED_JT)`.
    function test_KnownVuln_UnboundedDustToleranceDisablesRecoveryAndFees() public {
        _deploy(_defaultParams());
        _seedFlat();
        accountant.setDustTolerance(toNAVUnits(uint256(1e30)));
        _assertConfigBounds("huge dust still passes every configuration bound");

        SyncedAccountingState memory dip = kernel.doPreOp(toNAVUnits(SEED_C - 50e18));
        assertEq(uint8(dip.marketState), uint8(MarketState.PERPETUAL), "forced perpetual by the dust gate");
        assertEq(toUint256(dip.jtImpermanentLoss), 0, "the junior recovery claim is erased");
        assertEq(toUint256(dip.stEffectiveNAV), SEED_ST, "senior untouched");
        assertEq(toUint256(dip.jtEffectiveNAV), 150e18, "junior absorbed the whole drawdown");

        SyncedAccountingState memory rec = kernel.doPreOp(toNAVUnits(SEED_C));
        assertEq(toUint256(rec.stEffectiveNAV), 1043478260869565217391, "the senior tranche keeps most of the recovery");
        assertEq(toUint256(rec.jtEffectiveNAV), 156521739130434782609, "the junior tranche recovers only its pro-rata share");
        assertLt(toUint256(rec.jtEffectiveNAV), SEED_JT, "a closed dip/recover cycle permanently shrinks the junior claim");
        _assertNoDistribution(rec, "all protocol revenue suppressed");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 32 - waterfall_attribution_base_equals_live_claims
    //////////////////////////////////////////////////////////////////////*/

    function testFuzz_WaterfallAttributionBaseEqualsLiveClaims(uint256 _il, uint256 _gain) public {
        _il = bound(_il, 1e18, 100e18);
        _gain = bound(_gain, _il + 1, 1000e18);

        _deploy(_defaultParams());
        _seedState(SEED_ST, SEED_JT, _il, SEED_LPT, MarketState.FIXED_TERM);

        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(SEED_C + _gain));

        uint256 stLive = SEED_ST;
        uint256 jtLive = SEED_JT + _il;
        uint256 base = SEED_C + _il;
        assertEq(base, stLive + jtLive, "the attribution base equals the live claims");

        uint256 residual = _gain - _il;
        uint256 stGain = Math.mulDiv(residual, stLive, base, Math.Rounding.Floor);
        uint256 jtGain = residual - stGain;
        assertLe(stGain, residual, "senior attribution within the residual");

        assertEq(toUint256(s.stEffectiveNAV), stLive + stGain, "senior attributed against the live base");
        assertEq(toUint256(s.jtEffectiveNAV), jtLive + jtGain, "junior credited the repayment then its pro-rata share");
        assertEq(toUint256(s.jtImpermanentLoss), 0, "the ledger was fully repaid");
        _assertReturnedConservation(s, "attribution");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 33 - returned_fees_and_premiums_bounded_for_kernel_mints
    //////////////////////////////////////////////////////////////////////*/

    function testFuzz_ReturnedFeesAndPremiumsBounded(uint256 _gain, uint256 _dt) public {
        _gain = bound(_gain, 1, 1e24);
        _dt = bound(_dt, 1, 100_000);

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        p.jtProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        p.jtYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        p.lptYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        _deploy(p);
        jtYDM.setRates(type(uint256).max);
        lptYDM.setRates(type(uint256).max);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(_dt);

        SyncedAccountingState memory s = kernel.doPreOp(toNAVUnits(SEED_C + _gain));

        uint256 lptPremium = toUint256(s.lptLiquidityPremium);
        uint256 stFee = toUint256(s.stProtocolFee);
        uint256 jtFee = toUint256(s.jtProtocolFee);
        uint256 lptFee = toUint256(s.lptProtocolFee);

        assertLe(lptFee, lptPremium, "lptProtocolFee <= lptLiquidityPremium");
        assertLe(stFee + lptPremium, toUint256(s.stEffectiveNAV), "senior mints fit inside the senior claim");
        assertLe(jtFee, toUint256(s.jtEffectiveNAV), "junior fee mint fits inside the junior claim");
        assertLe(stFee + jtFee + lptFee, _gain, "no wei of yield is charged a protocol fee twice");
        assertApproxEqAbs(stFee + jtFee + lptFee, _gain, 3, "the four fee bases tile the settled gain");
        _assertReturnedConservation(s, "fees");
    }

    function test_FeeAccrualDoesNotMoveNAVs() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stProtocolFeeWAD = 0;
        p.jtProtocolFeeWAD = 0;
        p.jtYieldShareProtocolFeeWAD = 0;
        p.lptYieldShareProtocolFeeWAD = 0;
        _deploy(p);
        jtYDM.setRates(0.2e18);
        lptYDM.setRates(0.1e18);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(1000);
        SyncedAccountingState memory a = kernel.doPreOp(toNAVUnits(SEED_C + 90e18));

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p2 = _defaultParams();
        p2.stProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        p2.jtProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        p2.jtYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        p2.lptYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        _deploy(p2);
        jtYDM.setRates(0.2e18);
        lptYDM.setRates(0.1e18);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(1000);
        SyncedAccountingState memory b = kernel.doPreOp(toNAVUnits(SEED_C + 90e18));

        assertEq(toUint256(a.stProtocolFee), 0, "control charges no fee");
        assertGt(toUint256(b.stProtocolFee), 0, "treatment charges a fee");
        assertEq(toUint256(a.stEffectiveNAV), toUint256(b.stEffectiveNAV), "fees are never subtracted from the senior claim");
        assertEq(toUint256(a.jtEffectiveNAV), toUint256(b.jtEffectiveNAV), "fees are never subtracted from the junior claim");
        assertEq(toUint256(a.lptLiquidityPremium), toUint256(b.lptLiquidityPremium), "fees do not resize the premium");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 34 - returned_state_mirrors_committed_checkpoint
    //////////////////////////////////////////////////////////////////////*/

    function test_ReturnedStateMirrorsCommittedCheckpoint() public {
        _deploy(_defaultParams());
        jtYDM.setRates(0.2e18);
        lptYDM.setRates(0.1e18);
        _seedFlat();

        _assertMirrorsCheckpoint(kernel.doPreOp(toNAVUnits(SEED_C + 30e18)), "perp->perp");
        _advance(100);
        _assertMirrorsCheckpoint(kernel.doPreOp(toNAVUnits(SEED_C)), "perp->fixed");
        assertEq(uint8(_snap().lastMarketState), uint8(MarketState.FIXED_TERM), "entered the term");
        _advance(100);
        _assertMirrorsCheckpoint(kernel.doPreOp(toNAVUnits(SEED_C - 5e18)), "fixed->fixed");
        _advance(100);
        _assertMirrorsCheckpoint(kernel.doPreOp(toNAVUnits(SEED_C + 200e18)), "fixed->perp");
        assertEq(uint8(_snap().lastMarketState), uint8(MarketState.PERPETUAL), "left the term");
        uint256 c = toUint256(_snap().lastCollateralNAV);
        _assertMirrorsCheckpoint(kernel.doPostOp(Operation.JT_DEPOSIT, toNAVUnits(c + 4e18), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS), "postop");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 35 - fixed_term_dip_recover_is_exact
    //////////////////////////////////////////////////////////////////////*/

    function testFuzz_FixedTermDipRecoverIsExact(uint256 _loss, uint256 _dt) public {
        _loss = bound(_loss, 1, 99e18);
        _dt = bound(_dt, 1, 100_000);

        _deploy(_defaultParams());
        jtYDM.setRates(0.2e18);
        lptYDM.setRates(0.1e18);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(_dt);

        SyncedAccountingState memory dip = kernel.doPreOp(toNAVUnits(SEED_C - _loss));
        assertEq(uint8(dip.marketState), uint8(MarketState.FIXED_TERM), "the dip opens the recovery term");
        assertEq(toUint256(dip.jtImpermanentLoss), _loss, "the whole dip is a recovery claim");

        _advance(_dt);
        SyncedAccountingState memory rec = kernel.doPreOp(toNAVUnits(SEED_C));
        assertEq(toUint256(rec.stEffectiveNAV), SEED_ST, "senior restored wei-exactly");
        assertEq(toUint256(rec.jtEffectiveNAV), SEED_JT, "junior restored wei-exactly");
        assertEq(toUint256(rec.jtImpermanentLoss), 0, "the recovery claim is cleared");
        assertEq(uint8(rec.marketState), uint8(MarketState.PERPETUAL), "the term closes");
        _assertNoDistribution(rec, "closed dip-recover cycle");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 36 - perpetual_dip_recover_ratchets_value_from_junior_to_senior
    //////////////////////////////////////////////////////////////////////*/

    /// @notice KNOWN VULNERABILITY DEMONSTRATION for
    ///         `perpetual_dip_recover_ratchets_value_from_junior_to_senior`.
    /// @dev This test PASSES in the current (vulnerable) implementation. Any PERPETUAL resolution erases the
    ///      ENTIRE junior impermanent loss as a realized loss, so the recovery gain has no restoration claim
    ///      to repay and is split pro-rata instead. A closed volatility cycle of 10e18 with zero net
    ///      collateral PnL therefore ratchets 8.403e18 out of the junior claim into the senior claim, and any
    ///      actor able to force syncs at moments of its choosing can repeat the cycle. WHEN THIS IS FIXED
    ///      THIS TEST MUST BE INVERTED to `assertEq(back.stEffectiveNAV, SEED_ST)`.
    function test_KnownVuln_PerpetualDipRecoverRatchetsValueToSenior() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.fixedTermDurationSeconds = 0;
        _deploy(p);
        _seedFlat();

        SyncedAccountingState memory dip = kernel.doPreOp(toNAVUnits(SEED_C - 10e18));
        assertEq(uint8(dip.marketState), uint8(MarketState.PERPETUAL), "no recovery term is ever opened");
        assertEq(toUint256(dip.jtImpermanentLoss), 0, "the recovery claim is erased immediately");
        assertEq(toUint256(dip.jtEffectiveNAV), 190e18, "the junior absorbed the whole dip");

        SyncedAccountingState memory back = kernel.doPreOp(toNAVUnits(SEED_C));
        assertEq(toUint256(back.stEffectiveNAV), 1008403361344537815126, "senior claim after a closed cycle");
        assertEq(toUint256(back.jtEffectiveNAV), 191596638655462184874, "junior claim after a closed cycle");
        assertEq(toUint256(back.stEffectiveNAV) - SEED_ST, 8403361344537815126, "value ratcheted from junior to senior per cycle");
        assertEq(SEED_JT - toUint256(back.jtEffectiveNAV), 8403361344537815126, "the junior funded exactly that transfer");
        _assertReturnedConservation(back, "ratchet");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 37 - bonus_accepted_without_liquidation_precondition
    //////////////////////////////////////////////////////////////////////*/

    /// @notice `bonus_accepted_without_liquidation_precondition`: the liquidation precondition is enforced,
    ///         by the self-liquidation helper the kernel routes every senior redemption through.
    /// @dev The helper returns a zero bonus while `coverageUtilizationWAD < coverageLiquidationUtilizationWAD`
    ///      and only opens the bonus once the threshold is reached, so a junior-funded bonus cannot be sized
    ///      in a healthy market. The accountant's own role is to settle whatever bonus it is handed within
    ///      the magnitude bounds and NAV conservation (property 17).
    ///      EXPLICIT LIMITATION: the accountant does not independently re-derive the liquidation
    ///      precondition from its own checkpoint, so the guarantee rests entirely on the kernel-side helper;
    ///      adding a defensive check in the accountant is recorded as a recommendation.
    function test_SelfLiquidationBonusPreconditionEnforcedByKernelHelper() public {
        SelfLiquidationHarness h = new SelfLiquidationHarness();
        h.setSelfLiquidationBonusWAD(0.05e18);

        AssetClaims memory claims;
        claims.collateralAssets = toTrancheUnits(uint256(100e18));
        claims.nav = toNAVUnits(uint256(100e18));

        SyncedAccountingState memory healthy;
        healthy.coverageUtilizationWAD = _covUtil(SEED_C, MIN_COVERAGE, SEED_JT);
        healthy.coverageLiquidationUtilizationWAD = LIQ_UTIL;
        healthy.stEffectiveNAV = toNAVUnits(SEED_ST);
        healthy.jtEffectiveNAV = toNAVUnits(SEED_JT);
        assertLt(healthy.coverageUtilizationWAD, LIQ_UTIL, "market is healthy");
        (AssetClaims memory outHealthy, NAV_UNIT bonusHealthy) = h.applyBonus(healthy, claims);
        assertEq(toUint256(bonusHealthy), 0, "no bonus is sized below the liquidation threshold");
        assertEq(toUint256(outHealthy.nav), 100e18, "the redeemer's claims pass through unchanged");

        SyncedAccountingState memory justBelow;
        justBelow.coverageUtilizationWAD = LIQ_UTIL - 1;
        justBelow.coverageLiquidationUtilizationWAD = LIQ_UTIL;
        justBelow.stEffectiveNAV = toNAVUnits(SEED_ST);
        justBelow.jtEffectiveNAV = toNAVUnits(SEED_JT);
        (, NAV_UNIT bonusJustBelow) = h.applyBonus(justBelow, claims);
        assertEq(toUint256(bonusJustBelow), 0, "the boundary is strict: one wei below the threshold still grants nothing");

        SyncedAccountingState memory breached;
        breached.coverageUtilizationWAD = LIQ_UTIL;
        breached.coverageLiquidationUtilizationWAD = LIQ_UTIL;
        breached.stEffectiveNAV = toNAVUnits(SEED_ST);
        breached.jtEffectiveNAV = toNAVUnits(SEED_JT);
        (AssetClaims memory outBreached, NAV_UNIT bonusBreached) = h.applyBonus(breached, claims);
        assertEq(toUint256(bonusBreached), 5e18, "the bonus opens only once the threshold is reached");
        assertEq(toUint256(outBreached.nav), 105e18, "and it is credited to the senior redeemer");

        // A zero bonus - the only value the helper produces in a healthy market - settles as a plain senior
        // redemption that never touches the junior claim.
        _deploy(_defaultParams());
        _seedFlat();
        assertLt(_covUtil(SEED_C, MIN_COVERAGE, SEED_JT), LIQ_UTIL, "the accountant's own checkpoint shows a healthy market");
        SyncedAccountingState memory s =
            kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(SEED_C - 100e18), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS);
        assertEq(toUint256(s.jtEffectiveNAV), SEED_JT, "a healthy-market senior redemption leaves the junior claim untouched");
        assertEq(toUint256(s.stEffectiveNAV), SEED_ST - 100e18, "and debits only the senior claim");
        _assertReturnedConservation(s, "zero-bonus redemption");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 38 - zero_collateral_nav_recovery_all_to_senior
    //////////////////////////////////////////////////////////////////////*/

    /// @notice KNOWN VULNERABILITY DEMONSTRATION for `zero_collateral_nav_recovery_all_to_senior`.
    /// @dev This test PASSES in the current (vulnerable) implementation. A total collateral wipe leaves
    ///      C == S == J == 0 and forces PERPETUAL (both `stEffectiveNAV == 0` and `jtEffectiveNAV == 0` are
    ///      forcing conditions), erasing the junior recovery claim. The next positive mark hits the
    ///      `lastCollateralNAV == ZERO_NAV_UNITS` special case in the residual-gain attribution, which
    ///      credits 100% of the recovered value to the senior claim (and charges the senior protocol fee on
    ///      all of it), leaving the wiped junior holders with nothing. WHEN THIS IS FIXED THIS TEST MUST BE
    ///      INVERTED to `assertGt(rec.jtEffectiveNAV, 0)`.
    function test_KnownVuln_ZeroCollateralRecoveryAllToSenior() public {
        _deploy(_defaultParams());
        _seedFlat();

        SyncedAccountingState memory wipe = kernel.doPreOp(ZERO_NAV_UNITS);
        assertEq(toUint256(wipe.collateralNAV), 0, "total wipe");
        assertEq(toUint256(wipe.stEffectiveNAV), 0, "senior wiped");
        assertEq(toUint256(wipe.jtEffectiveNAV), 0, "junior wiped");
        assertEq(uint8(wipe.marketState), uint8(MarketState.PERPETUAL), "the wipe forces perpetual");
        assertEq(toUint256(wipe.jtImpermanentLoss), 0, "the recovery claim was erased as a realized loss");

        SyncedAccountingState memory rec = kernel.doPreOp(toNAVUnits(uint256(100e18)));
        assertEq(toUint256(rec.stEffectiveNAV), 100e18, "the whole recovery is credited to the senior claim");
        assertEq(toUint256(rec.jtEffectiveNAV), 0, "the junior tranche receives none of the recovery it funded");
        assertEq(toUint256(rec.stProtocolFee), 10e18, "and the protocol fee is taken on the full senior residual");
        _assertReturnedConservation(rec, "zero-collateral recovery");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 39 - sync_monotone_in_collateral_nav
    //////////////////////////////////////////////////////////////////////*/

    function testFuzz_SyncMonotoneInCollateralNAV(uint256 _a, uint256 _b, uint256 _il, uint256 _dt) public {
        _a = bound(_a, 0, 4000e18);
        _b = bound(_b, 0, 4000e18);
        (uint256 lo, uint256 hi) = _a <= _b ? (_a, _b) : (_b, _a);
        _il = bound(_il, 0, 150e18);
        _dt = bound(_dt, 1, 100_000);

        _deploy(_defaultParams());
        jtYDM.setRates(0.2e18);
        lptYDM.setRates(0.1e18);
        if (_il == 0) {
            _seedFlat();
        } else {
            _seedState(SEED_ST, SEED_JT, _il, SEED_LPT, MarketState.FIXED_TERM);
        }
        kernel.doPreOp(_snap().lastCollateralNAV);
        _advance(_dt);

        bytes32 h = _stateHash();
        SyncedAccountingState memory sLo = accountant.previewSyncTrancheAccounting(toNAVUnits(lo));
        SyncedAccountingState memory sHi = accountant.previewSyncTrancheAccounting(toNAVUnits(hi));
        assertEq(_stateHash(), h, "preview writes no storage");

        assertLe(toUint256(sLo.stEffectiveNAV), toUint256(sHi.stEffectiveNAV), "senior claim monotone in the mark");
        assertLe(toUint256(sLo.jtEffectiveNAV), toUint256(sHi.jtEffectiveNAV), "junior claim monotone in the mark");
        assertTrue(
            toUint256(sLo.jtImpermanentLoss) >= toUint256(sHi.jtImpermanentLoss) || sLo.marketState == MarketState.PERPETUAL,
            "impermanent loss anti-monotone in the mark"
        );
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 40 - postop_returned_utilizations_are_settled_gate_inputs
    //////////////////////////////////////////////////////////////////////*/

    function testFuzz_PostOpReturnedUtilizationsAreSettledGateInputs(uint256 _amt, uint256 _bonus) public {
        _amt = bound(_amt, 1, 100e18);
        _bonus = bound(_bonus, 0, 50e18);

        _deploy(_defaultParams());
        _seedFlat();

        SyncedAccountingState memory s = kernel.doPostOp(Operation.ST_DEPOSIT, toNAVUnits(SEED_C + _amt), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS);
        assertEq(s.coverageUtilizationWAD, _covUtil(SEED_C + _amt, MIN_COVERAGE, toUint256(s.jtEffectiveNAV)), "st deposit coverage");
        assertEq(s.liquidityUtilizationWAD, _liqUtil(toUint256(s.stEffectiveNAV), MIN_LIQUIDITY, SEED_LPT), "st deposit liquidity");

        s = kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(SEED_C + _amt - 1e18), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS);
        assertEq(s.coverageUtilizationWAD, _covUtil(SEED_C + _amt - 1e18, MIN_COVERAGE, toUint256(s.jtEffectiveNAV)), "jt redemption coverage");
        assertEq(s.liquidityUtilizationWAD, _liqUtil(toUint256(s.stEffectiveNAV), MIN_LIQUIDITY, SEED_LPT), "jt redemption liquidity");

        s = kernel.doPostOp(Operation.LPT_REDEMPTION, toNAVUnits(SEED_C + _amt - 1e18), toNAVUnits(uint256(1e18)), ZERO_NAV_UNITS);
        assertEq(s.liquidityUtilizationWAD, _liqUtil(toUint256(s.stEffectiveNAV), MIN_LIQUIDITY, 1e18), "lpt redemption liquidity");

        uint256 c = toUint256(_snap().lastCollateralNAV);
        s = kernel.doPostOp(Operation.ST_REDEMPTION, toNAVUnits(c - 100e18), toNAVUnits(uint256(1e18)), toNAVUnits(_bonus));
        assertEq(
            s.coverageUtilizationWAD,
            _covUtil(c - 100e18, MIN_COVERAGE, toUint256(s.jtEffectiveNAV)),
            "st redemption coverage includes the bonus debit"
        );
        assertEq(s.liquidityUtilizationWAD, _liqUtil(toUint256(s.stEffectiveNAV), MIN_LIQUIDITY, 1e18), "st redemption liquidity");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 41 - premiums_paid_without_live_coverage_or_depth
    //////////////////////////////////////////////////////////////////////*/

    /// @notice KNOWN VULNERABILITY DEMONSTRATION for `premiums_paid_without_live_coverage_or_depth`.
    /// @dev This test PASSES in the current (vulnerable) implementation. The risk premium is sized purely
    ///      from the (clamped) YDM output and the accountant never requires a live loss-absorption buffer.
    ///      (a) With `jtEffectiveNAV == 0` against positive collateral, coverage utilization is the max
    ///      sentinel, so the clamped share is MAXIMAL precisely when the junior is providing nothing: 2.4e18
    ///      of senior yield is diverted to a wiped junior tranche. (b) With `minCoverageWAD == 0` coverage
    ///      utilization is identically zero, so a junior redeemed down to 1e18 still collects the model's
    ///      full 15% share of every subsequent senior gain. WHEN THIS IS FIXED THIS TEST MUST BE INVERTED to
    ///      `assertEq(premT, 0)`.
    function test_KnownVuln_PremiumsPaidWithoutLiveCoverageOrDepth() public {
        EchoUtilizationYDM c1 = new EchoUtilizationYDM();
        EchoUtilizationYDM c2 = new EchoUtilizationYDM();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory pc = _defaultParams();
        pc.minCoverageWAD = 0.02e18;
        pc.jtYDM = address(c1);
        pc.lptYDM = address(c2);
        _deploy(pc);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        _advance(1000);
        SyncedAccountingState memory ctrl = kernel.doPreOp(toNAVUnits(SEED_C + 12e18));
        uint256 stGainC = Math.mulDiv(12e18, SEED_ST, SEED_C, Math.Rounding.Floor);
        uint256 premC = toUint256(ctrl.jtEffectiveNAV) - SEED_JT - (12e18 - stGainC);
        assertEq(premC, Math.mulDiv(stGainC, 0.12e18, WAD, Math.Rounding.Floor), "control risk premium at the 12% coverage reading");

        EchoUtilizationYDM t1 = new EchoUtilizationYDM();
        EchoUtilizationYDM t2 = new EchoUtilizationYDM();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory pt = _defaultParams();
        pt.minCoverageWAD = 0.02e18;
        pt.jtYDM = address(t1);
        pt.lptYDM = address(t2);
        _deploy(pt);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        kernel.doPreOp(toNAVUnits(SEED_ST));
        assertEq(toUint256(_snap().lastJTEffectiveNAV), 0, "junior buffer wiped");
        assertEq(_covUtil(SEED_ST, 0.02e18, 0), type(uint256).max, "utilization is the max sentinel with no buffer");
        _advance(1000);
        SyncedAccountingState memory trt = kernel.doPreOp(toNAVUnits(SEED_ST + 12e18));
        uint256 stGainT = 12e18;
        uint256 premT = toUint256(trt.jtEffectiveNAV);
        assertEq(premT, Math.mulDiv(stGainT, MAX_JT_SHARE, WAD, Math.Rounding.Floor), "wiped-buffer risk premium is pinned at maxJT");
        assertEq(premT, 2.4e18, "2.4e18 of senior yield diverted to a junior tranche with no buffer");
        assertEq(_rate(premT, stGainT), MAX_JT_SHARE, "the premium share is MAXIMAL exactly when coverage is zero");
        assertGt(_rate(premT, stGainT), _rate(premC, stGainC), "less coverage buys a bigger premium");

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory pz = _defaultParams();
        pz.minCoverageWAD = 0;
        _deploy(pz);
        jtYDM.setRates(0.15e18);
        lptYDM.setRates(0);
        _seedFlat();
        kernel.doPreOp(toNAVUnits(SEED_C));
        kernel.doPostOp(Operation.JT_REDEMPTION, toNAVUnits(SEED_C - (SEED_JT - 1e18)), toNAVUnits(SEED_LPT), ZERO_NAV_UNITS);
        uint256 cz = toUint256(_snap().lastCollateralNAV);
        uint256 stz = toUint256(_snap().lastSTEffectiveNAV);
        _advance(1000);
        SyncedAccountingState memory z = kernel.doPreOp(toNAVUnits(cz + 12e18));
        uint256 stGainZ = Math.mulDiv(12e18, stz, cz, Math.Rounding.Floor);
        uint256 premZ = toUint256(z.jtEffectiveNAV) - 1e18 - (12e18 - stGainZ);
        assertEq(z.coverageUtilizationWAD, 0, "minCoverage == 0 makes coverage utilization identically zero");
        assertEq(premZ, Math.mulDiv(stGainZ, 0.15e18, WAD, Math.Rounding.Floor), "a dust junior still collects the model's full 15% share");
        assertGt(premZ, 0, "a free option on senior yield funded by a dust coverage position");
    }
}
