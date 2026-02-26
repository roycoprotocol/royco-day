// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { DeploymentConfig } from "../../../../script/config/DeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { YieldBearingERC20Chainlink_TestBase } from "../base/YieldBearingERC20Chainlink_TestBase.t.sol";

/// @dev Concrete instantiation of DeploymentConfig so it can be used via composition
contract MfOneDeploymentConfig is DeploymentConfig { }

/// @title MfOne_Test
/// @notice Tests IdenticalAssetsChainlinkToAdminOracleQuoter_Kernel with Midas Fasanara ONE (mF-ONE)
/// @dev Both ST and JT use mF-ONE as the tranche asset
///
/// mF-ONE is a yield-bearing ERC20 token where:
///   - Tranche Unit: mF-ONE tokens (18 decimals)
///   - Reference Asset: intermediate reference priced by chainlink oracle
///   - NAV Unit: USD
/// The chainlink oracle provides mF-ONE -> reference asset price.
/// The stored conversion rate provides reference asset -> USD price (initialized at 1:1).
contract MfOne_Test is YieldBearingERC20Chainlink_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice mF-ONE token on Ethereum mainnet
    address internal constant MFONE_TOKEN = 0x238a700eD6165261Cf8b2e544ba797BC11e466Ba;

    /// @notice Chainlink oracle for mF-ONE pricing
    address internal constant MFONE_CHAINLINK_ORACLE = 0x8D51DBC85cEef637c97D02bdaAbb5E274850e68C;

    /// @notice Fork block for deterministic testing
    uint256 internal constant FORK_BLOCK = 24_543_000;

    /// @notice Deployment config instance for reading market parameters
    MfOneDeploymentConfig internal deploymentConfig;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the protocol configuration for mF-ONE
    function getProtocolConfig() public pure override returns (ProtocolConfig memory) {
        return ProtocolConfig({
            name: "mF-ONE",
            forkBlock: FORK_BLOCK,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: MFONE_TOKEN,
            jtAsset: MFONE_TOKEN,
            initialFunding: 1_000_000e18 // 1M mF-ONE
        });
    }

    /// @notice Returns the chainlink oracle address for mF-ONE
    function _getChainlinkOracle() internal pure override returns (address) {
        return MFONE_CHAINLINK_ORACLE;
    }

    /// @notice Returns the staleness threshold for the chainlink oracle
    /// @dev Use max threshold for testing since we mock the oracle after initial read
    function _getStalenessThreshold() internal pure override returns (uint48) {
        return type(uint48).max;
    }

    /// @notice Returns the initial reference-asset-to-NAV conversion rate
    /// @dev 1:1 conversion (WAD) as configured in DeploymentConfig
    function _getInitialConversionRate() internal pure override returns (uint256) {
        return 1e18;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUNDING OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deals ST asset (mF-ONE) to an address using forge's deal cheatcode
    function dealSTAsset(address _to, uint256 _amount) public override {
        deal(MFONE_TOKEN, _to, _amount);
    }

    /// @notice Deals JT asset (mF-ONE) to an address using forge's deal cheatcode
    function dealJTAsset(address _to, uint256 _amount) public override {
        deal(MFONE_TOKEN, _to, _amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for mF-ONE (18 decimals)
    /// @dev Higher tolerance due to chainlink oracle rounding
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e8));
    }

    /// @notice Returns max NAV delta for mF-ONE
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses DeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the mF-ONE kernel and market using parameters from DeploymentConfig
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        // Instantiate the deployment config to access market parameters
        deploymentConfig = new MfOneDeploymentConfig();
        DeploymentConfig.MarketDeploymentConfig memory mfOneConfig = deploymentConfig.getMarketConfig("mF-ONE ");

        // Store the chainlink oracle address for mocking
        chainlinkOracle = _getChainlinkOracle();

        // Mock the chainlink oracle before deployment for consistent pricing
        (, int256 initialPrice,,,) = AggregatorV3Interface(chainlinkOracle).latestRoundData();
        _mockChainlinkPrice(initialPrice);

        // Decode kernel-specific params from the deployment config
        DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams memory kernelParams =
            abi.decode(mfOneConfig.kernelSpecificParams, (DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams));

        // Override staleness threshold for testing
        kernelParams.stalenessThresholdSeconds = _getStalenessThreshold();

        // Decode YDM params from the deployment config
        DeployScript.AdaptiveCurveYDM_V2_Params memory ydmParams = abi.decode(mfOneConfig.ydmSpecificParams, (DeployScript.AdaptiveCurveYDM_V2_Params));

        // Build role assignments
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        DeployScript.DeploymentParams memory params = DeployScript.DeploymentParams({
            factoryAdmin: OWNER_ADDRESS,
            seniorTrancheName: mfOneConfig.seniorTrancheName,
            seniorTrancheSymbol: mfOneConfig.seniorTrancheSymbol,
            juniorTrancheName: mfOneConfig.juniorTrancheName,
            juniorTrancheSymbol: mfOneConfig.juniorTrancheSymbol,
            seniorAsset: mfOneConfig.seniorAsset,
            juniorAsset: mfOneConfig.juniorAsset,
            stNAVDustTolerance: toNAVUnits(mfOneConfig.stDustTolerance),
            jtNAVDustTolerance: toNAVUnits(mfOneConfig.jtDustTolerance),
            kernelType: mfOneConfig.kernelType,
            kernelSpecificParams: abi.encode(kernelParams),
            stSelfLiquidationBonusWAD: mfOneConfig.stSelfLiquidationBonusWAD,
            protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS,
            stProtocolFeeWAD: mfOneConfig.stProtocolFeeWAD,
            jtProtocolFeeWAD: mfOneConfig.jtProtocolFeeWAD,
            jtYieldShareProtocolFeeWAD: mfOneConfig.jtYieldShareProtocolFeeWAD,
            coverageWAD: mfOneConfig.coverageWAD,
            betaWAD: mfOneConfig.betaWAD,
            lltvWAD: mfOneConfig.lltvWAD,
            fixedTermDurationSeconds: mfOneConfig.fixedTermDurationSeconds,
            ydmType: mfOneConfig.ydmType,
            ydmSpecificParams: abi.encode(ydmParams),
            roleAssignments: roleAssignments
        });

        return DEPLOY_SCRIPT.deploy(params, DEPLOYER.privateKey);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // mF-ONE-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the mF-ONE token is correctly configured
    function test_mfOne_tokenConfiguration() external view {
        uint8 decimals = IERC20Metadata(MFONE_TOKEN).decimals();
        assertEq(decimals, 18, "mF-ONE should have 18 decimals");
    }

    /// @notice Verifies that the chainlink oracle is correctly configured
    function test_mfOne_chainlinkOracleConfiguration() external view {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = AggregatorV3Interface(MFONE_CHAINLINK_ORACLE).latestRoundData();

        assertGt(answer, 0, "Oracle should return positive price");
        assertGt(updatedAt, 0, "Oracle should have valid updatedAt timestamp");
        assertGe(answeredInRound, roundId, "answeredInRound should be >= roundId");
    }

    /// @notice Verifies initial conversion rate is set correctly from deployment config
    function test_mfOne_initialConversionRate() external view {
        uint256 storedRate = _getStoredConversionRate();
        assertEq(storedRate, 1e18, "Stored rate should be WAD (1:1)");
    }
}
