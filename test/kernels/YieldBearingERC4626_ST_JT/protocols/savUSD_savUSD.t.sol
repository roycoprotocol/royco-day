// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { YieldBearingERC4626_TestBase } from "../base/YieldBearingERC4626_TestBase.t.sol";

/// @title savUSD_savUSD_Test
/// @notice Tests YieldBearingERC4626_ST_YieldBearingERC4626_JT_IdenticalERC4626SharesAdminOracleQuoter_Kernel with sAVUSD
/// @dev Both ST and JT use sAVUSD as the tranche asset on Avalanche mainnet
///
/// sAVUSD is an ERC4626 vault where:
///   - Tranche Unit: sAVUSD shares
///   - Vault Asset: AVUSD (the underlying)
///   - NAV Unit: USD
/// The stored conversion rate is vaultAsset-to-NAV (AVUSD->USD), which is ~1:1 for stablecoins.
contract savUSD_savUSD_Test is YieldBearingERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // AVALANCHE MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice sAVUSD on Avalanche mainnet
    address internal constant SAVUSD = 0x06d47F3fb376649c3A9Dafe069B3D6E35572219E;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the protocol configuration for sAVUSD
    function getProtocolConfig() public pure override returns (ProtocolConfig memory) {
        return ProtocolConfig({
            name: "savUSD",
            forkBlock: 76_172_623,
            forkRpcUrlEnvVar: "AVALANCHE_RPC_URL",
            stAsset: SAVUSD,
            jtAsset: SAVUSD,
            initialFunding: 1_000_000e18 // 1M sAVUSD
        });
    }

    /// @notice Returns the initial AVUSD->USD conversion rate (in WAD precision)
    /// @dev For AVUSD (a stablecoin), this is 1:1, so we return WAD (1e18)
    function _getInitialConversionRate() internal pure override returns (uint256) {
        return WAD; // 1:1 AVUSD to USD
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for sAVUSD (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12)); // 0.000001 sAVUSD tolerance
    }

    /// @notice Returns max NAV delta for sAVUSD
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // sAVUSD-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the sAVUSD vault is correctly configured
    function test_sAVUSD_vaultConfiguration() external view {
        // Verify decimals
        uint8 decimals = IERC4626(SAVUSD).decimals();
        assertEq(decimals, 18, "sAVUSD should have 18 decimals");

        // Verify the vault has a valid share price
        uint256 sharePrice = IERC4626(SAVUSD).convertToAssets(1e18);
        assertGe(sharePrice, 1e18, "sAVUSD share price should be >= 1:1");
    }

    /// @notice Verifies initial conversion rate is set correctly
    function test_sAVUSD_initialConversionRate() external view {
        uint256 storedRate = _getConversionRate();

        // The stored rate is the AVUSD->USD rate in WAD precision
        // For a stablecoin, this should be 1e18 (1:1)
        assertEq(storedRate, WAD, "Stored rate should be WAD (1:1 for stablecoin)");
    }

    /// @notice Test that simulated yield works correctly for sAVUSD
    function testFuzz_sAVUSD_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e18, 100_000e18); // 1 to 100k sAVUSD
        _yieldBps = bound(_yieldBps, 10, 1000); // 0.1% to 10% yield

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        // Simulate yield by increasing the AVUSD->USD rate
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

    /// @notice Test loss simulation for sAVUSD
    function testFuzz_sAVUSD_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _lossBps = bound(_lossBps, 10, 500); // 0.1% to 5% loss

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        // Simulate loss by decreasing the AVUSD->USD rate
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
