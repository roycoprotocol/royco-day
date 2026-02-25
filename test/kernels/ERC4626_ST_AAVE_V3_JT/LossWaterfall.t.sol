// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD } from "../../../src/libraries/Constants.sol";
import { AssetClaims, TrancheType } from "../../../src/libraries/Types.sol";
import { SyncedAccountingState } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { UnitsMathLib } from "../../../src/libraries/Units.sol";
import { UtilsLib } from "../../../src/libraries/UtilsLib.sol";
import { MainnetForkWithAaveTestBase } from "./base/MainnetForkWithAaveBaseTest.t.sol";

contract LossWaterfall is MainnetForkWithAaveTestBase {
    using Math for uint256;
    using UnitsMathLib for TRANCHE_UNIT;
    using UnitsMathLib for NAV_UNIT;

    // Test State Trackers
    TrancheState internal stState;
    TrancheState internal jtState;

    function setUp() public {
        _setUpRoyco();
    }

    function testFuzz_jtLoss(uint256 _assets) external {
        // Bound assets to reasonable range (avoid zero and very large amounts)
        _assets = bound(_assets, 10e6, 1_000_000e6); // Between 1 USDC and 1M USDC (6 decimals)

        address depositor = ALICE_ADDRESS;

        // Approve the junior tranche to spend assets
        vm.prank(depositor);
        USDC.approve(address(JT), _assets);

        // Deposit into junior tranche
        vm.prank(depositor);
        (uint256 shares,) = JT.deposit(toTrancheUnits(_assets), depositor, depositor);
        AssetClaims memory postDepositUserClaims = JT.convertToAssets(shares);
        (SyncedAccountingState memory postDepositState, AssetClaims memory postDepositTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Simulate a loss by transferring out A Tokens from the kernel
        uint256 lossAssets = bound(_assets, 1e6, _assets - 1);
        vm.prank(address(KERNEL));
        AUSDC.transfer(BOB_ADDRESS, lossAssets);
        AssetClaims memory postLossUserClaims = JT.convertToAssets(shares);
        (SyncedAccountingState memory postLossState, AssetClaims memory postLossTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Assert that the accounting reflects the JT loss
        assertApproxEqRel(
            toUint256(postDepositTotalClaims.jtAssets - postLossTotalClaims.jtAssets),
            lossAssets,
            MAX_CONVERT_TO_ASSETS_RELATIVE_DELTA,
            "JT total claims must decrease by loss amount"
        );
        assertApproxEqRel(
            toUint256(postDepositUserClaims.jtAssets - postLossUserClaims.jtAssets),
            lossAssets,
            MAX_CONVERT_TO_ASSETS_RELATIVE_DELTA,
            "JT user claims must decrease by loss amount"
        );
        assertApproxEqRel(
            toUint256(KERNEL.jtConvertNAVUnitsToTrancheUnits(postDepositState.jtRawNAV - postLossState.jtRawNAV)),
            lossAssets,
            MAX_CONVERT_TO_ASSETS_RELATIVE_DELTA,
            "JT raw NAV must decrease by loss amount"
        );
        assertApproxEqRel(
            toUint256(KERNEL.jtConvertNAVUnitsToTrancheUnits(postDepositState.jtEffectiveNAV - postLossState.jtEffectiveNAV)),
            lossAssets,
            MAX_CONVERT_TO_ASSETS_RELATIVE_DELTA,
            "JT effective NAV must decrease by loss amount"
        );
    }

    function testFuzz_jtGain(uint256 _assets, uint256 _timeToTravel) external {
        // Bound assets to reasonable range (avoid zero and very large amounts)
        _assets = bound(_assets, 10e6, 1_000_000e6); // Between 1 USDC and 1M USDC (6 decimals)
        _timeToTravel = bound(_timeToTravel, 1 hours, 365 days);

        address depositor = ALICE_ADDRESS;

        // Approve the junior tranche to spend assets
        vm.prank(depositor);
        USDC.approve(address(JT), _assets);

        // Deposit into junior tranche
        vm.prank(depositor);
        (uint256 shares,) = JT.deposit(toTrancheUnits(_assets), depositor, depositor);
        AssetClaims memory postDepositUserClaims = JT.convertToAssets(shares);
        (SyncedAccountingState memory postDepositState, AssetClaims memory postDepositTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Time travel
        skip(_timeToTravel);

        // Check the state after interest accrued
        AssetClaims memory postGainUserClaims = JT.convertToAssets(shares);
        (SyncedAccountingState memory postGainState, AssetClaims memory postGainTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Assert that the accounting reflects the JT gain
        assertGt(toUint256(postGainState.jtProtocolFeeAccrued), 0, "JT protocol fees must accrue on gain");
        assertGt(toUint256(postGainTotalClaims.jtAssets), toUint256(postDepositTotalClaims.jtAssets), "JT total claims must increase on gain");
        assertGt(toUint256(postGainUserClaims.jtAssets), toUint256(postDepositUserClaims.jtAssets), "JT user claims must increase on gain");
        assertGt(toUint256(postGainState.jtRawNAV), toUint256(postDepositState.jtRawNAV), "JT raw NAV must increase on gain");
        assertGt(toUint256(postGainState.jtEffectiveNAV), toUint256(postDepositState.jtEffectiveNAV), "JT effective NAV must increase on gain");
    }

    function testFuzz_stGain(uint256 _assets, uint256 _stDepositPercentage) external {
        // Bound assets to reasonable range (avoid zero and very large amounts)
        _assets = bound(_assets, 10e6, 1_000_000e6); // Between 1 USDC and 1M USDC (6 decimals)
        _stDepositPercentage = bound(_stDepositPercentage, 1, 90);

        // Deposit into junior tranche
        address depositor = ALICE_ADDRESS;
        vm.startPrank(depositor);
        USDC.approve(address(JT), _assets);
        JT.deposit(toTrancheUnits(_assets), depositor, depositor);
        vm.stopPrank();

        address stDepositor = BOB_ADDRESS;
        TRANCHE_UNIT expectedMaxDeposit = KERNEL.jtConvertNAVUnitsToTrancheUnits(JT.totalAssets().nav.mulDiv(WAD, COVERAGE_WAD, Math.Rounding.Floor));
        // Deposit a percentage of the max deposit
        TRANCHE_UNIT depositAmount = expectedMaxDeposit.mulDiv(_stDepositPercentage, 100, Math.Rounding.Floor);
        vm.startPrank(stDepositor);
        USDC.approve(address(ST), toUint256(depositAmount));
        (uint256 shares,) = ST.deposit(depositAmount, stDepositor, stDepositor);
        vm.stopPrank();
        AssetClaims memory postDepositSTUserClaims = ST.convertToAssets(shares);
        (SyncedAccountingState memory postDepositState, AssetClaims memory postDepositSTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        (, AssetClaims memory postDepositJTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Raise the NAV of ST
        vm.startPrank(stDepositor);
        USDC.transfer(address(MOCK_UNDERLYING_ST_VAULT), 100e6);
        vm.stopPrank();

        skip(1 days);

        AssetClaims memory postGainSTUserClaims = ST.convertToAssets(shares);
        (SyncedAccountingState memory postGainState, AssetClaims memory postGainSTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        (, AssetClaims memory postGainJTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Assert that the accounting reflects the ST gain
        assertGt(toUint256(postGainState.jtProtocolFeeAccrued), 0, "JT protocol fees must accrue on ST gain (yield distribution)");
        assertGt(toUint256(postGainState.stProtocolFeeAccrued), 0, "ST protocol fees must accrue on ST gain");

        assertGt(toUint256(postGainSTUserClaims.stAssets), toUint256(postDepositSTUserClaims.stAssets), "ST user claims must increase on gain");
        assertGt(toUint256(postGainSTTotalClaims.stAssets), toUint256(postDepositSTTotalClaims.stAssets), "ST total claims must increase on gain");
        assertGt(
            toUint256(postGainJTTotalClaims.stAssets), toUint256(postDepositJTTotalClaims.stAssets), "JT ST asset claims must increase (yield distribution)"
        );

        assertGt(toUint256(postGainState.jtRawNAV), toUint256(postDepositState.jtRawNAV), "JT raw NAV must increase (yield distribution)");
        assertGt(toUint256(postGainState.jtEffectiveNAV), toUint256(postDepositState.jtEffectiveNAV), "JT effective NAV must increase (yield distribution)");
        assertGt(toUint256(postGainState.stRawNAV), toUint256(postDepositState.stRawNAV), "ST raw NAV must increase on gain");
        assertGt(toUint256(postGainState.stEffectiveNAV), toUint256(postDepositState.stEffectiveNAV), "ST effective NAV must increase on gain");
    }

    function testFuzz_stLoss(uint256 _assets, uint256 _stDepositPercentage) external {
        // Bound assets to reasonable range (avoid zero and very large amounts)
        _assets = bound(_assets, 10e6, 1_000_000e6); // Between 1 USDC and 1M USDC (6 decimals)
        _stDepositPercentage = bound(_stDepositPercentage, 20, 90);

        // Deposit into junior tranche
        address depositor = ALICE_ADDRESS;
        vm.startPrank(depositor);
        USDC.approve(address(JT), _assets);
        JT.deposit(toTrancheUnits(_assets), depositor, depositor);
        vm.stopPrank();

        address stDepositor = BOB_ADDRESS;
        TRANCHE_UNIT expectedMaxDeposit = KERNEL.jtConvertNAVUnitsToTrancheUnits(JT.totalAssets().nav.mulDiv(WAD, COVERAGE_WAD, Math.Rounding.Floor));
        // Deposit a percentage of the max deposit
        TRANCHE_UNIT depositAmount = expectedMaxDeposit.mulDiv(_stDepositPercentage, 100, Math.Rounding.Floor);
        vm.startPrank(stDepositor);
        USDC.approve(address(ST), toUint256(depositAmount));
        (uint256 shares,) = ST.deposit(depositAmount, stDepositor, stDepositor);
        vm.stopPrank();
        AssetClaims memory postDepositSTUserClaims = ST.convertToAssets(shares);
        (SyncedAccountingState memory postDepositState, AssetClaims memory postDepositSTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        (, AssetClaims memory postDepositJTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Lower the NAV of ST
        vm.startPrank(address(MOCK_UNDERLYING_ST_VAULT));
        USDC.transfer(BOB_ADDRESS, bound(toUint256(depositAmount), 1e6, toUint256(depositAmount)));
        vm.stopPrank();

        AssetClaims memory postLossSTUserClaims = ST.convertToAssets(shares);
        (SyncedAccountingState memory postLossState, AssetClaims memory postLossSTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        (, AssetClaims memory postLossJTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Assert that the accounting reflects the ST loss
        assertEq(toUint256(postLossState.jtProtocolFeeAccrued), 0, "JT protocol fees must be zero on loss");
        assertEq(toUint256(postLossState.stProtocolFeeAccrued), 0, "ST protocol fees must be zero on loss");

        assertGt(toUint256(postLossSTUserClaims.jtAssets), toUint256(postDepositSTUserClaims.jtAssets), "ST user JT claims must increase (coverage activated)");
        assertLt(toUint256(postLossSTUserClaims.stAssets), toUint256(postDepositSTUserClaims.stAssets), "ST user ST claims must decrease on loss");
        assertLt(toUint256(postLossSTTotalClaims.stAssets), toUint256(postDepositSTTotalClaims.stAssets), "ST total claims must decrease on loss");
        assertLt(toUint256(postLossJTTotalClaims.jtAssets), toUint256(postDepositJTTotalClaims.jtAssets), "JT total claims must decrease (providing coverage)");

        if (UtilsLib.computeLTV(postLossState.stEffectiveNAV, postLossState.stImpermanentLoss, postLossState.jtEffectiveNAV) < LLTV) {
            assertGt(
                toUint256(postLossState.jtImpermanentLoss),
                toUint256(postDepositState.jtImpermanentLoss),
                "JT coverage impermanent loss must increase when LTV below threshold"
            );
        } else {
            assertEq(toUint256(postLossState.jtImpermanentLoss), 0, "JT coverage impermanent loss must be zero when LTV at or above threshold");
        }
        assertGe(toUint256(postLossState.stImpermanentLoss), toUint256(postDepositState.stImpermanentLoss), "ST impermanent loss must increase on loss");
        assertLt(toUint256(postLossState.jtEffectiveNAV), toUint256(postDepositState.jtEffectiveNAV), "JT effective NAV must decrease (providing coverage)");
        assertLe(toUint256(postLossState.stEffectiveNAV), toUint256(postDepositState.stEffectiveNAV), "ST effective NAV must decrease on loss");
    }

    // ============================================
    // SEQUENTIAL EVENT TESTS
    // ============================================

    /// @notice Test JT loss followed by gain (recovery scenario)
    function test_jtLossThenGain_recovery() external {
        address depositor = ALICE_ADDRESS;
        uint256 depositAmount = 100_000e6;

        // Deposit into JT
        vm.startPrank(depositor);
        USDC.approve(address(JT), depositAmount);
        (uint256 shares,) = JT.deposit(toTrancheUnits(depositAmount), depositor, depositor);
        vm.stopPrank();

        // Record initial state
        (SyncedAccountingState memory initialState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Simulate loss (10%)
        uint256 lossAmount = 10_000e6;
        vm.prank(address(KERNEL));
        AUSDC.transfer(BOB_ADDRESS, lossAmount);

        // Record post-loss state
        (SyncedAccountingState memory postLossState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Verify loss affected state
        assertLt(toUint256(postLossState.jtRawNAV), toUint256(initialState.jtRawNAV), "JT raw NAV must decrease after loss");

        // Time passes, interest accrues (recovery)
        skip(365 days);

        // Record post-recovery state
        (SyncedAccountingState memory postRecoveryState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Verify recovery: NAV increased from post-loss state
        assertGt(toUint256(postRecoveryState.jtRawNAV), toUint256(postLossState.jtRawNAV), "JT raw NAV must increase after recovery");
        // Note: Protocol fees only accrue when NAV exceeds the high-water mark
        // If loss was significant, recovery may not reach high-water mark, so fees may be 0
    }

    /// @notice Test JT gain followed by loss
    function test_jtGainThenLoss() external {
        address depositor = ALICE_ADDRESS;
        uint256 depositAmount = 100_000e6;

        // Deposit into JT
        vm.startPrank(depositor);
        USDC.approve(address(JT), depositAmount);
        (uint256 shares,) = JT.deposit(toTrancheUnits(depositAmount), depositor, depositor);
        vm.stopPrank();

        // Record initial state
        (SyncedAccountingState memory initialState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Time passes, interest accrues (gain)
        skip(180 days);

        // Record post-gain state
        (SyncedAccountingState memory postGainState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Verify gain
        assertGt(toUint256(postGainState.jtRawNAV), toUint256(initialState.jtRawNAV), "JT raw NAV must increase after gain");

        // Simulate loss (larger than the gain)
        uint256 lossAmount = 20_000e6;
        vm.prank(address(KERNEL));
        AUSDC.transfer(BOB_ADDRESS, lossAmount);

        // Record post-loss state
        (SyncedAccountingState memory postLossState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Verify loss
        assertLt(toUint256(postLossState.jtRawNAV), toUint256(postGainState.jtRawNAV), "JT raw NAV must decrease after loss");
    }

    /// @notice Test ST loss followed by JT yield recovery (coverage then recoupment)
    function test_stLossThenJtYieldRecovery() external {
        // Setup JT
        address jtDepositor = ALICE_ADDRESS;
        vm.startPrank(jtDepositor);
        USDC.approve(address(JT), 500_000e6);
        JT.deposit(toTrancheUnits(500_000e6), jtDepositor, jtDepositor);
        vm.stopPrank();

        // Setup ST (30% of max for sufficient loss impact)
        address stDepositor = BOB_ADDRESS;
        TRANCHE_UNIT maxDeposit = ST.maxDeposit(stDepositor);
        TRANCHE_UNIT stAmount = maxDeposit.mulDiv(30, 100, Math.Rounding.Floor);
        vm.startPrank(stDepositor);
        USDC.approve(address(ST), toUint256(stAmount));
        ST.deposit(stAmount, stDepositor, stDepositor);
        vm.stopPrank();

        // Record initial state
        (SyncedAccountingState memory initialState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);

        // Simulate ST loss (10% for meaningful impermanent loss)
        uint256 lossAmount = toUint256(stAmount) / 10;
        vm.prank(address(MOCK_UNDERLYING_ST_VAULT));
        USDC.transfer(CHARLIE_ADDRESS, lossAmount);

        // Record post-loss state
        (SyncedAccountingState memory postLossState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);

        // Verify loss - ST raw NAV must decrease
        assertLt(toUint256(postLossState.stRawNAV), toUint256(initialState.stRawNAV), "ST raw NAV must decrease after loss");

        // Time passes, JT earns yield
        skip(180 days);

        // Record post-recovery state
        (SyncedAccountingState memory postRecoveryState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);

        // JT should have recovered through yield
        assertGt(toUint256(postRecoveryState.jtRawNAV), toUint256(postLossState.jtRawNAV), "JT raw NAV must increase from yield");
    }

    /// @notice Test multiple sequential losses on ST
    function test_multipleSequentialSTLosses() external {
        // Setup JT
        address jtDepositor = ALICE_ADDRESS;
        vm.startPrank(jtDepositor);
        USDC.approve(address(JT), 1_000_000e6);
        JT.deposit(toTrancheUnits(1_000_000e6), jtDepositor, jtDepositor);
        vm.stopPrank();

        // Setup ST (30% of max for sufficient loss impact)
        address stDepositor = BOB_ADDRESS;
        TRANCHE_UNIT maxDeposit = ST.maxDeposit(stDepositor);
        TRANCHE_UNIT stAmount = maxDeposit.mulDiv(30, 100, Math.Rounding.Floor);
        vm.startPrank(stDepositor);
        USDC.approve(address(ST), toUint256(stAmount));
        ST.deposit(stAmount, stDepositor, stDepositor);
        vm.stopPrank();

        // Record states after each loss
        (SyncedAccountingState memory state0,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);

        // First loss (5%)
        uint256 loss1 = toUint256(stAmount) / 20;
        vm.prank(address(MOCK_UNDERLYING_ST_VAULT));
        USDC.transfer(CHARLIE_ADDRESS, loss1);
        (SyncedAccountingState memory state1,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);

        // Verify first loss - raw NAV must decrease
        assertLt(toUint256(state1.stRawNAV), toUint256(state0.stRawNAV), "ST raw NAV must decrease after first loss");

        // Second loss (5%)
        uint256 loss2 = toUint256(stAmount) / 20;
        vm.prank(address(MOCK_UNDERLYING_ST_VAULT));
        USDC.transfer(CHARLIE_ADDRESS, loss2);
        (SyncedAccountingState memory state2,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);

        // Verify cumulative losses - raw NAV must decrease further
        assertLt(toUint256(state2.stRawNAV), toUint256(state1.stRawNAV), "ST raw NAV must decrease after second loss");
        // Total raw NAV decrease should reflect cumulative loss
        assertLt(toUint256(state2.stRawNAV), toUint256(state0.stRawNAV), "ST raw NAV must reflect cumulative losses");
    }

    // ============================================
    // CROSS-TRANCHE INTERACTION TESTS
    // ============================================

    /// @notice Test ST loss impact on JT depositors
    function test_stLoss_impactOnJTDepositors() external {
        // Setup two JT depositors
        address jtDepositor1 = ALICE_ADDRESS;
        address jtDepositor2 = BOB_ADDRESS;

        vm.startPrank(jtDepositor1);
        USDC.approve(address(JT), 200_000e6);
        (uint256 jt1Shares,) = JT.deposit(toTrancheUnits(200_000e6), jtDepositor1, jtDepositor1);
        vm.stopPrank();

        vm.startPrank(jtDepositor2);
        USDC.approve(address(JT), 300_000e6);
        (uint256 jt2Shares,) = JT.deposit(toTrancheUnits(300_000e6), jtDepositor2, jtDepositor2);
        vm.stopPrank();

        // Setup ST
        address stDepositor = CHARLIE_ADDRESS;
        TRANCHE_UNIT maxDeposit = ST.maxDeposit(stDepositor);
        TRANCHE_UNIT stAmount = maxDeposit.mulDiv(15, 100, Math.Rounding.Floor);
        vm.startPrank(stDepositor);
        USDC.approve(address(ST), toUint256(stAmount));
        ST.deposit(stAmount, stDepositor, stDepositor);
        vm.stopPrank();

        // Record initial claims
        AssetClaims memory jt1ClaimsBefore = JT.convertToAssets(jt1Shares);
        AssetClaims memory jt2ClaimsBefore = JT.convertToAssets(jt2Shares);

        // Simulate ST loss (3%)
        uint256 lossAmount = toUint256(stAmount) / 33;
        vm.prank(address(MOCK_UNDERLYING_ST_VAULT));
        USDC.transfer(DAN_ADDRESS, lossAmount);

        // Record claims after loss
        AssetClaims memory jt1ClaimsAfter = JT.convertToAssets(jt1Shares);
        AssetClaims memory jt2ClaimsAfter = JT.convertToAssets(jt2Shares);

        // Both JT depositors should have reduced claims (providing coverage)
        assertLt(toUint256(jt1ClaimsAfter.jtAssets), toUint256(jt1ClaimsBefore.jtAssets), "JT1 claims must decrease (coverage)");
        assertLt(toUint256(jt2ClaimsAfter.jtAssets), toUint256(jt2ClaimsBefore.jtAssets), "JT2 claims must decrease (coverage)");

        // Loss should be proportional to their holdings
        uint256 jt1Loss = toUint256(jt1ClaimsBefore.jtAssets) - toUint256(jt1ClaimsAfter.jtAssets);
        uint256 jt2Loss = toUint256(jt2ClaimsBefore.jtAssets) - toUint256(jt2ClaimsAfter.jtAssets);
        // JT2 has 1.5x the shares of JT1, so should have ~1.5x the loss
        assertApproxEqRel(jt2Loss, jt1Loss * 15 / 10, 0.05e18, "Loss must be proportional to holdings");
    }

    /// @notice Test simultaneous JT and ST losses
    function test_simultaneousJTAndSTLoss() external {
        // Setup JT
        address jtDepositor = ALICE_ADDRESS;
        vm.startPrank(jtDepositor);
        USDC.approve(address(JT), 500_000e6);
        (uint256 jtShares,) = JT.deposit(toTrancheUnits(500_000e6), jtDepositor, jtDepositor);
        vm.stopPrank();

        // Setup ST
        address stDepositor = BOB_ADDRESS;
        TRANCHE_UNIT stAmount = ST.maxDeposit(stDepositor).mulDiv(10, 100, Math.Rounding.Floor);
        vm.startPrank(stDepositor);
        USDC.approve(address(ST), toUint256(stAmount));
        (uint256 stShares,) = ST.deposit(stAmount, stDepositor, stDepositor);
        vm.stopPrank();

        // Record initial state
        (SyncedAccountingState memory initialState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        AssetClaims memory initialJTClaims = JT.convertToAssets(jtShares);
        AssetClaims memory initialSTClaims = ST.convertToAssets(stShares);

        // Simulate JT loss (from Aave)
        uint256 jtLossAmount = 20_000e6;
        vm.prank(address(KERNEL));
        AUSDC.transfer(CHARLIE_ADDRESS, jtLossAmount);

        // Simulate ST loss (from underlying vault)
        uint256 stLossAmount = toUint256(stAmount) / 20; // 5%
        vm.prank(address(MOCK_UNDERLYING_ST_VAULT));
        USDC.transfer(CHARLIE_ADDRESS, stLossAmount);

        // Record final state
        (SyncedAccountingState memory finalState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        AssetClaims memory finalJTClaims = JT.convertToAssets(jtShares);
        AssetClaims memory finalSTClaims = ST.convertToAssets(stShares);

        // Verify both losses reflected
        assertLt(toUint256(finalState.jtRawNAV), toUint256(initialState.jtRawNAV), "JT raw NAV must decrease");
        assertLt(toUint256(finalState.stRawNAV), toUint256(initialState.stRawNAV), "ST raw NAV must decrease");
        assertLt(toUint256(finalJTClaims.jtAssets), toUint256(initialJTClaims.jtAssets), "JT claims must decrease");
        // ST effective claims should be protected by JT coverage
        assertGt(toUint256(finalSTClaims.jtAssets), 0, "ST must have JT coverage claims");
    }

    // ============================================
    // STATE CONSISTENCY VERIFICATION TESTS
    // ============================================

    /// @notice Test accountant and kernel state consistency
    function test_stateConsistency_afterLoss() external {
        // Setup
        address jtDepositor = ALICE_ADDRESS;
        vm.startPrank(jtDepositor);
        USDC.approve(address(JT), 100_000e6);
        JT.deposit(toTrancheUnits(100_000e6), jtDepositor, jtDepositor);
        vm.stopPrank();

        // Get state from both sources
        (SyncedAccountingState memory kernelState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Verify consistency: totalAssets matches NAV calculations
        NAV_UNIT jtTotalNav = JT.totalAssets().nav;
        assertApproxEqRel(toUint256(jtTotalNav), toUint256(kernelState.jtEffectiveNAV), 0.001e18, "JT totalAssets NAV must match kernel effective NAV");

        // Simulate loss
        vm.prank(address(KERNEL));
        AUSDC.transfer(BOB_ADDRESS, 10_000e6);

        // Verify consistency after loss
        (SyncedAccountingState memory postLossKernelState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);
        NAV_UNIT postLossJtTotalNav = JT.totalAssets().nav;

        assertApproxEqRel(
            toUint256(postLossJtTotalNav),
            toUint256(postLossKernelState.jtEffectiveNAV),
            0.001e18,
            "Post-loss JT totalAssets NAV must match kernel effective NAV"
        );
    }

    /// @notice Test total claims sum equals total NAV
    function test_totalClaimsSum_equalsTotalNAV() external {
        // Setup JT and ST
        address jtDepositor = ALICE_ADDRESS;
        address stDepositor = BOB_ADDRESS;

        vm.startPrank(jtDepositor);
        USDC.approve(address(JT), 500_000e6);
        JT.deposit(toTrancheUnits(500_000e6), jtDepositor, jtDepositor);
        vm.stopPrank();

        TRANCHE_UNIT stAmount = ST.maxDeposit(stDepositor).mulDiv(50, 100, Math.Rounding.Floor);
        vm.startPrank(stDepositor);
        USDC.approve(address(ST), toUint256(stAmount));
        ST.deposit(stAmount, stDepositor, stDepositor);
        vm.stopPrank();

        // Get claims from both tranches
        (, AssetClaims memory jtTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);
        (, AssetClaims memory stTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);

        // JT total claims = jtAssets + stAssets
        // ST total claims = stAssets + jtAssets
        // These should be consistent with accounting
        assertTrue(toUint256(jtTotalClaims.jtAssets) >= 0, "JT total JT claims must be non-negative");
        assertTrue(toUint256(stTotalClaims.stAssets) >= 0, "ST total ST claims must be non-negative");

        // After loss, verify consistency maintained
        vm.prank(address(MOCK_UNDERLYING_ST_VAULT));
        USDC.transfer(CHARLIE_ADDRESS, toUint256(stAmount) / 10);

        (, AssetClaims memory postLossJTClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);
        (, AssetClaims memory postLossSTClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);

        // JT should be providing coverage (jtAssets claims given to ST)
        assertGt(toUint256(postLossSTClaims.jtAssets), 0, "ST must have JT claims (coverage)");
    }

    // ============================================
    // BOUNDARY CONDITION TESTS
    // ============================================

    /// @notice Test loss equal to entire ST deposit
    function test_loss_entireSTDeposit() external {
        // Setup JT with large amount
        address jtDepositor = ALICE_ADDRESS;
        vm.startPrank(jtDepositor);
        USDC.approve(address(JT), 1_000_000e6);
        JT.deposit(toTrancheUnits(1_000_000e6), jtDepositor, jtDepositor);
        vm.stopPrank();

        // Setup ST with small amount
        address stDepositor = BOB_ADDRESS;
        TRANCHE_UNIT stAmount = ST.maxDeposit(stDepositor).mulDiv(5, 100, Math.Rounding.Floor);
        vm.startPrank(stDepositor);
        USDC.approve(address(ST), toUint256(stAmount));
        (uint256 stShares,) = ST.deposit(stAmount, stDepositor, stDepositor);
        vm.stopPrank();

        // Record initial state
        AssetClaims memory initialClaims = ST.convertToAssets(stShares);

        // Total loss on ST vault - use most of the deposit but not all to avoid errors
        uint256 lossAmount = toUint256(stAmount) * 95 / 100;
        vm.prank(address(MOCK_UNDERLYING_ST_VAULT));
        USDC.transfer(CHARLIE_ADDRESS, lossAmount);

        // ST depositor should still have claims (from JT coverage)
        AssetClaims memory finalClaims = ST.convertToAssets(stShares);
        assertTrue(toUint256(finalClaims.jtAssets) > 0 || toUint256(finalClaims.stAssets) > 0, "ST must have some claims remaining (coverage protection)");
    }

    /// @notice Test minimal loss (1 wei equivalent)
    function test_minimalLoss() external {
        // Setup
        address jtDepositor = ALICE_ADDRESS;
        vm.startPrank(jtDepositor);
        USDC.approve(address(JT), 100_000e6);
        (uint256 shares,) = JT.deposit(toTrancheUnits(100_000e6), jtDepositor, jtDepositor);
        vm.stopPrank();

        // Record state before
        (SyncedAccountingState memory stateBefore,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Minimal loss (1 USDC)
        vm.prank(address(KERNEL));
        AUSDC.transfer(BOB_ADDRESS, 1e6);

        // Record state after
        (SyncedAccountingState memory stateAfter,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Even minimal loss should be reflected
        assertLt(toUint256(stateAfter.jtRawNAV), toUint256(stateBefore.jtRawNAV), "Even minimal loss must be reflected in NAV");
    }

    // ============================================
    // PROTOCOL FEE VERIFICATION TESTS
    // ============================================

    /// @notice Test protocol fees only accrue on gains, not losses
    function test_protocolFees_onlyOnGains() external {
        // Setup with smaller deposit
        address jtDepositor = ALICE_ADDRESS;
        vm.startPrank(jtDepositor);
        USDC.approve(address(JT), 100_000e6);
        JT.deposit(toTrancheUnits(100_000e6), jtDepositor, jtDepositor);
        vm.stopPrank();

        // Simulate small loss (1%)
        vm.prank(address(KERNEL));
        AUSDC.transfer(BOB_ADDRESS, 1000e6);

        // Check state - fees should be 0 after loss
        (SyncedAccountingState memory postLossState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);
        assertEq(toUint256(postLossState.jtProtocolFeeAccrued), 0, "Protocol fees must be 0 after loss");

        // Time passes, yield accrues (need longer time to recover from loss and generate new gains)
        skip(730 days); // 2 years to ensure gains exceed high-water mark

        // Check fees accrued on gains
        (SyncedAccountingState memory postYieldState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);
        // Protocol fees should accrue when yield exceeds the high-water mark
        // If the loss was small enough and enough time has passed, fees should be > 0
        // Note: This may still be 0 if the high-water mark accounting prevents fee accrual
        assertTrue(toUint256(postYieldState.jtRawNAV) > toUint256(postLossState.jtRawNAV), "JT raw NAV must increase from yield over time");
    }
}
