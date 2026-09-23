// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Initializable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { RoycoDayFixedRateAccountant } from "../../../src/accountant/RoycoDayFixedRateAccountant.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/accountant/IRoycoDayAccountant.sol";
import { IRoycoDayFixedRateAccountant } from "../../../src/interfaces/accountant/IRoycoDayFixedRateAccountant.sol";
import { MAX_PROTOCOL_FEE_WAD, WAD } from "../../../src/libraries/Constants.sol";
import { MarketState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockRecordingYDM } from "../../mocks/MockRecordingYDM.sol";
import { FixedRateAccountantTestBase } from "../../utils/FixedRateAccountantTestBase.sol";

/**
 * @title Test_Initialization_FixedRateAccountant
 * @notice Initialize coverage for RoycoDayFixedRateAccountant: every base param validation boundary bubbling
 *         through standardParams, the fixed rate flavor's pinned knobs (zero JT protocol fee and the WAD-capped
 *         max LPT yield share), the LPT YDM raw-call initialization paths, the emitted configuration events,
 *         the coupon window opening at initialization, and the initializer guards on the proxy and the
 *         implementation
 */
contract Test_Initialization_FixedRateAccountant is FixedRateAccountantTestBase {
    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(_defaultParams());
    }

    /// a null kernel reverts at initialization (the kernel is an init param, not an implementation immutable)
    function test_RevertIf_InitializeNullKernel() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.kernel = address(0);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /// the kernel is recorded in the accountant's own storage, so one implementation serves every market
    function test_Initialize_recordsKernel() public {
        RoycoDayFixedRateAccountant acct = _deploy(_defaultParams());
        assertEq(acct.getState().kernel, address(kernel), "kernel recorded in storage");
    }

    /// each of the four fee params above MAX_PROTOCOL_FEE_WAD reverts independently
    function test_RevertIf_InitializeSTProtocolFeeAboveMax() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.stProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /// The JT protocol fee above MAX_PROTOCOL_FEE_WAD hits the base fee bound before the flavor's zero pin
    function test_RevertIf_InitializeJTProtocolFeeAboveMax() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.jtProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /// The JT yield-share protocol fee above MAX_PROTOCOL_FEE_WAD reverts
    function test_RevertIf_InitializeJTYieldShareProtocolFeeAboveMax() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.jtYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /// The LPT yield-share protocol fee above MAX_PROTOCOL_FEE_WAD reverts
    function test_RevertIf_InitializeLPTYieldShareProtocolFeeAboveMax() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.lptYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /// the three unpinned fees at exactly MAX_PROTOCOL_FEE_WAD (100%) pass with the JT protocol fee held at zero
    function test_Initialize_unpinnedFeesAtExactlyMax() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.stProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        p.standardParams.jtProtocolFeeWAD = 0;
        p.standardParams.jtYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        p.standardParams.lptYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
        IRoycoDayAccountant.RoycoDayAccountantState memory s = acct.getState();
        assertEq(s.stProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "st fee at max");
        assertEq(s.jtProtocolFeeWAD, 0, "jt fee pinned at zero");
        assertEq(s.jtYieldShareProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "jt ys fee at max");
        assertEq(s.lptYieldShareProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "lt ys fee at max");
    }

    /// the smallest nonzero JT protocol fee reverts: the flavor charges JT via jtYieldShareProtocolFeeWAD so the unbound knob is pinned at zero
    function test_RevertIf_InitializeNonzeroJTProtocolFee() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.jtProtocolFeeWAD = 1;
        vm.expectRevert(IRoycoDayFixedRateAccountant.INVALID_PROTOCOL_FEE_CONFIG.selector);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /// a JT protocol fee that passes the base fee bound still reverts on the flavor's zero pin
    function test_RevertIf_InitializeJTProtocolFeeAtMax() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.jtProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        vm.expectRevert(IRoycoDayFixedRateAccountant.INVALID_PROTOCOL_FEE_CONFIG.selector);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /// minCoverage == WAD reverts
    function test_RevertIf_InitializeMinCoverageAtWAD() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.minCoverageWAD = uint64(WAD);
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /// minCoverage > WAD reverts
    function test_RevertIf_InitializeMinCoverageAboveWAD() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.minCoverageWAD = uint64(WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /// liquidation utilization == WAD reverts
    function test_RevertIf_InitializeLiquidationUtilizationAtWAD() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.coverageLiquidationUtilizationWAD = WAD;
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /// liquidation utilization < WAD reverts
    function test_RevertIf_InitializeLiquidationUtilizationBelowWAD() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.coverageLiquidationUtilizationWAD = WAD - 1;
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /// minCoverage = WAD - 1 with liquidation utilization = WAD + 1 passes (both boundaries)
    function test_Initialize_coverageConfigBoundariesPass() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.minCoverageWAD = uint64(WAD - 1);
        p.standardParams.coverageLiquidationUtilizationWAD = WAD + 1;
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
        IRoycoDayAccountant.RoycoDayAccountantState memory s = acct.getState();
        assertEq(s.minCoverageWAD, uint64(WAD - 1), "minCoverage boundary");
        assertEq(s.coverageLiquidationUtilizationWAD, WAD + 1, "liquidation utilization boundary");
    }

    /// minLiquidity == WAD reverts
    function test_RevertIf_InitializeMinLiquidityAtWAD() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.minLiquidityWAD = uint64(WAD);
        vm.expectRevert(IRoycoDayAccountant.INVALID_LIQUIDITY_CONFIG.selector);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /// minLiquidity = WAD - 1 passes
    function test_Initialize_minLiquidityBoundaryPasses() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.minLiquidityWAD = uint64(WAD - 1);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
        assertEq(acct.getState().minLiquidityWAD, uint64(WAD - 1), "minLiquidity boundary");
    }

    /// maxLPT > WAD reverts: the liquidity premium must always fit within the excess it is carved from
    function test_RevertIf_InitializeMaxLPTYieldShareAboveWAD() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.maxLPTYieldShareWAD = uint64(WAD + 1);
        vm.expectRevert(IRoycoDayFixedRateAccountant.INVALID_MAX_YIELD_SHARE_CONFIG.selector);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /// maxLPT == WAD passes (the disabled-JT configuration routes the entire excess to the LPT)
    function test_Initialize_maxLPTYieldShareAtWADPasses() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.maxLPTYieldShareWAD = uint64(WAD);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
        assertEq(acct.getRoycoDayFixedRateAccountantState().maxLPTYieldShareWAD, uint64(WAD), "maxLPT written at the WAD boundary");
    }

    /// the fixed rate is unbounded, so the uint64 maximum is accepted verbatim
    function test_Initialize_maxFixedRateAccepted() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.stFixedRatePerSecondWAD = type(uint64).max;
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
        assertEq(acct.getRoycoDayFixedRateAccountantState().stFixedRatePerSecondWAD, type(uint64).max, "unbounded rate written");
    }

    /// a null LPT YDM reverts
    function test_RevertIf_InitializeNullLPTYDM() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.lptYDM = address(0);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /// non-empty init data is forwarded to the LPT YDM verbatim
    function test_Initialize_ydmInitCalledWithNonEmptyData() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.lptYDMInitializationData = abi.encodeCall(MockRecordingYDM.initializeModel, (hex"5678"));
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
        assertEq(MockRecordingYDM(p.lptYDM).initializeCallCount(), 1, "lt ydm initialized once");
        assertEq(MockRecordingYDM(p.lptYDM).lastInitializePayload(), hex"5678", "lt ydm payload");
    }

    /// empty init data makes no call to the LPT YDM
    function test_Initialize_ydmInitSkippedWithEmptyData() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
        assertEq(MockRecordingYDM(p.lptYDM).initializeCallCount(), 0, "lt ydm never called");
    }

    /// a reverting LPT YDM initialization bubbles the YDM's exact revert verbatim
    function test_RevertIf_InitializeLPTYDMInitReverts() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        MockRecordingYDM(p.lptYDM).setRevertOnInitialize(true);
        p.lptYDMInitializationData = abi.encodeCall(MockRecordingYDM.initializeModel, (hex""));
        vm.expectRevert(MockRecordingYDM.YDM_INIT_REVERTED.selector);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /**
     * initialize emits the accountant's 13 configuration events with exact args in slot-grouped order, the
     * shared base events first and the fixed rate events after
     * NOTE: the other observable logs are OZ's AuthorityUpdated and Initialized, which are not accountant
     * configuration events
     */
    function test_Initialize_emitsAllInitEvents() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.SeniorTrancheProtocolFeeUpdated(p.standardParams.stProtocolFeeWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.JuniorTrancheProtocolFeeUpdated(p.standardParams.jtProtocolFeeWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareProtocolFeeUpdated(p.standardParams.jtYieldShareProtocolFeeWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.LiquidityProviderTrancheYieldShareProtocolFeeUpdated(p.standardParams.lptYieldShareProtocolFeeWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.MinCoverageUpdated(p.standardParams.minCoverageWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.MinLiquidityUpdated(p.standardParams.minLiquidityWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.FixedTermDurationUpdated(p.standardParams.fixedTermDurationSeconds);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.FixedTermCommenceableAt(uint64(block.timestamp + p.standardParams.fixedTermGracePeriodSeconds));
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.LiquidationCoverageUtilizationUpdated(p.standardParams.coverageLiquidationUtilizationWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.DustToleranceUpdated(p.standardParams.dustTolerance);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayFixedRateAccountant.LiquidityProviderTrancheYDMUpdated(p.lptYDM);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayFixedRateAccountant.MaxLPTYieldShareUpdated(p.maxLPTYieldShareWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayFixedRateAccountant.SeniorTrancheFixedRateUpdated(p.stFixedRatePerSecondWAD);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
    }

    /**
     * getState and getRoycoDayFixedRateAccountantState after initialization return every configured field
     * exactly and zero all dynamic state except the coupon settlement clock, which stamps to now: the first
     * coupon accrual window opens at initialization
     */
    function test_Initialize_stateMatchesParams() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        p.standardParams.minCoverageWAD = 0.123e18;
        p.standardParams.coverageLiquidationUtilizationWAD = 1.7e18;
        p.standardParams.minLiquidityWAD = 0.045e18;
        p.stFixedRatePerSecondWAD = 2.5e9;
        p.maxLPTYieldShareWAD = 0.35e18;
        p.standardParams.fixedTermDurationSeconds = 12_345;
        p.standardParams.dustTolerance = toNAVUnits(uint256(7));
        p.standardParams.stProtocolFeeWAD = 0.11e18;
        p.standardParams.jtProtocolFeeWAD = 0;
        p.standardParams.jtYieldShareProtocolFeeWAD = 0.13e18;
        p.standardParams.lptYieldShareProtocolFeeWAD = 0.14e18;
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);

        IRoycoDayAccountant.RoycoDayAccountantState memory s = acct.getState();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantState memory sFixed = acct.getRoycoDayFixedRateAccountantState();
        assertEq(s.stProtocolFeeWAD, 0.11e18, "stProtocolFeeWAD");
        assertEq(s.jtProtocolFeeWAD, 0, "jtProtocolFeeWAD");
        assertEq(s.jtYieldShareProtocolFeeWAD, 0.13e18, "jtYieldShareProtocolFeeWAD");
        assertEq(s.lptYieldShareProtocolFeeWAD, 0.14e18, "lptYieldShareProtocolFeeWAD");
        assertEq(s.minCoverageWAD, 0.123e18, "minCoverageWAD");
        assertEq(s.fixedTermDurationSeconds, 12_345, "fixedTermDurationSeconds");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "lastMarketState");
        assertEq(s.fixedTermEndTimestamp, 0, "fixedTermEndTimestamp");
        assertEq(s.kernel, address(kernel), "kernel");
        // zero grace period, so the fixed term is commenceable at the initializing block itself
        assertEq(s.fixedTermCommenceableAtTimestamp, uint64(block.timestamp), "fixedTermCommenceableAtTimestamp");
        assertEq(s.minLiquidityWAD, 0.045e18, "minLiquidityWAD");
        assertEq(s.coverageLiquidationUtilizationWAD, 1.7e18, "coverageLiquidationUtilizationWAD");
        assertEq(toUint256(s.lastCollateralNAV), 0, "lastCollateralNAV");
        assertEq(toUint256(s.lastSTEffectiveNAV), 0, "lastSTEffectiveNAV");
        assertEq(toUint256(s.lastJTEffectiveNAV), 0, "lastJTEffectiveNAV");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "lastJTImpermanentLoss");
        assertEq(toUint256(s.lastLPTRawNAV), 0, "lastLPTRawNAV");
        assertEq(toUint256(s.dustTolerance), 7, "dustTolerance");
        assertEq(sFixed.lptYDM, p.lptYDM, "lptYDM");
        assertEq(sFixed.maxLPTYieldShareWAD, 0.35e18, "maxLPTYieldShareWAD");
        assertEq(sFixed.stFixedRatePerSecondWAD, 2.5e9, "stFixedRatePerSecondWAD");
        assertEq(sFixed.lastYieldShareAccrualTimestamp, 0, "lastYieldShareAccrualTimestamp");
        assertEq(sFixed.lastPremiumPaymentTimestamp, 0, "lastPremiumPaymentTimestamp");
        assertEq(sFixed.twLPTYieldShareAccruedWAD, 0, "twLPTYieldShareAccruedWAD");
        // the coupon window opens at initialization, not at the first sync
        assertEq(sFixed.lastCouponSettlementTimestamp, uint32(block.timestamp), "lastCouponSettlementTimestamp");
    }

    /// the coupon settlement clock stamps the initializing block's timestamp exactly, pinned at a distinctive time
    function test_Initialize_opensCouponWindowAtInitTimestamp() public {
        RoycoDayFixedRateAccountant acct = _deployUninitialized();
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        // Derivation: initialize at t = 1_700_000_000, so lastCouponSettlementTimestamp = 1_700_000_000 and the
        // first window's elapsed at any later settlement is (t_settle - 1_700_000_000)
        vm.warp(1_700_000_000);
        p.standardParams.initialAuthority = address(authority);
        acct.initialize(p);
        assertEq(acct.getRoycoDayFixedRateAccountantState().lastCouponSettlementTimestamp, 1_700_000_000, "coupon window opens at init");
    }

    /// a nonzero grace period stamps the commenceable-at anchor to the initializing block plus the grace period
    function test_Initialize_gracePeriodStampsCommenceableAt() public {
        // Derivation: initialize at t = 1_000_000 with grace 86_400, so
        // fixedTermCommenceableAtTimestamp = 1_000_000 + 86_400 = 1_086_400
        vm.warp(1_000_000);
        RoycoDayFixedRateAccountant acct = _deployWithGrace(_defaultParams(), 86_400);
        assertEq(acct.getState().fixedTermCommenceableAtTimestamp, 1_086_400, "commenceable at init time plus grace");
    }

    /// a second initialize on the proxy reverts via the initializer guard
    function test_RevertIf_SecondInitialize() public {
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        accountant.initialize(p);
    }

    /// the implementation contract itself can never be initialized (initializers disabled in the constructor)
    function test_RevertIf_InitializeOnImplementation() public {
        IRoycoDayFixedRateAccountant.RoycoDayFixedRateAccountantInitParams memory p = _paramsWithFreshYDM();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(p);
    }
}
