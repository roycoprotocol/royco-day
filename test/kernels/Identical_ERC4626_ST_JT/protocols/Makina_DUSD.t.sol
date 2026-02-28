// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { DeploymentConfig } from "../../../../script/config/DeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { IMachine } from "../../../../src/interfaces/external/makina/IMachine.sol";
import { Identical_Makina_ST_Makina_JT_Kernel } from "../../../../src/kernels/Identical_Makina_ST_Makina_JT_Kernel.sol";
import { WAD, WAD_DECIMALS } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { YieldBearingERC4626_TestBase } from "../base/YieldBearingERC4626_TestBase.t.sol";

/// @title Makina_DUSD_Test
/// @notice Tests Identical_Makina_ST_Makina_JT_Kernel with Makina's DUSD
/// @dev Both ST and JT use DUSD (Makina machine shares) as the tranche asset
///
/// DUSD is a Makina machine share where:
///   - Tranche Unit: DUSD shares (Makina machine shares)
///   - Accounting Asset: USDC (the underlying)
///   - NAV Unit: USD
/// The quoter uses IMachine.convertToAssets() for share-to-accounting-asset conversion,
/// and an admin-set rate for accounting-asset-to-NAV (USDC->USD), which is ~1:1 for stablecoins.
contract Makina_DUSD_Test is YieldBearingERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice DUSD on Ethereum mainnet
    address internal constant DUSD = 0x1e33E98aF620F1D563fcD3cfd3C75acE841204ef;

    /// @notice Makina machine for DUSD
    address internal constant MAKINA_MACHINE = 0x6b006870C83b1Cd49E766Ac9209f8d68763Df721;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for DUSD
    function getTestConfig() public pure override returns (TestConfig memory) {
        return
            TestConfig({
                forkBlock: 24_532_268,
                forkRpcUrlEnvVar: "MAINNET_RPC_URL",
                stAsset: DUSD,
                jtAsset: DUSD,
                initialFunding: 1_000_000_000e18 // 1B DUSD
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

    /// @notice Deploys the DUSD kernel and market using parameters from DeploymentConfig
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        DeploymentConfig.MarketDeploymentConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("MakinaDUSD");

        // Override initial conversion rate for testing
        marketConfig.kernelSpecificParams = abi.encode(
            DeployScript.IdenticalMakinaSTMakinaJTKernelParams({
                makinaMachine: 0x6b006870C83b1Cd49E766Ac9209f8d68763Df721, initialConversionRateWAD: _getInitialConversionRate()
            })
        );

        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        return DEPLOY_SCRIPT.deploy(marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, roleAssignments, DEPLOYER.privateKey);
    }

    // NOTE: simulateVaultSharePriceYield() and simulateVaultSharePriceLoss() are inherited from
    // YieldBearingERC4626_TestBase and work correctly because they call the overridden internal
    // functions _getCurrentSharePriceWAD() and _mockConvertToAssets() below.

    /// @notice Computes the share amount to pass to convertToAssets() to get WAD-scaled output
    /// @dev This matches the kernel's MACHINE_SHARES_TO_CONVERT_TO_ASSETS calculation
    function _getSharesToConvertToAssets() internal view override returns (uint256) {
        return 10 ** (WAD_DECIMALS + IERC20Metadata(config.stAsset).decimals() - IERC20Metadata(IMachine(MAKINA_MACHINE).accountingToken()).decimals());
    }

    /// @notice Gets the current share price (either mocked or from the actual Makina machine)
    /// @return The share price in WAD precision
    function _getCurrentSharePriceWAD() internal view override returns (uint256) {
        if (mockedSharePriceWAD != 0) {
            return mockedSharePriceWAD;
        }
        // Get the actual share price from the Makina machine using the same input the kernel uses
        return IMachine(MAKINA_MACHINE).convertToAssets(_getSharesToConvertToAssets());
    }

    /// @notice Mocks the convertToAssets function on the Makina machine
    /// @param _newSharePriceWAD The new share price in WAD precision
    function _mockConvertToAssets(uint256 _newSharePriceWAD) internal override {
        mockedSharePriceWAD = _newSharePriceWAD;

        // Mock convertToAssets on the Makina machine with the same input the kernel uses
        uint256 sharesToConvert = _getSharesToConvertToAssets();
        vm.mockCall(MAKINA_MACHINE, abi.encodeWithSelector(IMachine.convertToAssets.selector, sharesToConvert), abi.encode(_newSharePriceWAD));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for DUSD (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(3e12)); // 0.000003 DUSD tolerance
    }

    /// @notice Returns max NAV delta for DUSD
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONVERSION RATE OVERRIDES (use Makina kernel instead of ERC4626 kernel)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the current conversion rate using the Makina kernel's getter (in WAD precision)
    function _getConversionRate() internal view override returns (uint256) {
        return Identical_Makina_ST_Makina_JT_Kernel(address(KERNEL)).getStoredConversionRateWAD();
    }

    /// @notice Sets the conversion rate using the Makina kernel's setter (in WAD precision)
    /// @dev Requires ADMIN_ORACLE_QUOTER_ROLE, which is granted to ORACLE_QUOTER_ADMIN_ADDRESS
    function _setConversionRate(uint256 _newRateWAD) internal override {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        Identical_Makina_ST_Makina_JT_Kernel(address(KERNEL)).setConversionRate(_newRateWAD);
    }
}
