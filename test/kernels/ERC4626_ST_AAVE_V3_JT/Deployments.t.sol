// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DeployScript } from "../../../script/Deploy.s.sol";
import { RoycoAccountant } from "../../../src/accountant/RoycoAccountant.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoFactory } from "../../../src/interfaces/IRoycoFactory.sol";
import { IPool } from "../../../src/interfaces/external/aave/IPool.sol";
import { TrancheType } from "../../../src/interfaces/kernel/IRoycoKernel.sol";
import { ERC4626_ST_AaveV3_JT_InKindAssets_Kernel } from "../../../src/kernels/ERC4626_ST_AaveV3_JT_InKindAssets_Kernel.sol";
import { ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../../src/libraries/Constants.sol";
import { RoycoKernelInitParams } from "../../../src/libraries/RoycoKernelStorageLib.sol";
import {
    IRoycoAccountant,
    IRoycoKernel,
    MarketDeploymentParams,
    RolesTargetConfiguration,
    SyncedAccountingState,
    TrancheDeploymentParams
} from "../../../src/libraries/Types.sol";
import { toNAVUnits } from "../../../src/libraries/Units.sol";
import { AdaptiveCurveYDM_V1 } from "../../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { MainnetForkWithAaveTestBase } from "./base/MainnetForkWithAaveBaseTest.t.sol";

contract DeploymentsTest is MainnetForkWithAaveTestBase {
    constructor() {
        BETA_WAD = 1e18; // Same opportunities
    }

    function setUp() public {
        _setUpRoyco();
    }

    /// @notice Verifies senior tranche deployment parameters
    function test_SeniorTrancheDeployment() public view {
        // Basic wiring
        assertTrue(address(ST) != address(0), "Senior tranche not deployed");
        // Kernel wiring
        assertEq(ST.kernel(), address(KERNEL), "ST KERNEL address mismatch");
        assertEq(ST.marketId(), MARKET_ID, "ST MARKET_ID mismatch");

        // Asset and metadata
        assertEq(address(ST.asset()), ETHEREUM_MAINNET_USDC_ADDRESS, "ST asset must be USDC");
        assertEq(ST.name(), SENIOR_TRANCHE_NAME, "ST name mismatch");
        assertEq(ST.symbol(), SENIOR_TRANCHE_SYMBOL, "ST symbol mismatch");
        assertTrue(ST.TRANCHE_TYPE() == TrancheType.SENIOR, "ST tranche type mismatch");

        // Initial NAV and totals
        assertEq(ST.totalSupply(), 0, "ST initial totalSupply must be 0");
        assertEq(ST.getRawNAV(), ZERO_NAV_UNITS, "ST initial raw NAV must be 0");
        assertEq(ST.totalAssets().nav, ZERO_NAV_UNITS, "ST initial effective NAV must be 0");
        assertEq(ST.totalAssets().stAssets, ZERO_TRANCHE_UNITS, "ST initial total st assets must be 0");
        assertEq(ST.totalAssets().jtAssets, ZERO_TRANCHE_UNITS, "ST initial total jt assets must be 0");
    }

    /// @notice Verifies junior tranche deployment parameters
    function test_JuniorTrancheDeployment() public view {
        // Basic wiring
        assertTrue(address(JT) != address(0), "Junior tranche not deployed");
        // Kernel wiring
        assertEq(JT.kernel(), address(KERNEL), "JT KERNEL address mismatch");
        assertEq(JT.marketId(), MARKET_ID, "JT MARKET_ID mismatch");
        assertTrue(JT.TRANCHE_TYPE() == TrancheType.JUNIOR, "JT tranche type mismatch");

        // Asset and metadata
        assertEq(address(JT.asset()), ETHEREUM_MAINNET_USDC_ADDRESS, "JT asset must be USDC");
        assertEq(JT.name(), JUNIOR_TRANCHE_NAME, "JT name mismatch");
        assertEq(JT.symbol(), JUNIOR_TRANCHE_SYMBOL, "JT symbol mismatch");

        // Initial NAV and totals
        assertEq(JT.totalSupply(), 0, "JT initial totalSupply must be 0");
        assertEq(JT.getRawNAV(), ZERO_NAV_UNITS, "JT initial raw NAV must be 0");
        assertEq(JT.totalAssets().nav, ZERO_NAV_UNITS, "JT initial effective NAV must be 0");
        assertEq(JT.totalAssets().stAssets, ZERO_TRANCHE_UNITS, "JT initial total st assets must be 0");
        assertEq(JT.totalAssets().jtAssets, ZERO_TRANCHE_UNITS, "JT initial total jt assets must be 0");
    }

    /// @notice Verifies kernel and accountant deployment parameters and wiring
    function test_KernelAndAccountantDeployment() public view {
        // Basic wiring
        assertTrue(address(KERNEL) != address(0), "Kernel not deployed");

        (address seniorTranche,, address juniorTranche,, address protocolFeeRecipient, address accountant,) = KERNEL.getState();

        // Tranche wiring
        assertEq(seniorTranche, address(ST), "Kernel ST mismatch");
        assertEq(juniorTranche, address(JT), "Kernel JT mismatch");
        assertEq(accountant, address(ACCOUNTANT), "Kernel accountant mismatch");
        assertEq(protocolFeeRecipient, PROTOCOL_FEE_RECIPIENT_ADDRESS, "Kernel protocolFeeRecipient mismatch");

        IRoycoAccountant.RoycoAccountantState memory accountantState = ACCOUNTANT.getState();

        // Coverage, beta, protocol fee configuration
        assertEq(accountantState.coverageWAD, COVERAGE_WAD, "Kernel coverageWAD mismatch");
        assertEq(accountantState.betaWAD, BETA_WAD, "BETA_WAD mismatch");
        assertEq(accountantState.stProtocolFeeWAD, ST_PROTOCOL_FEE_WAD, "Kernel stProtocolFeeWAD mismatch");
        assertEq(accountantState.jtProtocolFeeWAD, JT_PROTOCOL_FEE_WAD, "Kernel jtProtocolFeeWAD mismatch");

        // YDM wiring
        assertEq(accountantState.ydm, address(YDM), "Kernel YDM mismatch");

        // Initial NAV / ASSETS via KERNEL view functions
        (SyncedAccountingState memory state,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        assertEq(state.stEffectiveNAV, ZERO_NAV_UNITS, "Kernel ST total effective ASSETS must be 0");
        assertEq(state.jtEffectiveNAV, ZERO_NAV_UNITS, "Kernel JT total effective ASSETS must be 0");
        assertEq(state.stRawNAV, ZERO_NAV_UNITS, "Kernel ST raw NAV must be 0");
        assertEq(state.jtRawNAV, ZERO_NAV_UNITS, "Kernel JT raw NAV must be 0");

        // Aave wiring: pool and AUSDC mapping must be consistent
        address expectedAToken = IPool(ETHEREUM_MAINNET_AAVE_V3_POOL_ADDRESS).getReserveAToken(ETHEREUM_MAINNET_USDC_ADDRESS);
        assertEq(expectedAToken, address(AUSDC), "AUSDC address must match Aave pool data");
    }

    function test_deployMarket_revertsOnEmptySeniorTrancheName() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.seniorTrancheName = "";

        vm.expectRevert(IRoycoFactory.INVALID_NAME.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnEmptySeniorTrancheSymbol() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.seniorTrancheSymbol = "";

        vm.expectRevert(IRoycoFactory.INVALID_SYMBOL.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnEmptyJuniorTrancheName() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.juniorTrancheName = "";

        vm.expectRevert(IRoycoFactory.INVALID_NAME.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnEmptyJuniorTrancheSymbol() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.juniorTrancheSymbol = "";

        vm.expectRevert(IRoycoFactory.INVALID_SYMBOL.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroMarketId() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.marketId = bytes32(0);

        vm.expectRevert(IRoycoFactory.INVALID_MARKET_ID.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroKernelImplementation() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.kernelImplementation = IRoycoKernel(address(0));

        vm.expectRevert(IRoycoFactory.INVALID_KERNEL_IMPLEMENTATION.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroAccountantImplementation() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.accountantImplementation = IRoycoAccountant(address(0));

        vm.expectRevert(IRoycoFactory.INVALID_ACCOUNTANT_IMPLEMENTATION.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnEmptyKernelInitializationData() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.kernelInitializationData = "";

        vm.expectRevert(IRoycoFactory.INVALID_KERNEL_INITIALIZATION_DATA.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnEmptyAccountantInitializationData() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.accountantInitializationData = "";

        vm.expectRevert(IRoycoFactory.INVALID_ACCOUNTANT_INITIALIZATION_DATA.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroSeniorTrancheProxyDeploymentSalt() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.seniorTrancheProxyDeploymentSalt = bytes32(0);

        vm.expectRevert(IRoycoFactory.INVALID_SENIOR_TRANCHE_PROXY_DEPLOYMENT_SALT.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroJuniorTrancheProxyDeploymentSalt() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.juniorTrancheProxyDeploymentSalt = bytes32(0);

        vm.expectRevert(IRoycoFactory.INVALID_JUNIOR_TRANCHE_PROXY_DEPLOYMENT_SALT.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroKernelProxyDeploymentSalt() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.kernelProxyDeploymentSalt = bytes32(0);

        vm.expectRevert(IRoycoFactory.INVALID_KERNEL_PROXY_DEPLOYMENT_SALT.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroAccountantProxyDeploymentSalt() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.accountantProxyDeploymentSalt = bytes32(0);

        vm.expectRevert(IRoycoFactory.INVALID_ACCOUNTANT_PROXY_DEPLOYMENT_SALT.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnFailedSeniorTrancheInitialization() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "FAILED_ST_INIT"));
        (MarketDeploymentParams memory params,) = _buildValidMarketParamsForSalt(salt);

        // Provide non-empty but invalid initialization data so the call to the senior tranche fails
        params.seniorTrancheInitializationData = abi.encodeWithSignature("nonExistentFunction(address)", address(this));

        vm.expectRevert(abi.encodeWithSelector(IRoycoFactory.FAILED_TO_INITIALIZE_SENIOR_TRANCHE.selector, ""));
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnFailedJuniorTrancheInitialization() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "FAILED_JT_INIT"));
        (MarketDeploymentParams memory params,) = _buildValidMarketParamsForSalt(salt);

        // Provide non-empty but invalid initialization data so the call to the junior tranche fails
        params.juniorTrancheInitializationData = abi.encodeWithSignature("nonExistentFunction(address)", address(this));

        vm.expectRevert(abi.encodeWithSelector(IRoycoFactory.FAILED_TO_INITIALIZE_JUNIOR_TRANCHE.selector, ""));
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnFailedAccountantInitialization() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "FAILED_ACCOUNTANT_INIT"));
        (MarketDeploymentParams memory params,) = _buildValidMarketParamsForSalt(salt);

        // Provide invalid (but non-empty) initialization data so the call to the accountant fails
        params.accountantInitializationData = abi.encodeWithSignature("nonExistentFunction(address)", address(this));

        vm.expectRevert(abi.encodeWithSelector(IRoycoFactory.FAILED_TO_INITIALIZE_ACCOUNTANT.selector, ""));
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnFailedKernelInitialization() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "FAILED_KERNEL_INIT"));
        (MarketDeploymentParams memory params,) = _buildValidMarketParamsForSalt(salt);

        // Provide invalid (but non-empty) initialization data so the call to the kernel fails
        params.kernelInitializationData = abi.encodeWithSignature("nonExistentFunction(address)", address(this));

        vm.expectRevert(abi.encodeWithSelector(IRoycoFactory.FAILED_TO_INITIALIZE_KERNEL.selector, ""));
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidAccessManager() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_ACCESS_MANAGER"));
        (MarketDeploymentParams memory params, bytes32 marketId) = _buildValidMarketParamsForSalt(salt);

        // Rebuild only the senior tranche initialization data with an invalid authority
        address expectedKernelAddress = FACTORY.predictERC1967ProxyAddress(address(KERNEL_IMPL), salt);

        params.seniorTrancheInitializationData = abi.encodeCall(
            ST_IMPL.initialize,
            (
                TrancheDeploymentParams({ name: SENIOR_TRANCHE_NAME, symbol: SENIOR_TRANCHE_SYMBOL, kernel: expectedKernelAddress }),
                ETHEREUM_MAINNET_USDC_ADDRESS,
                OWNER_ADDRESS, // invalid authority: must be FACTORY
                marketId
            )
        );

        vm.expectRevert(IRoycoFactory.INVALID_ACCESS_MANAGER.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidAccessManagerForAccountant() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_ACCESS_MANAGER_ACCOUNTANT"));
        (MarketDeploymentParams memory params,) = _buildValidMarketParamsForSalt(salt);

        // Rebuild only the accountant initialization data with an invalid authority
        address expectedKernelAddress = FACTORY.predictERC1967ProxyAddress(address(KERNEL_IMPL), salt);

        params.accountantInitializationData = abi.encodeCall(
            RoycoAccountant.initialize,
            (
                IRoycoAccountant.RoycoAccountantInitParams({
                    kernel: expectedKernelAddress,
                    stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
                    jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
                    coverageWAD: COVERAGE_WAD,
                    betaWAD: BETA_WAD,
                    ydm: address(YDM),
                    ydmInitializationData: abi.encodeCall(AdaptiveCurveYDM_V1.initializeYDMForMarket, (0.225e18, 1e18)),
                    fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
                    lltvWAD: LLTV,
                    stNAVDustTolerance: toNAVUnits(uint256(10 ** 21)), // 10^(18-6) for USDC
                    jtNAVDustTolerance: toNAVUnits(uint256(10 ** 21)) // 10^(18-6) for USDC
                }),
                OWNER_ADDRESS // invalid authority: must be FACTORY
            )
        );

        vm.expectRevert(IRoycoFactory.INVALID_ACCESS_MANAGER.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidAccessManagerForKernel() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_ACCESS_MANAGER_KERNEL"));
        (MarketDeploymentParams memory params,) = _buildValidMarketParamsForSalt(salt);

        // Rebuild only the kernel initialization data with an invalid authority
        address expectedAccountantAddress = FACTORY.predictERC1967ProxyAddress(address(ACCOUNTANT_IMPL), salt);

        params.kernelInitializationData = abi.encodeCall(
            ERC4626_ST_AaveV3_JT_InKindAssets_Kernel.initialize,
            (RoycoKernelInitParams({
                    initialAuthority: OWNER_ADDRESS,
                    accountant: expectedAccountantAddress,
                    protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS,
                    jtRedemptionDelayInSeconds: JT_REDEMPTION_DELAY_SECONDS
                }))
        );

        vm.expectRevert(IRoycoFactory.INVALID_ACCESS_MANAGER.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidAccessManagerForJuniorTranche() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_ACCESS_MANAGER_JT"));
        (MarketDeploymentParams memory params, bytes32 marketId) = _buildValidMarketParamsForSalt(salt);

        // Rebuild only the junior tranche initialization data with an invalid authority
        address expectedKernelAddress = FACTORY.predictERC1967ProxyAddress(address(KERNEL_IMPL), salt);

        params.juniorTrancheInitializationData = abi.encodeCall(
            JT_IMPL.initialize,
            (
                TrancheDeploymentParams({ name: JUNIOR_TRANCHE_NAME, symbol: JUNIOR_TRANCHE_SYMBOL, kernel: expectedKernelAddress }),
                ETHEREUM_MAINNET_USDC_ADDRESS,
                OWNER_ADDRESS, // invalid authority: must be FACTORY
                marketId
            )
        );

        vm.expectRevert(IRoycoFactory.INVALID_ACCESS_MANAGER.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidKernelOnSeniorTranche() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_KERNEL_ST"));
        (MarketDeploymentParams memory params, bytes32 marketId) = _buildValidMarketParamsForSalt(salt);

        // Use an previously deployed kernel address in the senior tranche initialization params
        // This should revert as the call with deploy a new kernel and check against that
        address wrongKernelAddress = address(KERNEL);

        params.seniorTrancheInitializationData = abi.encodeCall(
            ST_IMPL.initialize,
            (
                TrancheDeploymentParams({ name: SENIOR_TRANCHE_NAME, symbol: SENIOR_TRANCHE_SYMBOL, kernel: wrongKernelAddress }),
                ETHEREUM_MAINNET_USDC_ADDRESS,
                address(FACTORY),
                marketId
            )
        );

        // The deployment should revert due to inconsistent senior tranche kernel wiring
        vm.expectRevert(IRoycoFactory.INVALID_KERNEL_ON_SENIOR_TRANCHE.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidKernelOnJuniorTranche() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_KERNEL_JT"));
        (MarketDeploymentParams memory params, bytes32 marketId) = _buildValidMarketParamsForSalt(salt);

        // Use an previously deployed kernel address in the junior tranche initialization params
        // This should revert as the call with deploy a new kernel and check against that
        address wrongKernelAddress = address(KERNEL);

        params.juniorTrancheInitializationData = abi.encodeCall(
            JT_IMPL.initialize,
            (
                TrancheDeploymentParams({ name: JUNIOR_TRANCHE_NAME, symbol: JUNIOR_TRANCHE_SYMBOL, kernel: wrongKernelAddress }),
                ETHEREUM_MAINNET_USDC_ADDRESS,
                address(FACTORY),
                marketId
            )
        );

        // The deployment should revert due to inconsistent junior tranche kernel wiring
        vm.expectRevert(IRoycoFactory.INVALID_KERNEL_ON_JUNIOR_TRANCHE.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidAccountantOnKernel() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_ACCOUNTANT_ON_KERNEL"));
        (MarketDeploymentParams memory params,) = _buildValidMarketParamsForSalt(salt);

        // Use an incorrect accountant address in the kernel initialization params
        params.kernelInitializationData = abi.encodeCall(
            ERC4626_ST_AaveV3_JT_InKindAssets_Kernel.initialize,
            (RoycoKernelInitParams({
                    initialAuthority: address(FACTORY),
                    accountant: address(0xdead), // wrong accountant
                    protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS,
                    jtRedemptionDelayInSeconds: JT_REDEMPTION_DELAY_SECONDS
                }))
        );

        vm.expectRevert(IRoycoFactory.INVALID_ACCOUNTANT_ON_KERNEL.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidKernelOnAccountant() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_KERNEL_ON_ACCOUNTANT"));
        (MarketDeploymentParams memory params,) = _buildValidMarketParamsForSalt(salt);

        // Use an incorrect kernel address in the accountant initialization params
        params.accountantInitializationData = abi.encodeCall(
            RoycoAccountant.initialize,
            (
                IRoycoAccountant.RoycoAccountantInitParams({
                    kernel: address(0xdead), // wrong kernel
                    stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
                    jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
                    coverageWAD: COVERAGE_WAD,
                    betaWAD: BETA_WAD,
                    ydm: address(YDM),
                    ydmInitializationData: abi.encodeCall(AdaptiveCurveYDM_V1.initializeYDMForMarket, (0.225e18, 1e18)),
                    fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
                    lltvWAD: LLTV,
                    stNAVDustTolerance: toNAVUnits(uint256(10 ** 21)), // 10^(18-6) for USDC
                    jtNAVDustTolerance: toNAVUnits(uint256(10 ** 21)) // 10^(18-6) for USDC
                }),
                address(FACTORY)
            )
        );

        vm.expectRevert(IRoycoFactory.INVALID_KERNEL_ON_ACCOUNTANT.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnRolesTargetConfigurationLengthMismatch() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "ROLES_LENGTH_MISMATCH"));
        (MarketDeploymentParams memory params,) = _buildValidMarketParamsForSalt(salt);

        // Create a roles configuration with mismatched lengths
        RolesTargetConfiguration[] memory roles = new RolesTargetConfiguration[](1);
        bytes4[] memory selectors = new bytes4[](2);
        uint64[] memory rolesArray = new uint64[](1); // Different length!

        selectors[0] = IRoycoAuth.pause.selector;
        selectors[1] = IRoycoAuth.unpause.selector;
        rolesArray[0] = ADMIN_PAUSER_ROLE;

        roles[0] = RolesTargetConfiguration({
            target: params.roles[0].target, // Use a valid target
            selectors: selectors,
            roles: rolesArray
        });

        params.roles = roles;

        vm.expectRevert(IRoycoFactory.ROLES_CONFIGURATION_LENGTH_MISMATCH.selector);
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidTarget() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_TARGET"));
        (MarketDeploymentParams memory params,) = _buildValidMarketParamsForSalt(salt);

        // Create a roles configuration with an invalid target (not one of the deployed contracts)
        RolesTargetConfiguration[] memory roles = new RolesTargetConfiguration[](1);
        bytes4[] memory selectors = new bytes4[](1);
        uint64[] memory rolesArray = new uint64[](1);

        selectors[0] = IRoycoAuth.pause.selector;
        rolesArray[0] = ADMIN_PAUSER_ROLE;

        roles[0] = RolesTargetConfiguration({
            target: address(0xdead), // Invalid target - not one of the deployed contracts
            selectors: selectors,
            roles: rolesArray
        });

        params.roles = roles;

        vm.expectRevert(abi.encodeWithSelector(IRoycoFactory.INVALID_TARGET.selector, address(0xdead)));
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidTargetForRandomAddress() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_TARGET_RANDOM"));
        (MarketDeploymentParams memory params,) = _buildValidMarketParamsForSalt(salt);

        // Create a roles configuration with an invalid target
        RolesTargetConfiguration[] memory roles = new RolesTargetConfiguration[](1);
        bytes4[] memory selectors = new bytes4[](1);
        uint64[] memory rolesArray = new uint64[](1);

        selectors[0] = IRoycoAuth.pause.selector;
        rolesArray[0] = ADMIN_PAUSER_ROLE;

        address invalidTarget = address(0x1234567890123456789012345678901234567890);
        roles[0] = RolesTargetConfiguration({
            target: invalidTarget, // Invalid target - not one of the deployed contracts
            selectors: selectors,
            roles: rolesArray
        });

        params.roles = roles;

        vm.expectRevert(abi.encodeWithSelector(IRoycoFactory.INVALID_TARGET.selector, invalidTarget));
        vm.prank(DEPLOYER_ADDRESS);
        FACTORY.deployMarket(params);
    }

    /// @dev Helper to construct a valid set of market deployment params that mirrors `_deployMarketWithKernel`
    /// @dev Uses a default salt; useful for tests that only hit parameter validation
    function _buildValidMarketParams() internal view returns (MarketDeploymentParams memory params, bytes32 marketId, bytes32 salt) {
        salt = keccak256(abi.encodePacked("SALT"));
        (params, marketId) = _buildValidMarketParamsForSalt(salt);
    }

    /// @dev Helper to construct a valid set of market deployment params for a specific salt
    /// @dev Use this when you need to actually deploy contracts (to avoid Create2 collisions)
    function _buildValidMarketParamsForSalt(bytes32 salt) internal view returns (MarketDeploymentParams memory params, bytes32 marketId) {
        marketId = keccak256(abi.encodePacked(SENIOR_TRANCHE_NAME, JUNIOR_TRANCHE_NAME, vm.getBlockTimestamp()));

        // Precompute the expected addresses of the kernel and accountant
        address expectedSeniorTrancheAddress = FACTORY.predictERC1967ProxyAddress(address(ST_IMPL), salt);
        address expectedJuniorTrancheAddress = FACTORY.predictERC1967ProxyAddress(address(JT_IMPL), salt);
        address expectedKernelAddress = FACTORY.predictERC1967ProxyAddress(address(KERNEL_IMPL), salt);
        address expectedAccountantAddress = FACTORY.predictERC1967ProxyAddress(address(ACCOUNTANT_IMPL), salt);

        // Create the initialization data
        bytes memory kernelInitializationData = abi.encodeCall(
            ERC4626_ST_AaveV3_JT_InKindAssets_Kernel.initialize,
            (RoycoKernelInitParams({
                    initialAuthority: address(FACTORY),
                    accountant: expectedAccountantAddress,
                    protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS,
                    jtRedemptionDelayInSeconds: JT_REDEMPTION_DELAY_SECONDS
                }))
        );
        bytes memory accountantInitializationData = abi.encodeCall(
            RoycoAccountant.initialize,
            (
                IRoycoAccountant.RoycoAccountantInitParams({
                    kernel: expectedKernelAddress,
                    stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
                    jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
                    coverageWAD: COVERAGE_WAD,
                    betaWAD: BETA_WAD,
                    ydm: address(YDM),
                    ydmInitializationData: abi.encodeCall(AdaptiveCurveYDM_V1.initializeYDMForMarket, (0.225e18, 1e18)),
                    fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
                    lltvWAD: LLTV,
                    stNAVDustTolerance: toNAVUnits(uint256(10 ** 21)), // 10^(18-6) for USDC
                    jtNAVDustTolerance: toNAVUnits(uint256(10 ** 21)) // 10^(18-6) for USDC
                }),
                address(FACTORY)
            )
        );
        bytes memory seniorTrancheInitializationData = abi.encodeCall(
            ST_IMPL.initialize,
            (
                TrancheDeploymentParams({ name: SENIOR_TRANCHE_NAME, symbol: SENIOR_TRANCHE_SYMBOL, kernel: expectedKernelAddress }),
                ETHEREUM_MAINNET_USDC_ADDRESS,
                address(FACTORY),
                marketId
            )
        );
        bytes memory juniorTrancheInitializationData = abi.encodeCall(
            JT_IMPL.initialize,
            (
                TrancheDeploymentParams({ name: JUNIOR_TRANCHE_NAME, symbol: JUNIOR_TRANCHE_SYMBOL, kernel: expectedKernelAddress }),
                ETHEREUM_MAINNET_USDC_ADDRESS,
                address(FACTORY),
                marketId
            )
        );

        params = MarketDeploymentParams({
            seniorTrancheName: SENIOR_TRANCHE_NAME,
            seniorTrancheSymbol: SENIOR_TRANCHE_SYMBOL,
            juniorTrancheName: JUNIOR_TRANCHE_NAME,
            juniorTrancheSymbol: JUNIOR_TRANCHE_SYMBOL,
            marketId: marketId,
            seniorTrancheImplementation: ST_IMPL,
            juniorTrancheImplementation: JT_IMPL,
            kernelImplementation: IRoycoKernel(address(KERNEL_IMPL)),
            seniorTrancheInitializationData: seniorTrancheInitializationData,
            juniorTrancheInitializationData: juniorTrancheInitializationData,
            accountantImplementation: IRoycoAccountant(address(ACCOUNTANT_IMPL)),
            kernelInitializationData: kernelInitializationData,
            accountantInitializationData: accountantInitializationData,
            seniorTrancheProxyDeploymentSalt: salt,
            juniorTrancheProxyDeploymentSalt: salt,
            kernelProxyDeploymentSalt: salt,
            accountantProxyDeploymentSalt: salt,
            roles: DEPLOY_SCRIPT.buildRolesTargetConfiguration(
                expectedSeniorTrancheAddress, expectedJuniorTrancheAddress, expectedKernelAddress, expectedAccountantAddress
            )
        });
    }
}
