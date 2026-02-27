// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { DeploymentConfig } from "../../../../script/config/DeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { YieldBearingERC4626_TestBase } from "../base/YieldBearingERC4626_TestBase.t.sol";

/// @title Morpho_SmokehouseUSDC_Test
/// @notice Tests YieldBearingERC4626_ST_YieldBearingERC4626_JT_Identical_ERC4626_ST_ERC4626_JT_Kernel with Morpho's SmokehouseUSDC
/// @dev Both ST and JT use SmokehouseUSDC vault shares as the tranche asset
///
/// SmokehouseUSDC is an ERC4626 vault where:
///   - Tranche Unit: SmokehouseUSDC shares
///   - Vault Asset: USDC (the underlying)
///   - NAV Unit: USD
/// The stored conversion rate is vaultAsset-to-NAV (USDC->USD), which is ~1:1 for stablecoins.
contract MorphoV1_SmokehouseUSDC is YieldBearingERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice SmokehouseUSDC on Ethereum mainnet
    address internal constant SmokehouseUSDC = 0xBEeFFF209270748ddd194831b3fa287a5386f5bC;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for SmokehouseUSDC
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 24_532_268,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: SmokehouseUSDC,
            jtAsset: SmokehouseUSDC,
            initialFunding: 1_000_000_000e18 // 1B SmokehouseUSDC
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

    /// @notice Deploys the SmokehouseUSDC kernel and market using parameters from DeploymentConfig
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        DeploymentConfig.MarketDeploymentConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("SmokehouseUSDC");

        // Override initial conversion rate for testing
        marketConfig.kernelSpecificParams =
            abi.encode(DeployScript.IdenticalERC4626SharesAdminOracleQuoterKernelParams({ initialConversionRateWAD: _getInitialConversionRate() }));

        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        return DEPLOY_SCRIPT.deploy(marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, roleAssignments, DEPLOYER.privateKey);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for SmokehouseUSDC (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(3e12)); // 0.000003 SmokehouseUSDC tolerance
    }

    /// @notice Returns max NAV delta for SmokehouseUSDC
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }
}
