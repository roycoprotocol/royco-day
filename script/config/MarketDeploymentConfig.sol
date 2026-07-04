// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { BalancerV3DeploymentTemplate } from "../../src/factory/templates/BalancerV3DeploymentTemplate.sol";
import {
    IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter
} from "../../src/kernels/base/quoter/identical-st-jt/IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { DeployScript } from "../Deploy.s.sol";

/**
 * @title MarketDeploymentConfig
 * @notice Configuration for the Royco Day market deployment path.
 * @dev The Dawn-era multi-kernel market catalog was removed in the Day fork. This config now describes the single
 *      Day deployment path (ST/JT + a Balancer Gyro E-CLP liquidity tranche). Add further Day markets as they ship.
 *      The `snUSD` market's asset/oracle addresses and E-CLP curve params are real mainnet values; the only values
 *      still to finalize per market/chain are the ones marked `TODO` (the BPT oracle and the Gyro pool factory).
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
    address internal constant GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;

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
        bool jtCoinvested;
        uint256 coverageLiquidationUtilizationWAD;
        uint24 fixedTermDurationSeconds;
        // YDM (JT risk-premium model) + LDM (LT liquidity-premium model). Both share the YDM type/param encoding, but each
        // has its own curve params and target utilization (the JT YDM is driven by coverage utilization, the LDM by liquidity).
        DeployScript.YDMType ydmType;
        bytes ydmSpecificParams; // JT YDM curve
        bytes ltYdmSpecificParams; // LDM curve
        uint256 jtYdmTargetUtilizationWAD; // JT YDM target-utilization kink
        uint256 ltYdmTargetUtilizationWAD; // LDM target-utilization kink
        // Liquidity tranche: the Gyro E-CLP {ST_share, quote} pool the LT BPT is minted from.
        BalancerV3DeploymentTemplate.GyroECLPPoolParams gyroECLPPoolParams;
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
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // LT pool quote token

        address snusdVault = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313; // snUSD ERC4626 (ST/JT asset)
        address nusdRedstoneOracle = 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95; // base(nUSD)->NAV feed

        _marketConfigs[SNUSD] = MarketConfig({
            marketName: SNUSD,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(SNUSD),
            seniorTrancheSymbol: _seniorTrancheSymbol(SNUSD),
            juniorTrancheName: _juniorTrancheName(SNUSD),
            juniorTrancheSymbol: _juniorTrancheSymbol(SNUSD),
            liquidityTrancheName: _liquidityTrancheName(SNUSD),
            liquidityTrancheSymbol: _liquidityTrancheSymbol(SNUSD),
            seniorAsset: snusdVault,
            juniorAsset: snusdVault,
            stDustTolerance: 5,
            jtDustTolerance: 5,
            kernelType: DeployScript.KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_BalancerV3_BPTOracle_LT_Kernel,
            kernelSpecificParams: abi.encode(
                DeployScript.IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_QuoterKernelParams({
                    stAndJTQuoterParams: IdenticalERC4626Shares_ST_JT_SharePriceToChainlinkOracle_Quoter.ST_JT_QuoterSpecificParams({
                        // Enable the oracle leg by using the sentinel initial conversion rate
                        initialConversionRateWAD: 0,
                        baseAssetToNavAssetOracle: nusdRedstoneOracle,
                        // RedStone pushes updates ~every 12 hours; 48h staleness threshold for safety
                        stalenessThresholdSeconds: 48 hours,
                        // Ethereum mainnet has no L2 sequencer, so the sequencer-uptime check is disabled
                        sequencerUptimeFeed: address(0),
                        gracePeriodSeconds: 0
                    }),
                    ltQuoterParams: BalancerV3_LT_BPTOracle_Quoter.LT_QuoterSpecificParams({
                        bptOracle: 0x000000000000000000000000000000000000dEaD, // TODO: real manipulation-resistant E-CLP BPT oracle
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
            jtCoinvested: true,
            coverageLiquidationUtilizationWAD: 1.0009009e18,
            fixedTermDurationSeconds: 0, // stable market, no fixed term
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    yieldShareAtZeroUtilWAD: 0.11e18,
                    yieldShareAtTargetUtilWAD: 0.11e18,
                    yieldShareAtFullUtilWAD: 0.31e18,
                    maxAdaptationSpeedWAD: uint64(50e18 / uint256(365 days))
                })
            ),
            // LDM curve (LT liquidity premium off in the baseline, so only needs to be a valid curve to initialize the LDM).
            ltYdmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    yieldShareAtZeroUtilWAD: 0.11e18,
                    yieldShareAtTargetUtilWAD: 0.11e18,
                    yieldShareAtFullUtilWAD: 0.31e18,
                    maxAdaptationSpeedWAD: uint64(50e18 / uint256(365 days))
                })
            ),
            jtYdmTargetUtilizationWAD: 0.9e18,
            ltYdmTargetUtilizationWAD: 0.9e18,
            gyroECLPPoolParams: snusdGyroECLPPoolParams(usdc)
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // E-CLP POOL PARAMS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gyro E-CLP pool params for the snUSD market's `{snUSD_share, quote}` near-peg pool.
    /// @dev The curve params are a known-good near-peg set (copied from Balancer's pool-gyro test util, extracted from a real
    ///      mainnet pool) that pass the Gyro `create` validation. A production market should recompute these off-chain for the
    ///      exact snUSD/USDC curve; kept whole because the derived params are only valid for these exact `eclpParams`.
    function snusdGyroECLPPoolParams(address _quoteToken) public pure returns (BalancerV3DeploymentTemplate.GyroECLPPoolParams memory) {
        return BalancerV3DeploymentTemplate.GyroECLPPoolParams({
            name: "Royco Day LP snUSD",
            symbol: "ROY-LP-snUSD",
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
