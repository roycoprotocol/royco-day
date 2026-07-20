// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { BalancerV3_GyroECLP_LT_DeploymentTemplate } from "../../src/factory/templates/liquidity-tranche/BalancerV3_GyroECLP_LT_DeploymentTemplate.sol";
import { IRoycoDayEntryPoint } from "../../src/interfaces/IRoycoDayEntryPoint.sol";
import {
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "../../src/kernels/base/quoter/identical-st-jt/IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { DeployScript } from "../Deploy.s.sol";

/**
 * @title MarketDeploymentConfig
 * @notice Configuration for the Royco Day market deployment path.
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

    mapping(uint256 chainId => address) internal USDC;
    mapping(uint256 chainId => address) internal GYRO_ECLP_POOL_FACTORY;
    /// @dev Balancer's E-CLP LP oracle factory (deploys the manipulation-resistant BPT TVL oracle per pool).
    mapping(uint256 chainId => address) internal ECLP_LP_ORACLE_FACTORY;

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET NAMES
    // ═══════════════════════════════════════════════════════════════════════════

    string public constant SNUSD = "snUSD";

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
        // Day: Balancer's E-CLP LP oracle factory; the template deploys each market's BPT oracle through it.
        address eclpLPOracleFactory;
        // Foundation ("fndn") operational role holders.
        address balancerPoolManagerAddress;
        address marketOpsAddress;
        // Holder of the dedicated liquidity-premium reinvestment retry knob (split from market ops).
        address marketReinvestLiquidityPremiumAddress;
        // Entry point admins: config changes (delays, oracle clocks, enable flags) and protocol fee collection.
        address adminEntryPointAddress;
        address entryPointFeeCollectorAddress;
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
        uint256 coverageLiquidationUtilizationWAD;
        uint24 fixedTermDurationSeconds;
        DeployScript.YDMType ydmType;
        bytes ydmSpecificParams; // JT YDM curve
        bytes ltYdmSpecificParams; // LDM curve
        uint256 jtYdmTargetUtilizationWAD; // JT YDM target-utilization kink
        uint256 ltYdmTargetUtilizationWAD; // LDM target-utilization kink
        // Liquidity tranche: the Gyro E-CLP {ST_share, quote} pool the LT BPT is minted from.
        BalancerV3_GyroECLP_LT_DeploymentTemplate.GyroECLPPoolParams gyroECLPPoolParams;
        // Entry point config per tranche
        IRoycoDayEntryPoint.TrancheConfig stEntryPointConfig;
        IRoycoDayEntryPoint.TrancheConfig jtEntryPointConfig;
        IRoycoDayEntryPoint.TrancheConfig ltEntryPointConfig;
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
        // Set the real USDC address before deploying.
        USDC[MAINNET] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        // Set the real Balancer V3 Gyro E-CLP pool factory address before deploying.
        GYRO_ECLP_POOL_FACTORY[MAINNET] = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;

        // Balancer's canonical E-CLP LP oracle factory (https://etherscan.io/address/0x301EDe5Fd4f9d7266B09c3A2E38F97776447154B).
        ECLP_LP_ORACLE_FACTORY[MAINNET] = 0x301EDe5Fd4f9d7266B09c3A2E38F97776447154B;

        _initializeMarketConfigs();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN CONFIG GETTER
    // ═══════════════════════════════════════════════════════════════════════════

    function getChainConfig(uint256 _chainId) public view returns (ChainConfig memory) {
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
            gyroECLPPoolFactory: GYRO_ECLP_POOL_FACTORY[_chainId],
            eclpLPOracleFactory: ECLP_LP_ORACLE_FACTORY[_chainId],
            balancerPoolManagerAddress: ROOT_MULTISIG,
            marketOpsAddress: ROOT_MULTISIG,
            marketReinvestLiquidityPremiumAddress: ROOT_MULTISIG,
            // The operational (executor) multisig manages entry point tranche configs, mirroring the WCE-immediate
            // model of the retired standalone entry point deployment; the root multisig collects protocol fees.
            adminEntryPointAddress: EXECUTOR_MULTISIG,
            entryPointFeeCollectorAddress: ROOT_MULTISIG
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
        _marketConfigs[SNUSD] = MarketConfig({
            marketName: SNUSD,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(SNUSD),
            seniorTrancheSymbol: _seniorTrancheSymbol(SNUSD),
            juniorTrancheName: _juniorTrancheName(SNUSD),
            juniorTrancheSymbol: _juniorTrancheSymbol(SNUSD),
            liquidityTrancheName: _liquidityTrancheName(SNUSD),
            liquidityTrancheSymbol: _liquidityTrancheSymbol(SNUSD),
            seniorAsset: 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313,
            juniorAsset: 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313,
            stDustTolerance: 5,
            jtDustTolerance: 5,
            kernelType: DeployScript.KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel,
            kernelSpecificParams: abi.encode(
                DeployScript.IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_QuoterKernelParams({
                    stAndJTQuoterParams: IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams({
                        // Enable the oracle leg by using the sentinel initial conversion rate
                        initialConversionRateWAD: 0,
                        baseAssetToNavAssetOracle: 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95,
                        // RedStone pushes updates ~every 12 hours; 48h staleness threshold for safety
                        stalenessThresholdSeconds: 48 hours,
                        // Ethereum mainnet has no L2 sequencer, so the sequencer-uptime check is disabled
                        sequencerUptimeFeed: address(0),
                        gracePeriodSeconds: 0
                    }),
                    ltQuoterParams: BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams({
                        bptOracle: address(0), // This is deployed by the template after the pool is created and ignored here
                        maxReinvestmentSlippageWAD: 0.001e18 // 10 bps single-sided liquidity-premium reinvestment slippage gate
                    })
                })
            ),
            enforceVaultSharesTransferWhitelist: false,
            stSelfLiquidationBonusWAD: 0.005e18,
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0,
            jtYieldShareProtocolFeeWAD: 0.45e18,
            minCoverageWAD: 0.1e18,
            coverageLiquidationUtilizationWAD: 1.0009009e18,
            fixedTermDurationSeconds: 0, // stable market, no fixed term
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    yieldShareAtZeroUtilWAD: 0.11e18, yieldShareAtTargetUtilWAD: 0.11e18, yieldShareAtFullUtilWAD: 0.31e18
                })
            ),
            ltYdmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                        yieldShareAtZeroUtilWAD: 0.11e18, yieldShareAtTargetUtilWAD: 0.11e18, yieldShareAtFullUtilWAD: 0.31e18
                    })
            ),
            jtYdmTargetUtilizationWAD: 0.9e18,
            ltYdmTargetUtilizationWAD: 0.9e18,
            gyroECLPPoolParams: BalancerV3_GyroECLP_LT_DeploymentTemplate.GyroECLPPoolParams({
                name: _poolName(SNUSD, USDC[block.chainid]),
                symbol: _poolSymbol(SNUSD, USDC[block.chainid]),
                eclpParams: IGyroECLPPool.EclpParams({
                    alpha: 998_502_246_630_054_917,
                    beta: 1_000_200_040_008_001_600,
                    c: 707_106_781_186_547_524,
                    s: 707_106_781_186_547_524,
                    lambda: 4_000_000_000_000_000_000_000
                }),
                derivedEclpParams: IGyroECLPPool.DerivedEclpParams({
                    tauAlpha: IGyroECLPPool.Vector2({
                        x: -94_861_212_813_096_057_289_512_505_574_275_160_547, y: 31_644_119_574_235_279_926_451_292_677_567_331_630
                    }),
                    tauBeta: IGyroECLPPool.Vector2({
                        x: 37_142_269_533_113_549_537_591_131_345_643_981_951, y: 92_846_388_265_400_743_995_957_747_409_218_517_601
                    }),
                    u: 66_001_741_173_104_803_338_721_745_994_955_553_010,
                    v: 62_245_253_919_818_011_890_633_399_060_291_020_887,
                    w: 30_601_134_345_582_732_000_058_913_853_921_008_022,
                    z: -28_859_471_639_991_253_843_240_999_485_797_747_790,
                    dSq: 99_999_999_999_999_999_886_624_093_342_106_115_200
                }),
                swapFeePercentage: 1e14, // 1 bp
                quoteAsset: USDC[block.chainid],
                quoteAssetRateProvider: address(0), // USDC is a pegged quote: register STANDARD (rate = 1)
                chargeYieldFeeOnSeniorTrancheShares: false,
                chargeYieldFeeOnQuoteAsset: false
            }),
            stEntryPointConfig: _defaultEntryPointTrancheConfig(),
            jtEntryPointConfig: _defaultEntryPointTrancheConfig(),
            ltEntryPointConfig: _defaultEntryPointTrancheConfig()
        });
    }

    /// @notice The default entry point config a tranche is enabled with at market deployment
    /// @dev The oracle clock is deployed externally per market and wired post-deployment (a null clock disables the gate)
    function _defaultEntryPointTrancheConfig() internal pure returns (IRoycoDayEntryPoint.TrancheConfig memory) {
        return IRoycoDayEntryPoint.TrancheConfig({ enabled: true, depositDelaySeconds: 5 minutes, redemptionDelaySeconds: 24 hours, oracleClock: address(0) });
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

    /// @notice Returns the pool name for a given market name and quote asset (e.g. "Royco Day LP ROY-ST-snUSD-USDC")
    function _poolName(string memory marketName, address quoteAsset) internal view returns (string memory) {
        return string(abi.encodePacked("Royco Day LP ", _seniorTrancheSymbol(marketName), "-", IERC20Metadata(quoteAsset).symbol()));
    }

    /// @notice Returns the pool symbol for a given market name and quote asset (e.g. "ROY-LP-ROY-ST-snUSD-USDC")
    function _poolSymbol(string memory marketName, address quoteAsset) internal view returns (string memory) {
        return string(abi.encodePacked("ROY-LP-", _seniorTrancheSymbol(marketName), "-", IERC20Metadata(quoteAsset).symbol()));
    }
}
