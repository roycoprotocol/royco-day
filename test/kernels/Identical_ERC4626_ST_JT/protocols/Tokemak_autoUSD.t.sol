// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { DeploymentConfig } from "../../../../script/config/DeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { YieldBearingERC4626_TestBase } from "../base/YieldBearingERC4626_TestBase.t.sol";

/// @title Tokemak_autoUSD_Test
/// @notice Tests YieldBearingERC4626_ST_YieldBearingERC4626_JT_Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel with Tokemak autoUSD
/// @dev Both ST and JT use autoUSD as the tranche asset on Ethereum mainnet
///
/// autoUSD is Tokemak's ERC4626 autopool vault where:
///   - Tranche Unit: autoUSD shares
///   - Vault Asset: USDC (the underlying)
///   - NAV Unit: USD
/// The stored conversion rate is vaultAsset-to-NAV (USDC->USD), which is ~1:1 for stablecoins.
contract Tokemak_autoUSD_Test is YieldBearingERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tokemak autoUSD on Ethereum mainnet
    address internal constant AUTO_USD = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for autoUSD
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 24_261_516,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: AUTO_USD,
            jtAsset: AUTO_USD,
            initialFunding: 1_000_000e18 // 1M autoUSD
        });
    }

    /// @notice Returns the initial USDC->USD conversion rate (in WAD precision)
    /// @dev For USDC (a stablecoin), this is 1:1, so we return WAD (1e18)
    function _getInitialConversionRate() internal pure override returns (uint256) {
        return WAD; // 1:1 USDC to USD
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses DeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the autoUSD kernel and market using parameters from DeploymentConfig
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        DeploymentConfig.MarketDeploymentConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("autoUSD");

        // Override initial conversion rate for testing
        marketConfig.kernelSpecificParams =
            abi.encode(DeployScript.IdenticalERC4626SharesToAdminOracleQuoterKernelParams({ initialConversionRateWAD: _getInitialConversionRate() }));

        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        return DEPLOY_SCRIPT.deploy(marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, roleAssignments, DEPLOYER.privateKey);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for autoUSD (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12)); // 0.000001 autoUSD tolerance
    }

    /// @notice Returns max NAV delta for autoUSD
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // autoUSD-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the autoUSD vault is correctly configured
    function test_autoUSD_vaultConfiguration() external view {
        // Verify decimals
        uint8 decimals = IERC4626(AUTO_USD).decimals();
        assertEq(decimals, 18, "autoUSD should have 18 decimals");

        // Verify the vault has a valid share price
        uint256 sharePrice = IERC4626(AUTO_USD).convertToAssets(1e18);
        assertGt(sharePrice, 0, "autoUSD share price should be > 0");
    }

    /// @notice Verifies initial conversion rate is set correctly
    function test_autoUSD_initialConversionRate() external view {
        uint256 storedRate = _getConversionRate();

        // The stored rate is the USDC->USD rate in WAD precision
        // For a stablecoin, this should be 1e18 (1:1)
        assertEq(storedRate, WAD, "Stored rate should be WAD (1:1 for stablecoin)");
    }

    /// @notice Test that simulated yield works correctly for autoUSD
    function testFuzz_autoUSD_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e18, 100_000e18); // 1 to 100k autoUSD
        _yieldBps = bound(_yieldBps, 10, 1000); // 0.1% to 10% yield

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        // Simulate yield by increasing the USDC->USD rate
        uint256 yieldWAD = _yieldBps * 1e14; // Convert bps to WAD
        simulateJTYield(yieldWAD);

        uint256 rateAfter = _getConversionRate();
        assertGt(rateAfter, rateBefore, "Rate should increase after yield");

        // Sync accounting
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    /// @notice Test loss simulation for autoUSD
    function testFuzz_autoUSD_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _lossBps = bound(_lossBps, 10, 500); // 0.1% to 5% loss

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        // Simulate loss by decreasing the USDC->USD rate
        uint256 lossWAD = _lossBps * 1e14;
        simulateJTLoss(lossWAD);

        uint256 rateAfter = _getConversionRate();
        assertLt(rateAfter, rateBefore, "Rate should decrease after loss");

        // Sync accounting
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after loss");
    }

    /// @notice Test that autoUSD vault share price changes affect NAV correctly
    function testFuzz_autoUSD_vaultSharePriceYield(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 20); // 1-20% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate vault share price yield (mocks convertToAssets)
        simulateVaultSharePriceYield(_yieldPercentage * 1e16); // Convert to WAD

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after vault share price yield");
    }
}
