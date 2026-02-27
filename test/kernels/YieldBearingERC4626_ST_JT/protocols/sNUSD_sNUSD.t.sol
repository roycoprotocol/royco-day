// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { DeploymentConfig } from "../../../../script/config/DeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { YieldBearingERC4626_TestBase } from "../base/YieldBearingERC4626_TestBase.t.sol";

/// @title sNUSD_sNUSD_Test
/// @notice Tests YieldBearingERC4626_ST_YieldBearingERC4626_JT_IdenticalERC4626SharesAdminOracleQuoter_Kernel with sNUSD
/// @dev Both ST and JT use sNUSD as the tranche asset
///
/// sNUSD is an ERC4626 vault where:
///   - Tranche Unit: sNUSD shares
///   - Vault Asset: NUSD (the underlying)
///   - NAV Unit: USD
/// The stored conversion rate is vaultAsset-to-NAV (NUSD->USD), which is ~1:1 for stablecoins.
contract sNUSD_sNUSD_Test is YieldBearingERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice sNUSD on Ethereum mainnet
    address internal constant SNUSD = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for sNUSD
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 24_180_513,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: SNUSD,
            jtAsset: SNUSD,
            initialFunding: 1_000_000_000e18 // 1B sNUSD
        });
    }

    /// @notice Returns the initial NUSD->USD conversion rate (in WAD precision)
    /// @dev For NUSD (a stablecoin), this is 1:1, so we return WAD (1e18)
    function _getInitialConversionRate() internal pure override returns (uint256) {
        return WAD; // 1:1 NUSD to USD
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses DeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the sNUSD kernel and market using parameters from DeploymentConfig
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        DeploymentConfig.MarketDeploymentConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("sNUSD");

        // Override initial conversion rate for testing
        marketConfig.kernelSpecificParams =
            abi.encode(DeployScript.IdenticalERC4626SharesAdminOracleQuoterKernelParams({ initialConversionRateWAD: _getInitialConversionRate() }));

        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        return DEPLOY_SCRIPT.deploy(marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, roleAssignments, DEPLOYER.privateKey);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for sNUSD (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12)); // 0.000001 sNUSD tolerance
    }

    /// @notice Returns max NAV delta for sNUSD
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // sNUSD-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the sNUSD vault is correctly configured
    function test_sNUSD_vaultConfiguration() external view {
        // Verify decimals
        uint8 decimals = IERC4626(SNUSD).decimals();
        assertEq(decimals, 18, "sNUSD should have 18 decimals");

        // Verify the vault has a valid share price
        uint256 sharePrice = IERC4626(SNUSD).convertToAssets(1e18);
        assertGe(sharePrice, 1e18, "sNUSD share price should be >= 1:1");
    }

    /// @notice Verifies initial conversion rate is set correctly
    function test_sNUSD_initialConversionRate() external view {
        uint256 storedRate = _getConversionRate();

        // The stored rate is the NUSD->USD rate in WAD precision
        // For a stablecoin, this should be 1e18 (1:1)
        assertEq(storedRate, WAD, "Stored rate should be WAD (1:1 for stablecoin)");
    }

    /// @notice Test that simulated yield works correctly for sNUSD
    function testFuzz_sNUSD_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e18, 100_000e18); // 1 to 100k sNUSD
        _yieldBps = bound(_yieldBps, 10, 1000); // 0.1% to 10% yield

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        // Simulate yield by increasing the NUSD->USD rate
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

    /// @notice Test loss simulation for sNUSD
    function testFuzz_sNUSD_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _lossBps = bound(_lossBps, 10, 500); // 0.1% to 5% loss

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        // Simulate loss by decreasing the NUSD->USD rate
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
}
