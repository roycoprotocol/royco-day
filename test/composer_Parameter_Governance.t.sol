// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../lib/forge-std/src/Test.sol";
import { AccessManager } from "../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { Math } from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { Initializable } from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";

import { RoycoDayAccountant } from "../src/accountant/RoycoDayAccountant.sol";
import { ADMIN_ACCOUNTANT_ROLE, ADMIN_MARKET_OPS_ROLE, ADMIN_PROTOCOL_FEE_SETTER_ROLE } from "../src/factory/Roles.sol";
import { IRoycoAuth } from "../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../src/interfaces/IRoycoDayAccountant.sol";
import { IYDM } from "../src/interfaces/IYDM.sol";
import { MAX_PROTOCOL_FEE_WAD, WAD, ZERO_NAV_UNITS } from "../src/libraries/Constants.sol";
import { MarketState, Operation, SyncedAccountingState } from "../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits, toUint256 } from "../src/libraries/Units.sol";
import { UtilizationLogic } from "../src/libraries/logic/UtilizationLogic.sol";
import { StaticCurveYDM } from "../src/ydm/StaticCurveYDM.sol";

import { MockRecordingYDM } from "./mocks/MockRecordingYDM.sol";
import { UninitializedERC1967Proxy } from "./mocks/UninitializedERC1967Proxy.sol";

/*//////////////////////////////////////////////////////////////////////////////
                                  TEST DOUBLES
//////////////////////////////////////////////////////////////////////////////*/

/**
 * @notice A faithful mirror of the market kernel's accounting-sync seam
 * @dev The accountant's `withSyncedAccounting` guard drives `syncTrancheAccountingFromAccountant` before and after
 *      every guarded setter. The real kernel (AccountingSyncLogic.preOpSyncTrancheAccounting + _commitLPTRawNAV)
 *      commits the freshly marked liquidity-provider depth and REFRESHES the liquidity utilization in the returned
 *      packet, because the accountant returns zero placeholders for both. This mirror reproduces that exactly, so
 *      the guard's liquidity clause is exercised for real rather than vacuously.
 */
contract GuardKernel {
    error KERNEL_PAUSED();

    IRoycoDayAccountant public accountant;

    NAV_UNIT public collateralNAV;
    NAV_UNIT public lptRawNAV;
    bool public paused;

    uint256 public syncCount;
    uint256 public stFeeTotal;
    uint256 public jtFeeTotal;
    uint256 public lptFeeTotal;
    uint256 public liquidityPremiumTotal;

    function setAccountant(address _accountant) external {
        accountant = IRoycoDayAccountant(_accountant);
    }

    /// @dev Models the kernel being paused / the collateral oracle failing shut: the sync seam reverts
    function setPaused(bool _paused) external {
        paused = _paused;
    }

    /// @notice The entrypoint the accountant's guard (and its best-effort YDM-swap sync) calls
    function syncTrancheAccountingFromAccountant() public returns (SyncedAccountingState memory state) {
        require(!paused, KERNEL_PAUSED());
        syncCount++;
        state = accountant.preOpSyncTrancheAccounting(collateralNAV);
        // Mirror of AccountingSyncLogic._commitLPTRawNAV
        accountant.commitLiquidityProviderTrancheRawNAV(lptRawNAV);
        state.lptRawNAV = lptRawNAV;
        state.liquidityUtilizationWAD = UtilizationLogic._computeLiquidityUtilization(state.stEffectiveNAV, state.minLiquidityWAD, lptRawNAV);
        stFeeTotal += toUint256(state.stProtocolFee);
        jtFeeTotal += toUint256(state.jtProtocolFee);
        lptFeeTotal += toUint256(state.lptProtocolFee);
        liquidityPremiumTotal += toUint256(state.lptLiquidityPremium);
    }

    /// @notice Test-facing alias for the sync seam
    function sync() external returns (SyncedAccountingState memory) {
        return syncTrancheAccountingFromAccountant();
    }

    /// @notice Read-only mirror of the settled state a sync would produce
    function previewSync() external view returns (SyncedAccountingState memory state) {
        state = accountant.previewSyncTrancheAccounting(collateralNAV);
        state.lptRawNAV = lptRawNAV;
        state.liquidityUtilizationWAD = UtilizationLogic._computeLiquidityUtilization(state.stEffectiveNAV, state.minLiquidityWAD, lptRawNAV);
    }

    /// @notice Marks collateral PnL WITHOUT syncing, so a later setter's own guard syncs settle it
    function markPnL(int256 _delta) external {
        collateralNAV = _delta >= 0 ? collateralNAV + toNAVUnits(uint256(_delta)) : collateralNAV - toNAVUnits(uint256(-_delta));
    }

    function depositST(uint256 _amount) external returns (SyncedAccountingState memory) {
        collateralNAV = collateralNAV + toNAVUnits(_amount);
        return accountant.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, collateralNAV, lptRawNAV, ZERO_NAV_UNITS);
    }

    function depositJT(uint256 _amount) external returns (SyncedAccountingState memory) {
        collateralNAV = collateralNAV + toNAVUnits(_amount);
        return accountant.postOpSyncTrancheAccounting(Operation.JT_DEPOSIT, collateralNAV, lptRawNAV, ZERO_NAV_UNITS);
    }

    /// @notice Commits a fresh market-making depth, the only legal way the LPT raw NAV moves
    function setDepth(uint256 _lptRawNAV) external {
        lptRawNAV = toNAVUnits(_lptRawNAV);
        accountant.commitLiquidityProviderTrancheRawNAV(lptRawNAV);
    }
}

/**
 * @notice A contract that is simultaneously a (trivial) YDM and the holder of an accountant-gated privileged
 *         entrypoint, used to observe whether the YDM setters can be made to issue arbitrary calls carrying the
 *         accountant's identity
 */
contract AccountantGatedVictim is IYDM {
    error ONLY_ACCOUNTANT();

    address public immutable ACCOUNTANT;
    uint256 public privilegedCallCount;
    uint256 public lastPrivilegedArg;

    constructor(address _accountant) {
        ACCOUNTANT = _accountant;
    }

    /// @dev The shape of every privileged market entrypoint: gated purely on `msg.sender == accountant`
    function privilegedEntrypoint(uint256 _arg) external {
        require(msg.sender == ACCOUNTANT, ONLY_ACCOUNTANT());
        privilegedCallCount++;
        lastPrivilegedArg = _arg;
    }

    function yieldShare(MarketState, uint256) external pure override(IYDM) returns (uint256) {
        return 0;
    }

    function previewYieldShare(MarketState, uint256) external pure override(IYDM) returns (uint256) {
        return 0;
    }
}

/*//////////////////////////////////////////////////////////////////////////////
                                    TEST SUITE
//////////////////////////////////////////////////////////////////////////////*/

/**
 * @title Test_RoycoDayAccountant_ParameterGovernance
 * @notice Formalizes the Parameter Governance component of `RoycoDayAccountant`: the role-gated setters for protocol
 *         fees, coverage / liquidity thresholds, max yield shares, fixed-term duration, dust tolerance and the two
 *         YDM instances, together with the `withSyncedAccounting` guard wrapped around them.
 *
 * @dev READING THE RESULTS. Tests come in two kinds.
 *      (1) SPECIFICATION tests: they pass iff the property holds. Any RED here is a regression.
 *      (2) EXPECTED-FAIL demonstrations, each flagged `EXPECTED-FAIL` in its header and registered with the runner
 *          as an expected failure. Each is written so it PASSES in the fixed world and FAILS in the world the
 *          current implementation actually inhabits; its RED result, with the concrete counterexample in the
 *          assertion message, IS the finding.
 *
 * @dev ONE CLAIM PER EXPECTED-FAIL TEST. forge-std's assertions revert on failure, so everything after the first
 *      failing assertion in a body is dead code. Every distinct harm named by an attack-vector property therefore
 *      gets its OWN expected-fail test, so each produces its own recorded counterexample rather than being masked
 *      by an earlier one. Where a test must tolerate the setter being rejected in the fixed world, the setter is
 *      invoked through a low-level `call` so that the test's assertions - not the setter's own revert - decide the
 *      outcome in both worlds.
 */
contract Test_RoycoDayAccountant_ParameterGovernance is Test {
    /*//////////////////////////////////////////////////////////////////////
                                 FIXTURE PLUMBING
    //////////////////////////////////////////////////////////////////////*/

    struct Fixture {
        RoycoDayAccountant acct;
        GuardKernel kern;
        MockRecordingYDM jt;
        MockRecordingYDM lpt;
    }

    uint64 internal constant DEFAULT_MIN_COVERAGE_WAD = 0.1e18;
    uint256 internal constant DEFAULT_LIQUIDATION_UTILIZATION_WAD = 1.1e18;
    uint64 internal constant DEFAULT_MIN_LIQUIDITY_WAD = 0.05e18;
    uint64 internal constant DEFAULT_MAX_JT_YIELD_SHARE_WAD = 0.2e18;
    uint64 internal constant DEFAULT_MAX_LPT_YIELD_SHARE_WAD = 0.1e18;
    uint24 internal constant DEFAULT_FIXED_TERM_DURATION_SECONDS = 604_800;
    uint64 internal constant DEFAULT_PROTOCOL_FEE_WAD = 0.1e18;

    uint256 internal constant SEED_ST = 1000e18;
    uint256 internal constant SEED_JT = 300e18;
    uint256 internal constant SEED_DEPTH = 200e18;

    // StaticCurveYDM anchors used by the YDM-swap tests
    uint256 internal constant CURVE_TARGET_WAD = 0.8e18;
    uint64 internal constant CURVE_Y0_WAD = 0.01e18;
    uint64 internal constant CURVE_YT_WAD = 0.05e18;
    uint64 internal constant CURVE_YFULL_WAD = 0.1e18;

    AccessManager internal authority;
    RoycoDayAccountant internal implementation;

    address internal accountantAdmin;
    address internal feeAdmin;
    address internal opsAdmin;
    address internal stranger;

    Fixture internal fx;

    function setUp() public {
        vm.warp(1_700_000_000);

        accountantAdmin = makeAddr("accountantAdmin");
        feeAdmin = makeAddr("feeAdmin");
        opsAdmin = makeAddr("marketOpsAdmin");
        stranger = makeAddr("stranger");

        authority = new AccessManager(address(this));
        authority.grantRole(ADMIN_ACCOUNTANT_ROLE, accountantAdmin, 0);
        authority.grantRole(ADMIN_PROTOCOL_FEE_SETTER_ROLE, feeAdmin, 0);
        authority.grantRole(ADMIN_MARKET_OPS_ROLE, opsAdmin, 0);

        implementation = new RoycoDayAccountant();

        fx = _newFixture(_defaultParams());
        _seed(fx);
    }

    function _defaultParams() internal pure returns (IRoycoDayAccountant.RoycoDayAccountantInitParams memory p) {
        p.fixedTermGracePeriodSeconds = 0;
        p.minCoverageWAD = DEFAULT_MIN_COVERAGE_WAD;
        p.coverageLiquidationUtilizationWAD = DEFAULT_LIQUIDATION_UTILIZATION_WAD;
        p.minLiquidityWAD = DEFAULT_MIN_LIQUIDITY_WAD;
        p.maxJTYieldShareWAD = DEFAULT_MAX_JT_YIELD_SHARE_WAD;
        p.maxLPTYieldShareWAD = DEFAULT_MAX_LPT_YIELD_SHARE_WAD;
        p.fixedTermDurationSeconds = DEFAULT_FIXED_TERM_DURATION_SECONDS;
        p.dustTolerance = ZERO_NAV_UNITS;
        p.stProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        p.jtProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        p.jtYieldShareProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
        p.lptYieldShareProtocolFeeWAD = DEFAULT_PROTOCOL_FEE_WAD;
    }

    /// @dev Deploys a proxy + kernel mirror + (optionally shared) YDMs and wires the production role bindings
    function _newFixture(IRoycoDayAccountant.RoycoDayAccountantInitParams memory _p) internal returns (Fixture memory f) {
        f.kern = new GuardKernel();
        f.acct = RoycoDayAccountant(address(new UninitializedERC1967Proxy(address(implementation))));
        f.kern.setAccountant(address(f.acct));

        if (_p.jtYDM == address(0)) _p.jtYDM = address(new MockRecordingYDM());
        if (_p.lptYDM == address(0)) _p.lptYDM = address(new MockRecordingYDM());
        f.jt = MockRecordingYDM(_p.jtYDM);
        f.lpt = MockRecordingYDM(_p.lptYDM);

        _p.kernel = address(f.kern);
        _p.initialAuthority = address(authority);
        f.acct.initialize(_p);

        _wireRoles(address(f.acct));
    }

    /// @dev Mirrors the production role binding written by the market deployment template
    function _wireRoles(address _target) internal {
        bytes4[] memory acctSel = new bytes4[](7);
        acctSel[0] = IRoycoDayAccountant.setJuniorTrancheYDM.selector;
        acctSel[1] = IRoycoDayAccountant.setLiquidityProviderTrancheYDM.selector;
        acctSel[2] = IRoycoDayAccountant.setMinCoverage.selector;
        acctSel[3] = IRoycoDayAccountant.setLiquidationCoverageUtilization.selector;
        acctSel[4] = IRoycoDayAccountant.setMinLiquidity.selector;
        acctSel[5] = IRoycoDayAccountant.setMaxYieldShares.selector;
        acctSel[6] = IRoycoDayAccountant.setFixedTermDuration.selector;
        authority.setTargetFunctionRole(_target, acctSel, ADMIN_ACCOUNTANT_ROLE);

        bytes4[] memory feeSel = new bytes4[](4);
        feeSel[0] = IRoycoDayAccountant.setSeniorTrancheProtocolFee.selector;
        feeSel[1] = IRoycoDayAccountant.setJuniorTrancheProtocolFee.selector;
        feeSel[2] = IRoycoDayAccountant.setJTYieldShareProtocolFee.selector;
        feeSel[3] = IRoycoDayAccountant.setLPTYieldShareProtocolFee.selector;
        authority.setTargetFunctionRole(_target, feeSel, ADMIN_PROTOCOL_FEE_SETTER_ROLE);

        bytes4[] memory opsSel = new bytes4[](1);
        opsSel[0] = IRoycoDayAccountant.setDustTolerance.selector;
        authority.setTargetFunctionRole(_target, opsSel, ADMIN_MARKET_OPS_ROLE);
    }

    /// @dev Seeds a flat, healthy market through legal kernel calls only, and initializes the accrual clock
    function _seed(Fixture memory _f) internal {
        _f.kern.depositST(SEED_ST);
        _f.kern.depositJT(SEED_JT);
        _f.kern.setDepth(SEED_DEPTH);
        _f.kern.sync();
        _f.jt.setRates(0.1e18);
        _f.lpt.setRates(0.05e18);
    }

    /// @dev Drives the seeded market into FIXED_TERM carrying a junior impermanent loss of exactly `_loss`
    function _enterFixedTerm(Fixture memory _f, uint256 _loss) internal {
        _f.kern.markPnL(-int256(_loss));
        _f.kern.sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory s = _f.acct.getState();
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "arrange: the market must be in a fixed term");
        assertEq(toUint256(s.lastJTImpermanentLoss), _loss, "arrange: the junior impermanent loss must equal the staged loss");
    }

    /// @dev Hash of the whole persisted state, normalized so fixtures with distinct kernel mirrors are comparable
    function _normalizedHash(IRoycoDayAccountant.RoycoDayAccountantState memory _s) internal pure returns (bytes32) {
        _s.kernel = address(0);
        return keccak256(abi.encode(_s));
    }

    /// @dev Hash of exactly the governed configuration fields (nothing mark-to-market)
    function _configHash(IRoycoDayAccountant.RoycoDayAccountantState memory _s) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _s.stProtocolFeeWAD,
                _s.jtProtocolFeeWAD,
                _s.jtYieldShareProtocolFeeWAD,
                _s.lptYieldShareProtocolFeeWAD,
                _s.minCoverageWAD,
                _s.minLiquidityWAD,
                _s.fixedTermDurationSeconds,
                _s.jtYDM,
                _s.maxJTYieldShareWAD,
                _s.lptYDM,
                _s.maxLPTYieldShareWAD,
                _s.kernel,
                _s.fixedTermCommenceableAtTimestamp,
                _s.coverageLiquidationUtilizationWAD,
                _s.dustTolerance
            )
        );
    }

    function _assertStateEquals(IRoycoDayAccountant.RoycoDayAccountantState memory _expected, string memory _label) internal view {
        assertEq(keccak256(abi.encode(fx.acct.getState())), keccak256(abi.encode(_expected)), _label);
    }

    /// @dev The largest minCoverage keeping ceil(collateralNAV * minCoverage / jtEffectiveNAV) at or below 100%
    function _maxSafeMinCoverage(SyncedAccountingState memory _s) internal pure returns (uint64) {
        return uint64(Math.mulDiv(toUint256(_s.jtEffectiveNAV), WAD, toUint256(_s.collateralNAV), Math.Rounding.Floor));
    }

    /// @dev The largest minLiquidity keeping ceil(stEffectiveNAV * minLiquidity / lptRawNAV) at or below 100%
    function _maxSafeMinLiquidity(SyncedAccountingState memory _s) internal pure returns (uint64) {
        return uint64(Math.mulDiv(toUint256(_s.lptRawNAV), WAD, toUint256(_s.stEffectiveNAV), Math.Rounding.Floor));
    }

    /// @dev Independent reimplementation of StaticCurveYDM's below-target leg, used to predict a swapped-in curve
    function _staticCurveShareBelowTarget(uint256 _utilizationWAD) internal pure returns (uint256) {
        uint256 slopeLt = Math.mulDiv(CURVE_YT_WAD - CURVE_Y0_WAD, WAD, CURVE_TARGET_WAD, Math.Rounding.Floor);
        return Math.mulDiv(slopeLt, _utilizationWAD, WAD, Math.Rounding.Floor) + CURVE_Y0_WAD;
    }

    function _staticCurveInitData() internal pure returns (bytes memory) {
        return abi.encodeCall(StaticCurveYDM.initializeYDMForMarket, (CURVE_Y0_WAD, CURVE_YT_WAD, CURVE_YFULL_WAD));
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 1: coverage_liquidity_config_bounds
    //////////////////////////////////////////////////////////////////////*/

    /// @dev minCoverage < WAD, liquidation coverage utilization > WAD, minLiquidity < WAD
    function _assertThresholdBounds(string memory _phase) internal view {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = fx.acct.getState();
        assertLt(uint256(s.minCoverageWAD), WAD, string.concat(_phase, ": minCoverage must stay below 100% of exposure"));
        assertGt(s.coverageLiquidationUtilizationWAD, WAD, string.concat(_phase, ": the liquidation coverage utilization must stay above 100%"));
        assertLt(uint256(s.minLiquidityWAD), WAD, string.concat(_phase, ": minLiquidity must stay below 100% of senior NAV"));
    }

    /// @notice SPEC. `coverage_liquidity_config_bounds`: construction and every threshold setter preserve the bounds
    function testFuzz_CoverageAndLiquidityConfigBoundsAlwaysHold(uint64 _minCoverage, uint64 _minLiquidity, uint256 _liquidationThreshold) public {
        _minCoverage = uint64(bound(_minCoverage, 0, 2 * WAD));
        _minLiquidity = uint64(bound(_minLiquidity, 0, 2 * WAD));
        _liquidationThreshold = bound(_liquidationThreshold, 0, 4 * WAD);

        _assertThresholdBounds("after construction");

        vm.prank(accountantAdmin);
        (bool okCoverage,) = address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setMinCoverage, (_minCoverage)));
        if (_minCoverage >= WAD) assertFalse(okCoverage, "a coverage requirement at or above 100% of exposure must be rejected");
        _assertThresholdBounds("after setMinCoverage");

        vm.prank(accountantAdmin);
        (bool okThreshold,) = address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setLiquidationCoverageUtilization, (_liquidationThreshold)));
        if (_liquidationThreshold <= WAD) assertFalse(okThreshold, "a liquidation coverage utilization at or below 100% must be rejected");
        _assertThresholdBounds("after setLiquidationCoverageUtilization");

        vm.prank(accountantAdmin);
        (bool okLiquidity,) = address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setMinLiquidity, (_minLiquidity)));
        if (_minLiquidity >= WAD) assertFalse(okLiquidity, "a liquidity requirement at or above 100% of senior NAV must be rejected");
        _assertThresholdBounds("after setMinLiquidity");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 2: fee_and_yield_share_config_bounds
    //////////////////////////////////////////////////////////////////////*/

    function _assertFeeAndYieldShareBounds(string memory _phase) internal view {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = fx.acct.getState();
        assertLe(uint256(s.stProtocolFeeWAD), MAX_PROTOCOL_FEE_WAD, string.concat(_phase, ": ST protocol fee cap"));
        assertLe(uint256(s.jtProtocolFeeWAD), MAX_PROTOCOL_FEE_WAD, string.concat(_phase, ": JT protocol fee cap"));
        assertLe(uint256(s.jtYieldShareProtocolFeeWAD), MAX_PROTOCOL_FEE_WAD, string.concat(_phase, ": JT yield-share protocol fee cap"));
        assertLe(uint256(s.lptYieldShareProtocolFeeWAD), MAX_PROTOCOL_FEE_WAD, string.concat(_phase, ": LPT yield-share protocol fee cap"));
        assertLe(
            uint256(s.maxJTYieldShareWAD) + uint256(s.maxLPTYieldShareWAD),
            WAD,
            string.concat(_phase, ": the JT risk premium plus the LPT liquidity premium must fit inside the senior gain")
        );
    }

    /// @notice SPEC. `fee_and_yield_share_config_bounds`: every fee and max-yield-share setter preserves the caps
    function testFuzz_FeeAndYieldShareConfigBoundsAlwaysHold(uint64 _fee, uint64 _maxJT, uint64 _maxLPT) public {
        _fee = uint64(bound(_fee, 0, 2 * WAD));
        _maxJT = uint64(bound(_maxJT, 0, 2 * WAD));
        _maxLPT = uint64(bound(_maxLPT, 0, 2 * WAD));

        _assertFeeAndYieldShareBounds("after construction");

        bytes[] memory feeCalls = new bytes[](4);
        feeCalls[0] = abi.encodeCall(IRoycoDayAccountant.setSeniorTrancheProtocolFee, (_fee));
        feeCalls[1] = abi.encodeCall(IRoycoDayAccountant.setJuniorTrancheProtocolFee, (_fee));
        feeCalls[2] = abi.encodeCall(IRoycoDayAccountant.setJTYieldShareProtocolFee, (_fee));
        feeCalls[3] = abi.encodeCall(IRoycoDayAccountant.setLPTYieldShareProtocolFee, (_fee));
        for (uint256 i; i < feeCalls.length; ++i) {
            vm.prank(feeAdmin);
            (bool ok,) = address(fx.acct).call(feeCalls[i]);
            if (_fee > MAX_PROTOCOL_FEE_WAD) assertFalse(ok, "a protocol fee above MAX_PROTOCOL_FEE_WAD must be rejected");
            else assertTrue(ok, "a protocol fee within the cap must be accepted");
            _assertFeeAndYieldShareBounds("after a protocol fee setter");
        }

        vm.prank(accountantAdmin);
        (bool okShares,) = address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setMaxYieldShares, (_maxJT, _maxLPT)));
        if (uint256(_maxJT) + uint256(_maxLPT) > WAD) assertFalse(okShares, "max yield shares summing past 100% of senior appreciation must be rejected");
        else assertTrue(okShares, "max yield shares summing within 100% of senior appreciation must be accepted");
        _assertFeeAndYieldShareBounds("after setMaxYieldShares");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 3: ydms_distinct_and_nonzero
    //////////////////////////////////////////////////////////////////////*/

    /// @notice SPEC. `ydms_distinct_and_nonzero`: the two YDM pointers are always distinct and non-zero
    function test_YDMsRemainDistinctAndNonZero() public {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = fx.acct.getState();
        assertTrue(s.jtYDM != address(0), "the JT YDM must be non-zero after construction");
        assertTrue(s.lptYDM != address(0), "the LPT YDM must be non-zero after construction");
        assertTrue(s.jtYDM != s.lptYDM, "the two YDMs must be distinct after construction");

        // Collapsing the two pointers onto one instance is rejected from either side
        vm.prank(accountantAdmin);
        vm.expectRevert(IRoycoDayAccountant.YDMS_CANNOT_BE_IDENTICAL.selector);
        fx.acct.setJuniorTrancheYDM(s.lptYDM, "");

        vm.prank(accountantAdmin);
        vm.expectRevert(IRoycoDayAccountant.YDMS_CANNOT_BE_IDENTICAL.selector);
        fx.acct.setLiquidityProviderTrancheYDM(s.jtYDM, "");

        // Neither pointer may be zeroed
        vm.prank(accountantAdmin);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        fx.acct.setJuniorTrancheYDM(address(0), "");

        vm.prank(accountantAdmin);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        fx.acct.setLiquidityProviderTrancheYDM(address(0), "");

        // A legitimate swap keeps the invariant
        MockRecordingYDM fresh = new MockRecordingYDM();
        vm.prank(accountantAdmin);
        fx.acct.setJuniorTrancheYDM(address(fresh), "");

        s = fx.acct.getState();
        assertEq(s.jtYDM, address(fresh), "the swap must persist");
        assertTrue(s.jtYDM != address(0) && s.lptYDM != address(0), "both YDMs must stay non-zero");
        assertTrue(s.jtYDM != s.lptYDM, "both YDMs must stay distinct");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 4: parameter_setters_role_gated
    //////////////////////////////////////////////////////////////////////*/

    /// @dev Every parameter setter, paired with the role production binds it to
    function _allSetterCalls() internal pure returns (bytes[] memory calls, uint8[] memory roleIdx) {
        calls = new bytes[](12);
        roleIdx = new uint8[](12);
        // 0 == accountant admin, 1 == protocol fee setter, 2 == market ops
        calls[0] = abi.encodeCall(IRoycoDayAccountant.setMinCoverage, (uint64(0.12e18)));
        roleIdx[0] = 0;
        calls[1] = abi.encodeCall(IRoycoDayAccountant.setLiquidationCoverageUtilization, (uint256(1.4e18)));
        roleIdx[1] = 0;
        calls[2] = abi.encodeCall(IRoycoDayAccountant.setMinLiquidity, (uint64(0.06e18)));
        roleIdx[2] = 0;
        calls[3] = abi.encodeCall(IRoycoDayAccountant.setMaxYieldShares, (uint64(0.3e18), uint64(0.2e18)));
        roleIdx[3] = 0;
        calls[4] = abi.encodeCall(IRoycoDayAccountant.setFixedTermDuration, (uint24(1_209_600)));
        roleIdx[4] = 0;
        calls[5] = abi.encodeCall(IRoycoDayAccountant.setSeniorTrancheProtocolFee, (uint64(0.2e18)));
        roleIdx[5] = 1;
        calls[6] = abi.encodeCall(IRoycoDayAccountant.setJuniorTrancheProtocolFee, (uint64(0.2e18)));
        roleIdx[6] = 1;
        calls[7] = abi.encodeCall(IRoycoDayAccountant.setJTYieldShareProtocolFee, (uint64(0.2e18)));
        roleIdx[7] = 1;
        calls[8] = abi.encodeCall(IRoycoDayAccountant.setLPTYieldShareProtocolFee, (uint64(0.2e18)));
        roleIdx[8] = 1;
        calls[9] = abi.encodeCall(IRoycoDayAccountant.setDustTolerance, (toNAVUnits(uint256(5))));
        roleIdx[9] = 2;
        calls[10] = abi.encodeCall(IRoycoDayAccountant.setJuniorTrancheYDM, (address(0xBEEF), ""));
        roleIdx[10] = 0;
        calls[11] = abi.encodeCall(IRoycoDayAccountant.setLiquidityProviderTrancheYDM, (address(0xBEEF), ""));
        roleIdx[11] = 0;
    }

    /// @notice SPEC. `parameter_setters_role_gated`: only the account authorized for that specific function may call
    ///         it, and an unauthorized attempt leaves every configuration field untouched
    function test_ParameterSettersAreRoleGated() public {
        (bytes[] memory calls, uint8[] memory roleIdx) = _allSetterCalls();
        address[3] memory holders = [accountantAdmin, feeAdmin, opsAdmin];

        bytes32 configBefore = _configHash(fx.acct.getState());

        for (uint256 i; i < calls.length; ++i) {
            // A pure stranger is never authorized
            vm.prank(stranger);
            (bool ok,) = address(fx.acct).call(calls[i]);
            assertFalse(ok, "an unauthorized caller must never reach a parameter setter");
            assertEq(_configHash(fx.acct.getState()), configBefore, "a rejected call must leave the configuration untouched");

            // Neither is a holder of a DIFFERENT accountant admin role
            for (uint256 r; r < 3; ++r) {
                if (r == roleIdx[i]) continue;
                vm.prank(holders[r]);
                (bool okCross,) = address(fx.acct).call(calls[i]);
                assertFalse(okCross, "a holder of a different accountant admin role must never reach this setter");
                assertEq(_configHash(fx.acct.getState()), configBefore, "a cross-role rejection must leave the configuration untouched");
            }
        }

        // The exact revert an unauthorized caller sees
        vm.prank(feeAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, feeAdmin));
        fx.acct.setMinCoverage(0.12e18);

        vm.prank(opsAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, opsAdmin));
        fx.acct.setSeniorTrancheProtocolFee(0.2e18);

        // The correctly-roled caller succeeds on each
        vm.prank(accountantAdmin);
        fx.acct.setMinCoverage(0.12e18);
        vm.prank(feeAdmin);
        fx.acct.setSeniorTrancheProtocolFee(0.2e18);
        vm.prank(opsAdmin);
        fx.acct.setDustTolerance(toNAVUnits(uint256(5)));

        IRoycoDayAccountant.RoycoDayAccountantState memory s = fx.acct.getState();
        assertEq(uint256(s.minCoverageWAD), 0.12e18, "the authorized coverage change must persist");
        assertEq(uint256(s.stProtocolFeeWAD), 0.2e18, "the authorized fee change must persist");
        assertEq(toUint256(s.dustTolerance), 5, "the authorized dust tolerance change must persist");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 5: config_change_cannot_worsen_coverage_past_100
    //////////////////////////////////////////////////////////////////////*/

    /// @notice SPEC. `config_change_cannot_worsen_coverage_past_100`
    function test_ConfigChangeCannotWorsenCoverageUtilizationPastOneHundredPercent() public {
        SyncedAccountingState memory pre = fx.kern.previewSync();
        assertLe(pre.coverageUtilizationWAD, WAD, "arrange: the market starts coverage-compliant");

        // A worsening change that stays within 100% is admissible
        uint64 bounded = _maxSafeMinCoverage(pre);
        vm.prank(accountantAdmin);
        fx.acct.setMinCoverage(bounded);
        SyncedAccountingState memory post = fx.kern.previewSync();
        assertGt(post.coverageUtilizationWAD, pre.coverageUtilizationWAD, "the tightening must genuinely worsen utilization");
        assertLe(post.coverageUtilizationWAD, WAD, "a compliant market must stay compliant");

        // A change that would push the compliant market past 100% is rejected without a trace
        vm.prank(accountantAdmin);
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        fx.acct.setMinCoverage(bounded + 0.01e18);
        assertEq(uint256(fx.acct.getState().minCoverageWAD), uint256(bounded), "a rejected coverage change must never persist");

        // Restore a moderate requirement, then breach through PnL (never through configuration)
        vm.prank(accountantAdmin);
        fx.acct.setMinCoverage(DEFAULT_MIN_COVERAGE_WAD);
        fx.kern.markPnL(-250e18);
        SyncedAccountingState memory breached = fx.kern.sync();
        assertGt(breached.coverageUtilizationWAD, WAD, "arrange: the losses must breach the coverage requirement");

        // Deepening an existing breach is rejected
        vm.prank(accountantAdmin);
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        fx.acct.setMinCoverage(DEFAULT_MIN_COVERAGE_WAD + 0.01e18);

        // Improving it is always available
        vm.prank(accountantAdmin);
        fx.acct.setMinCoverage(DEFAULT_MIN_COVERAGE_WAD / 2);
        SyncedAccountingState memory healed = fx.kern.previewSync();
        assertLe(healed.coverageUtilizationWAD, breached.coverageUtilizationWAD, "an admitted change must never deepen the breach");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 6: config_change_cannot_worsen_liquidity_past_100
    //////////////////////////////////////////////////////////////////////*/

    /// @notice SPEC. `config_change_cannot_worsen_liquidity_past_100`
    function test_ConfigChangeCannotWorsenLiquidityUtilizationPastOneHundredPercent() public {
        SyncedAccountingState memory pre = fx.kern.previewSync();
        assertLe(pre.liquidityUtilizationWAD, WAD, "arrange: the market starts liquidity-compliant");

        uint64 bounded = _maxSafeMinLiquidity(pre);
        vm.prank(accountantAdmin);
        fx.acct.setMinLiquidity(bounded);
        SyncedAccountingState memory post = fx.kern.previewSync();
        assertGt(post.liquidityUtilizationWAD, pre.liquidityUtilizationWAD, "the tightening must genuinely worsen utilization");
        assertLe(post.liquidityUtilizationWAD, WAD, "a compliant market must stay compliant");

        vm.prank(accountantAdmin);
        vm.expectRevert(IRoycoDayAccountant.INVALID_LIQUIDITY_CONFIG.selector);
        fx.acct.setMinLiquidity(bounded + 0.01e18);
        assertEq(uint256(fx.acct.getState().minLiquidityWAD), uint256(bounded), "a rejected liquidity change must never persist");

        // Breach through a collapse of the market-making depth
        fx.kern.setDepth(40e18);
        SyncedAccountingState memory breached = fx.kern.previewSync();
        assertGt(breached.liquidityUtilizationWAD, WAD, "arrange: the depth collapse must breach the liquidity floor");

        vm.prank(accountantAdmin);
        vm.expectRevert(IRoycoDayAccountant.INVALID_LIQUIDITY_CONFIG.selector);
        fx.acct.setMinLiquidity(bounded + 0.01e18);

        vm.prank(accountantAdmin);
        fx.acct.setMinLiquidity(bounded / 4);
        SyncedAccountingState memory healed = fx.kern.previewSync();
        assertLe(healed.liquidityUtilizationWAD, breached.liquidityUtilizationWAD, "an admitted change must never deepen the breach");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 7: config_change_cannot_trigger_liquidation
    //////////////////////////////////////////////////////////////////////*/

    /// @notice SPEC. `config_change_cannot_trigger_liquidation`
    function test_ConfigChangeCannotTriggerLiquidation() public {
        // Stage a market that is breached on coverage but strictly below the liquidation threshold
        fx.kern.markPnL(-190e18);
        SyncedAccountingState memory pre = fx.kern.sync();
        assertGt(pre.coverageUtilizationWAD, WAD, "arrange: the market must be coverage-breached");
        assertLt(pre.coverageUtilizationWAD, pre.coverageLiquidationUtilizationWAD, "arrange: the market must not be liquidating");

        // Lowering the threshold onto live utilization would arm the regime the moment the setter returned
        vm.prank(accountantAdmin);
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        fx.acct.setLiquidationCoverageUtilization(pre.coverageUtilizationWAD);

        // Raising minCoverage until utilization reaches the threshold is likewise rejected
        vm.prank(accountantAdmin);
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        fx.acct.setMinCoverage(0.12e18);

        // Lowering the threshold to strictly above live utilization is admissible and leaves the regime disarmed
        vm.prank(accountantAdmin);
        fx.acct.setLiquidationCoverageUtilization(pre.coverageUtilizationWAD + 1);
        SyncedAccountingState memory post = fx.kern.previewSync();
        assertLt(post.coverageUtilizationWAD, post.coverageLiquidationUtilizationWAD, "an admitted threshold change must not arm the liquidation regime");

        // Fee, max-yield-share, dust-tolerance and fixed-term writes cannot arm it either. Each is made against a
        // freshly marked, UNSETTLED gain, so the guard's pre-sync runs the full repayment / premium / fee waterfall
        // and the write genuinely moves the junior claim that coverage utilization is measured against.
        uint256 jtBefore = toUint256(fx.acct.getState().lastJTEffectiveNAV);

        vm.warp(block.timestamp + 100);
        fx.kern.markPnL(250e18); // repays the whole impermanent loss and leaves a residual senior gain
        vm.prank(feeAdmin);
        fx.acct.setSeniorTrancheProtocolFee(uint64(MAX_PROTOCOL_FEE_WAD));

        vm.warp(block.timestamp + 100);
        fx.kern.markPnL(100e18);
        vm.prank(accountantAdmin);
        fx.acct.setMaxYieldShares(uint64(0.5e18), uint64(0.5e18));

        vm.warp(block.timestamp + 100);
        fx.kern.markPnL(100e18);
        vm.prank(opsAdmin);
        fx.acct.setDustTolerance(toNAVUnits(uint256(1e12)));

        vm.warp(block.timestamp + 100);
        fx.kern.markPnL(100e18);
        vm.prank(accountantAdmin);
        fx.acct.setFixedTermDuration(uint24(3600));

        assertTrue(toUint256(fx.acct.getState().lastJTEffectiveNAV) != jtBefore, "arrange: the writes must have settled real PnL through the junior claim");

        post = fx.kern.previewSync();
        assertLt(post.coverageUtilizationWAD, post.coverageLiquidationUtilizationWAD, "no configuration write may arm the ST self-liquidation bonus");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 8: setter_mutates_only_its_own_fields
    //////////////////////////////////////////////////////////////////////*/

    /// @notice SPEC. `setter_mutates_only_its_own_fields`: each setter writes exactly the field(s) it names
    function test_SetterMutatesOnlyItsOwnFields() public {
        address kernelBefore = fx.acct.getState().kernel;
        IRoycoDayAccountant.RoycoDayAccountantState memory e;

        e = fx.acct.getState();
        vm.prank(feeAdmin);
        fx.acct.setSeniorTrancheProtocolFee(0.2e18);
        e.stProtocolFeeWAD = 0.2e18;
        _assertStateEquals(e, "setSeniorTrancheProtocolFee must touch only the ST protocol fee");

        e = fx.acct.getState();
        vm.prank(feeAdmin);
        fx.acct.setJuniorTrancheProtocolFee(0.21e18);
        e.jtProtocolFeeWAD = 0.21e18;
        _assertStateEquals(e, "setJuniorTrancheProtocolFee must touch only the JT protocol fee");

        e = fx.acct.getState();
        vm.prank(feeAdmin);
        fx.acct.setJTYieldShareProtocolFee(0.22e18);
        e.jtYieldShareProtocolFeeWAD = 0.22e18;
        _assertStateEquals(e, "setJTYieldShareProtocolFee must touch only the JT yield-share protocol fee");

        e = fx.acct.getState();
        vm.prank(feeAdmin);
        fx.acct.setLPTYieldShareProtocolFee(0.23e18);
        e.lptYieldShareProtocolFeeWAD = 0.23e18;
        _assertStateEquals(e, "setLPTYieldShareProtocolFee must touch only the LPT yield-share protocol fee");

        e = fx.acct.getState();
        vm.prank(accountantAdmin);
        fx.acct.setMinCoverage(0.15e18);
        e.minCoverageWAD = 0.15e18;
        _assertStateEquals(e, "setMinCoverage must leave the liquidity configuration and the fees untouched");

        e = fx.acct.getState();
        vm.prank(accountantAdmin);
        fx.acct.setLiquidationCoverageUtilization(1.5e18);
        e.coverageLiquidationUtilizationWAD = 1.5e18;
        _assertStateEquals(e, "setLiquidationCoverageUtilization must touch only the liquidation threshold");

        e = fx.acct.getState();
        vm.prank(accountantAdmin);
        fx.acct.setMinLiquidity(0.06e18);
        e.minLiquidityWAD = 0.06e18;
        _assertStateEquals(e, "setMinLiquidity must leave the coverage configuration and the fees untouched");

        e = fx.acct.getState();
        vm.prank(accountantAdmin);
        fx.acct.setMaxYieldShares(0.3e18, 0.2e18);
        e.maxJTYieldShareWAD = 0.3e18;
        e.maxLPTYieldShareWAD = 0.2e18;
        _assertStateEquals(e, "setMaxYieldShares must touch only the two maximum yield shares");

        e = fx.acct.getState();
        vm.prank(accountantAdmin);
        fx.acct.setFixedTermDuration(1_209_600);
        e.fixedTermDurationSeconds = 1_209_600;
        _assertStateEquals(e, "a non-zero setFixedTermDuration must touch only the duration");

        e = fx.acct.getState();
        vm.prank(opsAdmin);
        fx.acct.setDustTolerance(toNAVUnits(uint256(7)));
        e.dustTolerance = toNAVUnits(uint256(7));
        _assertStateEquals(e, "setDustTolerance must touch only the dust tolerance");

        MockRecordingYDM newJT = new MockRecordingYDM();
        e = fx.acct.getState();
        vm.prank(accountantAdmin);
        fx.acct.setJuniorTrancheYDM(address(newJT), "");
        e.jtYDM = address(newJT);
        _assertStateEquals(e, "setJuniorTrancheYDM must touch only the JT YDM pointer");

        MockRecordingYDM newLPT = new MockRecordingYDM();
        e = fx.acct.getState();
        vm.prank(accountantAdmin);
        fx.acct.setLiquidityProviderTrancheYDM(address(newLPT), "");
        e.lptYDM = address(newLPT);
        _assertStateEquals(e, "setLiquidityProviderTrancheYDM must touch only the LPT YDM pointer");

        assertEq(fx.acct.getState().kernel, kernelBefore, "no setter may ever reassign the kernel pointer");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 9: zero_fixed_term_duration_forces_perpetual
    //////////////////////////////////////////////////////////////////////*/

    /// @notice SPEC. `zero_fixed_term_duration_forces_perpetual`
    function test_ZeroFixedTermDurationForcesPerpetual() public {
        _enterFixedTerm(fx, 190e18);

        vm.prank(accountantAdmin);
        fx.acct.setFixedTermDuration(0);

        IRoycoDayAccountant.RoycoDayAccountantState memory s = fx.acct.getState();
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "a zero duration must force the market perpetual");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "a zero duration must zero the junior impermanent loss");
        assertEq(uint256(s.fixedTermEndTimestamp), 0, "a zero duration must clear the fixed-term end timestamp");

        // While the duration stays zero, no sync may re-enter FIXED_TERM or re-open an impermanent loss
        for (uint256 i; i < 5; ++i) {
            vm.warp(block.timestamp + 3600);
            fx.kern.markPnL(-60e18);
            fx.kern.sync();
            s = fx.acct.getState();
            assertEq(uint256(s.fixedTermDurationSeconds), 0, "arrange: the duration must still be zero");
            assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "a zero-duration market must never re-enter a fixed term");
            assertEq(toUint256(s.lastJTImpermanentLoss), 0, "a zero-duration market must never re-open an impermanent loss");
        }
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 10: nonzero_fixed_term_duration_preserves_recovery_state
    //////////////////////////////////////////////////////////////////////*/

    /// @notice SPEC. `nonzero_fixed_term_duration_preserves_recovery_state`: a non-zero duration write leaves
    ///         (marketState, jtImpermanentLoss, fixedTermEndTimestamp) exactly where plain syncs would
    function test_NonZeroFixedTermDurationPreservesRecoveryState() public {
        // Two identical markets sharing the same YDM instances so their states are directly comparable
        MockRecordingYDM sharedJT = new MockRecordingYDM();
        MockRecordingYDM sharedLPT = new MockRecordingYDM();

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory pa = _defaultParams();
        pa.jtYDM = address(sharedJT);
        pa.lptYDM = address(sharedLPT);
        Fixture memory a = _newFixture(pa);
        _seed(a);

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory pb = _defaultParams();
        pb.jtYDM = address(sharedJT);
        pb.lptYDM = address(sharedLPT);
        Fixture memory b = _newFixture(pb);
        _seed(b);

        _enterFixedTerm(a, 190e18);
        _enterFixedTerm(b, 190e18);

        vm.warp(block.timestamp + 1000);

        // A: a non-zero duration write (whose guard performs the two syncs)
        vm.prank(accountantAdmin);
        a.acct.setFixedTermDuration(2 * DEFAULT_FIXED_TERM_DURATION_SECONDS);

        // B: the two plain accounting syncs at the same timestamp
        b.kern.sync();
        b.kern.sync();

        IRoycoDayAccountant.RoycoDayAccountantState memory sa = a.acct.getState();
        IRoycoDayAccountant.RoycoDayAccountantState memory sb = b.acct.getState();

        assertEq(uint8(sa.lastMarketState), uint8(sb.lastMarketState), "the market state must match plain syncs");
        assertEq(toUint256(sa.lastJTImpermanentLoss), toUint256(sb.lastJTImpermanentLoss), "the junior recovery claim must match plain syncs");
        assertEq(uint256(sa.fixedTermEndTimestamp), uint256(sb.fixedTermEndTimestamp), "the fixed-term end must match plain syncs");
        assertEq(uint8(sa.lastMarketState), uint8(MarketState.FIXED_TERM), "the recovery regime must not have been flipped by the write");
        assertGt(toUint256(sa.lastJTImpermanentLoss), 0, "the recovery claim must not have been erased by the write");
        assertEq(uint256(sa.fixedTermDurationSeconds), 2 * DEFAULT_FIXED_TERM_DURATION_SECONDS, "the new duration must persist");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 11: parameter_changes_apply_prospectively_to_premium_accrual
    //////////////////////////////////////////////////////////////////////*/

    /// @notice SPEC. `parameter_changes_apply_prospectively_to_premium_accrual`
    function test_ParameterChangesApplyProspectivelyToPremiumAccrual() public {
        // The YDMs quote above both caps, so the caps in force during a window fully determine its accrual
        fx.jt.setRates(0.5e18);
        fx.lpt.setRates(0.5e18);

        uint256 windowOne = 100;
        vm.warp(block.timestamp + windowOne);

        // Raising the caps must not re-price the window that already elapsed
        vm.prank(accountantAdmin);
        fx.acct.setMaxYieldShares(0.4e18, 0.3e18);

        IRoycoDayAccountant.RoycoDayAccountantState memory s = fx.acct.getState();
        assertEq(
            uint256(s.twJTYieldShareAccruedWAD),
            windowOne * DEFAULT_MAX_JT_YIELD_SHARE_WAD,
            "the elapsed JT window must be priced with the maximum share in force during it"
        );
        assertEq(
            uint256(s.twLPTYieldShareAccruedWAD),
            windowOne * DEFAULT_MAX_LPT_YIELD_SHARE_WAD,
            "the elapsed LPT window must be priced with the maximum share in force during it"
        );
        assertEq(
            uint256(s.lastYieldShareAccrualTimestamp), block.timestamp, "the accrual checkpoint must be advanced before the new configuration is effective"
        );

        // A YDM swap must likewise price the pre-swap window with the outgoing curve
        uint256 windowTwo = 50;
        vm.warp(block.timestamp + windowTwo);

        MockRecordingYDM incoming = new MockRecordingYDM();
        incoming.setRates(0.05e18);
        vm.prank(accountantAdmin);
        fx.acct.setJuniorTrancheYDM(address(incoming), "");

        s = fx.acct.getState();
        assertEq(s.jtYDM, address(incoming), "arrange: the swap must have landed");
        assertEq(
            uint256(s.twJTYieldShareAccruedWAD),
            windowOne * DEFAULT_MAX_JT_YIELD_SHARE_WAD + windowTwo * 0.4e18,
            "the pre-swap window must be priced with the outgoing YDM curve, never re-priced by the incoming one"
        );
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 12: ydm_swap_leaves_market_syncable
    //////////////////////////////////////////////////////////////////////*/

    /// @notice SPEC. `ydm_swap_leaves_market_syncable`: a swap carrying initialization data leaves the incoming model
    ///         initialized FOR THIS ACCOUNTANT, so the market keeps pricing and syncing
    function test_YDMSwapWithInitializationDataLeavesMarketSyncable() public {
        StaticCurveYDM incoming = new StaticCurveYDM(CURVE_TARGET_WAD);

        vm.prank(accountantAdmin);
        fx.acct.setJuniorTrancheYDM(address(incoming), _staticCurveInitData());
        assertEq(fx.acct.getState().jtYDM, address(incoming), "the swap must persist");

        // The newly installed model must actually PRICE the next window (not merely fail to revert): predict the
        // curve output independently from the StaticCurveYDM anchors and the market's own coverage utilization
        IRoycoDayAccountant.RoycoDayAccountantState memory pre = fx.acct.getState();
        uint256 covUtil = UtilizationLogic._computeCoverageUtilization(pre.lastCollateralNAV, pre.minCoverageWAD, pre.lastJTEffectiveNAV);
        assertLt(covUtil, CURVE_TARGET_WAD, "arrange: the market must sit on the curve's below-target leg");
        uint256 expectedShare = Math.min(_staticCurveShareBelowTarget(covUtil), uint256(pre.maxJTYieldShareWAD));
        assertGt(expectedShare, 0, "arrange: the installed curve must quote a live rate");

        uint256 window = 100;
        vm.warp(block.timestamp + window);
        fx.kern.sync();

        assertEq(
            uint256(fx.acct.getState().twJTYieldShareAccruedWAD),
            uint256(pre.twJTYieldShareAccruedWAD) + window * expectedShare,
            "the incoming model must be initialized for this accountant and price the window exactly"
        );

        // And a real gain still settles end-to-end through the new model
        fx.kern.markPnL(100e18);
        SyncedAccountingState memory s = fx.kern.sync();
        assertGt(toUint256(s.lptLiquidityPremium) + toUint256(s.stProtocolFee), 0, "the market must keep settling premiums and fees after the swap");
    }

    /// @notice EXPECTED-FAIL. `ydm_swap_leaves_market_syncable` (strong form). Passes in the fixed world (a swap that
    ///         would leave the incoming model uninitialized is rejected or self-initializes); RED on the current
    ///         implementation, where `_initializeYDM` skips the call entirely for empty data and imposes no
    ///         post-condition, so `StaticCurveYDM._yieldShare` reverts `UNINITIALIZED_YDM()` and every sync (and
    ///         therefore every deposit and redemption) is bricked.
    function test_YDMSwapCannotCompleteLeavingIncomingModelUninitialized() public {
        StaticCurveYDM incoming = new StaticCurveYDM(CURVE_TARGET_WAD);

        // Empty initialization data: the setter never initializes the incoming model for this accountant
        vm.prank(accountantAdmin);
        (bool swapped,) = address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setJuniorTrancheYDM, (address(incoming), "")));

        vm.warp(block.timestamp + 100);
        try fx.kern.sync() {
            // In the fixed world either the swap was refused (market still on the old, working model) or the setter
            // initialized the incoming model itself. Either way the market stays syncable.
            assertTrue(!swapped || fx.acct.getState().jtYDM == address(incoming), "the market must stay syncable and its YDM pointer coherent");
        } catch {
            fail("a completed YDM swap must never leave the market unsyncable");
        }
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 13: ydm_swap_remains_available_when_syncs_revert
    //////////////////////////////////////////////////////////////////////*/

    /// @notice SPEC. `ydm_swap_remains_available_when_syncs_revert`: a sync-bricking YDM is always recoverable
    function test_YDMSwapRemainsAvailableWhenSyncsRevert() public {
        // Brick the market: the installed JT YDM reverts, so every accounting sync reverts
        fx.jt.setRevertOnYieldShare(true);
        fx.jt.setRevertOnPreviewYieldShare(true);
        vm.warp(block.timestamp + 100);

        vm.expectRevert(MockRecordingYDM.YDM_REVERTED.selector);
        fx.kern.sync();

        // The JT YDM setter must remain callable and must not condition its success on a successful sync
        StaticCurveYDM incoming = new StaticCurveYDM(CURVE_TARGET_WAD);
        vm.prank(accountantAdmin);
        fx.acct.setJuniorTrancheYDM(address(incoming), _staticCurveInitData());
        assertEq(fx.acct.getState().jtYDM, address(incoming), "the JT YDM swap must succeed while syncs revert");

        // The market is healed
        fx.kern.sync();

        // The same must hold for the LPT setter when the sync seam itself is unavailable
        fx.kern.setPaused(true);
        StaticCurveYDM incomingLPT = new StaticCurveYDM(CURVE_TARGET_WAD);
        vm.prank(accountantAdmin);
        fx.acct.setLiquidityProviderTrancheYDM(address(incomingLPT), _staticCurveInitData());
        assertEq(fx.acct.getState().lptYDM, address(incomingLPT), "the LPT YDM swap must succeed while the sync seam reverts");

        fx.kern.setPaused(false);
        fx.kern.sync();
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 14: no_hidden_state_change_on_no_op_config_write
    //////////////////////////////////////////////////////////////////////*/

    /// @dev A/B differential: market A takes the no-op config write, market B takes the two plain syncs the guard
    ///      performs. Both must land byte-identical state and identical fee / premium flows
    function _assertNoOpWriteMatchesPlainSyncs(bytes memory _call, address _caller, string memory _label) internal {
        MockRecordingYDM sharedJT = new MockRecordingYDM();
        MockRecordingYDM sharedLPT = new MockRecordingYDM();
        sharedJT.setRates(0.1e18);
        sharedLPT.setRates(0.05e18);

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory pa = _defaultParams();
        pa.jtYDM = address(sharedJT);
        pa.lptYDM = address(sharedLPT);
        Fixture memory a = _newFixture(pa);
        _seed(a);

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory pb = _defaultParams();
        pb.jtYDM = address(sharedJT);
        pb.lptYDM = address(sharedLPT);
        Fixture memory b = _newFixture(pb);
        _seed(b);

        // Outstanding PnL and elapsed time, so the two guard syncs actually do work
        vm.warp(block.timestamp + 500);
        a.kern.markPnL(300e18);
        b.kern.markPnL(300e18);

        vm.prank(_caller);
        (bool ok,) = address(a.acct).call(_call);
        assertTrue(ok, string.concat(_label, ": the no-op write must be admitted"));

        b.kern.sync();
        b.kern.sync();

        assertEq(
            _normalizedHash(a.acct.getState()),
            _normalizedHash(b.acct.getState()),
            string.concat(_label, ": a no-op config write must leave the state identical to the plain syncs alone")
        );
        assertEq(a.kern.stFeeTotal(), b.kern.stFeeTotal(), string.concat(_label, ": must move no senior protocol fee"));
        assertEq(a.kern.jtFeeTotal(), b.kern.jtFeeTotal(), string.concat(_label, ": must move no junior protocol fee"));
        assertEq(a.kern.lptFeeTotal(), b.kern.lptFeeTotal(), string.concat(_label, ": must move no LPT protocol fee"));
        assertEq(a.kern.liquidityPremiumTotal(), b.kern.liquidityPremiumTotal(), string.concat(_label, ": must move no liquidity premium"));
        assertGt(a.kern.stFeeTotal() + a.kern.jtFeeTotal(), 0, string.concat(_label, ": arrange, the settled window must have produced real fees"));
    }

    /// @notice SPEC. `no_hidden_state_change_on_no_op_config_write`, across a fee setter, both threshold setters, the
    ///         fixed-term branch and the dust tolerance
    function test_NoHiddenStateChangeOnNoOpConfigWrite() public {
        _assertNoOpWriteMatchesPlainSyncs(
            abi.encodeCall(IRoycoDayAccountant.setSeniorTrancheProtocolFee, (DEFAULT_PROTOCOL_FEE_WAD)), feeAdmin, "setSeniorTrancheProtocolFee"
        );
        _assertNoOpWriteMatchesPlainSyncs(abi.encodeCall(IRoycoDayAccountant.setMinCoverage, (DEFAULT_MIN_COVERAGE_WAD)), accountantAdmin, "setMinCoverage");
        _assertNoOpWriteMatchesPlainSyncs(abi.encodeCall(IRoycoDayAccountant.setMinLiquidity, (DEFAULT_MIN_LIQUIDITY_WAD)), accountantAdmin, "setMinLiquidity");
        _assertNoOpWriteMatchesPlainSyncs(
            abi.encodeCall(IRoycoDayAccountant.setLiquidationCoverageUtilization, (DEFAULT_LIQUIDATION_UTILIZATION_WAD)),
            accountantAdmin,
            "setLiquidationCoverageUtilization"
        );
        _assertNoOpWriteMatchesPlainSyncs(
            abi.encodeCall(IRoycoDayAccountant.setFixedTermDuration, (DEFAULT_FIXED_TERM_DURATION_SECONDS)), accountantAdmin, "setFixedTermDuration"
        );
        _assertNoOpWriteMatchesPlainSyncs(abi.encodeCall(IRoycoDayAccountant.setDustTolerance, (ZERO_NAV_UNITS)), opsAdmin, "setDustTolerance");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 15: unbounded_dust_tolerance_abuse

        The property names two distinct harms. Each gets its own expected-fail test so that neither is masked by
        the other's assertion reverting first.
    //////////////////////////////////////////////////////////////////////*/

    /// @notice EXPECTED-FAIL. `unbounded_dust_tolerance_abuse`, harm (a): forcing the market out of FIXED_TERM by
    ///         treating a real junior impermanent loss as dust, erasing the junior tranche's recovery claim. Passes
    ///         in the fixed world (the dust tolerance is bounded, or the guard rejects a write that erases a live
    ///         recovery claim); RED on the current implementation, where `setDustTolerance` accepts any NAV_UNIT and
    ///         the guard compares only coverage / liquidity utilization, so `jtImpermanentLoss <= dustTolerance`
    ///         drops the market to PERPETUAL. Note the escalation: this setter sits under the market-ops role, not
    ///         the coverage or fee admin roles.
    function test_UnboundedDustToleranceCannotForceMarketOutOfFixedTerm() public {
        _enterFixedTerm(fx, 190e18);

        // The market-ops role installs a dust tolerance dwarfing the entire market
        vm.prank(opsAdmin);
        address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setDustTolerance, (toNAVUnits(uint256(1e30)))));

        IRoycoDayAccountant.RoycoDayAccountantState memory s = fx.acct.getState();
        assertGt(toUint256(s.lastJTImpermanentLoss), 0, "an unbounded dust tolerance must not erase the junior tranche's recovery claim");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "an unbounded dust tolerance must not force the market out of its fixed term");
    }

    /// @notice EXPECTED-FAIL. `unbounded_dust_tolerance_abuse`, harm (b): suppressing ALL premium and protocol-fee
    ///         accrual through the `stGain > dust` / `jtGain > dust` gates. Passes in the fixed world (a bounded
    ///         dust tolerance cannot swallow a 500e18 gain); RED on the current implementation, where the market-ops
    ///         role installs an arbitrarily large tolerance and the subsequent sync accrues zero fees on a real gain.
    function test_UnboundedDustToleranceCannotSuppressFeeAccrual() public {
        vm.prank(opsAdmin);
        address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setDustTolerance, (toNAVUnits(uint256(1e30)))));

        vm.warp(block.timestamp + 100);
        uint256 feesBefore = fx.kern.stFeeTotal() + fx.kern.jtFeeTotal() + fx.kern.lptFeeTotal();
        uint256 premiumBefore = fx.kern.liquidityPremiumTotal();

        fx.kern.markPnL(500e18);
        fx.kern.sync();

        assertGt(
            fx.kern.stFeeTotal() + fx.kern.jtFeeTotal() + fx.kern.lptFeeTotal(),
            feesBefore,
            "an unbounded dust tolerance must not suppress protocol fee accrual on a real 500e18 gain"
        );
        assertGt(fx.kern.liquidityPremiumTotal(), premiumBefore, "an unbounded dust tolerance must not suppress liquidity premium accrual on a real gain");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 16: arbitrary_call_through_ydm_initialization_data
    //////////////////////////////////////////////////////////////////////*/

    /// @notice EXPECTED-FAIL. `arbitrary_call_through_ydm_initialization_data`. Passes in the fixed world (the YDM
    ///         setters validate the incoming model against an interface/registry and never forward opaque calldata);
    ///         RED on the current implementation, where `_initializeYDM` performs
    ///         `_ydm._dispatch(DispatchMode.EXECUTE, _ydmInitializationData)` -- a raw call from the accountant to a
    ///         caller-supplied address with caller-supplied data -- so a compromised or careless admin can drive any
    ///         entrypoint gated on `msg.sender == accountant`.
    function test_YDMInitializationDataCannotIssueArbitraryCallsFromTheAccountant() public {
        AccountantGatedVictim victim = new AccountantGatedVictim(address(fx.acct));

        vm.prank(accountantAdmin);
        address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setJuniorTrancheYDM, (address(victim), abi.encodeCall(AccountantGatedVictim.privilegedEntrypoint, (42)))));

        assertEq(victim.privilegedCallCount(), 0, "the YDM setter must never let an admin issue an arbitrary call with the accountant's identity");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 17: ydm_swap_bypasses_synced_accounting_guard
    //////////////////////////////////////////////////////////////////////*/

    /// @notice EXPECTED-FAIL. `ydm_swap_bypasses_synced_accounting_guard`. Passes in the fixed world (the swap either
    ///         requires a settled sync or advances the accrual checkpoint itself); RED on the current implementation,
    ///         where `$.kernel._tryExecute(...)` silently swallows the failing sync, `lastYieldShareAccrualTimestamp`
    ///         is not advanced, and the entire pre-swap elapsed window is subsequently accrued through the newly
    ///         installed curve, re-attributing premium between the senior, junior and LP tranches for a period that
    ///         already elapsed.
    function test_YDMSwapWithFailingSyncCannotRepriceTheElapsedWindow() public {
        // Outgoing curve quotes 0.1e18, well under the 0.2e18 cap, so the window's price is the curve's
        fx.jt.setRates(0.1e18);

        uint256 window = 100;
        vm.warp(block.timestamp + window);

        // The swap's best-effort sync fails (a paused kernel / stale oracle), so the accrual checkpoint is not advanced
        fx.kern.setPaused(true);
        MockRecordingYDM incoming = new MockRecordingYDM();
        incoming.setRates(0.2e18);
        vm.prank(accountantAdmin);
        address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setJuniorTrancheYDM, (address(incoming), "")));
        fx.kern.setPaused(false);

        // The next sync accrues the whole pre-swap window
        fx.kern.sync();

        assertEq(
            uint256(fx.acct.getState().twJTYieldShareAccruedWAD),
            window * 0.1e18,
            "a swap whose sync failed must not re-price the already-elapsed window with the incoming curve"
        );
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 18: zeroing_requirements_disarms_protection_gates

        Two distinct harms: the instant disarm, and the one-way ratchet that follows it. Separate tests so that
        each records its own counterexample.
    //////////////////////////////////////////////////////////////////////*/

    /// @notice EXPECTED-FAIL. `zeroing_requirements_disarms_protection_gates`, harm (a): the instant disarm. Passes
    ///         in the fixed world (the guard refuses a requirement change that flips the market out of liquidation);
    ///         RED on the current implementation, where `UtilizationLogic._computeCoverageUtilization` returns 0
    ///         whenever `minCoverage == 0`, so the guard's `post <= WAD` branch admits the write unconditionally,
    ///         instantly disarming the self-liquidation bonus senior redeemers were entitled to and freezing the
    ///         junior buffer.
    function test_ZeroingMinCoverageCannotDisarmTheLiquidationRegime() public {
        fx.kern.markPnL(-250e18);
        SyncedAccountingState memory armed = fx.kern.sync();
        assertGe(armed.coverageUtilizationWAD, armed.coverageLiquidationUtilizationWAD, "arrange: the market must be liquidating");

        vm.prank(accountantAdmin);
        address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setMinCoverage, (uint64(0))));

        SyncedAccountingState memory post = fx.kern.previewSync();
        assertGe(
            post.coverageUtilizationWAD,
            post.coverageLiquidationUtilizationWAD,
            "governance must not be able to instantly disarm a live liquidation regime by zeroing the coverage requirement"
        );
    }

    /// @notice EXPECTED-FAIL. `zeroing_requirements_disarms_protection_gates`, harm (b): the one-way ratchet. Once
    ///         the requirement has been zeroed, the guard's own "never worsen" rule makes the change irreversible
    ///         until the market is healthy again, so the senior liquidity/coverage floor cannot be restored. Passes
    ///         in the fixed world (where the zeroing is rejected outright, leaving the restore a no-op that
    ///         succeeds); RED on the current implementation, where the zeroing lands and the restore is then
    ///         rejected with INVALID_COVERAGE_CONFIG.
    function test_ZeroingMinCoverageIsNotAOneWayRatchet() public {
        fx.kern.markPnL(-250e18);
        fx.kern.sync();

        vm.prank(accountantAdmin);
        address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setMinCoverage, (uint64(0))));

        vm.prank(accountantAdmin);
        (bool restored,) = address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setMinCoverage, (DEFAULT_MIN_COVERAGE_WAD)));
        assertTrue(restored, "zeroing the coverage requirement must not be a one-way ratchet: the original floor must be restorable");
        assertEq(
            uint256(fx.acct.getState().minCoverageWAD), uint256(DEFAULT_MIN_COVERAGE_WAD), "the original coverage requirement must be back in force"
        );
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 19: guarded_setters_unavailable_while_paused_or_oracle_fails_shut
    //////////////////////////////////////////////////////////////////////*/

    /// @notice EXPECTED-FAIL. `guarded_setters_unavailable_while_paused_or_oracle_fails_shut`. This is the batch's
    ///         LIVENESS counterpart to property 21's safety requirement (which pins the mandatory pre-change sync as
    ///         desirable and is asserted, green, in `test_FeeRateChangesApplyOnlyToFuturePnL`). It passes only in a
    ///         world where repair remains possible while the sync seam is down; it is RED on the current
    ///         implementation because every guarded setter performs two MANDATORY kernel syncs, and
    ///         `syncTrancheAccountingFromAccountant` is `whenNotPaused` and pokes the collateral oracle first. The
    ///         RED result is the recorded finding: a market left with an unsafe configuration cannot be repaired
    ///         exactly when repair matters most, and a party able to pause can block parameter governance
    ///         indefinitely. The suite therefore certifies property 21's framing, not this one.
    function test_GuardedSettersRemainAvailableWhilePausedOrOracleFailing() public {
        // The kernel is paused / the collateral oracle fails shut, so both of the guard's syncs revert
        fx.kern.setPaused(true);

        vm.prank(accountantAdmin);
        fx.acct.setMinCoverage(0.05e18);
        assertEq(uint256(fx.acct.getState().minCoverageWAD), 0.05e18, "a coverage repair must remain available while the sync seam is unavailable");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 20: protocol_fee_bases_disjoint_and_capped
    //////////////////////////////////////////////////////////////////////*/

    /// @notice SPEC. `protocol_fee_bases_disjoint_and_capped`: the four fee rates apply to disjoint slices that
    ///         exactly partition the settled gain (junior residual, JT risk premium, LPT liquidity premium, senior
    ///         residual). Upper bound: the total can never exceed the LARGEST of the four rates applied to the whole
    ///         gain -- impossible if any wei were charged twice. Lower bound: the total can never fall more than the
    ///         four floor-roundings below the SMALLEST rate applied to the whole gain -- impossible if the four bases
    ///         failed to exhaust the gain.
    function testFuzz_ProtocolFeeBasesAreDisjointAndCapped(
        uint256 _gainSeed,
        uint64 _stFee,
        uint64 _jtFee,
        uint64 _jtYsFee,
        uint64 _lptYsFee,
        uint64 _maxJT,
        uint64 _maxLPT
    )
        public
    {
        _stFee = uint64(bound(_stFee, 0, MAX_PROTOCOL_FEE_WAD));
        _jtFee = uint64(bound(_jtFee, 0, MAX_PROTOCOL_FEE_WAD));
        _jtYsFee = uint64(bound(_jtYsFee, 0, MAX_PROTOCOL_FEE_WAD));
        _lptYsFee = uint64(bound(_lptYsFee, 0, MAX_PROTOCOL_FEE_WAD));
        _maxJT = uint64(bound(_maxJT, 0, WAD));
        _maxLPT = uint64(bound(_maxLPT, 0, WAD - _maxJT));
        uint256 gain = bound(_gainSeed, 1e12, 1e24);

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stProtocolFeeWAD = _stFee;
        p.jtProtocolFeeWAD = _jtFee;
        p.jtYieldShareProtocolFeeWAD = _jtYsFee;
        p.lptYieldShareProtocolFeeWAD = _lptYsFee;
        p.maxJTYieldShareWAD = _maxJT;
        p.maxLPTYieldShareWAD = _maxLPT;

        Fixture memory f = _newFixture(p);
        _seed(f);
        // The YDMs quote the maximum, so the configured caps bind and the premium slices are as large as possible
        f.jt.setRates(WAD);
        f.lpt.setRates(WAD);

        f.kern.markPnL(int256(gain));
        SyncedAccountingState memory s = f.kern.sync();

        uint256 total = toUint256(s.stProtocolFee) + toUint256(s.jtProtocolFee) + toUint256(s.lptProtocolFee);
        uint256 maxRate = Math.max(Math.max(uint256(_stFee), uint256(_jtFee)), Math.max(uint256(_jtYsFee), uint256(_lptYsFee)));
        uint256 minRate = Math.min(Math.min(uint256(_stFee), uint256(_jtFee)), Math.min(uint256(_jtYsFee), uint256(_lptYsFee)));

        assertLe(
            total,
            Math.mulDiv(gain, maxRate, WAD, Math.Rounding.Ceil),
            "the four fee bases must be disjoint: the total fee cannot exceed the largest rate applied to the whole gain"
        );
        // Four independent floor-roundings (JT residual, JT risk premium, LPT premium, ST residual) lose < 1 wei each
        assertGe(
            total + 4,
            Math.mulDiv(gain, minRate, WAD, Math.Rounding.Floor),
            "the four fee bases must exhaust the settled gain: no slice of it may escape a fee"
        );
        assertLe(toUint256(s.lptLiquidityPremium), gain, "the liquidity premium is a slice of the gain, never more");
        assertEq(toUint256(s.collateralNAV), toUint256(s.stEffectiveNAV) + toUint256(s.jtEffectiveNAV), "regression tripwire: NAV conservation");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 21: fee_rate_changes_apply_only_to_future_pnl
    //////////////////////////////////////////////////////////////////////*/

    /// @notice SPEC. `fee_rate_changes_apply_only_to_future_pnl`
    function test_FeeRateChangesApplyOnlyToFuturePnL() public {
        MockRecordingYDM sharedJT = new MockRecordingYDM();
        MockRecordingYDM sharedLPT = new MockRecordingYDM();
        sharedJT.setRates(0.1e18);
        sharedLPT.setRates(0.05e18);

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory pa = _defaultParams();
        pa.jtYDM = address(sharedJT);
        pa.lptYDM = address(sharedLPT);
        Fixture memory a = _newFixture(pa);
        _seed(a);

        IRoycoDayAccountant.RoycoDayAccountantInitParams memory pb = _defaultParams();
        pb.jtYDM = address(sharedJT);
        pb.lptYDM = address(sharedLPT);
        Fixture memory b = _newFixture(pb);
        _seed(b);

        // Identical outstanding PnL on both markets
        vm.warp(block.timestamp + 500);
        a.kern.markPnL(400e18);
        b.kern.markPnL(400e18);

        // A: raise the senior fee rate. B: a plain sync at the OLD rate
        vm.prank(feeAdmin);
        a.acct.setSeniorTrancheProtocolFee(uint64(0.9e18));
        b.kern.sync();

        assertEq(a.kern.stFeeTotal(), b.kern.stFeeTotal(), "the ST fee charged across the setter must equal what a plain sync at the old rate charged");
        assertEq(a.kern.jtFeeTotal(), b.kern.jtFeeTotal(), "the JT fee charged across the setter must equal the old-rate fee");
        assertEq(a.kern.lptFeeTotal(), b.kern.lptFeeTotal(), "the LPT fee charged across the setter must equal the old-rate fee");
        assertGt(a.kern.stFeeTotal(), 0, "arrange: the settled window must have produced a real senior fee");

        // The first fee at the new rate is sized only on PnL marked after the setter returned
        uint256 oldRateFee = a.kern.stFeeTotal();
        vm.warp(block.timestamp + 500);
        a.kern.markPnL(400e18);
        a.kern.sync();
        uint256 newRateFee = a.kern.stFeeTotal() - oldRateFee;
        assertGt(newRateFee, oldRateFee, "the new, higher rate must apply to the window that followed the change");

        // The pre-change sync is mandatory, not failure-tolerant: a fee setter cannot complete on an unsettled market
        a.kern.setPaused(true);
        vm.prank(feeAdmin);
        vm.expectRevert(GuardKernel.KERNEL_PAUSED.selector);
        a.acct.setSeniorTrancheProtocolFee(uint64(0.5e18));
        assertEq(uint256(a.acct.getState().stProtocolFeeWAD), 0.9e18, "a swallowed pre-sync must never let the rate change land");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 22: no_reachable_config_bricks_accounting_sync
    //////////////////////////////////////////////////////////////////////*/

    /// @notice SPEC. `no_reachable_config_bricks_accounting_sync`: for every configuration the non-YDM setters admit,
    ///         and for any sequence of collateral PnL, elapsed time and interleaved setter calls, every subsequent
    ///         accounting sync AND every preview succeeds (a reverting sync would block every deposit and redemption
    ///         permanently, with no recovery setter able to repair a fee / share / threshold / dust configuration)
    function testFuzz_NoReachableConfigBricksAccountingSync(
        uint64 _stFee,
        uint64 _jtFee,
        uint64 _jtYsFee,
        uint64 _lptYsFee,
        uint64 _maxJT,
        uint64 _maxLPT,
        uint64 _minCoverage,
        uint64 _minLiquidity,
        uint256 _liquidationThreshold,
        uint256 _dust,
        uint24 _term,
        uint256 _seedPnL
    )
        public
    {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _defaultParams();
        p.stProtocolFeeWAD = uint64(bound(_stFee, 0, MAX_PROTOCOL_FEE_WAD));
        p.jtProtocolFeeWAD = uint64(bound(_jtFee, 0, MAX_PROTOCOL_FEE_WAD));
        p.jtYieldShareProtocolFeeWAD = uint64(bound(_jtYsFee, 0, MAX_PROTOCOL_FEE_WAD));
        p.lptYieldShareProtocolFeeWAD = uint64(bound(_lptYsFee, 0, MAX_PROTOCOL_FEE_WAD));
        p.maxJTYieldShareWAD = uint64(bound(_maxJT, 0, WAD));
        p.maxLPTYieldShareWAD = uint64(bound(_maxLPT, 0, WAD - p.maxJTYieldShareWAD));
        p.minCoverageWAD = uint64(bound(_minCoverage, 0, WAD - 1));
        p.minLiquidityWAD = uint64(bound(_minLiquidity, 0, WAD - 1));
        p.coverageLiquidationUtilizationWAD = bound(_liquidationThreshold, WAD + 1, type(uint256).max);
        p.dustTolerance = toNAVUnits(bound(_dust, 0, 1e24));
        p.fixedTermDurationSeconds = _term;

        Fixture memory f = _newFixture(p);
        _seed(f);
        // Maximal premium pressure: both YDMs quote 100%, so the configured caps are what binds
        f.jt.setRates(WAD);
        f.lpt.setRates(WAD);

        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + bound(uint256(keccak256(abi.encode(_seedPnL, i, "t"))), 0, 30 days));

            int256 delta = int256(bound(uint256(keccak256(abi.encode(_seedPnL, i, "p"))), 0, 400e18)) - 200e18;
            f.kern.markPnL(delta);

            // Every preview and every sync must succeed under this configuration
            f.kern.previewSync();
            SyncedAccountingState memory s = f.kern.sync();
            assertEq(toUint256(s.collateralNAV), toUint256(s.stEffectiveNAV) + toUint256(s.jtEffectiveNAV), "regression tripwire: NAV conservation");

            // Interleave a guarded setter call: rejection by the guard is fine, a bricked sync is not
            uint256 which = uint256(keccak256(abi.encode(_seedPnL, i, "s"))) % 4;
            if (which == 0) {
                vm.prank(feeAdmin);
                address(f.acct).call(abi.encodeCall(IRoycoDayAccountant.setSeniorTrancheProtocolFee, (uint64(MAX_PROTOCOL_FEE_WAD))));
            } else if (which == 1) {
                vm.prank(accountantAdmin);
                address(f.acct).call(abi.encodeCall(IRoycoDayAccountant.setMaxYieldShares, (uint64(WAD / 2), uint64(WAD / 2))));
            } else if (which == 2) {
                vm.prank(opsAdmin);
                address(f.acct).call(abi.encodeCall(IRoycoDayAccountant.setDustTolerance, (toNAVUnits(uint256(1e18)))));
            } else {
                vm.prank(accountantAdmin);
                address(f.acct).call(abi.encodeCall(IRoycoDayAccountant.setFixedTermDuration, (uint24(86_400))));
            }

            // And a sync right after the (possibly applied) configuration write must succeed too
            f.kern.previewSync();
            f.kern.sync();
        }
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 23: guard_vacuous_when_utilization_degenerate

        The property names two degenerate regimes (zero utilization on an empty market -- the guard's `post <= WAD`
        branch -- and saturated utilization on a wiped junior tranche -- the guard's `post <= pre` branch) and two
        distinct writes admitted in the first. Three separate expected-fail tests, one claim each.
    //////////////////////////////////////////////////////////////////////*/

    /// @notice EXPECTED-FAIL. `guard_vacuous_when_utilization_degenerate`, regime (a) / write (i): a near-total
    ///         coverage requirement installed on a freshly deployed, empty market. Passes in the fixed world (the
    ///         guard recognizes a degenerate utilization signal and refuses to admit a requirement it could never
    ///         have policed); RED on the current implementation, where coverage utilization reads 0 with no
    ///         collateral, so the guard's `post <= WAD` branch holds trivially.
    function test_GuardIsNotVacuousOnADegenerateEmptyMarket() public {
        Fixture memory empty = _newFixture(_defaultParams());
        SyncedAccountingState memory pre = empty.kern.previewSync();
        assertEq(pre.coverageUtilizationWAD, 0, "arrange: coverage utilization must be degenerate on an empty market");

        vm.prank(accountantAdmin);
        address(empty.acct).call(abi.encodeCall(IRoycoDayAccountant.setMinCoverage, (uint64(WAD - 1))));

        assertLt(
            uint256(empty.acct.getState().minCoverageWAD),
            WAD - 1,
            "the guard must not admit a near-total coverage requirement in a state where the utilization signal carries no information"
        );
    }

    /// @notice EXPECTED-FAIL. `guard_vacuous_when_utilization_degenerate`, regime (a) / write (ii): a hair-trigger
    ///         liquidation threshold installed on the same empty market, before the first depositor arrives. Passes
    ///         in the fixed world; RED on the current implementation, where the zero utilization reading makes the
    ///         guard's liquidation clause (`post.threshold > post.coverageUtilization`) trivially satisfiable at
    ///         `WAD + 1`.
    function test_GuardIsNotVacuousOnAnEmptyMarketForTheLiquidationThreshold() public {
        Fixture memory empty = _newFixture(_defaultParams());
        SyncedAccountingState memory pre = empty.kern.previewSync();
        assertEq(pre.coverageUtilizationWAD, 0, "arrange: coverage utilization must be degenerate on an empty market");

        vm.prank(accountantAdmin);
        address(empty.acct).call(abi.encodeCall(IRoycoDayAccountant.setLiquidationCoverageUtilization, (WAD + 1)));

        assertGt(
            empty.acct.getState().coverageLiquidationUtilizationWAD,
            WAD + 1,
            "the guard must not admit a hair-trigger liquidation threshold before the first depositor arrives"
        );
    }

    /// @notice EXPECTED-FAIL. `guard_vacuous_when_utilization_degenerate`, regime (b): the economically severe one.
    ///         With the junior tranche wiped and collateral still present, coverage utilization SATURATES at
    ///         `type(uint256).max`, so the guard's `post <= pre` branch holds for ANY new requirement. Passes in the
    ///         fixed world; RED on the current implementation, where a near-total minCoverage lands in exactly the
    ///         state where it raises the bar the rescuing JT deposit must clear (it must settle strictly below the
    ///         liquidation threshold), prolonging the self-liquidation bonus drain on incoming junior capital.
    function test_GuardIsNotVacuousWhenTheJuniorTrancheIsWiped() public {
        fx.kern.markPnL(-350e18); // wipes the 300e18 junior tranche outright, 950e18 of collateral remains
        SyncedAccountingState memory pre = fx.kern.sync();
        assertEq(toUint256(pre.jtEffectiveNAV), 0, "arrange: the junior tranche must be wiped");
        assertEq(pre.coverageUtilizationWAD, type(uint256).max, "arrange: coverage utilization must saturate");

        vm.prank(accountantAdmin);
        address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setMinCoverage, (uint64(WAD - 1))));

        assertLt(
            uint256(fx.acct.getState().minCoverageWAD),
            WAD - 1,
            "the guard must not admit an arbitrarily strict coverage requirement while the utilization signal is saturated"
        );
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 24: unbounded_liquidation_threshold_removes_forced_exit
    //////////////////////////////////////////////////////////////////////*/

    /// @notice EXPECTED-FAIL. `unbounded_liquidation_threshold_removes_forced_exit`. This asserts the CONSEQUENCE,
    ///         not the storage write: an impaired market must still drop out of FIXED_TERM through the
    ///         `coverageUtilization >= coverageLiquidationUtilization` forcing condition, which is the escape hatch
    ///         that lets seniors exit and the coverage YDM re-price. The market is staged in FIXED_TERM, an
    ///         unbounded threshold is attempted, and then a further drawdown takes coverage utilization to ~1.53e18,
    ///         well past the original 1.1e18 threshold. Passes in the fixed world (the threshold carries an upper
    ///         bound or the raise is rejected, so the forced exit fires and the market drops to PERPETUAL); RED on
    ///         the current implementation, where `setLiquidationCoverageUtilization` validates only `> WAD` and the
    ///         guard's liquidation clause is satisfied by `pre <= post` on any raise, so `type(uint256).max` lands,
    ///         the forcing condition is deleted, and the market is held in FIXED_TERM with ST/JT deposits and
    ///         redemptions blocked and the self-liquidation bonus never armed.
    function test_LiquidationThresholdCannotBeRaisedOutOfReach() public {
        _enterFixedTerm(fx, 190e18);

        vm.prank(accountantAdmin);
        address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setLiquidationCoverageUtilization, (type(uint256).max)));

        fx.kern.markPnL(-40e18);
        SyncedAccountingState memory s = fx.kern.sync();
        assertGe(
            s.coverageUtilizationWAD, DEFAULT_LIQUIDATION_UTILIZATION_WAD, "arrange: the drawdown must breach the market's original forced-exit threshold"
        );

        assertEq(
            uint8(fx.acct.getState().lastMarketState),
            uint8(MarketState.PERPETUAL),
            "an unreachable liquidation threshold must not delete the forced-exit escape hatch from the market state machine"
        );
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 25: configuration_written_only_once_at_init_and_by_gated_setters
    //////////////////////////////////////////////////////////////////////*/

    /// @notice SPEC. `configuration_written_only_once_at_init_and_by_gated_setters`
    function test_ConfigurationWrittenOnlyOnceAtInitAndByGatedSetters() public {
        // (a) The one-shot initializer can never be re-run on a live proxy
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory hostile = _defaultParams();
        hostile.kernel = address(fx.kern);
        hostile.initialAuthority = address(authority);
        hostile.minCoverageWAD = 0;
        hostile.coverageLiquidationUtilizationWAD = WAD + 1;
        hostile.jtYDM = address(new MockRecordingYDM());
        hostile.lptYDM = address(new MockRecordingYDM());

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fx.acct.initialize(hostile);

        vm.prank(stranger);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fx.acct.initialize(hostile);

        // (b) No sync, post-op, capacity, preview or view entrypoint may write any governed configuration field
        bytes32 configBefore = _configHash(fx.acct.getState());
        address kernelBefore = fx.acct.getState().kernel;
        uint64 commenceableBefore = fx.acct.getState().fixedTermCommenceableAtTimestamp;

        vm.warp(block.timestamp + 1000);
        fx.kern.markPnL(250e18);
        SyncedAccountingState memory s = fx.kern.sync();
        fx.acct.previewSyncTrancheAccounting(s.collateralNAV);
        fx.acct.maxSTDeposit(s);
        fx.acct.maxJTWithdrawal(s);
        fx.acct.maxLPTWithdrawal(s);
        fx.kern.depositST(100e18);
        fx.kern.depositJT(100e18);
        fx.kern.setDepth(300e18);
        vm.warp(block.timestamp + 1000);
        fx.kern.markPnL(-150e18);
        fx.kern.sync();

        assertEq(_configHash(fx.acct.getState()), configBefore, "no sync, post-op, capacity or preview entrypoint may write a governed configuration field");

        // (c) The fields with no setter are immutable for the lifetime of the market, including across gated writes
        vm.prank(accountantAdmin);
        fx.acct.setMinCoverage(0.09e18);
        vm.prank(feeAdmin);
        fx.acct.setJuniorTrancheProtocolFee(0.3e18);
        vm.prank(opsAdmin);
        fx.acct.setDustTolerance(toNAVUnits(uint256(11)));

        IRoycoDayAccountant.RoycoDayAccountantState memory after_ = fx.acct.getState();
        assertEq(after_.kernel, kernelBefore, "the kernel pointer has no setter and must be immutable");
        assertEq(
            uint256(after_.fixedTermCommenceableAtTimestamp), uint256(commenceableBefore), "the fixed-term commenceable timestamp has no setter and must be immutable"
        );
        assertEq(uint256(after_.minCoverageWAD), 0.09e18, "the gated setter is the only writer of minCoverage");
        assertEq(uint256(after_.jtProtocolFeeWAD), 0.3e18, "the gated setter is the only writer of the JT protocol fee");
        assertEq(toUint256(after_.dustTolerance), 11, "the gated setter is the only writer of the dust tolerance");
    }

    /*//////////////////////////////////////////////////////////////////////
        Property 26: fixed_term_duration_zero_confiscates_junior_recovery_claim

        The property's harm is a COMBINATION of (i) confiscating the junior recovery claim and (ii) lifting the
        FIXED_TERM freeze on senior exits in the same transaction. Separate expected-fail tests so both are recorded.
    //////////////////////////////////////////////////////////////////////*/

    /// @notice EXPECTED-FAIL. `fixed_term_duration_zero_confiscates_junior_recovery_claim`, harm (i): confiscation of
    ///         the junior tranche's recovery claim. Passes in the fixed world (the write cannot silently realize a
    ///         live junior drawdown); RED on the current implementation, where `setFixedTermDuration(0)`
    ///         unconditionally zeroes `lastJTImpermanentLoss` while `withSyncedAccounting` polices only coverage and
    ///         liquidity utilization -- neither of which is a function of the junior impermanent loss -- so the guard
    ///         is structurally incapable of objecting. Restoring a non-zero duration afterwards leaves the
    ///         configuration hash identical, making the confiscation invisible in configuration.
    function test_ZeroFixedTermDurationCannotConfiscateTheJuniorRecoveryClaim() public {
        _enterFixedTerm(fx, 190e18);

        IRoycoDayAccountant.RoycoDayAccountantState memory before = fx.acct.getState();
        uint256 recoveryClaimBefore = toUint256(before.lastJTImpermanentLoss);
        bytes32 configBefore = _configHash(before);
        assertGt(recoveryClaimBefore, 0, "arrange: the junior tranche must hold a recoverable drawdown");

        // One transaction: erase the claim, then restore the duration so the configuration looks untouched
        vm.startPrank(accountantAdmin);
        address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setFixedTermDuration, (uint24(0))));
        address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setFixedTermDuration, (DEFAULT_FIXED_TERM_DURATION_SECONDS)));
        vm.stopPrank();

        assertEq(_configHash(fx.acct.getState()), configBefore, "arrange: the round trip must leave the configuration hash unchanged");
        assertEq(
            toUint256(fx.acct.getState().lastJTImpermanentLoss),
            recoveryClaimBefore,
            "the guard must not be blind to a write that confiscates the junior tranche's recovery claim"
        );
    }

    /// @notice EXPECTED-FAIL. `fixed_term_duration_zero_confiscates_junior_recovery_claim`, harm (ii): the
    ///         in-transaction unfreeze of senior exits, which is what distinguishes this route from the
    ///         dust-tolerance one. Passes in the fixed world; RED on the current implementation, where the same
    ///         `setFixedTermDuration(0)` forces `lastMarketState` to PERPETUAL and deletes `fixedTermEndTimestamp`,
    ///         lifting the FIXED_TERM freeze that was blocking ST/JT redemptions and letting seniors exit against a
    ///         junior that has just forfeited its recovery claim.
    function test_ZeroFixedTermDurationCannotUnfreezeSeniorExits() public {
        _enterFixedTerm(fx, 190e18);
        uint64 fixedTermEndBefore = fx.acct.getState().fixedTermEndTimestamp;
        assertGt(uint256(fixedTermEndBefore), 0, "arrange: the fixed-term freeze must be live");

        vm.startPrank(accountantAdmin);
        address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setFixedTermDuration, (uint24(0))));
        address(fx.acct).call(abi.encodeCall(IRoycoDayAccountant.setFixedTermDuration, (DEFAULT_FIXED_TERM_DURATION_SECONDS)));
        vm.stopPrank();

        IRoycoDayAccountant.RoycoDayAccountantState memory s = fx.acct.getState();
        assertEq(uint8(s.lastMarketState), uint8(MarketState.FIXED_TERM), "a configuration write must not lift the fixed-term freeze on senior exits");
        assertEq(uint256(s.fixedTermEndTimestamp), uint256(fixedTermEndBefore), "a configuration write must not delete the fixed-term end timestamp");
    }
}
