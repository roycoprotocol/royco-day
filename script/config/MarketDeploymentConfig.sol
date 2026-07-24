// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IRoycoDayEntryPoint } from "../../src/interfaces/IRoycoDayEntryPoint.sol";
import { BalancerV3LiquidityVenue } from "../../src/kernels/base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";
import {
    AdaptiveCurveYDM_V2_Params,
    ChainConfig,
    ERC4626SharePriceOracleParams,
    GyroECLPPoolParams,
    KernelType,
    MarketConfig,
    OracleType,
    YDMType
} from "./DeploymentTypes.sol";

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

    // ═══════════════════════════════════════════════════════════════════════════
    // ENVIRONMENT (test vs production)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Selects the deployment environment. Production (false) is the DEFAULT, so the whole test suite exercises
    ///      the production config; the deploy entrypoints override it from the env. Drives the singleton salt suffix
    ///      and the role config `getChainConfig` returns.
    bool internal isTestEnv;

    /// @dev The single admin every role resolves to for a test deployment. Overridable via the TEST_ADMIN env var.
    address internal testDeploymentAdmin = 0x77777Cc68b333a2256B436D675E8D257699Aa667;

    // ═══════════════════════════════════════════════════════════════════════════
    // SINGLETON CREATE2 SALTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev CREATE2 salt for a protocol singleton (AccessManager, factory, etc.), suffixed with the environment so a
    ///      test deployment and a production deployment never collide on a deterministic address.
    function _singletonSalt(string memory _seed) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_seed, isTestEnv ? "_TEST" : "_PROD"));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOKEN ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    mapping(uint256 chainId => address) internal USDC;
    mapping(uint256 chainId => address) internal GYRO_ECLP_POOL_FACTORY;
    mapping(uint256 chainId => address) internal ECLP_LP_ORACLE_FACTORY;

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET NAMES
    // ═══════════════════════════════════════════════════════════════════════════

    string public constant SNUSD = "snUSD";

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET CONFIG MAPPING
    // ═══════════════════════════════════════════════════════════════════════════

    mapping(string marketName => MarketConfig) internal _marketConfigs;

    // ═══════════════════════════════════════════════════════════════════════════
    // MINED MARKET IDs (per market, per factory)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The pre-mined marketId to use for `marketName` when deploying against `factory`.
    mapping(bytes32 marketNameHash => mapping(address factory => bytes32 marketId)) internal _marketIds;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error MarketConfigNotFound(string marketName);
    error MarketChainIdMismatch(string marketName, uint256 expectedChainId, uint256 actualChainId);
    error MarketIdNotConfigured(string marketName, address factory);

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
        _initializeMinedMarketIds();
    }

    /// @notice Registers each market's pre-mined marketId, keyed by the factory it was mined against.
    /// @dev Mined offline (script/mine-market-id); re-mine and update the value if a market's factory changes (new
    ///      deployer or changed singleton salts). The factory addresses are the deterministic proxy addresses the
    ///      production deployer and the test harness's `vm.createWallet("DEPLOYER")` each stand up.
    function _initializeMinedMarketIds() internal {
        bytes32 snUSDHash = keccak256(bytes(SNUSD));
        // The factory proxy addresses moved with the oracle-collapse refactor (the RoycoFactory creation code feeds the
        // CREATE2 derivation), so the "_PROD" entries below were re-mined against the new addresses (nonce 0 still wins).
        // snUSD against the production factory (prod deployer, "_PROD" salts).
        _marketIds[snUSDHash][0x7FcE8a894d418B4FB1c67E44e38d98da13E38220] = 0xb3d433a58a0d62af783a1fcb783e83f5efc3867dfa2e807ed7455be4373d0bda;
        // snUSD against the local test factory (test-harness deployer, "_PROD" salts — the suite runs on the prod config).
        _marketIds[snUSDHash][0xCBc6b42FdE77F3D12Ed9108E60988bdc18Be5F65] = 0xb3d433a58a0d62af783a1fcb783e83f5efc3867dfa2e807ed7455be4373d0bda;
        // snUSD against the test-environment factory on mainnet ("_TEST" salts). STALE since the refactor moved the
        // factory: re-mine (script/mine-market-id) against the new test-env factory before the next test-env deploy.
        _marketIds[snUSDHash][0xE9B3356dAc63Cca56fAAAdD9Ba91C41712BF121C] = 0xb3d433a58a0d62af783a1fcb783e83f5efc3867dfa2e807ed7455be4373d0bda;
    }

    /// @notice The pre-mined marketId for `_marketName` against `_factory`. Reverts if none is configured.
    function getMarketId(string memory _marketName, address _factory) public view returns (bytes32 marketId) {
        marketId = _marketIds[keccak256(bytes(_marketName))][_factory];
        require(marketId != bytes32(0), MarketIdNotConfigured(_marketName, _factory));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN CONFIG GETTER
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The chain-level config for `_chainId`. In a test deployment (`_isTest`) every role resolves to the
    ///         single `testDeploymentAdmin`; in production each role points at its dedicated multisig. The chain-level
    ///         addresses (pool factory, oracle factory) are the same real addresses in both environments.
    function getChainConfig(uint256 _chainId, bool _isTest) public view returns (ChainConfig memory) {
        // Role holders: one test admin for a test deployment, dedicated multisigs for production.
        address factoryAdmin = _isTest ? testDeploymentAdmin : ROOT_MULTISIG;
        address rootRole = _isTest ? testDeploymentAdmin : ROOT_MULTISIG;
        address guardian = _isTest ? testDeploymentAdmin : EXECUTOR_MULTISIG;
        address entryPointAdmin = _isTest ? testDeploymentAdmin : EXECUTOR_MULTISIG;
        address protocolFeeRecipient = _isTest ? testDeploymentAdmin : PROTOCOL_FEE_RECIPIENT;

        return ChainConfig({
            factoryAdmin: factoryAdmin,
            protocolFeeRecipient: protocolFeeRecipient,
            pauserAddress: rootRole,
            unpauserAddress: rootRole,
            upgraderAddress: rootRole,
            syncRoleAddress: rootRole,
            adminKernelAddress: rootRole,
            adminAccountantAddress: rootRole,
            adminProtocolFeeSetterAddress: rootRole,
            adminOracleAddress: rootRole,
            lpRoleAdminAddress: rootRole,
            guardianAddress: guardian,
            deployerAddress: DEPLOYER,
            deployerAdminAddress: rootRole,
            scheduledOperationsExpirySeconds: 1 weeks,
            gyroECLPPoolFactory: GYRO_ECLP_POOL_FACTORY[_chainId],
            eclpLPOracleFactory: ECLP_LP_ORACLE_FACTORY[_chainId],
            balancerPoolManagerAddress: rootRole,
            marketOpsAddress: rootRole,
            marketReinvestLiquidityPremiumAddress: rootRole,
            adminEntryPointAddress: entryPointAdmin,
            entryPointFeeCollectorAddress: rootRole
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
            liquidityProviderTrancheName: _liquidityProviderTrancheName(SNUSD),
            liquidityProviderTrancheSymbol: _liquidityProviderTrancheSymbol(SNUSD),
            collateralAsset: 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313,
            // The script deploys an ERC4626SharePriceOracle over the feed below (share price x feed) at deployment
            collateralAssetOracle: address(0),
            collateralAssetOracleType: OracleType.ERC4626SharePrice,
            collateralAssetOracleSpecificParams: abi.encode(
                ERC4626SharePriceOracleParams({ baseAssetToNavAssetFeed: 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95 })
            ),
            // RedStone pushes updates ~every 12 hours; 48h staleness threshold for safety
            stalenessThresholdSeconds: 48 hours,
            // Ethereum mainnet has no L2 sequencer, so the sequencer-uptime check is disabled
            sequencerUptimeFeed: address(0),
            gracePeriodSeconds: 0,
            dustTolerance: 5,
            kernelType: KernelType.RoycoDayBalancerV3Kernel,
            kernelSpecificParams: abi.encode(
                BalancerV3LiquidityVenue.LiquidityVenueInitParams({
                    bptOracle: address(0), // This is deployed by the script after the pool is created and overwritten by the template
                    maxReinvestmentSlippageWAD: 0.001e18 // 10 bps single-sided liquidity-premium reinvestment slippage gate
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
            ydmType: YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.11e18, yieldShareAtTargetUtilWAD: 0.11e18, yieldShareAtFullUtilWAD: 0.31e18 })
            ),
            lptYdmSpecificParams: abi.encode(
                AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.11e18, yieldShareAtTargetUtilWAD: 0.11e18, yieldShareAtFullUtilWAD: 0.31e18 })
            ),
            jtYdmTargetUtilizationWAD: 0.9e18,
            lptYdmTargetUtilizationWAD: 0.9e18,
            gyroECLPPoolParams: GyroECLPPoolParams({
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
            lptEntryPointConfig: _defaultEntryPointTrancheConfig()
        });
    }

    /// @notice The default entry point config a tranche is enabled with at market deployment
    /// @dev The collateral asset oracle gate starts disabled and is armed post-deployment (the oracle itself is resolved live from the kernel)
    function _defaultEntryPointTrancheConfig() internal pure returns (IRoycoDayEntryPoint.TrancheConfig memory) {
        return IRoycoDayEntryPoint.TrancheConfig({ enabled: true, depositDelaySeconds: 5 minutes, redemptionDelaySeconds: 24 hours, gateByOracleUpdate: false });
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

    /// @notice Returns the liquidity provider tranche name for a given market name
    function _liquidityProviderTrancheName(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("Royco Liquidity Provider Tranche ", marketName));
    }

    /// @notice Returns the senior tranche symbol for a given market name
    function _seniorTrancheSymbol(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("ROY-ST-", marketName));
    }

    /// @notice Returns the junior tranche symbol for a given market name
    function _juniorTrancheSymbol(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("ROY-JT-", marketName));
    }

    /// @notice Returns the liquidity provider tranche symbol for a given market name
    function _liquidityProviderTrancheSymbol(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("ROY-LPT-", marketName));
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
