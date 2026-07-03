// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../lib/forge-std/src/Vm.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { DeployScript } from "../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../script/config/MarketDeploymentConfig.sol";
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
        // Build YDM params (AdaptiveCurve_V2)
        DeployScript.AdaptiveCurveYDM_V2_Params memory ydmParams = DeployScript.AdaptiveCurveYDM_V2_Params({
            yieldShareAtZeroUtilWAD: 0.225e18, // Y_0 = Y_T (same as target)
            yieldShareAtTargetUtilWAD: 0.225e18,
            yieldShareAtFullUtilWAD: 1e18,
            maxAdaptationSpeedWAD: uint64(30e18 / uint256(365 days))
        });

        // Build role assignments using the centralized function
        DeployScript.RoleAssignment[] memory roleAssignments = _generateRoleAssignments();

        // Build deployment config
        MarketDeploymentConfig.MarketConfig memory config = MarketDeploymentConfig.MarketConfig({
            marketName: "test",
            chainId: block.chainid,
            seniorTrancheName: SENIOR_TRANCHE_NAME,
            seniorTrancheSymbol: SENIOR_TRANCHE_SYMBOL,
            juniorTrancheName: JUNIOR_TRANCHE_NAME,
            juniorTrancheSymbol: JUNIOR_TRANCHE_SYMBOL,
            liquidityTrancheName: "Royco Liquidity test",
            liquidityTrancheSymbol: "ROY-LT-test",
            seniorAsset: address(MOCK_UNDERLYING_ST_VAULT),
            juniorAsset: address(MOCK_UNDERLYING_ST_VAULT),
            stDustTolerance: 1,
            jtDustTolerance: 1,
            kernelType: DeployScript.KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Day_Kernel,
            // A NON-ZERO `initialConversionRateWAD` makes the quoter use the admin-set rate (1:1 here) and
            // never query the Chainlink feed, so this test does not depend on a live oracle. The oracle
            // address must be non-zero (the quoter's initializer requires it) but is never read.
            kernelSpecificParams: abi.encode(
                DeployScript.IdenticalERC4626Shares_ST_JT_ToChainlinkOracleQuoterKernelParams({
                    initialConversionRateWAD: 1e18, baseAssetToNavAssetOracle: address(0xDA7A0FEED), stalenessThresholdSeconds: 48 hours
                })
            ),
            stSelfLiquidationBonusWAD: 0,
            enforceVaultSharesTransferWhitelist: false,
            stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
            jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            jtYieldShareProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            minCoverageWAD: COVERAGE_WAD,
            // Same asset for ST and JT (both MOCK_UNDERLYING_ST_VAULT), so the kernel's
            // `(stAsset != jtAsset) || JT_COINVESTED()` invariant requires the JT to be co-invested.
            jtCoinvested: true,
            coverageLiquidationUtilizationWAD: LIQUIDATION_COVERAGE_UTILIZATION_WAD,
            fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(ydmParams),
            gyroECLPPoolParams: DEPLOY_SCRIPT.demoGyroECLPPoolParams("test", 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48),
            transferAgentAddress: address(0)
        });

        // Deploy using the deployment script
        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        // TODO(day-fork): requires a Balancer Gyro pool factory + valid E-CLP params on a fork to run
        return
            DEPLOY_SCRIPT.deploy(config, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey);
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
        ACCESS_MANAGER.schedule(address(KERNEL), data, 0);

        // Verify operation is scheduled
        bytes32 operationId = ACCESS_MANAGER.hashOperation(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);
        uint48 scheduledTime = ACCESS_MANAGER.getSchedule(operationId);
        assertTrue(scheduledTime > 0, "Operation should be scheduled");

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        ACCESS_MANAGER.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);

        // Verify operation is cancelled (schedule returns 0)
        scheduledTime = ACCESS_MANAGER.getSchedule(operationId);
        assertEq(scheduledTime, 0, "Operation should be cancelled");

        // Verify the operation cannot be executed even after delay
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(KERNEL_ADMIN_ADDRESS);
        vm.expectRevert(); // Should revert - operation was cancelled
        ACCESS_MANAGER.execute(address(KERNEL), data);
    }

    /// @notice Test that guardian can cancel a scheduled accountant admin operation (setCoverage)
    function test_guardian_canCancelAccountantAdminSetCoverage() public {
        uint64 newCoverage = 0.3e18; // 30%
        bytes memory data = abi.encodeCall(ACCOUNTANT.setMinCoverage, (newCoverage));

        // Schedule the operation as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), data, 0);

        // Verify operation is scheduled
        bytes32 operationId = ACCESS_MANAGER.hashOperation(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);
        uint48 scheduledTime = ACCESS_MANAGER.getSchedule(operationId);
        assertTrue(scheduledTime > 0, "Operation should be scheduled");

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        ACCESS_MANAGER.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        // Verify operation is cancelled
        scheduledTime = ACCESS_MANAGER.getSchedule(operationId);
        assertEq(scheduledTime, 0, "Operation should be cancelled");
    }

    /// @notice Test that guardian can cancel a scheduled accountant admin operation (setLiquidationCoverageUtilization)
    function test_guardian_canCancelAccountantAdminSetLiquidationCoverageUtilization() public {
        uint256 newLiquidationCoverageUtilization = 5e18;
        bytes memory data = abi.encodeCall(ACCOUNTANT.setLiquidationCoverageUtilization, (newLiquidationCoverageUtilization));

        // Schedule the operation as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), data, 0);

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        ACCESS_MANAGER.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        // Verify the operation cannot be executed
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        vm.expectRevert();
        ACCESS_MANAGER.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel a scheduled accountant admin operation (setFixedTermDuration)
    function test_guardian_canCancelAccountantAdminSetFixedTermDuration() public {
        uint24 newDuration = 4 weeks;
        bytes memory data = abi.encodeCall(ACCOUNTANT.setFixedTermDuration, (newDuration));

        // Schedule the operation as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), data, 0);

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        ACCESS_MANAGER.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        // Verify the operation cannot be executed
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        vm.expectRevert();
        ACCESS_MANAGER.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel a scheduled accountant admin operation (setSeniorTrancheDustTolerance)
    function test_guardian_canCancelAccountantAdminSetDustTolerance() public {
        NAV_UNIT newDustTolerance = toNAVUnits(uint256(100));
        bytes memory data = abi.encodeCall(ACCOUNTANT.setSeniorTrancheDustTolerance, (newDustTolerance));

        // Schedule the operation as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), data, 0);

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        ACCESS_MANAGER.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        // Verify the operation cannot be executed
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        vm.expectRevert();
        ACCESS_MANAGER.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel a scheduled protocol fee setter operation (setSeniorTrancheProtocolFee)
    function test_guardian_canCancelProtocolFeeSetterSetSTFee() public {
        uint64 newFee = 0.15e18; // 15%
        bytes memory data = abi.encodeCall(ACCOUNTANT.setSeniorTrancheProtocolFee, (newFee));

        // Schedule the operation as protocol fee setter
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), data, 0);

        // Verify operation is scheduled
        bytes32 operationId = ACCESS_MANAGER.hashOperation(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data);
        uint48 scheduledTime = ACCESS_MANAGER.getSchedule(operationId);
        assertTrue(scheduledTime > 0, "Operation should be scheduled");

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        ACCESS_MANAGER.cancel(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data);

        // Verify operation is cancelled
        scheduledTime = ACCESS_MANAGER.getSchedule(operationId);
        assertEq(scheduledTime, 0, "Operation should be cancelled");
    }

    /// @notice Test that guardian can cancel a scheduled protocol fee setter operation (setJuniorTrancheProtocolFee)
    function test_guardian_canCancelProtocolFeeSetterSetJTFee() public {
        uint64 newFee = 0.2e18; // 20%
        bytes memory data = abi.encodeCall(ACCOUNTANT.setJuniorTrancheProtocolFee, (newFee));

        // Schedule the operation as protocol fee setter
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), data, 0);

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        ACCESS_MANAGER.cancel(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data);

        // Verify the operation cannot be executed
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        vm.expectRevert();
        ACCESS_MANAGER.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel a scheduled upgrader operation (upgradeToAndCall on kernel)
    function test_guardian_canCancelUpgraderOperation() public {
        // Create mock new implementation address
        address newImpl = address(0xBEEF);
        // Use UUPSUpgradeable.upgradeToAndCall selector
        bytes memory data = abi.encodeWithSelector(bytes4(keccak256("upgradeToAndCall(address,bytes)")), newImpl, "");

        // Schedule the operation as upgrader
        vm.prank(UPGRADER_ADDRESS);
        ACCESS_MANAGER.schedule(address(KERNEL), data, 0);

        // Verify operation is scheduled
        bytes32 operationId = ACCESS_MANAGER.hashOperation(UPGRADER_ADDRESS, address(KERNEL), data);
        uint48 scheduledTime = ACCESS_MANAGER.getSchedule(operationId);
        assertTrue(scheduledTime > 0, "Operation should be scheduled");

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        ACCESS_MANAGER.cancel(UPGRADER_ADDRESS, address(KERNEL), data);

        // Verify operation is cancelled
        scheduledTime = ACCESS_MANAGER.getSchedule(operationId);
        assertEq(scheduledTime, 0, "Operation should be cancelled");
    }

    /// @notice Test that non-guardian cannot cancel operations
    function test_nonGuardian_cannotCancelOperations() public {
        address newRecipient = address(0x1234);
        bytes memory data = abi.encodeCall(KERNEL.setProtocolFeeRecipient, (newRecipient));

        // Schedule the operation as kernel admin
        vm.prank(KERNEL_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(address(KERNEL), data, 0);

        // Random address tries to cancel - should fail
        vm.prank(address(0xBAD));
        vm.expectRevert();
        ACCESS_MANAGER.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);

        // Even another role holder (not guardian) cannot cancel
        vm.prank(PAUSER_ADDRESS);
        vm.expectRevert();
        ACCESS_MANAGER.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);
    }

    /// @notice Test that guardian can cancel multiple operations in sequence
    function test_guardian_canCancelMultipleOperations() public {
        // Schedule multiple operations
        bytes memory data1 = abi.encodeCall(KERNEL.setProtocolFeeRecipient, (address(0x1111)));
        bytes memory data2 = abi.encodeCall(ACCOUNTANT.setMinCoverage, (0.25e18));
        bytes memory data3 = abi.encodeCall(ACCOUNTANT.setSeniorTrancheProtocolFee, (0.12e18));

        vm.prank(KERNEL_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(address(KERNEL), data1, 0);

        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), data2, 0);

        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), data3, 0);

        // Guardian cancels all operations
        vm.startPrank(ROLE_GUARDIAN_ADDRESS);
        ACCESS_MANAGER.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data1);
        ACCESS_MANAGER.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data2);
        ACCESS_MANAGER.cancel(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data3);
        vm.stopPrank();

        // Verify all operations are cancelled
        assertEq(ACCESS_MANAGER.getSchedule(ACCESS_MANAGER.hashOperation(KERNEL_ADMIN_ADDRESS, address(KERNEL), data1)), 0);
        assertEq(ACCESS_MANAGER.getSchedule(ACCESS_MANAGER.hashOperation(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data2)), 0);
        assertEq(ACCESS_MANAGER.getSchedule(ACCESS_MANAGER.hashOperation(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data3)), 0);
    }

    // ============================================
    // ROLE ASSIGNMENT TESTS — newly added selectors
    // ============================================

    /// @notice Test that ADMIN_KERNEL_ROLE can call setSeniorTrancheSelfLiquidationBonus
    function test_role_kernelAdmin_canSetSelfLiquidationBonus() public {
        uint64 newBonus = 0.05e18; // 5%
        bytes memory data = abi.encodeCall(KERNEL.setSeniorTrancheSelfLiquidationBonus, (newBonus));

        // Schedule as kernel admin
        vm.prank(KERNEL_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(address(KERNEL), data, 0);

        // Advance past execution delay
        vm.warp(block.timestamp + 2 days + 1);

        // Execute
        vm.prank(KERNEL_ADMIN_ADDRESS);
        ACCESS_MANAGER.execute(address(KERNEL), data);
    }

    /// @notice Test that non-kernel-admin cannot call setSeniorTrancheSelfLiquidationBonus
    function test_role_nonKernelAdmin_cannotSetSelfLiquidationBonus() public {
        uint64 newBonus = 0.05e18;
        bytes memory data = abi.encodeCall(KERNEL.setSeniorTrancheSelfLiquidationBonus, (newBonus));

        // Random address tries to schedule — should fail
        vm.prank(address(0xBAD));
        vm.expectRevert();
        ACCESS_MANAGER.schedule(address(KERNEL), data, 0);
    }

    /// @notice Test that ADMIN_PROTOCOL_FEE_SETTER_ROLE can call setJTYieldShareProtocolFee
    function test_role_protocolFeeSetter_canSetJTYieldShareProtocolFee() public {
        uint64 newFee = 0.1e18; // 10%
        bytes memory data = abi.encodeCall(ACCOUNTANT.setJTYieldShareProtocolFee, (newFee));

        // Schedule as protocol fee setter
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), data, 0);

        // Advance past execution delay
        vm.warp(block.timestamp + 2 days + 1);

        // Execute
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        ACCESS_MANAGER.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that non-fee-setter cannot call setJTYieldShareProtocolFee
    function test_role_nonFeeSetter_cannotSetJTYieldShareProtocolFee() public {
        uint64 newFee = 0.1e18;
        bytes memory data = abi.encodeCall(ACCOUNTANT.setJTYieldShareProtocolFee, (newFee));

        vm.prank(address(0xBAD));
        vm.expectRevert();
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), data, 0);
    }

    /// @notice Test that ADMIN_ACCOUNTANT_ROLE can call setJuniorTrancheDustTolerance
    function test_role_accountantAdmin_canSetJuniorTrancheDustTolerance() public {
        NAV_UNIT newDustTolerance = toNAVUnits(uint256(200));
        bytes memory data = abi.encodeCall(ACCOUNTANT.setJuniorTrancheDustTolerance, (newDustTolerance));

        // Schedule as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), data, 0);

        // Advance past execution delay
        vm.warp(block.timestamp + 2 days + 1);

        // Execute
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        ACCESS_MANAGER.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that non-accountant-admin cannot call setJuniorTrancheDustTolerance
    function test_role_nonAccountantAdmin_cannotSetJuniorTrancheDustTolerance() public {
        NAV_UNIT newDustTolerance = toNAVUnits(uint256(200));
        bytes memory data = abi.encodeCall(ACCOUNTANT.setJuniorTrancheDustTolerance, (newDustTolerance));

        vm.prank(address(0xBAD));
        vm.expectRevert();
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), data, 0);
    }

    /// @notice Test that guardian can cancel setSeniorTrancheSelfLiquidationBonus
    function test_guardian_canCancelSetSelfLiquidationBonus() public {
        uint64 newBonus = 0.05e18;
        bytes memory data = abi.encodeCall(KERNEL.setSeniorTrancheSelfLiquidationBonus, (newBonus));

        vm.prank(KERNEL_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(address(KERNEL), data, 0);

        vm.prank(ROLE_GUARDIAN_ADDRESS);
        ACCESS_MANAGER.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(KERNEL_ADMIN_ADDRESS);
        vm.expectRevert();
        ACCESS_MANAGER.execute(address(KERNEL), data);
    }

    /// @notice Test that guardian can cancel setJTYieldShareProtocolFee
    function test_guardian_canCancelSetJTYieldShareProtocolFee() public {
        uint64 newFee = 0.1e18;
        bytes memory data = abi.encodeCall(ACCOUNTANT.setJTYieldShareProtocolFee, (newFee));

        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), data, 0);

        vm.prank(ROLE_GUARDIAN_ADDRESS);
        ACCESS_MANAGER.cancel(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data);

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        vm.expectRevert();
        ACCESS_MANAGER.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel setJuniorTrancheDustTolerance
    function test_guardian_canCancelSetJuniorTrancheDustTolerance() public {
        NAV_UNIT newDustTolerance = toNAVUnits(uint256(200));
        bytes memory data = abi.encodeCall(ACCOUNTANT.setJuniorTrancheDustTolerance, (newDustTolerance));

        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), data, 0);

        vm.prank(ROLE_GUARDIAN_ADDRESS);
        ACCESS_MANAGER.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        vm.expectRevert();
        ACCESS_MANAGER.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that the original caller can also cancel their own scheduled operation
    function test_originalCaller_canCancelOwnOperation() public {
        address newRecipient = address(0x1234);
        bytes memory data = abi.encodeCall(KERNEL.setProtocolFeeRecipient, (newRecipient));

        // Schedule the operation as kernel admin
        vm.prank(KERNEL_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(address(KERNEL), data, 0);

        // Kernel admin cancels their own operation
        vm.prank(KERNEL_ADMIN_ADDRESS);
        ACCESS_MANAGER.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);

        // Verify operation is cancelled
        bytes32 operationId = ACCESS_MANAGER.hashOperation(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);
        assertEq(ACCESS_MANAGER.getSchedule(operationId), 0, "Operation should be cancelled");
    }
}
