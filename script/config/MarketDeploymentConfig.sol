// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { BalancerV3DeploymentTemplate } from "../../src/factory/templates/BalancerV3DeploymentTemplate.sol";
import { DeployScript } from "../Deploy.s.sol";

/**
 * @title MarketDeploymentConfig
 * @notice Configuration for the Royco Day market deployment path.
 * @dev The Dawn-era multi-kernel market catalog was removed in the Day fork. This config now describes the single
 *      Day deployment path (ST/JT + a Balancer Gyro E-CLP liquidity tranche). Add further Day markets as they ship.
 *      Addresses and E-CLP curve params below are ILLUSTRATIVE PLACEHOLDERS — set real, SDK-derived values per
 *      market/chain before broadcasting a deployment.
 */
abstract contract MarketDeploymentConfig {
    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN IDs
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 internal constant MAINNET = 1;
    uint256 internal constant AVALANCHE = 43_114;
    uint256 internal constant ARBITRUM = 42_161;
    uint256 internal constant BASE = 8453;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONTROLLING MULTISIG ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    address internal constant EXECUTOR_MULTISIG = 0x84d37A25e46029CE161111420E07cEb78880119e;
    address internal constant DEPLOYER = 0x35518D5E1fD8105FC325c5c171c329c3B10b254c;
    address internal constant ROOT_MULTISIG = 0x7c405bbD131e42af506d14e752f2e59B19D49997;
    address internal constant PROTOCOL_FEE_RECIPIENT = 0x05ea95aE815809D77153Ed3500Ad6d936712b639;

    /// @dev Balancer V3 Gyro E-CLP pool factory used to create the liquidity tranche's `{ST_share, quote}` pool.
    /// @dev TODO: set the real per-chain Balancer V3 Gyro E-CLP pool factory address before deploying.
    address internal constant GYRO_ECLP_POOL_FACTORY = address(0);

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET NAMES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Single illustrative Day market: ST/JT share an ERC4626 yield vault, LT holds the {ST_share, USDC} E-CLP BPT.
    string public constant DAY_DEMO = "DayDemoMarket";

    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN-SPECIFIC CONFIG (defined once per chain)
    // ═══════════════════════════════════════════════════════════════════════════

    struct ChainConfig {
        address factoryAdmin;
        address protocolFeeRecipient;
        address pauserAddress;
        address unpauserAddress;
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
        uint32 scheduledOperationsExpirySeconds;
        // Day: the Balancer V3 Gyro E-CLP pool factory the LT pool is created against.
        address gyroECLPPoolFactory;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET-SPECIFIC CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    struct MarketConfig {
        // Market identification
        string marketName;
        uint256 chainId;
        // Tranche metadata
        string seniorTrancheName;
        string seniorTrancheSymbol;
        string juniorTrancheName;
        string juniorTrancheSymbol;
        string liquidityTrancheName;
        string liquidityTrancheSymbol;
        // Assets
        address seniorAsset;
        address juniorAsset;
        // Dust tolerances
        uint256 stDustTolerance;
        uint256 jtDustTolerance;
        // Kernel
        DeployScript.KernelType kernelType;
        bytes kernelSpecificParams;
        uint64 stSelfLiquidationBonusWAD;
        bool enforceVaultSharesTransferWhitelist;
        // Accountant
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 jtYieldShareProtocolFeeWAD;
        uint64 minCoverageWAD;
        uint96 betaWAD;
        uint256 liquidationCoverageUtilizationWAD;
        uint24 fixedTermDurationSeconds;
        // YDM
        DeployScript.YDMType ydmType;
        bytes ydmSpecificParams;
        // Liquidity tranche: the Gyro E-CLP {ST_share, quote} pool the LT BPT is minted from.
        BalancerV3DeploymentTemplate.GyroECLPPoolParams gyroECLPPoolParams;
        // Compliance
        address transferAgentAddress;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET CONFIG MAPPING
    // ═══════════════════════════════════════════════════════════════════════════

    mapping(string marketName => MarketConfig) internal _marketConfigs;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

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

    function getChainConfig(uint256) public pure returns (ChainConfig memory) {
        return ChainConfig({
            factoryAdmin: ROOT_MULTISIG,
            protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT,
            pauserAddress: ROOT_MULTISIG,
            unpauserAddress: ROOT_MULTISIG,
            upgraderAddress: ROOT_MULTISIG,
            syncRoleAddress: ROOT_MULTISIG,
            adminKernelAddress: ROOT_MULTISIG,
            adminAccountantAddress: ROOT_MULTISIG,
            adminProtocolFeeSetterAddress: ROOT_MULTISIG,
            adminOracleQuoterAddress: ROOT_MULTISIG,
            lpRoleAdminAddress: ROOT_MULTISIG,
            guardianAddress: EXECUTOR_MULTISIG,
            deployerAddress: DEPLOYER,
            deployerAdminAddress: ROOT_MULTISIG,
            scheduledOperationsExpirySeconds: 1 weeks,
            gyroECLPPoolFactory: GYRO_ECLP_POOL_FACTORY
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CHAINALYSIS SANCTIONS LIST GETTER
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the canonical Chainalysis sanctions oracle for the given chain.
    /// @dev Consumed by the SetSanctionsList ops script to wire the shared blacklist's screening list per chain.
    ///      Returns the null address for chains without a known oracle (e.g. local/test chains), which disables
    ///      Chainalysis screening while leaving the local blacklist mapping fully functional.
    /// @param _chainId The chain id to look up
    /// @return The Chainalysis sanctions oracle address for the chain, or the null address if none is configured
    function getChainalysisSanctionsList(uint256 _chainId) public pure returns (address) {
        // Chainalysis deploys its sanctions oracle at the same address on most chains; Base is the exception.
        if (_chainId == MAINNET || _chainId == AVALANCHE || _chainId == ARBITRUM) {
            return 0x40C57923924B5c5c5455c48D93317139ADDaC8fb;
        }
        if (_chainId == BASE) {
            return 0x3A91A31cB3dC49b4db9Ce721F50a9D076c8D739B;
        }
        // No Chainalysis oracle configured for this chain (e.g. local/test chains): disables sanctions screening
        return address(0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET CONFIG GETTER
    // ═══════════════════════════════════════════════════════════════════════════

    function getMarketConfig(string memory marketName) public view returns (MarketConfig memory) {
        MarketConfig memory config = _marketConfigs[marketName];
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
        // Single illustrative Day market. ST and JT share the same ERC4626 yield vault; the LT holds the
        // Gyro E-CLP BPT of {ST_share, USDC}. All addresses and E-CLP curve params below are PLACEHOLDERS.
        address erc4626YieldVault = 0x88887bE419578051FF9F4eb6C858A951921D8888; // TODO: real ST/JT ERC4626 vault share
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // quote token

        _marketConfigs[DAY_DEMO] = MarketConfig({
            marketName: DAY_DEMO,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(DAY_DEMO),
            seniorTrancheSymbol: _seniorTrancheSymbol(DAY_DEMO),
            juniorTrancheName: _juniorTrancheName(DAY_DEMO),
            juniorTrancheSymbol: _juniorTrancheSymbol(DAY_DEMO),
            liquidityTrancheName: _liquidityTrancheName(DAY_DEMO),
            liquidityTrancheSymbol: _liquidityTrancheSymbol(DAY_DEMO),
            seniorAsset: erc4626YieldVault,
            juniorAsset: erc4626YieldVault,
            stDustTolerance: 1e16,
            jtDustTolerance: 1e16,
            kernelType: DeployScript.KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Day_Kernel,
            kernelSpecificParams: abi.encode(
                DeployScript.IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams({
                        // Enable the oracle leg by using the sentinel initial conversion rate
                        initialConversionRateWAD: 0,
                        baseAssetToNavAssetOracle: 0x9A5a3c3Ed0361505cC1D4e824B3854De5724434A, // TODO: real base-asset->NAV Chainlink feed
                        stalenessThresholdSeconds: 48 hours
                    })
            ),
            enforceVaultSharesTransferWhitelist: false,
            stSelfLiquidationBonusWAD: 0,
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0,
            jtYieldShareProtocolFeeWAD: 0.45e18,
            minCoverageWAD: 0.03e18,
            betaWAD: 1e18,
            liquidationCoverageUtilizationWAD: 1.0032441e18,
            fixedTermDurationSeconds: 0,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    yieldShareAtZeroUtilWAD: 0.06e18, yieldShareAtTargetUtilWAD: 0.06e18, yieldShareAtFullUtilWAD: 0.18e18, maxAdaptationSpeedWAD: 0
                })
            ),
            gyroECLPPoolParams: demoGyroECLPPoolParams(DAY_DEMO, usdc),
            transferAgentAddress: address(0)
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // E-CLP POOL PARAMS (PLACEHOLDER)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Builds the Gyro E-CLP pool params for a market's `{ST_share, quote}` liquidity-tranche pool.
    /// @dev TODO: the E-CLP curve params (`eclpParams`/`derivedEclpParams`) MUST be computed off-chain via the Gyro
    ///      SDK for the target near-peg curve and supplied here — the placeholder zeros below will not produce a valid
    ///      pool and exist only so the deployment path compiles and wires correctly.
    function demoGyroECLPPoolParams(
        string memory _marketName,
        address _quoteToken
    )
        public
        pure
        returns (BalancerV3DeploymentTemplate.GyroECLPPoolParams memory)
    {
        return BalancerV3DeploymentTemplate.GyroECLPPoolParams({
            name: string(abi.encodePacked("Royco Day LP ", _marketName)),
            symbol: string(abi.encodePacked("ROY-LP-", _marketName)),
            eclpParams: IGyroECLPPool.EclpParams({ alpha: 0, beta: 0, c: 0, s: 0, lambda: 0 }),
            derivedEclpParams: IGyroECLPPool.DerivedEclpParams({
                tauAlpha: IGyroECLPPool.Vector2({ x: 0, y: 0 }), tauBeta: IGyroECLPPool.Vector2({ x: 0, y: 0 }), u: 0, v: 0, w: 0, z: 0, dSq: 0
            }),
            swapFeePercentage: 0.0001e18, // 1 bp (directional-fee tuning is a P6 calibration concern)
            enableDonation: false,
            disableUnbalancedLiquidity: false,
            quoteToken: _quoteToken
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TRANCHE NAME/SYMBOL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the senior tranche name for a given market name
    function _seniorTrancheName(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("Royco Senior Tranche ", marketName));
    }

    /// @notice Returns the junior tranche name for a given market name
    function _juniorTrancheName(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("Royco Junior Tranche ", marketName));
    }

    /// @notice Returns the liquidity tranche name for a given market name
    function _liquidityTrancheName(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("Royco Liquidity Tranche ", marketName));
    }

    /// @notice Returns the senior tranche symbol for a given market name
    function _seniorTrancheSymbol(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("ROY-ST-", marketName));
    }

    /// @notice Returns the junior tranche symbol for a given market name
    function _juniorTrancheSymbol(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("ROY-JT-", marketName));
    }

    /// @notice Returns the liquidity tranche symbol for a given market name
    function _liquidityTrancheSymbol(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("ROY-LT-", marketName));
    }
}
