// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { DeployScript } from "../../../../script/Deploy.s.sol";
import { DeploymentConfig } from "../../../../script/config/DeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";
import { YieldBearingERC20Chainlink_TestBase } from "../base/YieldBearingERC20Chainlink_TestBase.t.sol";

/// @title PendlePTcUSD_Test
/// @notice Tests YieldBearingERC20_ST_YieldBearingERC20_JT_IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel with Pendle PT-cUSD
/// @dev Both ST and JT use PT-cUSD as the tranche asset
///
/// PT-cUSD (Pendle Principal Token for cUSD) is a yield-bearing ERC20 where:
///   - Tranche Unit: PT-cUSD tokens
///   - Reference Asset: SY-cUSD (standardized yield cUSD)
///   - NAV Unit: USD
/// The chainlink oracle provides PT-cUSD -> SY-cUSD price.
/// The stored conversion rate provides SY-cUSD -> USD price (which is ~1:1 for stablecoins).
contract PendlePTcUSD_Test is YieldBearingERC20Chainlink_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice PT-cUSD on Ethereum mainnet
    address internal constant PT_CUSD = 0x545A490f9ab534AdF409A2E682bc4098f49952e3;

    /// @notice Chainlink oracle for PT-cUSD/SY-cUSD price
    address internal constant PT_CUSD_CHAINLINK_ORACLE = 0x6DA10958c691454BE7eb5f3e3B91b5713e542b17;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the protocol configuration for PT-cUSD
    function getProtocolConfig() public pure override returns (ProtocolConfig memory) {
        return ProtocolConfig({
            name: "PT-cUSD",
            forkBlock: 24_344_233,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: PT_CUSD,
            jtAsset: PT_CUSD,
            initialFunding: 1_000_000e18 // 1M PT-cUSD
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the YieldBearingERC20 Chainlink kernel and market
    function _deployKernelAndMarket() internal virtual override returns (DeployScript.DeploymentResult memory) {
        ProtocolConfig memory cfg = getProtocolConfig();

        // Get initial conversion rate (reference asset to NAV, in WAD precision)
        uint256 initialConversionRate = _getInitialConversionRate();

        DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams memory kernelParams =
            DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams({
                trancheAssetToReferenceAssetOracle: _getChainlinkOracle(),
                stalenessThresholdSeconds: _getStalenessThreshold(),
                initialConversionRateWAD: initialConversionRate
            });

        DeployScript.AdaptiveCurveYDM_V2_Params memory ydmParams = DeployScript.AdaptiveCurveYDM_V2_Params({
            jtYieldShareAtZeroUtilWAD: 0.3e18, // Y_0 = Y_T (same as target)
            jtYieldShareAtTargetUtilWAD: 0.3e18, // 30% at target utilization
            jtYieldShareAtFullUtilWAD: 1e18, // 100% at 100% utilization
            maxAdaptationSpeedWAD: uint64(30e18 / uint256(365 days))
        });

        // Build role assignments using the centralized function
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        DeploymentConfig.MarketDeploymentConfig memory config = DeploymentConfig.MarketDeploymentConfig({
            marketName: cfg.name,
            chainId: block.chainid,
            seniorTrancheName: string(abi.encodePacked("Royco Senior ", cfg.name)),
            seniorTrancheSymbol: string(abi.encodePacked("RS-", cfg.name)),
            juniorTrancheName: string(abi.encodePacked("Royco Junior ", cfg.name)),
            juniorTrancheSymbol: string(abi.encodePacked("RJ-", cfg.name)),
            seniorAsset: cfg.stAsset,
            juniorAsset: cfg.jtAsset,
            stDustTolerance: 1,
            jtDustTolerance: 1,
            kernelType: DeployScript.KernelType.IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel,
            kernelSpecificParams: abi.encode(kernelParams),
            stSelfLiquidationBonusWAD: 0,
            stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
            jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            jtYieldShareProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            coverageWAD: COVERAGE_WAD,
            betaWAD: 1e18, // Beta = 1 for identical assets
            lltvWAD: LLTV,
            fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(ydmParams)
        });

        return DEPLOY_SCRIPT.deploy(config, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, roleAssignments, DEPLOYER.privateKey);
    }

    /// @notice Returns the chainlink oracle address for PT-cUSD
    function _getChainlinkOracle() internal pure override returns (address) {
        return PT_CUSD_CHAINLINK_ORACLE;
    }

    /// @notice Returns the staleness threshold for the chainlink oracle
    /// @dev Use a very long threshold for testing since we mock the oracle
    /// This avoids PRICE_STALE errors when tests warp time
    function _getStalenessThreshold() internal pure override returns (uint48) {
        return type(uint48).max;
    }

    /// @notice Returns the initial SY-cUSD->USD conversion rate
    /// @dev For SY-cUSD (a stablecoin derivative), this is approximately 1:1
    function _getInitialConversionRate() internal pure override returns (uint256) {
        return WAD;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for PT-cUSD (18 decimals)
    /// @dev Higher tolerance due to chainlink oracle rounding
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e8)); // 0.00000001 PT-cUSD tolerance for chainlink precision
    }

    /// @notice Returns max NAV delta for PT-cUSD
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PT-cUSD-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the PT-cUSD token is correctly configured
    function test_PTcUSD_tokenConfiguration() external view {
        // Verify decimals
        uint8 decimals = IERC20Metadata(PT_CUSD).decimals();
        assertEq(decimals, 18, "PT-cUSD should have 18 decimals");
    }

    /// @notice Verifies that the chainlink oracle is correctly configured
    function test_PTcUSD_chainlinkOracleConfiguration() external view {
        // Verify the oracle returns valid data
        (, int256 answer,,,) = AggregatorV3Interface(PT_CUSD_CHAINLINK_ORACLE).latestRoundData();

        // Oracle should return positive price
        assertGt(answer, 0, "Oracle should return positive price");
    }

    /// @notice Verifies initial conversion rate is set correctly
    function test_PTcUSD_initialConversionRate() external view {
        uint256 storedRate = _getStoredConversionRate();

        // The stored rate is the SY-cUSD->USD rate, scaled by WAD
        assertEq(storedRate, WAD, "Stored rate should be WAD (1:1 for stablecoin derivative)");
    }

    /// @notice Test that simulated yield via chainlink price works correctly for PT-cUSD
    function testFuzz_PTcUSD_simulatedChainlinkYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e18, 100_000e18); // 1 to 100k PT-cUSD
        _yieldBps = bound(_yieldBps, 10, 1000); // 0.1% to 10% yield

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate yield by increasing the chainlink price
        uint256 yieldWAD = _yieldBps * 1e14; // Convert bps to WAD
        simulateChainlinkPriceYield(yieldWAD);

        // Sync accounting
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after chainlink price yield");
    }

    /// @notice Test loss simulation via chainlink price for PT-cUSD
    function testFuzz_PTcUSD_simulatedChainlinkLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _lossBps = bound(_lossBps, 10, 500); // 0.1% to 5% loss

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate loss by decreasing the chainlink price
        uint256 lossWAD = _lossBps * 1e14;
        simulateChainlinkPriceLoss(lossWAD);

        // Sync accounting
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after chainlink price loss");
    }

    /// @notice Test that stored rate yield simulation works
    function testFuzz_PTcUSD_simulatedStoredRateYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _yieldBps = bound(_yieldBps, 10, 500); // 0.1% to 5% yield

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getStoredConversionRate();

        // Simulate yield by increasing the stored rate (SY-cUSD -> USD)
        uint256 yieldWAD = _yieldBps * 1e14;
        simulateStoredRateYield(yieldWAD);

        uint256 rateAfter = _getStoredConversionRate();
        assertGt(rateAfter, rateBefore, "Stored rate should increase after yield");

        // Sync accounting
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after stored rate yield");
    }

    /// @notice Test combined chainlink and stored rate yield
    function testFuzz_PTcUSD_combinedYield_increasesNAV(uint256 _amount, uint256 _chainlinkYieldBps, uint256 _storedRateYieldBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _chainlinkYieldBps = bound(_chainlinkYieldBps, 10, 500);
        _storedRateYieldBps = bound(_storedRateYieldBps, 10, 500);

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate both chainlink price yield and stored rate yield
        simulateChainlinkPriceYield(_chainlinkYieldBps * 1e14);
        simulateStoredRateYield(_storedRateYieldBps * 1e14);

        // Sync accounting
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after combined yield");
    }
}
