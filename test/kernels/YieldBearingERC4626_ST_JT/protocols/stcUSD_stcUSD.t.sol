// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { YieldBearingERC4626_TestBase } from "../base/YieldBearingERC4626_TestBase.t.sol";

/// @title stcUSD_stcUSD_Test
/// @notice Tests YieldBearingERC4626 kernel with stcUSD vault on Ethereum mainnet
/// @dev Both ST and JT use stcUSD as the tranche asset
///
/// stcUSD is an ERC4626 vault where:
///   - Tranche Unit: stcUSD shares
///   - Vault Asset: cUSD (the underlying)
///   - NAV Unit: USD
/// The stored conversion rate is vaultAsset-to-NAV (cUSD->USD), hardcoded at 1:1.
contract stcUSD_stcUSD_Test is YieldBearingERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice stcUSD vault on Ethereum mainnet
    address internal constant STCUSD = 0x88887bE419578051FF9F4eb6C858A951921D8888;

    /// @notice cUSD (underlying asset) on Ethereum mainnet
    /// @dev Referenced for documentation; the vault's asset() returns this
    address internal constant CUSD = 0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the protocol configuration for stcUSD
    function getProtocolConfig() public pure override returns (ProtocolConfig memory) {
        return ProtocolConfig({
            name: "stcUSD",
            forkBlock: 24_372_719,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: STCUSD,
            jtAsset: STCUSD,
            stDecimals: 18,
            jtDecimals: 18,
            initialFunding: 1_000_000e18 // 1M stcUSD
        });
    }

    /// @notice Returns the initial cUSD->USD conversion rate (in WAD precision)
    /// @dev Hardcoded at 1:1, so we return WAD (1e18)
    function _getInitialConversionRate() internal pure override returns (uint256) {
        return WAD; // 1:1 cUSD to USD
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for stcUSD
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12)); // Tolerance for 18 decimal token
    }

    /// @notice Returns max NAV delta for stcUSD
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // stcUSD-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the stcUSD vault is correctly configured
    function test_stcUSD_vaultConfiguration() external view {
        // Verify underlying asset is cUSD
        address underlying = IERC4626(STCUSD).asset();
        assertEq(underlying, CUSD, "stcUSD underlying should be cUSD");

        // Verify decimals
        uint8 decimals = IERC4626(STCUSD).decimals();
        assertEq(decimals, 18, "stcUSD should have 18 decimals");

        // Verify the vault has a valid share price
        uint256 sharePrice = IERC4626(STCUSD).convertToAssets(1e18);
        assertGt(sharePrice, 0, "stcUSD share price should be > 0");
    }

    /// @notice Verifies initial conversion rate is set correctly
    function test_stcUSD_initialConversionRate() external view {
        uint256 storedRate = _getConversionRate();
        assertEq(storedRate, WAD, "Stored rate should be WAD (1:1 for stablecoin)");
    }

    /// @notice Test that simulated yield works correctly for stcUSD
    function testFuzz_stcUSD_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _yieldBps = bound(_yieldBps, 10, 1000); // 0.1% to 10% yield

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        // Simulate yield by increasing the cUSD->USD rate
        uint256 yieldWAD = _yieldBps * 1e14;
        simulateJTYield(yieldWAD);

        uint256 rateAfter = _getConversionRate();
        assertGt(rateAfter, rateBefore, "Rate should increase after yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    /// @notice Test loss simulation for stcUSD
    function testFuzz_stcUSD_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
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

    /// @notice Test vault share price yield affects NAV
    function testFuzz_stcUSD_vaultSharePriceYield(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 2);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after vault share price yield");
    }
}
