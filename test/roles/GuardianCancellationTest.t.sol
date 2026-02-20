// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../lib/forge-std/src/Vm.sol";
import { IAccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { DeployScript } from "../../script/Deploy.s.sol";
import { IRoycoAccountant } from "../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoKernel } from "../../src/interfaces/kernel/IRoycoKernel.sol";
import { NAV_UNIT, toNAVUnits } from "../../src/libraries/Units.sol";
import { BaseTest } from "../base/BaseTest.t.sol";
import { ERC4626Mock } from "../mock/ERC4626Mock.sol";

/// @title GuardianCancellationTest
/// @notice Tests that the GUARDIAN_ROLE can cancel any and all delayed operations
/// @dev Tests cover cancellation of operations for ADMIN_KERNEL_ROLE, ADMIN_ACCOUNTANT_ROLE,
///      ADMIN_PROTOCOL_FEE_SETTER_ROLE, and ADMIN_UPGRADER_ROLE
contract GuardianCancellationTest is BaseTest {
    uint24 internal constant JT_REDEMPTION_DELAY_SECONDS = 1_000_000;

    Vm.Wallet internal RESERVE;
    address internal RESERVE_ADDRESS;

    ERC4626Mock internal MOCK_UNDERLYING_ST_VAULT;
    IERC20 internal USDC;
    IERC20 internal AUSDC;

    function setUp() public {
        _setUpRoyco();
    }

    function _setUpRoyco() internal override {
        // Setup wallets
        RESERVE = vm.createWallet("RESERVE");
        RESERVE_ADDRESS = RESERVE.addr;
        vm.label(RESERVE_ADDRESS, "RESERVE");

        // Deploy core
        super._setUpRoyco();

        USDC = IERC20(ETHEREUM_MAINNET_USDC_ADDRESS);
        AUSDC = IERC20(aTokenAddresses[1][ETHEREUM_MAINNET_USDC_ADDRESS]);
        vm.label(address(USDC), "USDC");
        vm.label(address(AUSDC), "aUSDC");

        // Deploy mock senior tranche underlying vault
        MOCK_UNDERLYING_ST_VAULT = new ERC4626Mock(ETHEREUM_MAINNET_USDC_ADDRESS, RESERVE_ADDRESS);
        vm.label(address(MOCK_UNDERLYING_ST_VAULT), "MockSTUnderlyingVault");
        // Have the reserve approve the mock senior tranche underlying vault to spend USDC
        vm.prank(RESERVE_ADDRESS);
        IERC20(ETHEREUM_MAINNET_USDC_ADDRESS).approve(address(MOCK_UNDERLYING_ST_VAULT), type(uint256).max);

        // Deploy the markets
        DeployScript.DeploymentResult memory deploymentResult = _deployMarketWithKernel();
        _setDeployedMarket(deploymentResult);
    }

    function _deployMarketWithKernel() internal returns (DeployScript.DeploymentResult memory) {
        bytes32 marketID = keccak256(abi.encodePacked(SENIOR_TRANCHE_NAME, JUNIOR_TRANCHE_NAME, vm.getBlockTimestamp()));

        // Build kernel-specific params
        DeployScript.ERC4626STAaveV3JTInKindAssetsKernelParams memory kernelParams = DeployScript.ERC4626STAaveV3JTInKindAssetsKernelParams({
            stVault: address(MOCK_UNDERLYING_ST_VAULT), aaveV3Pool: ETHEREUM_MAINNET_AAVE_V3_POOL_ADDRESS
        });

        // Build YDM params (AdaptiveCurve)
        DeployScript.AdaptiveCurveYDM_V1Params memory ydmParams =
            DeployScript.AdaptiveCurveYDM_V1Params({ jtYieldShareAtTargetUtilWAD: 0.225e18, jtYieldShareAtFullUtilWAD: 1e18 });

        // Build role assignments using the centralized function
        DeployScript.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        // Build deployment params
        DeployScript.DeploymentParams memory params = DeployScript.DeploymentParams({
            factoryAdmin: OWNER_ADDRESS,
            marketId: marketID,
            seniorTrancheName: SENIOR_TRANCHE_NAME,
            seniorTrancheSymbol: SENIOR_TRANCHE_SYMBOL,
            juniorTrancheName: JUNIOR_TRANCHE_NAME,
            juniorTrancheSymbol: JUNIOR_TRANCHE_SYMBOL,
            seniorAsset: ETHEREUM_MAINNET_USDC_ADDRESS,
            juniorAsset: ETHEREUM_MAINNET_USDC_ADDRESS,
            stNAVDustTolerance: DUST_TOLERANCE,
            jtNAVDustTolerance: DUST_TOLERANCE,
            kernelType: DeployScript.KernelType.ERC4626_ST_AaveV3_JT_InKindAssets,
            kernelSpecificParams: abi.encode(kernelParams),
            protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS,
            jtRedemptionDelayInSeconds: JT_REDEMPTION_DELAY_SECONDS,
            stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
            jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            coverageWAD: COVERAGE_WAD,
            betaWAD: BETA_WAD,
            lltvWAD: LLTV,
            fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
            ydmType: DeployScript.YDMType.AdaptiveCurve,
            ydmSpecificParams: abi.encode(ydmParams),
            roleAssignments: roleAssignments
        });

        // Deploy using the deployment script
        return DEPLOY_SCRIPT.deploy(params, DEPLOYER.privateKey);
    }

    /// @notice Returns the fork configuration
    function _forkConfiguration() internal override returns (uint256 forkBlock, string memory forkRpcUrl) {
        forkBlock = 23_997_023;
        forkRpcUrl = vm.envString("MAINNET_RPC_URL");
        if (bytes(forkRpcUrl).length == 0) {
            fail("MAINNET_RPC_URL environment variable is not set");
        }
    }

    // ============================================
    // GUARDIAN CANCELLATION TESTS
    // ============================================

    /// @notice Test that guardian can cancel a scheduled kernel admin operation (setProtocolFeeRecipient)
    function test_guardian_canCancelKernelAdminOperation() public {
        address newRecipient = address(0x1234);
        bytes memory data = abi.encodeCall(KERNEL.setProtocolFeeRecipient, (newRecipient));

        // Schedule the operation as kernel admin
        vm.prank(KERNEL_ADMIN_ADDRESS);
        FACTORY.schedule(address(KERNEL), data, 0);

        // Verify operation is scheduled
        bytes32 operationId = FACTORY.hashOperation(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);
        uint48 scheduledTime = FACTORY.getSchedule(operationId);
        assertTrue(scheduledTime > 0, "Operation should be scheduled");

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        FACTORY.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);

        // Verify operation is cancelled (schedule returns 0)
        scheduledTime = FACTORY.getSchedule(operationId);
        assertEq(scheduledTime, 0, "Operation should be cancelled");

        // Verify the operation cannot be executed even after delay
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(KERNEL_ADMIN_ADDRESS);
        vm.expectRevert(); // Should revert - operation was cancelled
        FACTORY.execute(address(KERNEL), data);
    }

    /// @notice Test that guardian can cancel a scheduled kernel admin operation (setJuniorTrancheRedemptionDelay)
    function test_guardian_canCancelKernelAdminSetRedemptionDelay() public {
        uint24 newDelay = 500_000;
        bytes memory data = abi.encodeCall(KERNEL.setJuniorTrancheRedemptionDelay, (newDelay));

        // Schedule the operation as kernel admin
        vm.prank(KERNEL_ADMIN_ADDRESS);
        FACTORY.schedule(address(KERNEL), data, 0);

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        FACTORY.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);

        // Verify the operation cannot be executed
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(KERNEL_ADMIN_ADDRESS);
        vm.expectRevert();
        FACTORY.execute(address(KERNEL), data);
    }

    /// @notice Test that guardian can cancel a scheduled accountant admin operation (setCoverage)
    function test_guardian_canCancelAccountantAdminSetCoverage() public {
        uint64 newCoverage = 0.3e18; // 30%
        bytes memory data = abi.encodeCall(ACCOUNTANT.setCoverage, (newCoverage));

        // Schedule the operation as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        FACTORY.schedule(address(ACCOUNTANT), data, 0);

        // Verify operation is scheduled
        bytes32 operationId = FACTORY.hashOperation(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);
        uint48 scheduledTime = FACTORY.getSchedule(operationId);
        assertTrue(scheduledTime > 0, "Operation should be scheduled");

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        FACTORY.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        // Verify operation is cancelled
        scheduledTime = FACTORY.getSchedule(operationId);
        assertEq(scheduledTime, 0, "Operation should be cancelled");
    }

    /// @notice Test that guardian can cancel a scheduled accountant admin operation (setBeta)
    function test_guardian_canCancelAccountantAdminSetBeta() public {
        uint96 newBeta = 0.5e18;
        bytes memory data = abi.encodeCall(ACCOUNTANT.setBeta, (newBeta));

        // Schedule the operation as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        FACTORY.schedule(address(ACCOUNTANT), data, 0);

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        FACTORY.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        // Verify the operation cannot be executed
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        vm.expectRevert();
        FACTORY.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel a scheduled accountant admin operation (setLLTV)
    function test_guardian_canCancelAccountantAdminSetLLTV() public {
        uint64 newLLTV = 0.95e18;
        bytes memory data = abi.encodeCall(ACCOUNTANT.setLLTV, (newLLTV));

        // Schedule the operation as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        FACTORY.schedule(address(ACCOUNTANT), data, 0);

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        FACTORY.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        // Verify the operation cannot be executed
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        vm.expectRevert();
        FACTORY.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel a scheduled accountant admin operation (setFixedTermDuration)
    function test_guardian_canCancelAccountantAdminSetFixedTermDuration() public {
        uint24 newDuration = 4 weeks;
        bytes memory data = abi.encodeCall(ACCOUNTANT.setFixedTermDuration, (newDuration));

        // Schedule the operation as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        FACTORY.schedule(address(ACCOUNTANT), data, 0);

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        FACTORY.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        // Verify the operation cannot be executed
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        vm.expectRevert();
        FACTORY.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel a scheduled accountant admin operation (setSeniorTrancheDustTolerance)
    function test_guardian_canCancelAccountantAdminSetDustTolerance() public {
        NAV_UNIT newDustTolerance = toNAVUnits(uint256(100));
        bytes memory data = abi.encodeCall(ACCOUNTANT.setSeniorTrancheDustTolerance, (newDustTolerance));

        // Schedule the operation as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        FACTORY.schedule(address(ACCOUNTANT), data, 0);

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        FACTORY.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        // Verify the operation cannot be executed
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        vm.expectRevert();
        FACTORY.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel a scheduled protocol fee setter operation (setSeniorTrancheProtocolFee)
    function test_guardian_canCancelProtocolFeeSetterSetSTFee() public {
        uint64 newFee = 0.15e18; // 15%
        bytes memory data = abi.encodeCall(ACCOUNTANT.setSeniorTrancheProtocolFee, (newFee));

        // Schedule the operation as protocol fee setter
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        FACTORY.schedule(address(ACCOUNTANT), data, 0);

        // Verify operation is scheduled
        bytes32 operationId = FACTORY.hashOperation(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data);
        uint48 scheduledTime = FACTORY.getSchedule(operationId);
        assertTrue(scheduledTime > 0, "Operation should be scheduled");

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        FACTORY.cancel(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data);

        // Verify operation is cancelled
        scheduledTime = FACTORY.getSchedule(operationId);
        assertEq(scheduledTime, 0, "Operation should be cancelled");
    }

    /// @notice Test that guardian can cancel a scheduled protocol fee setter operation (setJuniorTrancheProtocolFee)
    function test_guardian_canCancelProtocolFeeSetterSetJTFee() public {
        uint64 newFee = 0.2e18; // 20%
        bytes memory data = abi.encodeCall(ACCOUNTANT.setJuniorTrancheProtocolFee, (newFee));

        // Schedule the operation as protocol fee setter
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        FACTORY.schedule(address(ACCOUNTANT), data, 0);

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        FACTORY.cancel(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data);

        // Verify the operation cannot be executed
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        vm.expectRevert();
        FACTORY.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel a scheduled upgrader operation (upgradeToAndCall on kernel)
    function test_guardian_canCancelUpgraderOperation() public {
        // Create mock new implementation address
        address newImpl = address(0xBEEF);
        // Use UUPSUpgradeable.upgradeToAndCall selector
        bytes memory data = abi.encodeWithSelector(bytes4(keccak256("upgradeToAndCall(address,bytes)")), newImpl, "");

        // Schedule the operation as upgrader
        vm.prank(UPGRADER_ADDRESS);
        FACTORY.schedule(address(KERNEL), data, 0);

        // Verify operation is scheduled
        bytes32 operationId = FACTORY.hashOperation(UPGRADER_ADDRESS, address(KERNEL), data);
        uint48 scheduledTime = FACTORY.getSchedule(operationId);
        assertTrue(scheduledTime > 0, "Operation should be scheduled");

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        FACTORY.cancel(UPGRADER_ADDRESS, address(KERNEL), data);

        // Verify operation is cancelled
        scheduledTime = FACTORY.getSchedule(operationId);
        assertEq(scheduledTime, 0, "Operation should be cancelled");
    }

    /// @notice Test that non-guardian cannot cancel operations
    function test_nonGuardian_cannotCancelOperations() public {
        address newRecipient = address(0x1234);
        bytes memory data = abi.encodeCall(KERNEL.setProtocolFeeRecipient, (newRecipient));

        // Schedule the operation as kernel admin
        vm.prank(KERNEL_ADMIN_ADDRESS);
        FACTORY.schedule(address(KERNEL), data, 0);

        // Random address tries to cancel - should fail
        vm.prank(address(0xBAD));
        vm.expectRevert();
        FACTORY.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);

        // Even another role holder (not guardian) cannot cancel
        vm.prank(PAUSER_ADDRESS);
        vm.expectRevert();
        FACTORY.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);
    }

    /// @notice Test that guardian can cancel multiple operations in sequence
    function test_guardian_canCancelMultipleOperations() public {
        // Schedule multiple operations
        bytes memory data1 = abi.encodeCall(KERNEL.setProtocolFeeRecipient, (address(0x1111)));
        bytes memory data2 = abi.encodeCall(ACCOUNTANT.setCoverage, (0.25e18));
        bytes memory data3 = abi.encodeCall(ACCOUNTANT.setSeniorTrancheProtocolFee, (0.12e18));

        vm.prank(KERNEL_ADMIN_ADDRESS);
        FACTORY.schedule(address(KERNEL), data1, 0);

        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        FACTORY.schedule(address(ACCOUNTANT), data2, 0);

        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        FACTORY.schedule(address(ACCOUNTANT), data3, 0);

        // Guardian cancels all operations
        vm.startPrank(ROLE_GUARDIAN_ADDRESS);
        FACTORY.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data1);
        FACTORY.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data2);
        FACTORY.cancel(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data3);
        vm.stopPrank();

        // Verify all operations are cancelled
        assertEq(FACTORY.getSchedule(FACTORY.hashOperation(KERNEL_ADMIN_ADDRESS, address(KERNEL), data1)), 0);
        assertEq(FACTORY.getSchedule(FACTORY.hashOperation(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data2)), 0);
        assertEq(FACTORY.getSchedule(FACTORY.hashOperation(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data3)), 0);
    }

    /// @notice Test that the original caller can also cancel their own scheduled operation
    function test_originalCaller_canCancelOwnOperation() public {
        address newRecipient = address(0x1234);
        bytes memory data = abi.encodeCall(KERNEL.setProtocolFeeRecipient, (newRecipient));

        // Schedule the operation as kernel admin
        vm.prank(KERNEL_ADMIN_ADDRESS);
        FACTORY.schedule(address(KERNEL), data, 0);

        // Kernel admin cancels their own operation
        vm.prank(KERNEL_ADMIN_ADDRESS);
        FACTORY.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);

        // Verify operation is cancelled
        bytes32 operationId = FACTORY.hashOperation(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);
        assertEq(FACTORY.getSchedule(operationId), 0, "Operation should be cancelled");
    }
}
