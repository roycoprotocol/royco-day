// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Initializable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { RoycoDayAccountant } from "../../../src/accountant/RoycoDayAccountant.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { MAX_PROTOCOL_FEE_WAD, WAD } from "../../../src/libraries/Constants.sol";
import { MarketState } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { MockAccountantKernel } from "../../mocks/MockAccountantKernel.sol";
import { MockRecordingYDM } from "../../mocks/MockRecordingYDM.sol";
import { AccountantTestBase } from "../../utils/AccountantTestBase.sol";

/**
 * @title Test_Initialization_Accountant
 * @notice Constructor and initialize coverage for RoycoDayAccountant: immutable wiring, every init
 *         param validation boundary, the YDM raw-call initialization paths, the emitted configuration
 *         events, and the initializer guards on the proxy and the implementation
 */
contract Test_Initialization_Accountant is AccountantTestBase {
    function setUp() public {
        stranger = makeAddr("stranger");
        _deploy(_defaultParams());
    }

    /// a null kernel reverts in the constructor
    function test_RevertIf_ConstructorNullKernel() public {
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new RoycoDayAccountant(address(0));
    }

    /// KERNEL is immutably set
    function test_Constructor_setsKernelImmutable() public {
        MockAccountantKernel freshKernel = new MockAccountantKernel();
        RoycoDayAccountant acct = new RoycoDayAccountant(address(freshKernel));
        assertEq(acct.KERNEL(), address(freshKernel), "kernel immutable");
    }

    /// each of the four fee params above MAX_PROTOCOL_FEE_WAD reverts independently
    function test_RevertIf_InitializeSTProtocolFeeAboveMax() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.stProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        acct.initialize(p, address(authority));
    }

    /// The JT protocol fee above MAX_PROTOCOL_FEE_WAD reverts
    function test_RevertIf_InitializeJTProtocolFeeAboveMax() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.jtProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        acct.initialize(p, address(authority));
    }

    /// The JT yield-share protocol fee above MAX_PROTOCOL_FEE_WAD reverts
    function test_RevertIf_InitializeJTYieldShareProtocolFeeAboveMax() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.jtYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        acct.initialize(p, address(authority));
    }

    /// The LPT yield-share protocol fee above MAX_PROTOCOL_FEE_WAD reverts
    function test_RevertIf_InitializeLPTYieldShareProtocolFeeAboveMax() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.lptYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        acct.initialize(p, address(authority));
    }

    /// all four fees at exactly MAX_PROTOCOL_FEE_WAD (100%) pass
    function test_Initialize_allFeesAtExactlyMax() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.stProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        p.jtProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        p.jtYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        p.lptYieldShareProtocolFeeWAD = uint64(MAX_PROTOCOL_FEE_WAD);
        acct.initialize(p, address(authority));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = acct.getState();
        assertEq(s.stProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "st fee at max");
        assertEq(s.jtProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "jt fee at max");
        assertEq(s.jtYieldShareProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "jt ys fee at max");
        assertEq(s.lptYieldShareProtocolFeeWAD, uint64(MAX_PROTOCOL_FEE_WAD), "lt ys fee at max");
    }

    /// identical JT and LPT YDMs revert
    function test_RevertIf_InitializeIdenticalYDMs() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.lptYDM = p.jtYDM;
        vm.expectRevert(IRoycoDayAccountant.YDMS_CANNOT_BE_IDENTICAL.selector);
        acct.initialize(p, address(authority));
    }

    /// minCoverage == WAD reverts
    function test_RevertIf_InitializeMinCoverageAtWAD() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.minCoverageWAD = uint64(WAD);
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        acct.initialize(p, address(authority));
    }

    /// minCoverage > WAD reverts
    function test_RevertIf_InitializeMinCoverageAboveWAD() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.minCoverageWAD = uint64(WAD + 1);
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        acct.initialize(p, address(authority));
    }

    /// liquidation utilization == WAD reverts
    function test_RevertIf_InitializeLiquidationUtilizationAtWAD() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.coverageLiquidationUtilizationWAD = WAD;
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        acct.initialize(p, address(authority));
    }

    /// liquidation utilization < WAD reverts
    function test_RevertIf_InitializeLiquidationUtilizationBelowWAD() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.coverageLiquidationUtilizationWAD = WAD - 1;
        vm.expectRevert(IRoycoDayAccountant.INVALID_COVERAGE_CONFIG.selector);
        acct.initialize(p, address(authority));
    }

    /// minCoverage = WAD - 1 with liquidation utilization = WAD + 1 passes (both boundaries)
    function test_Initialize_coverageConfigBoundariesPass() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.minCoverageWAD = uint64(WAD - 1);
        p.coverageLiquidationUtilizationWAD = WAD + 1;
        acct.initialize(p, address(authority));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = acct.getState();
        assertEq(s.minCoverageWAD, uint64(WAD - 1), "minCoverage boundary");
        assertEq(s.coverageLiquidationUtilizationWAD, WAD + 1, "liquidation utilization boundary");
    }

    /// minLiquidity == WAD reverts
    function test_RevertIf_InitializeMinLiquidityAtWAD() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.minLiquidityWAD = uint64(WAD);
        vm.expectRevert(IRoycoDayAccountant.INVALID_LIQUIDITY_CONFIG.selector);
        acct.initialize(p, address(authority));
    }

    /// minLiquidity = WAD - 1 passes
    function test_Initialize_minLiquidityBoundaryPasses() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.minLiquidityWAD = uint64(WAD - 1);
        acct.initialize(p, address(authority));
        assertEq(acct.getState().minLiquidityWAD, uint64(WAD - 1), "minLiquidity boundary");
    }

    /// maxJT + maxLPT > WAD reverts
    function test_RevertIf_InitializeMaxYieldSharesSumAboveWAD() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.maxJTYieldShareWAD = 0.6e18;
        p.maxLPTYieldShareWAD = 0.4e18 + 1;
        vm.expectRevert(IRoycoDayAccountant.INVALID_MAX_YIELD_SHARE_CONFIG.selector);
        acct.initialize(p, address(authority));
    }

    /// maxJT + maxLPT == WAD passes
    function test_Initialize_maxYieldSharesSumAtWADPasses() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.maxJTYieldShareWAD = 0.6e18;
        p.maxLPTYieldShareWAD = 0.4e18;
        acct.initialize(p, address(authority));
        IRoycoDayAccountant.RoycoDayAccountantState memory s = acct.getState();
        assertEq(s.maxJTYieldShareWAD, 0.6e18, "maxJT written");
        assertEq(s.maxLPTYieldShareWAD, 0.4e18, "maxLPT written");
    }

    /// a null JT YDM reverts
    function test_RevertIf_InitializeNullJTYDM() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.jtYDM = address(0);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        acct.initialize(p, address(authority));
    }

    /// a null LPT YDM reverts
    function test_RevertIf_InitializeNullLPTYDM() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.lptYDM = address(0);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        acct.initialize(p, address(authority));
    }

    /// non-empty init data is forwarded to each YDM verbatim
    function test_Initialize_ydmInitCalledWithNonEmptyData() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.jtYDMInitializationData = abi.encodeCall(MockRecordingYDM.initializeModel, (hex"1234"));
        p.lptYDMInitializationData = abi.encodeCall(MockRecordingYDM.initializeModel, (hex"5678"));
        acct.initialize(p, address(authority));
        assertEq(MockRecordingYDM(p.jtYDM).initializeCallCount(), 1, "jt ydm initialized once");
        assertEq(MockRecordingYDM(p.jtYDM).lastInitializePayload(), hex"1234", "jt ydm payload");
        assertEq(MockRecordingYDM(p.lptYDM).initializeCallCount(), 1, "lt ydm initialized once");
        assertEq(MockRecordingYDM(p.lptYDM).lastInitializePayload(), hex"5678", "lt ydm payload");
    }

    /// empty init data makes no call to either YDM
    function test_Initialize_ydmInitSkippedWithEmptyData() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        acct.initialize(p, address(authority));
        assertEq(MockRecordingYDM(p.jtYDM).initializeCallCount(), 0, "jt ydm never called");
        assertEq(MockRecordingYDM(p.lptYDM).initializeCallCount(), 0, "lt ydm never called");
    }

    /// a reverting JT YDM initialization bubbles the exact revert payload inside FAILED_TO_INITIALIZE_YDM
    function test_RevertIf_InitializeJTYDMInitReverts() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        MockRecordingYDM(p.jtYDM).setRevertOnInitialize(true);
        p.jtYDMInitializationData = abi.encodeCall(MockRecordingYDM.initializeModel, (hex""));
        vm.expectRevert(
            abi.encodeWithSelector(IRoycoDayAccountant.FAILED_TO_INITIALIZE_YDM.selector, abi.encodeWithSelector(MockRecordingYDM.YDM_INIT_REVERTED.selector))
        );
        acct.initialize(p, address(authority));
    }

    /// a reverting LPT YDM initialization bubbles the exact revert payload inside FAILED_TO_INITIALIZE_YDM
    function test_RevertIf_InitializeLPTYDMInitReverts() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        MockRecordingYDM(p.lptYDM).setRevertOnInitialize(true);
        p.lptYDMInitializationData = abi.encodeCall(MockRecordingYDM.initializeModel, (hex""));
        vm.expectRevert(
            abi.encodeWithSelector(IRoycoDayAccountant.FAILED_TO_INITIALIZE_YDM.selector, abi.encodeWithSelector(MockRecordingYDM.YDM_INIT_REVERTED.selector))
        );
        acct.initialize(p, address(authority));
    }

    /**
     * initialize emits the accountant's 12 configuration events with exact args in slot-grouped order
     * NOTE: an earlier count said 17 init events, the accountant itself emits 12 (the other
     * observable logs are OZ's AuthorityUpdated and Initialized, which are not accountant configuration events)
     */
    function test_Initialize_emitsAllInitEvents() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.SeniorTrancheProtocolFeeUpdated(p.stProtocolFeeWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.JuniorTrancheProtocolFeeUpdated(p.jtProtocolFeeWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareProtocolFeeUpdated(p.jtYieldShareProtocolFeeWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.LiquidityProviderTrancheYieldShareProtocolFeeUpdated(p.lptYieldShareProtocolFeeWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.CoverageUpdated(p.minCoverageWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.FixedTermDurationUpdated(p.fixedTermDurationSeconds);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.JuniorTrancheYDMUpdated(p.jtYDM);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.LiquidityProviderTrancheYDMUpdated(p.lptYDM);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.LiquidityUpdated(p.minLiquidityWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.MaxYieldSharesUpdated(p.maxJTYieldShareWAD, p.maxLPTYieldShareWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.LiquidationCoverageUtilizationUpdated(p.coverageLiquidationUtilizationWAD);
        vm.expectEmit(true, true, true, true, address(acct));
        emit IRoycoDayAccountant.DustToleranceUpdated(p.dustTolerance);
        acct.initialize(p, address(authority));
    }

    /// getState after initialization returns every configured field exactly and zeroes all dynamic state
    function test_Initialize_stateMatchesParams() public {
        RoycoDayAccountant acct = _deployUninitialized();
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        p.minCoverageWAD = 0.123e18;
        p.coverageLiquidationUtilizationWAD = 1.7e18;
        p.minLiquidityWAD = 0.045e18;
        p.maxJTYieldShareWAD = 0.25e18;
        p.maxLPTYieldShareWAD = 0.35e18;
        p.fixedTermDurationSeconds = 12_345;
        p.dustTolerance = toNAVUnits(uint256(7));
        p.stProtocolFeeWAD = 0.11e18;
        p.jtProtocolFeeWAD = 0.12e18;
        p.jtYieldShareProtocolFeeWAD = 0.13e18;
        p.lptYieldShareProtocolFeeWAD = 0.14e18;
        acct.initialize(p, address(authority));

        IRoycoDayAccountant.RoycoDayAccountantState memory s = acct.getState();
        assertEq(s.stProtocolFeeWAD, 0.11e18, "stProtocolFeeWAD");
        assertEq(s.jtProtocolFeeWAD, 0.12e18, "jtProtocolFeeWAD");
        assertEq(s.jtYieldShareProtocolFeeWAD, 0.13e18, "jtYieldShareProtocolFeeWAD");
        assertEq(s.lptYieldShareProtocolFeeWAD, 0.14e18, "lptYieldShareProtocolFeeWAD");
        assertEq(s.minCoverageWAD, 0.123e18, "minCoverageWAD");
        assertEq(s.fixedTermDurationSeconds, 12_345, "fixedTermDurationSeconds");
        assertEq(uint8(s.lastMarketState), uint8(MarketState.PERPETUAL), "lastMarketState");
        assertEq(s.fixedTermEndTimestamp, 0, "fixedTermEndTimestamp");
        assertEq(s.lastYieldShareAccrualTimestamp, 0, "lastYieldShareAccrualTimestamp");
        assertEq(s.lastPremiumPaymentTimestamp, 0, "lastPremiumPaymentTimestamp");
        assertEq(s.jtYDM, p.jtYDM, "jtYDM");
        assertEq(s.lptYDM, p.lptYDM, "lptYDM");
        assertEq(s.minLiquidityWAD, 0.045e18, "minLiquidityWAD");
        assertEq(s.twJTYieldShareAccruedWAD, 0, "twJTYieldShareAccruedWAD");
        assertEq(s.maxJTYieldShareWAD, 0.25e18, "maxJTYieldShareWAD");
        assertEq(s.twLPTYieldShareAccruedWAD, 0, "twLPTYieldShareAccruedWAD");
        assertEq(s.maxLPTYieldShareWAD, 0.35e18, "maxLPTYieldShareWAD");
        assertEq(s.coverageLiquidationUtilizationWAD, 1.7e18, "coverageLiquidationUtilizationWAD");
        assertEq(toUint256(s.lastCollateralNAV), 0, "lastCollateralNAV");
        assertEq(toUint256(s.lastSTEffectiveNAV), 0, "lastSTEffectiveNAV");
        assertEq(toUint256(s.lastJTEffectiveNAV), 0, "lastJTEffectiveNAV");
        assertEq(toUint256(s.lastJTImpermanentLoss), 0, "lastJTImpermanentLoss");
        assertEq(toUint256(s.lastLPTRawNAV), 0, "lastLPTRawNAV");
        assertEq(toUint256(s.dustTolerance), 7, "dustTolerance");
    }

    /// a second initialize on the proxy reverts via the initializer guard
    function test_RevertIf_SecondInitialize() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        accountant.initialize(p, address(authority));
    }

    /// the implementation contract itself can never be initialized (initializers disabled in the constructor)
    function test_RevertIf_InitializeOnImplementation() public {
        IRoycoDayAccountant.RoycoDayAccountantInitParams memory p = _paramsWithFreshYDMs();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(p, address(authority));
    }
}
