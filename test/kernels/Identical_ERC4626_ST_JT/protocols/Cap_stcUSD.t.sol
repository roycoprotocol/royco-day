// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { FundamentalStablecoinChainlinkOracleDeploymentConfig } from "../../../../script/config/FundamentalStablecoinChainlinkOracleDeploymentConfig.sol";
import { MarketDeploymentConfig } from "../../../../script/config/MarketDeploymentConfig.sol";
import { DeployFundamentalStablecoinChainlinkOracleScript } from "../../../../script/independent/DeployFundamentalStablecoinChainlinkOracle.s.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { DisabledChainlinkOracle_ERC4626_TestBase } from "../base/DisabledChainlinkOracle_ERC4626_TestBase.t.sol";

/// @title stcUSD_stcUSD_Test
/// @notice Tests Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel with stcUSD (disabled oracle)
/// @dev Both ST and JT use stcUSD as the tranche asset on Ethereum mainnet
///
/// stcUSD is an ERC4626 vault where:
///   - Tranche Unit: stcUSD shares
///   - Vault Asset: cUSD (the underlying)
///   - NAV Unit: USD
/// The stored conversion rate is 1:1 (WAD), with the Chainlink oracle disabled (address(1)).
contract stcUSD_stcUSD_Test is DisabledChainlinkOracle_ERC4626_TestBase {
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

    /// @notice Returns the test configuration for stcUSD
    function getTestConfig() public pure override returns (TestConfig memory) {
        return
            TestConfig({
                forkBlock: 24_372_719,
                forkRpcUrlEnvVar: "MAINNET_RPC_URL",
                stAsset: STCUSD,
                jtAsset: STCUSD,
                initialFunding: 1_000_000e18 // 1M stcUSD
            });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the stcUSD kernel and market using parameters from MarketDeploymentConfig
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        MarketDeploymentConfig.MarketConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("stcUSD");

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        DeployFundamentalStablecoinChainlinkOracleScript ORACLE_DEPLOY_SCRIPT = new DeployFundamentalStablecoinChainlinkOracleScript();
        FundamentalStablecoinChainlinkOracleDeploymentConfig.OracleConfig memory oracleConfig =
            ORACLE_DEPLOY_SCRIPT.getOracleConfig(ORACLE_DEPLOY_SCRIPT.MAINNET_CUSD_USD());
        address cUSDOracle = ORACLE_DEPLOY_SCRIPT.deployOracle(oracleConfig.underlyingOracle, oracleConfig.minPegPrice, DEPLOYER.privateKey);

        marketConfig.kernelSpecificParams = abi.encode(
            DeployScript.IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams({
                initialConversionRateWAD: 1e18, baseAssetToNavAssetOracle: cUSDOracle, stalenessThresholdSeconds: 86_400
            })
        );

        return DEPLOY_SCRIPT.deploy(
            marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey
        );
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
        address underlying = IERC4626(STCUSD).asset();
        assertEq(underlying, CUSD, "stcUSD underlying should be cUSD");

        uint8 decimals = IERC4626(STCUSD).decimals();
        assertEq(decimals, 18, "stcUSD should have 18 decimals");

        uint256 sharePrice = IERC4626(STCUSD).convertToAssets(1e18);
        assertGt(sharePrice, 0, "stcUSD share price should be > 0");
    }

    /// @notice Verifies initial stored conversion rate is WAD (1:1 for stablecoin)
    function test_stcUSD_initialConversionRate() external view {
        uint256 storedRate = _getConversionRate();
        assertEq(storedRate, WAD, "Stored rate should be WAD (1:1 for stablecoin)");
    }

    /// @notice Test that simulated yield works correctly for stcUSD
    function testFuzz_stcUSD_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _yieldBps = bound(_yieldBps, 10, 1000);

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        uint256 yieldWAD = _yieldBps * 1e14;
        simulateJTYield(yieldWAD);

        uint256 rateAfter = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(rateAfter, rateBefore, "Rate should increase after yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    /// @notice Test loss simulation for stcUSD
    function testFuzz_stcUSD_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _lossBps = bound(_lossBps, 10, 500);

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        uint256 lossWAD = _lossBps * 1e14;
        simulateJTLoss(lossWAD);

        uint256 rateAfter = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertLt(rateAfter, rateBefore, "Rate should decrease after loss");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after loss");
    }

    /// @notice Test vault share price yield affects NAV
    function testFuzz_stcUSD_vaultSharePriceYield(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
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
