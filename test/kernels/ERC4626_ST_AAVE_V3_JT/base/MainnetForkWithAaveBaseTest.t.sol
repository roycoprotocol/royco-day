// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../../../lib/forge-std/src/Vm.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { DeployScript } from "../../../../script/Deploy.s.sol";
import { WAD_DECIMALS } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import { BaseTest } from "../../../base/BaseTest.t.sol";
import { ERC4626Mock } from "../../../mock/ERC4626Mock.sol";

abstract contract MainnetForkWithAaveTestBase is BaseTest {
    /// @dev Maximum absolute delta for tranche unit comparisons (accounts for Aave rounding)
    TRANCHE_UNIT internal AAVE_MAX_ABS_TRANCHE_UNIT_DELTA = toTrancheUnits(3);
    /// @dev NAV delta scaled to WAD precision. For USDC (6 decimals): scale factor = 10^(WAD_DECIMALS - 6) = 10^21
    NAV_UNIT internal AAVE_MAX_ABS_NAV_DELTA = toNAVUnits(toUint256(AAVE_MAX_ABS_TRANCHE_UNIT_DELTA) * 10 ** (WAD_DECIMALS - 6));
    uint256 internal constant MAX_REDEEM_RELATIVE_DELTA = 1 * BPS;
    uint256 internal constant MAX_CONVERT_TO_ASSETS_RELATIVE_DELTA = 1 * BPS;
    uint256 internal constant AAVE_PREVIEW_DEPOSIT_RELATIVE_DELTA = 1 * BPS;
    uint24 internal constant JT_REDEMPTION_DELAY_SECONDS = 1_000_000;

    Vm.Wallet internal RESERVE;
    address internal RESERVE_ADDRESS;

    // Deployed contracts
    ERC4626Mock internal MOCK_UNDERLYING_ST_VAULT;

    // External Contracts
    IERC20 internal USDC;
    IERC20 internal AUSDC;

    constructor() {
        BETA_WAD = 0; // Different opportunities
        USDC = IERC20(ETHEREUM_MAINNET_USDC_ADDRESS);
        AUSDC = IERC20(aTokenAddresses[1][ETHEREUM_MAINNET_USDC_ADDRESS]);
    }

    function _setUpRoyco() internal override {
        // Setup wallets
        RESERVE = vm.createWallet("RESERVE");
        RESERVE_ADDRESS = RESERVE.addr;
        vm.label(RESERVE_ADDRESS, "RESERVE");

        // Deploy core
        super._setUpRoyco();
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

        // Setup providers and assets
        _setupProviders();
        _setupAssets(10_000_000_000);

        // Deal USDC to all configured addresses for mainnet fork tests
        _dealUSDCToAddresses();
    }

    /// @notice Deals USDC tokens to all configured addresses for mainnet fork tests
    /// @dev Each address receives 10M USDC (10_000_000e6) to ensure sufficient balance for testing
    function _dealUSDCToAddresses() internal {
        uint256 usdcAmount = 10_000_000e6; // 10M USDC (6 decimals)

        // Deal to admin/role addresses
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, OWNER_ADDRESS, usdcAmount);
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, PAUSER_ADDRESS, usdcAmount);
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, UPGRADER_ADDRESS, usdcAmount);
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, usdcAmount);

        // Deal to provider addresses
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, ALICE_ADDRESS, usdcAmount);
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, BOB_ADDRESS, usdcAmount);
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, CHARLIE_ADDRESS, usdcAmount);
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, DAN_ADDRESS, usdcAmount);

        // Deal to reserve address
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, RESERVE_ADDRESS, usdcAmount);
    }

    function _deployMarketWithKernel() internal returns (DeployScript.DeploymentResult memory) {
        bytes32 marketID = keccak256(abi.encodePacked(SENIOR_TRANCHE_NAME, JUNIOR_TRANCHE_NAME, vm.getBlockTimestamp()));

        // Build kernel-specific params
        DeployScript.ERC4626STAaveV3JTInKindAssetsKernelParams memory kernelParams = DeployScript.ERC4626STAaveV3JTInKindAssetsKernelParams({
            stVault: address(MOCK_UNDERLYING_ST_VAULT), aaveV3Pool: ETHEREUM_MAINNET_AAVE_V3_POOL_ADDRESS
        });

        // Build YDM params (AdaptiveCurve)
        DeployScript.AdaptiveCurveYDMParams memory ydmParams =
            DeployScript.AdaptiveCurveYDMParams({ jtYieldShareAtTargetUtilWAD: 0.225e18, jtYieldShareAtFullUtilWAD: 1e18 });

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
            baseAsset: ETHEREUM_MAINNET_USDC_ADDRESS,
            seniorAsset: ETHEREUM_MAINNET_USDC_ADDRESS,
            juniorAsset: ETHEREUM_MAINNET_USDC_ADDRESS,
            stNAVDustTolerance: toNAVUnits(uint256(10 ** 12)), // 10^(18-6) for USDC
            jtNAVDustTolerance: toNAVUnits(uint256(10 ** 12)), // 10^(18-6) for USDC
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
    /// @return forkBlock The fork block
    /// @return forkRpcUrl The fork RPC URL
    function _forkConfiguration() internal override returns (uint256 forkBlock, string memory forkRpcUrl) {
        forkBlock = 24_290_290;
        forkRpcUrl = vm.envString("MAINNET_RPC_URL");
        if (bytes(forkRpcUrl).length == 0) {
            fail("MAINNET_RPC_URL environment variable is not set");
        }
    }

    /// @notice Generates a provider address for the mainnet fork with Aave test base
    /// @param _index The index of the provider
    /// @return provider The provider wallet
    function _generateProvider(uint256 _index) internal virtual override returns (Vm.Wallet memory provider) {
        provider = super._generateProvider(_index);

        // Fund the provider with 10M USDC
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, provider.addr, 10_000_000e6);
    }
}
