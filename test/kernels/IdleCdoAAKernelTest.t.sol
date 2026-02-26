// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { DeployScript } from "../../script/Deploy.s.sol";
import { IRoycoFactory } from "../../src/interfaces/IRoycoFactory.sol";
import { IIdleCDO } from "../../src/interfaces/external/idle-finance/IIdleCDO.sol";
import { IdleCdoAA_ST_IdleCdoAA_JT_Kernel } from "../../src/kernels/IdleCdoAA_ST_IdleCdoAA_JT_Kernel.sol";
import { IdenticalAssetsOracleQuoter } from "../../src/kernels/base/quoter/base/IdenticalAssetsOracleQuoter.sol";
import { WAD, WAD_DECIMALS, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../src/libraries/Constants.sol";
import { AssetClaims } from "../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toNAVUnits, toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { AbstractKernelTestSuite } from "./abstract/AbstractKernelTestSuite.t.sol";

/// @title IdleCdoAAKernelTest
/// @notice Test suite for IdleCdoAA_ST_IdleCdoAA_JT_Kernel inheriting from AbstractKernelTestSuite
/// @dev Tests against Pareto's Falconx Prime Brokerage Vault on Ethereum mainnet
contract IdleCdoAAKernelTest is AbstractKernelTestSuite {
    using Math for uint256;
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS - Idle CDO Configuration (Pareto Falconx)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev IdleCDO contract address (Pareto Falconx Prime Brokerage Vault)
    address internal constant IDLE_CDO = 0x433D5B175148dA32Ffe1e1A37a939E1b7e79be4d;

    /// @dev AA Tranche token address (the asset for both ST and JT)
    address internal constant AA_TRANCHE_TOKEN = 0xC26A6Fa2C37b38E549a4a1807543801Db684f99C;

    /// @dev Whale address holding AA tranche tokens for funding test accounts
    address internal constant AA_TRANCHE_WHALE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    /// @dev JT redemption delay for tests
    uint24 internal constant LOCAL_JT_REDEMPTION_DELAY_SECONDS = 7 days;

    /// @dev Fork block for mainnet
    uint256 internal constant FORK_BLOCK = 24_187_000;

    /// @dev AA tranche token decimals (18 for Pareto AA tranche)
    uint8 internal constant AA_TRANCHE_DECIMALS = 18;

    /// @dev Scale factor to convert from AA tranche token decimals to WAD precision
    uint256 internal constant SCALE_FACTOR = 10 ** (WAD_DECIMALS - 6);

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    IERC20 internal AA_TRANCHE;
    IIdleCDO internal CDO;

    /// @dev Tracks the mocked virtual price (0 means use real CDO value)
    uint256 internal mockedVirtualPrice;

    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT KERNEL TEST SUITE - Required Implementations
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc AbstractKernelTestSuite
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        // Initialize external contracts before deployment
        AA_TRANCHE = IERC20(AA_TRANCHE_TOKEN);
        CDO = IIdleCDO(IDLE_CDO);

        bytes32 marketID = keccak256(abi.encodePacked(SENIOR_TRANCHE_NAME, JUNIOR_TRANCHE_NAME, vm.getBlockTimestamp()));

        // Build kernel-specific params
        DeployScript.IdleCdoAASTIdleCdoAAJTKernelParams memory kernelParams = DeployScript.IdleCdoAASTIdleCdoAAJTKernelParams({ idleCDO: IDLE_CDO });

        // Build YDM params (AdaptiveCurve)
        DeployScript.AdaptiveCurveYDM_V2_Params memory ydmParams = DeployScript.AdaptiveCurveYDM_V2_Params({
            jtYieldShareAtZeroUtilWAD: 0.225e18, // Y_0 = Y_T (same as target)
            jtYieldShareAtTargetUtilWAD: 0.225e18,
            jtYieldShareAtFullUtilWAD: 1e18,
            maxAdaptationSpeedWAD: uint64(30e18 / uint256(365 days))
        });

        // Build role assignments using the centralized function
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        // Build deployment params
        DeployScript.DeploymentParams memory params = DeployScript.DeploymentParams({
            factoryAdmin: OWNER_ADDRESS,
            seniorTrancheName: SENIOR_TRANCHE_NAME,
            seniorTrancheSymbol: SENIOR_TRANCHE_SYMBOL,
            juniorTrancheName: JUNIOR_TRANCHE_NAME,
            juniorTrancheSymbol: JUNIOR_TRANCHE_SYMBOL,
            seniorAsset: AA_TRANCHE_TOKEN,
            juniorAsset: AA_TRANCHE_TOKEN,
            stNAVDustTolerance: toNAVUnits(SCALE_FACTOR),
            jtNAVDustTolerance: toNAVUnits(SCALE_FACTOR),
            kernelType: DeployScript.KernelType.IdleCdoAA_ST_IdleCdoAA_JT,
            stSelfLiquidationBonusWAD: 0,
            kernelSpecificParams: abi.encode(kernelParams),
            protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS,
            stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
            jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            jtYieldShareProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            coverageWAD: COVERAGE_WAD,
            betaWAD: BETA_WAD,
            lltvWAD: LLTV,
            fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(ydmParams),
            roleAssignments: roleAssignments
        });

        // Deploy using the deployment script
        return DEPLOY_SCRIPT.deploy(params, DEPLOYER.privateKey);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IKernelTestHooks - Required Implementations
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc AbstractKernelTestSuite
    function getProtocolConfig() public pure override returns (ProtocolConfig memory) {
        return ProtocolConfig({
            name: "IdleCdoAA_ST_IdleCdoAA_JT",
            forkBlock: FORK_BLOCK,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: AA_TRANCHE_TOKEN,
            jtAsset: AA_TRANCHE_TOKEN,
            stDecimals: AA_TRANCHE_DECIMALS,
            jtDecimals: AA_TRANCHE_DECIMALS,
            initialFunding: 800_000 * (10 ** AA_TRANCHE_DECIMALS)
        });
    }

    /// @notice Simulates yield generation for ST by mocking the IdleCDO virtualPrice
    /// @dev Mocks the virtualPrice function to return a higher value proportionally
    /// @param _percentageWAD The percentage yield to add in WAD format (e.g., 0.1e18 = 10% yield)
    function simulateSTYield(uint256 _percentageWAD) public override {
        _simulateVirtualPriceYield(_percentageWAD);
    }

    /// @notice Simulates yield generation for JT by mocking the IdleCDO virtualPrice
    /// @dev ST and JT share the same asset so this has the same effect as simulateSTYield
    /// @param _percentageWAD The percentage yield to add in WAD format (e.g., 0.1e18 = 10% yield)
    function simulateJTYield(uint256 _percentageWAD) public override {
        _simulateVirtualPriceYield(_percentageWAD);
    }

    /// @notice Simulates loss for ST by mocking the IdleCDO virtualPrice
    /// @dev Mocks the virtualPrice function to return a lower value proportionally
    /// @param _percentageWAD The percentage loss in WAD format (e.g., 0.1e18 = 10% loss)
    function simulateSTLoss(uint256 _percentageWAD) public override {
        _simulateVirtualPriceLoss(_percentageWAD);
    }

    /// @notice Simulates loss for JT by mocking the IdleCDO virtualPrice
    /// @dev ST and JT share the same asset so this has the same effect as simulateSTLoss
    /// @param _percentageWAD The percentage loss in WAD format (e.g., 0.1e18 = 10% loss)
    function simulateJTLoss(uint256 _percentageWAD) public override {
        _simulateVirtualPriceLoss(_percentageWAD);
    }

    /// @notice Deals ST asset (AA tranche tokens) to an address
    /// @param _to The address to deal tokens to
    /// @param _amount The amount to deal
    function dealSTAsset(address _to, uint256 _amount) public override {
        _dealAATrancheFromWhale(_to, _amount);
    }

    /// @notice Deals JT asset (AA tranche tokens) to an address
    /// @param _to The address to deal tokens to
    /// @param _amount The amount to deal
    function dealJTAsset(address _to, uint256 _amount) public override {
        _dealAATrancheFromWhale(_to, _amount);
    }

    /// @notice Returns the maximum delta tolerance for tranche unit comparisons
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(3);
    }

    /// @notice Returns the maximum delta tolerance for NAV comparisons
    function maxNAVDelta() public pure override returns (NAV_UNIT) {
        return toNAVUnits(3 * SCALE_FACTOR);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deals AA tranche tokens from whale to an address
    function _dealAATrancheFromWhale(address _to, uint256 _amount) internal {
        vm.prank(AA_TRANCHE_WHALE);
        AA_TRANCHE.transfer(_to, _amount);
    }

    /// @notice Gets the current virtual price (either mocked or from actual CDO)
    function _getCurrentVirtualPrice() internal view returns (uint256) {
        if (mockedVirtualPrice != 0) {
            return mockedVirtualPrice;
        }
        return CDO.virtualPrice(AA_TRANCHE_TOKEN);
    }

    /// @notice Mocks the IdleCDO virtualPrice function with a new value
    /// @param _newVirtualPrice The new virtual price to return
    function _mockVirtualPrice(uint256 _newVirtualPrice) internal {
        mockedVirtualPrice = _newVirtualPrice;
        vm.mockCall(IDLE_CDO, abi.encodeWithSelector(IIdleCDO.virtualPrice.selector, AA_TRANCHE_TOKEN), abi.encode(_newVirtualPrice));
    }

    /// @notice Simulates yield by increasing the virtual price proportionally
    /// @param _percentageWAD The percentage yield in WAD format (e.g., 0.1e18 = 10%)
    function _simulateVirtualPriceYield(uint256 _percentageWAD) internal {
        uint256 currentVirtualPrice = _getCurrentVirtualPrice();
        uint256 newVirtualPrice = currentVirtualPrice * (WAD + _percentageWAD) / WAD;
        _mockVirtualPrice(newVirtualPrice);
    }

    /// @notice Simulates loss by decreasing the virtual price proportionally
    /// @param _percentageWAD The percentage loss in WAD format (e.g., 0.1e18 = 10%)
    function _simulateVirtualPriceLoss(uint256 _percentageWAD) internal {
        uint256 currentVirtualPrice = _getCurrentVirtualPrice();
        // Ensure we don't underflow by capping loss at 100%
        uint256 lossFactor = _percentageWAD >= WAD ? 0 : WAD - _percentageWAD;
        uint256 newVirtualPrice = currentVirtualPrice * lossFactor / WAD;
        // Ensure virtual price never goes to 0
        if (newVirtualPrice == 0) newVirtualPrice = 1;
        _mockVirtualPrice(newVirtualPrice);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // KERNEL-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that kernel is deployed with correct CDO address
    function test_kernel_hasCorrectIdleCDOAddress() public view {
        IdleCdoAA_ST_IdleCdoAA_JT_Kernel kernel = IdleCdoAA_ST_IdleCdoAA_JT_Kernel(address(KERNEL));
        assertEq(kernel.IDLE_CDO(), IDLE_CDO, "Kernel should have correct IdleCDO address");
    }

    /// @notice Test that kernel has correct virtual price multiplier
    function test_kernel_hasCorrectVirtualPriceMultiplier() public view {
        IdleCdoAA_ST_IdleCdoAA_JT_Kernel kernel = IdleCdoAA_ST_IdleCdoAA_JT_Kernel(address(KERNEL));
        assertEq(kernel.IDLE_CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION(), SCALE_FACTOR, "Kernel should have correct virtual price multiplier");
    }

    /// @notice Test that ST and JT assets are both the AA tranche token
    function test_kernel_assetsAreAATranche() public view {
        assertEq(ST.asset(), AA_TRANCHE_TOKEN, "ST asset should be AA tranche token");
        assertEq(JT.asset(), AA_TRANCHE_TOKEN, "JT asset should be AA tranche token");
    }

    /// @notice Test that conversion rate matches IdleCDO virtual price
    function test_conversionRate_matchesIdleCDOVirtualPrice() public view {
        IdleCdoAA_ST_IdleCdoAA_JT_Kernel kernel = IdleCdoAA_ST_IdleCdoAA_JT_Kernel(address(KERNEL));

        // Get virtual price from CDO
        uint256 virtualPrice = CDO.virtualPrice(AA_TRANCHE_TOKEN);

        // Get conversion rate from kernel (should be virtualPrice * multiplier)
        uint256 expectedConversionRateWAD = virtualPrice * kernel.IDLE_CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION();

        // Convert 1 unit and check
        TRANCHE_UNIT oneUnit = toTrancheUnits(10 ** AA_TRANCHE_DECIMALS);
        NAV_UNIT navUnits = KERNEL.stConvertTrancheUnitsToNAVUnits(oneUnit);

        // NAV should equal expectedConversionRateWAD (since we're converting 1 full token)
        assertApproxEqRel(toUint256(navUnits), expectedConversionRateWAD, 0.001e18, "Conversion should match CDO virtual price");
    }

    /// @notice Test that ST and JT conversions are identical (same asset)
    function test_conversionRate_stAndJtIdentical() public view {
        TRANCHE_UNIT amount = toTrancheUnits(1000 * (10 ** AA_TRANCHE_DECIMALS));

        NAV_UNIT stNav = KERNEL.stConvertTrancheUnitsToNAVUnits(amount);
        NAV_UNIT jtNav = KERNEL.jtConvertTrancheUnitsToNAVUnits(amount);

        assertEq(stNav, jtNav, "ST and JT conversions must be identical");
    }

    /// @notice Test round-trip conversion preserves value
    function test_conversionRate_roundTripPreservesValue() public view {
        uint256[] memory testAmounts = new uint256[](4);
        testAmounts[0] = 1 * (10 ** AA_TRANCHE_DECIMALS); // 1 token
        testAmounts[1] = 100 * (10 ** AA_TRANCHE_DECIMALS); // 100 tokens
        testAmounts[2] = 10_000 * (10 ** AA_TRANCHE_DECIMALS); // 10K tokens
        testAmounts[3] = 1; // 1 wei (minimum)

        for (uint256 i = 0; i < testAmounts.length; i++) {
            TRANCHE_UNIT original = toTrancheUnits(testAmounts[i]);

            NAV_UNIT nav = KERNEL.stConvertTrancheUnitsToNAVUnits(original);
            TRANCHE_UNIT back = KERNEL.stConvertNAVUnitsToTrancheUnits(nav);

            assertApproxEqAbs(back, original, 1, "Round-trip conversion must preserve value");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN CONVERSION RATE OVERRIDE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that oracle quoter admin can override conversion rate
    function test_setConversionRate_adminCanOverride() public {
        // New conversion rate: 1.5 WAD (50% premium over 1:1)
        uint256 newConversionRateWAD = 1.5e18;

        // Set conversion rate as oracle quoter admin
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        IdenticalAssetsOracleQuoter(address(KERNEL)).setConversionRate(newConversionRateWAD);

        // Verify the stored rate is updated
        uint256 storedRate = IdenticalAssetsOracleQuoter(address(KERNEL)).getStoredConversionRateWAD();
        assertEq(storedRate, newConversionRateWAD, "Stored conversion rate should be updated");
    }

    /// @notice Test that overridden conversion rate is used in conversions
    function test_setConversionRate_usedInConversions() public {
        // Get initial conversion for 1 token
        TRANCHE_UNIT oneToken = toTrancheUnits(10 ** AA_TRANCHE_DECIMALS);
        NAV_UNIT initialNav = KERNEL.stConvertTrancheUnitsToNAVUnits(oneToken);

        // Set a new conversion rate: 2x the current virtual price
        uint256 virtualPrice = CDO.virtualPrice(AA_TRANCHE_TOKEN);
        uint256 newConversionRateWAD = virtualPrice * SCALE_FACTOR * 2;

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        IdenticalAssetsOracleQuoter(address(KERNEL)).setConversionRate(newConversionRateWAD);

        // Get new conversion for 1 token
        NAV_UNIT newNav = KERNEL.stConvertTrancheUnitsToNAVUnits(oneToken);

        // New NAV should be approximately 2x the initial NAV
        assertApproxEqRel(toUint256(newNav), toUint256(initialNav) * 2, 0.01e18, "Conversion should use overridden rate");
    }

    /// @notice Test that non-admin cannot override conversion rate
    function test_setConversionRate_revertsForNonAdmin() public {
        uint256 newConversionRateWAD = 1.5e18;

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert();
        IdenticalAssetsOracleQuoter(address(KERNEL)).setConversionRate(newConversionRateWAD);
    }

    /// @notice Test setting conversion rate to sentinel value resets to oracle
    function test_setConversionRate_sentinelResetsToOracle() public {
        // First override the rate
        uint256 overrideRate = 2e18;
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        IdenticalAssetsOracleQuoter(address(KERNEL)).setConversionRate(overrideRate);

        // Verify override is active
        TRANCHE_UNIT oneToken = toTrancheUnits(10 ** AA_TRANCHE_DECIMALS);
        NAV_UNIT overriddenNav = KERNEL.stConvertTrancheUnitsToNAVUnits(oneToken);

        // Reset to sentinel (0) to use oracle
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        IdenticalAssetsOracleQuoter(address(KERNEL)).setConversionRate(0);

        // Get NAV with oracle rate
        NAV_UNIT oracleNav = KERNEL.stConvertTrancheUnitsToNAVUnits(oneToken);

        // Oracle NAV should match CDO virtual price
        uint256 expectedNav = CDO.virtualPrice(AA_TRANCHE_TOKEN) * SCALE_FACTOR;
        assertApproxEqRel(toUint256(oracleNav), expectedNav, 0.001e18, "Should use oracle rate after reset");

        // Verify it's different from the override (unless by coincidence)
        assertTrue(toUint256(oracleNav) != toUint256(overriddenNav) || overrideRate == expectedNav, "Oracle rate should differ from override");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NAV CALCULATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that raw NAV reflects deposits correctly
    function test_rawNAV_reflectsDeposits() public {
        // Check initial NAV is zero
        assertEq(JT.getRawNAV(), ZERO_NAV_UNITS, "Initial JT NAV should be 0");

        // Deposit JT
        uint256 depositAmount = 10_000 * (10 ** AA_TRANCHE_DECIMALS);
        vm.startPrank(ALICE_ADDRESS);
        AA_TRANCHE.approve(address(JT), depositAmount);
        JT.deposit(toTrancheUnits(depositAmount), ALICE_ADDRESS);
        vm.stopPrank();

        // NAV should now be non-zero
        NAV_UNIT rawNAV = JT.getRawNAV();
        assertGt(rawNAV, ZERO_NAV_UNITS, "JT NAV should be > 0 after deposit");

        // NAV should approximately equal deposit * conversion rate
        uint256 expectedNAV = depositAmount * CDO.virtualPrice(AA_TRANCHE_TOKEN) * SCALE_FACTOR / (10 ** AA_TRANCHE_DECIMALS);
        assertApproxEqRel(toUint256(rawNAV), expectedNAV, 0.01e18, "NAV should match expected value");
    }

    /// @notice Test total assets claim structure
    function test_totalAssets_hasCorrectStructure() public {
        // Deposit JT
        uint256 depositAmount = 10_000 * (10 ** AA_TRANCHE_DECIMALS);
        vm.startPrank(ALICE_ADDRESS);
        AA_TRANCHE.approve(address(JT), depositAmount);
        JT.deposit(toTrancheUnits(depositAmount), ALICE_ADDRESS);
        vm.stopPrank();

        AssetClaims memory claims = JT.totalAssets();

        assertGt(claims.nav, ZERO_NAV_UNITS, "NAV should be > 0");
        // For identical assets kernel, JT assets should be non-zero
        assertGt(claims.jtAssets, ZERO_TRANCHE_UNITS, "JT assets should be > 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIRTUAL PRICE MOCKING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that simulated yield increases NAV proportionally
    function test_simulateYield_increasesNAV() public {
        // Deposit JT
        uint256 depositAmount = 10_000 * (10 ** AA_TRANCHE_DECIMALS);
        _depositJT(ALICE_ADDRESS, depositAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 virtualPriceBefore = _getCurrentVirtualPrice();

        // Simulate 10% yield
        _simulateVirtualPriceYield(0.1e18);

        uint256 virtualPriceAfter = _getCurrentVirtualPrice();
        assertGt(virtualPriceAfter, virtualPriceBefore, "Virtual price should increase after yield");

        // Sync accounting
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    /// @notice Test that simulated loss decreases NAV proportionally
    function test_simulateLoss_decreasesNAV() public {
        // Deposit JT
        uint256 depositAmount = 10_000 * (10 ** AA_TRANCHE_DECIMALS);
        _depositJT(ALICE_ADDRESS, depositAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 virtualPriceBefore = _getCurrentVirtualPrice();

        // Simulate 10% loss
        _simulateVirtualPriceLoss(0.1e18);

        uint256 virtualPriceAfter = _getCurrentVirtualPrice();
        assertLt(virtualPriceAfter, virtualPriceBefore, "Virtual price should decrease after loss");

        // Sync accounting
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after loss");
    }
}
