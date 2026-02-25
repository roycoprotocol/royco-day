// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DeployScript } from "../Deploy.s.sol";

/**
 * @title DeploymentConfig
 * @notice Single configuration contract for all deployment parameters
 */
abstract contract DeploymentConfig {
    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN IDs
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 internal constant MAINNET = 1;
    uint256 internal constant AVALANCHE = 43_114;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONTROLLING MULTISIG ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    address internal constant ROOT_MULTISIG_ETHEREUM = 0x85De42e5697D16b853eA24259C42290DaCe35190;
    address internal constant ROOT_MULTISIG_NON_ETHEREUM = 0xBEe38793Eed92e6Cf9fcB56538CD981A87a8c315;
    address internal constant EXECUTOR_MULTISIG = 0x84d37A25e46029CE161111420E07cEb78880119e;
    address internal constant DEPLOYER = 0x35518D5E1fD8105FC325c5c171c329c3B10b254c;

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET NAMES
    // ═══════════════════════════════════════════════════════════════════════════

    string internal constant STCUSD = "stcUSD";
    string internal constant SNUSD = "sNUSD";
    string internal constant SAVUSD = "savUSD";
    string internal constant AUTOUSD = "autoUSD";

    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN-SPECIFIC CONFIG (defined once per chain)
    // ═══════════════════════════════════════════════════════════════════════════

    struct ChainConfig {
        address factoryAdmin;
        address protocolFeeRecipient;
        address pauserAddress;
        address upgraderAddress;
        address syncRoleAddress;
        address adminKernelAddress;
        address adminAccountantAddress;
        address adminProtocolFeeSetterAddress;
        address adminOracleQuoterAddress;
        address lpRoleAdminAddress;
        address guardianAddress;
        address deployerAddress;
        address deployerAdminAddress;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET-SPECIFIC CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    struct MarketDeploymentConfig {
        // Market identification
        string marketName;
        uint256 chainId;
        // Tranche metadata
        string seniorTrancheName;
        string seniorTrancheSymbol;
        string juniorTrancheName;
        string juniorTrancheSymbol;
        // Assets
        address baseAsset;
        address seniorAsset;
        address juniorAsset;
        // Dust tolerances
        uint256 stDustTolerance;
        uint256 jtDustTolerance;
        // Kernel
        DeployScript.KernelType kernelType;
        bytes kernelSpecificParams;
        // Accountant
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 coverageWAD;
        uint96 betaWAD;
        uint64 lltvWAD;
        uint24 fixedTermDurationSeconds;
        // YDM
        DeployScript.YDMType ydmType;
        bytes ydmSpecificParams;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET CONFIG MAPPING
    // ═══════════════════════════════════════════════════════════════════════════

    mapping(string marketName => MarketDeploymentConfig) internal _marketConfigs;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error ChainConfigNotFound(uint256 chainId);
    error MarketConfigNotFound(string marketName);
    error MarketChainIdMismatch(string marketName, uint256 expectedChainId, uint256 actualChainId);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeMarketConfigs();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN CONFIG GETTER
    // ═══════════════════════════════════════════════════════════════════════════

    function getChainConfig(uint256 chainId) public pure returns (ChainConfig memory) {
        if (chainId == MAINNET) {
            return ChainConfig({
                factoryAdmin: ROOT_MULTISIG_ETHEREUM,
                protocolFeeRecipient: ROOT_MULTISIG_ETHEREUM,
                pauserAddress: EXECUTOR_MULTISIG,
                upgraderAddress: ROOT_MULTISIG_ETHEREUM,
                syncRoleAddress: EXECUTOR_MULTISIG,
                adminKernelAddress: ROOT_MULTISIG_ETHEREUM,
                adminAccountantAddress: ROOT_MULTISIG_ETHEREUM,
                adminProtocolFeeSetterAddress: ROOT_MULTISIG_ETHEREUM,
                adminOracleQuoterAddress: ROOT_MULTISIG_ETHEREUM,
                lpRoleAdminAddress: EXECUTOR_MULTISIG,
                guardianAddress: EXECUTOR_MULTISIG,
                deployerAddress: DEPLOYER,
                deployerAdminAddress: EXECUTOR_MULTISIG
            });
        } else {
            return ChainConfig({
                factoryAdmin: ROOT_MULTISIG_NON_ETHEREUM,
                protocolFeeRecipient: ROOT_MULTISIG_NON_ETHEREUM,
                pauserAddress: EXECUTOR_MULTISIG,
                upgraderAddress: ROOT_MULTISIG_NON_ETHEREUM,
                syncRoleAddress: EXECUTOR_MULTISIG,
                adminKernelAddress: ROOT_MULTISIG_NON_ETHEREUM,
                adminAccountantAddress: ROOT_MULTISIG_NON_ETHEREUM,
                adminProtocolFeeSetterAddress: ROOT_MULTISIG_NON_ETHEREUM,
                adminOracleQuoterAddress: ROOT_MULTISIG_NON_ETHEREUM,
                lpRoleAdminAddress: EXECUTOR_MULTISIG,
                guardianAddress: EXECUTOR_MULTISIG,
                deployerAddress: DEPLOYER,
                deployerAdminAddress: EXECUTOR_MULTISIG
            });
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET CONFIG GETTER
    // ═══════════════════════════════════════════════════════════════════════════

    function getMarketConfig(string memory marketName) public view returns (MarketDeploymentConfig memory) {
        MarketDeploymentConfig memory config = _marketConfigs[marketName];
        if (bytes(config.marketName).length == 0) {
            revert MarketConfigNotFound(marketName);
        }
        if (config.chainId != block.chainid) {
            revert MarketChainIdMismatch(marketName, config.chainId, block.chainid);
        }
        return config;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET CONFIG INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _initializeMarketConfigs() internal {
        _marketConfigs[STCUSD] = MarketDeploymentConfig({
            marketName: STCUSD,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(STCUSD),
            seniorTrancheSymbol: _seniorTrancheSymbol(STCUSD),
            juniorTrancheName: _juniorTrancheName(STCUSD),
            juniorTrancheSymbol: _juniorTrancheSymbol(STCUSD),
            baseAsset: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            seniorAsset: 0x88887bE419578051FF9F4eb6C858A951921D8888,
            juniorAsset: 0x88887bE419578051FF9F4eb6C858A951921D8888,
            stDustTolerance: 3,
            jtDustTolerance: 3,
            kernelType: DeployScript.KernelType.IdenticalERC4626SharesAdminOracleQuoter_Kernel,
            kernelSpecificParams: abi.encode(DeployScript.IdenticalERC4626SharesAdminOracleQuoterKernelParams({ initialConversionRateWAD: 1e18 })),
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0.2e18,
            coverageWAD: 0.1e18,
            betaWAD: 1e18,
            lltvWAD: 0.91e18,
            fixedTermDurationSeconds: 0, // Market is not expected to have volatility, so no fixed term
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.053e18,
                    jtYieldShareAtTargetUtilWAD: 0.053e18,
                    jtYieldShareAtFullUtilWAD: 1e18,
                    maxAdaptationSpeedWAD: uint64(10e18 / uint256(365 days))
                })
            )
        });

        _marketConfigs[SNUSD] = MarketDeploymentConfig({
            marketName: SNUSD,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(SNUSD),
            seniorTrancheSymbol: _seniorTrancheSymbol(SNUSD),
            juniorTrancheName: _juniorTrancheName(SNUSD),
            juniorTrancheSymbol: _juniorTrancheSymbol(SNUSD),
            baseAsset: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            seniorAsset: 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313,
            juniorAsset: 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313,
            stDustTolerance: 3,
            jtDustTolerance: 3,
            kernelType: DeployScript.KernelType.IdenticalERC4626SharesAdminOracleQuoter_Kernel,
            kernelSpecificParams: abi.encode(DeployScript.IdenticalERC4626SharesAdminOracleQuoterKernelParams({ initialConversionRateWAD: 1e18 })),
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0.2e18,
            coverageWAD: 0.1e18,
            betaWAD: 1e18,
            lltvWAD: 0.91e18,
            fixedTermDurationSeconds: 0, // Market is not expected to have volatility, so no fixed term
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.1236e18,
                    jtYieldShareAtTargetUtilWAD: 0.1236e18,
                    jtYieldShareAtFullUtilWAD: 1e18,
                    maxAdaptationSpeedWAD: uint64(10e18 / uint256(365 days))
                })
            )
        });

        _marketConfigs[SAVUSD] = MarketDeploymentConfig({
            marketName: SAVUSD,
            chainId: AVALANCHE,
            seniorTrancheName: _seniorTrancheName(SAVUSD),
            seniorTrancheSymbol: _seniorTrancheSymbol(SAVUSD),
            juniorTrancheName: _juniorTrancheName(SAVUSD),
            juniorTrancheSymbol: _juniorTrancheSymbol(SAVUSD),
            baseAsset: 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E,
            seniorAsset: 0x06d47F3fb376649c3A9Dafe069B3D6E35572219E,
            juniorAsset: 0x06d47F3fb376649c3A9Dafe069B3D6E35572219E,
            stDustTolerance: 3,
            jtDustTolerance: 3,
            kernelType: DeployScript.KernelType.IdenticalERC4626SharesAdminOracleQuoter_Kernel,
            kernelSpecificParams: abi.encode(DeployScript.IdenticalERC4626SharesAdminOracleQuoterKernelParams({ initialConversionRateWAD: 1e18 })),
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0.2e18,
            coverageWAD: 0.2e18,
            betaWAD: 1e18,
            lltvWAD: 0.82e18,
            fixedTermDurationSeconds: 0, // Market is not expected to have volatility, so no fixed term
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.1357e18,
                    jtYieldShareAtTargetUtilWAD: 0.1357e18,
                    jtYieldShareAtFullUtilWAD: 1e18,
                    maxAdaptationSpeedWAD: uint64(10e18 / uint256(365 days))
                })
            )
        });

        _marketConfigs[AUTOUSD] = MarketDeploymentConfig({
            marketName: AUTOUSD,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(AUTOUSD),
            seniorTrancheSymbol: _seniorTrancheSymbol(AUTOUSD),
            juniorTrancheName: _juniorTrancheName(AUTOUSD),
            juniorTrancheSymbol: _juniorTrancheSymbol(AUTOUSD),
            baseAsset: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            seniorAsset: 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35,
            juniorAsset: 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35,
            stDustTolerance: 3,
            jtDustTolerance: 3,
            kernelType: DeployScript.KernelType.IdenticalERC4626SharesAdminOracleQuoter_Kernel,
            kernelSpecificParams: abi.encode(DeployScript.IdenticalERC4626SharesAdminOracleQuoterKernelParams({ initialConversionRateWAD: 1e18 })),
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0.2e18,
            coverageWAD: 0.1e18,
            betaWAD: 1e18,
            lltvWAD: 0.92e18,
            fixedTermDurationSeconds: 2 days,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.0661e18,
                    jtYieldShareAtTargetUtilWAD: 0.0661e18,
                    jtYieldShareAtFullUtilWAD: 1e18,
                    maxAdaptationSpeedWAD: uint64(10e18 / uint256(365 days))
                })
            )
        });
    }

    /// @notice Returns the senior tranche name for a given market name
    /// @param marketName The name of the market
    /// @return The senior tranche name
    function _seniorTrancheName(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("Royco Senior Tranche ", marketName));
    }

    /// @notice Returns the junior tranche name for a given market name
    /// @param marketName The name of the market
    /// @return The junior tranche name
    function _juniorTrancheName(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("Royco Junior Tranche ", marketName));
    }

    /// @notice Returns the senior tranche symbol for a given market name
    /// @param marketName The name of the market
    /// @return The senior tranche symbol
    function _seniorTrancheSymbol(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("ROY-ST-", marketName));
    }

    /// @notice Returns the junior tranche symbol for a given market name
    /// @param marketName The name of the market
    /// @return The junior tranche symbol
    function _juniorTrancheSymbol(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("ROY-JT-", marketName));
    }
}

