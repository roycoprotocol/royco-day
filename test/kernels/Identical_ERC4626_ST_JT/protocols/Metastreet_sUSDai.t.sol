// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { DeploymentConfig } from "../../../../script/config/DeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { IStakedUSDai } from "../../../../src/interfaces/external/usdai/IStakedUSDai.sol";
import { IUSDai } from "../../../../src/interfaces/external/usdai/IUSDai.sol";
import { sUSDai_ST_sUSDai_JT_Kernel } from "../../../../src/kernels/sUSDai_ST_sUSDai_JT_Kernel.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";

import { YieldBearingERC4626_TestBase } from "../base/YieldBearingERC4626_TestBase.t.sol";

/// @title Metastreet_sUSDai_Test
/// @notice Tests sUSDai_ST_sUSDai_JT_Kernel with Metastreet's sUSDai on Arbitrum
/// @dev Both ST and JT use sUSDai (Staked USDai) as the tranche asset
///
/// sUSDai is a yield-bearing staked token where:
///   - Tranche Unit: sUSDai shares
///   - Accounting Asset: USDai (the underlying stablecoin)
///   - NAV Unit: USD
/// The quoter uses IStakedUSDai.redemptionSharePrice() for share-to-USDai conversion,
/// and an admin-set rate for USDai-to-USD (which is ~1:1 for stablecoins).
contract Metastreet_sUSDai_Test is YieldBearingERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // ARBITRUM ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice sUSDai on Arbitrum
    address internal constant SUSDAI = 0x0B2b2B2076d95dda7817e785989fE353fe955ef9;

    /// @notice USDai address (fetched from sUSDai.asset() in setUp)
    address internal USDAI;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for sUSDai
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 438_062_279,
            forkRpcUrlEnvVar: "ARBITRUM_RPC_URL",
            stAsset: SUSDAI,
            jtAsset: SUSDAI,
            initialFunding: 1_000_000_000e18 // 1B sUSDai
        });
    }

    /// @notice Returns the initial USDai->USD conversion rate (in WAD precision)
    /// @dev For USDai (a stablecoin), this is 1:1, so we return WAD (1e18)
    function _getInitialConversionRate() internal pure override returns (uint256) {
        return WAD; // 1:1 USDai to USD
    }

    /// @notice Additional setup to fetch USDai address
    function setUp() public virtual override {
        super.setUp();
        USDAI = IStakedUSDai(SUSDAI).asset();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses DeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the sUSDai kernel and market using parameters from DeploymentConfig
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        DeploymentConfig.MarketDeploymentConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("sUSDai");

        // Override initial conversion rate for testing
        marketConfig.kernelSpecificParams =
            abi.encode(DeployScript.IdenticalAssetsAdminOracleQuoterKernelParams({ initialConversionRateWAD: _getInitialConversionRate() }));

        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        return DEPLOY_SCRIPT.deploy(marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, roleAssignments, DEPLOYER.privateKey);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SHARE PRICE MOCKING (sUSDai redemptionSharePrice)
    // ═══════════════════════════════════════════════════════════════════════════

    // NOTE: simulateVaultSharePriceYield() and simulateVaultSharePriceLoss() are inherited from
    // YieldBearingERC4626_TestBase and work correctly because they call the overridden internal
    // functions _getCurrentSharePriceWAD() and _mockConvertToAssets() below.

    /// @notice sUSDai uses redemptionSharePrice() which returns WAD-scaled output directly
    /// @dev No need to compute shares to convert - redemptionSharePrice() returns the rate directly
    function _getSharesToConvertToAssets() internal pure override returns (uint256) {
        return WAD; // redemptionSharePrice() returns the price of 1 sUSDai in USDai (WAD-scaled)
    }

    /// @notice Gets the current share price (either mocked or from the actual sUSDai contract)
    /// @return The share price in WAD precision (sUSDai -> USDai rate)
    function _getCurrentSharePriceWAD() internal view override returns (uint256) {
        if (mockedSharePriceWAD != 0) {
            return mockedSharePriceWAD;
        }
        // Get the actual redemption share price from sUSDai
        return IStakedUSDai(SUSDAI).redemptionSharePrice();
    }

    /// @notice Mocks the redemptionSharePrice function on sUSDai
    /// @param _newSharePriceWAD The new share price in WAD precision
    function _mockConvertToAssets(uint256 _newSharePriceWAD) internal override {
        mockedSharePriceWAD = _newSharePriceWAD;

        // Mock redemptionSharePrice on sUSDai
        vm.mockCall(SUSDAI, abi.encodeWithSelector(IStakedUSDai.redemptionSharePrice.selector), abi.encode(_newSharePriceWAD));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for sUSDai (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(3e12)); // 0.000003 sUSDai tolerance
    }

    /// @notice Returns max NAV delta for sUSDai
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONVERSION RATE OVERRIDES (use sUSDai kernel)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the current conversion rate using the sUSDai kernel's getter (in WAD precision)
    function _getConversionRate() internal view override returns (uint256) {
        return sUSDai_ST_sUSDai_JT_Kernel(address(KERNEL)).getStoredConversionRateWAD();
    }

    /// @notice Sets the conversion rate using the sUSDai kernel's setter (in WAD precision)
    /// @dev Requires ADMIN_ORACLE_QUOTER_ROLE, which is granted to ORACLE_QUOTER_ADMIN_ADDRESS
    function _setConversionRate(uint256 _newRateWAD) internal override {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        sUSDai_ST_sUSDai_JT_Kernel(address(KERNEL)).setConversionRate(_newRateWAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // sUSDai-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that sUSDai is correctly configured
    function test_sUSDai_configuration() external view {
        // Verify asset() returns USDai
        address asset = IStakedUSDai(SUSDAI).asset();
        assertTrue(asset != address(0), "sUSDai asset (USDai) should not be zero");

        // Verify the contract has a valid redemption share price
        uint256 sharePrice = IStakedUSDai(SUSDAI).redemptionSharePrice();
        assertGt(sharePrice, 0, "sUSDai redemption share price should be > 0");
    }

    /// @notice Verifies the kernel's USDAI immutable is set correctly
    function test_sUSDai_kernelConfiguration() external view {
        address kernelUsdai = sUSDai_ST_sUSDai_JT_Kernel(address(KERNEL)).USDAI();
        assertEq(kernelUsdai, USDAI, "Kernel's USDAI should match expected");
    }

    /// @notice Verifies initial conversion rate is set correctly
    function test_sUSDai_initialConversionRate() external view {
        uint256 storedRate = _getConversionRate();
        assertEq(storedRate, WAD, "Stored rate should be WAD (1:1 for stablecoin)");
    }

    /// @notice Test that simulated yield works correctly for sUSDai
    function testFuzz_sUSDai_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, _minDepositAmount(), config.initialFunding / 10);
        _yieldBps = bound(_yieldBps, 10, 1000); // 0.1% to 10% yield

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        // Simulate yield by increasing the USDai->USD rate
        uint256 yieldWAD = _yieldBps * 1e14;
        simulateJTYield(yieldWAD);

        uint256 rateAfter = _getConversionRate();
        assertGt(rateAfter, rateBefore, "Rate should increase after yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    /// @notice Test loss simulation for sUSDai
    function testFuzz_sUSDai_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, _minDepositAmount(), config.initialFunding / 10);
        _lossBps = bound(_lossBps, 10, 500); // 0.1% to 5% loss

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        uint256 lossWAD = _lossBps * 1e14;
        simulateJTLoss(lossWAD);

        uint256 rateAfter = _getConversionRate();
        assertLt(rateAfter, rateBefore, "Rate should decrease after loss");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after loss");
    }

    /// @notice Test sUSDai redemption share price yield affects NAV
    function testFuzz_sUSDai_redemptionSharePriceYield(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after sUSDai redemption share price yield");
    }

    /// @notice Test sUSDai redemption share price loss affects NAV
    function testFuzz_sUSDai_redemptionSharePriceLoss(uint256 _jtAmount, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossPercentage = bound(_lossPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        simulateVaultSharePriceLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after sUSDai redemption share price loss");
    }

    /// @notice Test combined yield: both redemption share price AND stored rate increase
    function testFuzz_sUSDai_combinedYield_bothComponents(uint256 _jtAmount, uint256 _sharePriceYieldBps, uint256 _rateYieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _sharePriceYieldBps = bound(_sharePriceYieldBps, 10, 500); // 0.1% to 5%
        _rateYieldBps = bound(_rateYieldBps, 10, 500); // 0.1% to 5%

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Apply both yields
        simulateVaultSharePriceYield(_sharePriceYieldBps * 1e14);
        _simulateYield(_rateYieldBps * 1e14);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after combined yield");
    }

    /// @notice Test that getTrancheUnitToNAVUnitConversionRateWAD returns expected value
    function test_sUSDai_conversionRateCalculation() external view {
        uint256 redemptionSharePriceWAD = IStakedUSDai(SUSDAI).redemptionSharePrice();
        uint256 storedRateWAD = _getConversionRate();

        uint256 expectedConversionRate = (redemptionSharePriceWAD * storedRateWAD) / WAD;
        uint256 actualConversionRate = sUSDai_ST_sUSDai_JT_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();

        assertEq(actualConversionRate, expectedConversionRate, "Conversion rate should equal redemptionSharePrice * storedRate / WAD");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BLACKLIST TESTS (sUSDai-specific)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that the kernel checks blacklist status via USDai
    /// @dev We verify the kernel's USDAI address is correctly set and the isBlacklisted function exists
    function test_sUSDai_blacklistIntegration() external view {
        // Verify kernel has correct USDai address
        address kernelUsdai = sUSDai_ST_sUSDai_JT_Kernel(address(KERNEL)).USDAI();
        assertEq(kernelUsdai, USDAI, "Kernel's USDAI should match expected");

        // Verify USDai has isBlacklisted function (will not revert if it exists)
        // On a real blacklisted account, this would return true
        bool isBlacklisted = IUSDai(USDAI).isBlacklisted(address(0));
        assertFalse(isBlacklisted, "Zero address should not be blacklisted");
    }

    /// @notice Test that non-blacklisted accounts can deposit and redeem normally
    function test_sUSDai_nonBlacklistedAccount_canDepositAndRedeem() external {
        uint256 amount = _minDepositAmount();

        // Deposit should succeed (ALICE is not blacklisted on the fork)
        _depositJT(ALICE_ADDRESS, amount);

        uint256 shares = JT.balanceOf(ALICE_ADDRESS);
        assertGt(shares, 0, "Should have received shares");

        // Redeem should succeed
        vm.prank(ALICE_ADDRESS);
        JT.redeem(shares, ALICE_ADDRESS, ALICE_ADDRESS);
    }
}
