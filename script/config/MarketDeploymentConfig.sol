// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { CREATE3 } from "../../lib/solady/src/utils/CREATE3.sol";
import { RoycoAccessManager } from "../../src/factory/RoycoAccessManager.sol";
import { RoycoCreate3Deployer } from "../../src/factory/RoycoCreate3Deployer.sol";
import { RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { TAG_ST_PROXY } from "../../src/factory/templates/base/Constants.sol";
import { IRoycoDayEntryPoint } from "../../src/interfaces/IRoycoDayEntryPoint.sol";
import { BalancerV3LiquidityVenue } from "../../src/kernels/base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { CREATE2_FACTORY_ADDRESS } from "../utils/Create2DeployUtils.sol";
import {
    AdaptiveCurveYDM_V2_Params,
    ChainConfig,
    ERC4626SharePriceOracleParams,
    GyroECLPPoolParams,
    IdleCDOTranchePriceOracleParams,
    KernelType,
    MarketConfig,
    OracleType,
    YDMType
} from "./DeploymentTypes.sol";

/**
 * @title MarketDeploymentConfig
 * @notice Configuration for the Royco Day market deployment path.
 */
/// todo: change structure and remove values. closer to the deployment config
/// todo: break script into multiple smaller scripts
/// todo: make config easier to digest
/// todo: per market fee
/// todo: roles
/// todo: make sync public (check if we need the blacklist)
abstract contract MarketDeploymentConfig {
    using Math for uint256;

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

    /// @dev The test harness deployer, `vm.createWallet("DEPLOYER")` (private key keccak256("DEPLOYER")).
    address internal constant TEST_HARNESS_DEPLOYER = 0x3A383B39c10856a75B9E3f6eda6fCC8fC3334050;
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

    /// @dev The environment salt suffixes. ONE definition each: `_predictFactoryProxy` derives the market-id registry
    ///      keys from these same constants, so bumping the test suffix (to force a fresh test namespace) regenerates
    ///      every test-env market id automatically instead of leaving the registry keyed to the old factory.
    string internal constant PROD_SALT_SUFFIX = "_PROD";
    string internal constant TEST_SALT_SUFFIX = "_TEST_3243241421";

    /// @dev CREATE2 salt for a protocol singleton (AccessManager, factory, etc.), suffixed with the environment so a
    ///      test deployment and a production deployment never collide on a deterministic address.
    function _singletonSalt(string memory _seed) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_seed, isTestEnv ? TEST_SALT_SUFFIX : PROD_SALT_SUFFIX));
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
    string public constant SRROYUSDC = "srRoyUSDC";
    string public constant FALCONX = "FalconX";
    string public constant APYX = "APYX";

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET CONFIG MAPPING
    // ═══════════════════════════════════════════════════════════════════════════

    mapping(string marketName => MarketConfig) internal _marketConfigs;

    // ═══════════════════════════════════════════════════════════════════════════
    // MINED MARKET IDs (per market, per factory)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The mined marketId to use for `marketName` when deploying against `factory`, keyed by the factory
    ///         proxy address predicted from this build's creation code.
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
        USDC[ARBITRUM] = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // native (Circle) USDC

        // Set the real Balancer V3 Gyro E-CLP pool factory address before deploying.
        GYRO_ECLP_POOL_FACTORY[MAINNET] = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;
        // Arbitrum counterpart of the SAME Balancer deployment task as mainnet's (20260126-v3-gyro-eclp-v2, ACTIVE),
        // so the create/verify interface is identical (https://github.com/balancer/balancer-deployments)
        GYRO_ECLP_POOL_FACTORY[ARBITRUM] = 0xe31715e75207acC8bfadd96902FF522058928479;

        // Balancer's canonical E-CLP LP oracle factory (https://etherscan.io/address/0x301EDe5Fd4f9d7266B09c3A2E38F97776447154B).
        ECLP_LP_ORACLE_FACTORY[MAINNET] = 0x301EDe5Fd4f9d7266B09c3A2E38F97776447154B;
        // Arbitrum counterpart, same deployment task as mainnet's (20260209-v3-gyro-eclp-oracle, ACTIVE)
        ECLP_LP_ORACLE_FACTORY[ARBITRUM] = 0xD9E91f7aD501929b089992842a3f193795E6479e;

        _initializeMarketConfigs();
        _initializeMinedMarketIds();
    }

    /// @notice Registers each market's mined marketId, keyed by the factory it deploys against.
    function _initializeMinedMarketIds() internal {
        bytes32 snUSDHash = keccak256(bytes(SNUSD));
        // snUSD against the production factory (prod deployer, "_PROD" salts), mined offline at nonce 0.
        _marketIds[snUSDHash][_predictFactoryProxy(DEPLOYER, false)] = 0xb3d433a58a0d62af783a1fcb783e83f5efc3867dfa2e807ed7455be4373d0bda;
        // snUSD against the local test-harness factory ("_PROD" salts, the suite runs on the prod config).
        address localFactory = _predictFactoryProxy(TEST_HARNESS_DEPLOYER, false);
        _marketIds[snUSDHash][localFactory] = _marketIdSeed(SNUSD, localFactory);
        // snUSD against the test-environment factory (TEST_SALT_SUFFIX salts, prod deployer key).
        address testEnvFactory = _predictFactoryProxy(DEPLOYER, true);
        _marketIds[snUSDHash][testEnvFactory] = _marketIdSeed(SNUSD, testEnvFactory);

        // srRoyUSDC, seeded per factory exactly as snUSD: the seed is mined on top of the full params at build time
        bytes32 srRoyUsdcHash = keccak256(bytes(SRROYUSDC));
        _marketIds[srRoyUsdcHash][_predictFactoryProxy(DEPLOYER, false)] = _marketIdSeed(SRROYUSDC, _predictFactoryProxy(DEPLOYER, false));
        _marketIds[srRoyUsdcHash][localFactory] = _marketIdSeed(SRROYUSDC, localFactory);
        _marketIds[srRoyUsdcHash][testEnvFactory] = _marketIdSeed(SRROYUSDC, testEnvFactory);

        // The remaining sheet markets, seeded per factory exactly as srRoyUSDC
        _seedMarketIdsForAllFactories(FALCONX);
        _seedMarketIdsForAllFactories(APYX);
    }

    /// @notice Seeds `_name`'s market id for the production, local test-harness, and test-environment factories,
    ///         each from the build-time seed the params builder mines on top of
    function _seedMarketIdsForAllFactories(string memory _name) internal {
        bytes32 nameHash = keccak256(bytes(_name));
        address prodFactory = _predictFactoryProxy(DEPLOYER, false);
        address localFactory = _predictFactoryProxy(TEST_HARNESS_DEPLOYER, false);
        address testEnvFactory = _predictFactoryProxy(DEPLOYER, true);
        _marketIds[nameHash][prodFactory] = _marketIdSeed(_name, prodFactory);
        _marketIds[nameHash][localFactory] = _marketIdSeed(_name, localFactory);
        _marketIds[nameHash][testEnvFactory] = _marketIdSeed(_name, testEnvFactory);
    }

    /// @notice The market id SEED for `_marketName` against `_factory`, which the params builder mines on top of.
    /// @dev Reverts if none is configured.
    function getMarketId(string memory _marketName, address _factory) public view returns (bytes32 marketId) {
        marketId = _marketIds[keccak256(bytes(_marketName))][_factory];
        require(marketId != bytes32(0), MarketIdNotConfigured(_marketName, _factory));
    }

    /// @dev CREATE2 address under the canonical deterministic deployer, mirrors Create2DeployUtils.
    function _create2Address(bytes32 _salt, bytes32 _initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY_ADDRESS, _salt, _initCodeHash)))));
    }

    /// @notice Predicts the factory proxy `_deployer` stands up under the `_isTest` environment salts.
    /// @dev Mirrors DeployScript._deployAccessManagerAndFactory. The AccessManager constructor arg is the deployer,
    ///      so each deployer gets its own deterministic factory.
    function _predictFactoryProxy(address _deployer, bool _isTest) internal pure returns (address) {
        string memory suffix = _isTest ? TEST_SALT_SUFFIX : PROD_SALT_SUFFIX;
        address create3Deployer =
            _create2Address(keccak256(abi.encodePacked("ROYCO_CREATE3_DEPLOYER", suffix)), keccak256(type(RoycoCreate3Deployer).creationCode));
        return
            CREATE3.predictDeterministicAddress(keccak256(abi.encode(_deployer, keccak256(abi.encodePacked("ROYCO_FACTORY_PROXY", suffix)))), create3Deployer);
    }

    /// @notice Mines the lowest-nonce marketId whose senior-tranche CREATE3 proxy sorts below `_quoteAsset` under
    ///         `_factory`, so the senior tranche registers as pool token0. Mirrors script/mine-market-id.
    /// @dev A stable per-(market, factory) SEED, not a usable market id on its own. Every component salt hashes the
    ///      whole params struct, so the id that actually places the senior tranche below the quote asset can only be
    ///      mined once the params are fully built: `Deploy.s.sol._buildMarketParams` does that, taking this as input
    function _marketIdSeed(string memory _name, address _factory) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes(_name), _factory));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN CONFIG GETTER
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev When set, `getChainConfig` returns this instead of the canonical values. Test-only: fork fixtures pin the
    ///      policy their reference math assumes without editing the production config
    bool internal chainConfigOverridden;
    ChainConfig internal chainConfigOverride;

    /// @notice Overrides the chain config returned by `getChainConfig`, for tests that need a pinned policy
    /// @param _config The full config to serve in place of the canonical one
    function overrideChainConfigForTest(ChainConfig memory _config) public {
        chainConfigOverridden = true;
        chainConfigOverride = _config;
    }

    /// @notice Overrides a market's config in place, for tests whose calibrated expectations must not drift with the
    ///         canonical parameters (keyed by `_config.marketName`)
    /// @param _config The full market config to serve in place of the canonical one
    function overrideMarketConfigForTest(MarketConfig memory _config) public {
        _marketConfigs[_config.marketName] = _config;
    }

    /// @notice The chain-level config for `_chainId`. In a test deployment (`_isTest`) every role resolves to the
    ///         single `testDeploymentAdmin`; in production each role points at its dedicated multisig. The chain-level
    ///         addresses (pool factory, oracle factory) are the same real addresses in both environments.
    function getChainConfig(uint256 _chainId, bool _isTest) public view returns (ChainConfig memory) {
        if (chainConfigOverridden) return chainConfigOverride;

        // Role holders: one test admin for a test deployment, dedicated multisigs for production.
        address factoryAdmin = _isTest ? testDeploymentAdmin : ROOT_MULTISIG;
        address rootRole = _isTest ? testDeploymentAdmin : ROOT_MULTISIG;
        address executor = _isTest ? testDeploymentAdmin : EXECUTOR_MULTISIG;
        address guardian = _isTest ? testDeploymentAdmin : EXECUTOR_MULTISIG;
        address entryPointAdmin = _isTest ? testDeploymentAdmin : EXECUTOR_MULTISIG;
        address protocolFeeRecipient = _isTest ? testDeploymentAdmin : PROTOCOL_FEE_RECIPIENT;

        return ChainConfig({
            factoryAdmin: factoryAdmin,
            protocolFeeRecipient: protocolFeeRecipient,
            stProtocolFeeWAD: 0,
            jtProtocolFeeWAD: 0,
            jtYieldShareProtocolFeeWAD: 0.45e18, // 45%
            lptYieldShareProtocolFeeWAD: 0.45e18, // 45%
            poolSwapFeePercentage: 5e14, // 5 bps
            chargeYieldFeeOnSeniorTrancheShares: false,
            chargeYieldFeeOnQuoteAsset: false,
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

    /// @notice Calculates the coverage liquidation utilization WAD based on the min coverage WAD and the coverage remaining WAD.
    /// @param _minCoverageWAD The minimum coverage WAD.
    /// @param _coverageRemainingWAD The coverage remaining WAD.
    /// @return The coverage liquidation utilization WAD.
    function calculateCoverageLiquidationUtilizationWAD(uint256 _minCoverageWAD, uint256 _coverageRemainingWAD) internal pure returns (uint256) {
        return _minCoverageWAD.mulDiv(WAD, _coverageRemainingWAD, Math.Rounding.Floor);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET CONFIG INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _initializeMarketConfigs() internal {
        _marketConfigs[SNUSD] = MarketConfig({
            marketName: SNUSD,
            chainId: MAINNET,
            seniorTrancheName: "Senior Staked NUSD",
            seniorTrancheSymbol: "srsNUSD",
            juniorTrancheName: "Junior Staked NUSD",
            juniorTrancheSymbol: "jrsNUSD",
            liquidityProviderTrancheName: "Senior Liquidity NUSD",
            liquidityProviderTrancheSymbol: "slsNUSD",
            collateralAsset: 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313,
            collateralAssetOracle: address(0),
            collateralAssetOracleType: OracleType.ERC4626SharePrice,
            collateralAssetOracleSpecificParams: abi.encode(
                ERC4626SharePriceOracleParams({
                    baseAssetToNavAssetFeed: 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95,
                    // RedStone pushes updates ~every 12 hours; 48h staleness threshold for safety
                    feedStalenessThresholdSeconds: 48 hours
                })
            ),
            // Ethereum mainnet has no L2 sequencer, so the sequencer-uptime check is disabled
            sequencerUptimeFeed: address(0),
            gracePeriodSeconds: 0,
            dustTolerance: 5,
            kernelType: KernelType.RoycoDayBalancerV3Kernel,
            kernelSpecificParams: abi.encode(
                RoycoDayBalancerV3MarketDeploymentTemplate.BalancerV3LiquidityVenueDeploymentParams({
                    maxReinvestmentSlippageWAD: 0.001e18 // 10 bps single-sided liquidity-premium reinvestment slippage gate
                })
            ),
            stSelfLiquidationBonusWAD: 0.005e18,
            minCoverageWAD: 0.1e18,
            minLiquidityWAD: 0, // no market-making depth requirement in the baseline // todo: get rid of
            maxJTYieldShareWAD: 1e18, // uncapped at the WAD ceiling; the real JT cap comes from the JT YDM curve
            maxLPTYieldShareWAD: 0, // LPT liquidity premium disabled in the baseline
            coverageLiquidationUtilizationWAD: 1.0009009e18,
            fixedTermDurationSeconds: 0, // stable market, no fixed term
            fixedTermGracePeriodSeconds: 0,
            ydmType: YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.11e18, yieldShareAtTargetUtilWAD: 0.11e18, yieldShareAtFullUtilWAD: 0.31e18 })
            ),
            lptYdmSpecificParams: abi.encode(
                AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.11e18, yieldShareAtTargetUtilWAD: 0.11e18, yieldShareAtFullUtilWAD: 0.31e18 })
            ),
            poolInitialization: RoycoDayBalancerV3MarketDeploymentTemplate.PoolInitializationParams({
                collateralAmount: 0, // no collateral leg: the genesis liquidity is quote-only
                quoteAmount: 1e6, // $1
                minLPTAssetsOut: 0
            }),
            gyroECLPPoolParams: GyroECLPPoolParams({
                name: "Senior Staked NUSD / USDC",
                symbol: "srsNUSD/USDC",
                eclpParams: IGyroECLPPool.EclpParams({
                    alpha: 979_500_000_000_000_000,
                    beta: 1_000_100_000_000_000_000,
                    c: 707_106_781_186_547_524,
                    s: 707_106_781_186_547_524,
                    lambda: 300_000_000_000_000_000_000
                }),
                derivedEclpParams: IGyroECLPPool.DerivedEclpParams({
                    tauAlpha: IGyroECLPPool.Vector2({
                        x: -95_190_609_145_778_628_634_003_067_669_167_913_840, y: 30_638_993_626_677_852_907_481_149_992_051_688_690
                    }),
                    tauBeta: IGyroECLPPool.Vector2({
                        x: 1_499_756_307_523_889_459_999_505_839_090_567_732, y: 99_988_753_022_617_710_298_167_054_292_168_150_721
                    }),
                    u: 48_345_182_726_651_258_992_189_497_512_372_871_627,
                    v: 65_313_873_324_647_781_528_773_906_086_902_197_476,
                    w: 34_674_879_697_969_928_656_029_992_909_950_847_655,
                    z: -46_845_426_419_127_369_533_890_353_984_596_464_770,
                    dSq: 99_999_999_999_999_999_886_624_093_342_106_115_200
                }),
                quoteAsset: USDC[block.chainid],
                quoteAssetRateProvider: address(0)
            }),
            stEntryPointConfig: _defaultEntryPointTrancheConfig(),
            jtEntryPointConfig: _defaultEntryPointTrancheConfig(),
            lptEntryPointConfig: _defaultEntryPointTrancheConfig()
        });

        _marketConfigs[SRROYUSDC] = MarketConfig({
            marketName: SRROYUSDC,
            chainId: MAINNET,
            seniorTrancheName: "Senior SrRoyUSDC",
            seniorTrancheSymbol: "srsrRoyUSDC",
            juniorTrancheName: "Junior SrRoyUSDC",
            juniorTrancheSymbol: "jrsrRoyUSDC",
            liquidityProviderTrancheName: "Senior Liquidity SrRoyUSDC",
            liquidityProviderTrancheSymbol: "slsrRoyUSDC",
            collateralAsset: 0xcD9f5907F92818bC06c9Ad70217f089E190d2a32,
            collateralAssetOracle: address(0),
            collateralAssetOracleType: OracleType.ERC4626SharePrice,
            collateralAssetOracleSpecificParams: abi.encode(
                ERC4626SharePriceOracleParams({
                    baseAssetToNavAssetFeed: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6,
                    feedStalenessThresholdSeconds: 48 hours // USDC/USD heartbeat is 24h; doubled for safety
                })
            ),
            sequencerUptimeFeed: address(0),
            gracePeriodSeconds: 0,
            dustTolerance: 5 * 10 ** 10,
            kernelType: KernelType.RoycoDayBalancerV3Kernel,
            kernelSpecificParams: abi.encode(
                RoycoDayBalancerV3MarketDeploymentTemplate.BalancerV3LiquidityVenueDeploymentParams({
                    maxReinvestmentSlippageWAD: 0.001e18 // 10 bps single-sided liquidity-premium reinvestment slippage gate
                })
            ),
            stSelfLiquidationBonusWAD: 0.01e18,
            minCoverageWAD: 0.2e18,
            minLiquidityWAD: 0.5e18,
            // The caps must SUM to at most WAD (both premiums are carved out of the same senior gain, enforced by the
            // accountant and the deployment validation). An even split never binds: both V2 curves top out at 0.31
            maxJTYieldShareWAD: 0.5e18,
            maxLPTYieldShareWAD: 0.5e18,
            coverageLiquidationUtilizationWAD: calculateCoverageLiquidationUtilizationWAD(0.2e18, 0.02e18),
            fixedTermDurationSeconds: 7 days,
            fixedTermGracePeriodSeconds: 1 days,
            ydmType: YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.1e18, yieldShareAtTargetUtilWAD: 0.14e18, yieldShareAtFullUtilWAD: 0.31e18 })
            ),
            lptYdmSpecificParams: abi.encode(
                AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.18e18, yieldShareAtTargetUtilWAD: 0.22e18, yieldShareAtFullUtilWAD: 0.31e18 })
            ),
            poolInitialization: RoycoDayBalancerV3MarketDeploymentTemplate.PoolInitializationParams({
                collateralAmount: 0, // no collateral leg: the genesis liquidity is quote-only
                quoteAmount: 1e18, // 1 sUSDe (~$1.24): the quote is 18 decimals, and the seed must cover the 1e12 dead-share lock
                minLPTAssetsOut: 0
            }),
            gyroECLPPoolParams: GyroECLPPoolParams({
                name: "Senior SrRoyUSDC / sUSDe",
                symbol: "srsrRoyUSDC/sUSDe",
                eclpParams: IGyroECLPPool.EclpParams({
                    alpha: 979_500_000_000_000_000,
                    beta: 1_000_100_000_000_000_000,
                    c: 707_106_781_186_547_524,
                    s: 707_106_781_186_547_524,
                    lambda: 300_000_000_000_000_000_000
                }),
                derivedEclpParams: IGyroECLPPool.DerivedEclpParams({
                    tauAlpha: IGyroECLPPool.Vector2({
                        x: -95_190_609_145_778_628_634_003_067_669_167_913_840, y: 30_638_993_626_677_852_907_481_149_992_051_688_690
                    }),
                    tauBeta: IGyroECLPPool.Vector2({
                        x: 1_499_756_307_523_889_459_999_505_839_090_567_732, y: 99_988_753_022_617_710_298_167_054_292_168_150_721
                    }),
                    u: 48_345_182_726_651_258_992_189_497_512_372_871_627,
                    v: 65_313_873_324_647_781_528_773_906_086_902_197_476,
                    w: 34_674_879_697_969_928_656_029_992_909_950_847_655,
                    z: -46_845_426_419_127_369_533_890_353_984_596_464_770,
                    dSq: 99_999_999_999_999_999_886_624_093_342_106_115_200
                }),
                quoteAsset: 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497,
                quoteAssetRateProvider: 0x3A244e6B3cfed21593a5E5B347B593C0B48C7dA1
            }),
            stEntryPointConfig: _defaultEntryPointTrancheConfig(),
            jtEntryPointConfig: _defaultEntryPointTrancheConfig(),
            lptEntryPointConfig: _defaultEntryPointTrancheConfig()
        });

        // The remaining sheet markets, one initializer each: this file sits near solc's per-function tag limit
        // ("Tag too large for reserved space" ICE), so the big struct literals stay out of this function's body
        _initializeFalconXConfig();
        _initializeApyxConfig();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SHARED E-CLP CURVE (the srRoyUSDC pool's, shared by the sheet markets)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev The srRoyUSDC pool's E-CLP curve (price band [0.9795, 1.0001], 45° rotation, lambda 300), which the sheet
    ///      markets deliberately share.
    function _srRoyUsdcEclpParams() internal pure returns (IGyroECLPPool.EclpParams memory) {
        return IGyroECLPPool.EclpParams({
            alpha: 979_500_000_000_000_000,
            beta: 1_000_100_000_000_000_000,
            c: 707_106_781_186_547_524,
            s: 707_106_781_186_547_524,
            lambda: 300_000_000_000_000_000_000
        });
    }

    /// @dev The high-precision derived params matching `_srRoyUsdcEclpParams`.
    function _srRoyUsdcDerivedEclpParams() internal pure returns (IGyroECLPPool.DerivedEclpParams memory) {
        return IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({ x: -95_190_609_145_778_628_634_003_067_669_167_913_840, y: 30_638_993_626_677_852_907_481_149_992_051_688_690 }),
            tauBeta: IGyroECLPPool.Vector2({ x: 1_499_756_307_523_889_459_999_505_839_090_567_732, y: 99_988_753_022_617_710_298_167_054_292_168_150_721 }),
            u: 48_345_182_726_651_258_992_189_497_512_372_871_627,
            v: 65_313_873_324_647_781_528_773_906_086_902_197_476,
            w: 34_674_879_697_969_928_656_029_992_909_950_847_655,
            z: -46_845_426_419_127_369_533_890_353_984_596_464_770,
            dSq: 99_999_999_999_999_999_886_624_093_342_106_115_200
        });
    }

    address internal constant SRROYUSDC_SENIOR_TRANCHE = 0x8246872B500ac07eD372aE4df9389687aA018853;
    address internal constant SRROYUSDC_KERNEL = 0x5ab0d3845b937C136DE156981C80811159C0fD7a;

    /// @notice FalconX, per the market sheet: underlying 7.68%, min coverage 3%, min liquidity 10%, JT yield share
    ///         4.5% @ target, LP yield share 9.1% @ target, 7-day observation period, protected exit at 2.99%
    ///         coverage remaining, 1% self-liquidation bonus. Monthly redemptions with 1-month notice.
    function _initializeFalconXConfig() internal {
        _marketConfigs[FALCONX] = MarketConfig({
            marketName: FALCONX,
            chainId: MAINNET,
            seniorTrancheName: "Senior FalconX",
            seniorTrancheSymbol: "srFalconX",
            juniorTrancheName: "Junior FalconX",
            juniorTrancheSymbol: "jrFalconX",
            liquidityProviderTrancheName: "Senior Liquidity FalconX",
            liquidityProviderTrancheSymbol: "slFalconX",
            collateralAsset: 0xC26A6Fa2C37b38E549a4a1807543801Db684f99C,
            collateralAssetOracle: address(0),
            collateralAssetOracleType: OracleType.IdleCDOTranchePrice,
            collateralAssetOracleSpecificParams: abi.encode(
                IdleCDOTranchePriceOracleParams({
                    idleCDO: 0x433D5B175148dA32Ffe1e1A37a939E1b7e79be4d,
                    underlyingTokenToNavAssetFeed: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6,
                    minDeviationWAD: 0.001e18,
                    // The CDO's last virtual-price update, attested on-chain: the AA virtualPrice jumped +0.67% at
                    // block ~25675158 (2026-08-03). RE-ATTEST BEFORE EVERY DEPLOY — a zero holds pricing shut, and a
                    // stale attestation fails the kernel's staleness gate; either way the deployment reverts
                    lastUpdate: 1_785_769_583,
                    // Per-hop thresholds, each sized to ITS source: the Chainlink USDC/USD leg keeps its tight 48h
                    // gate (24h heartbeat, doubled), while the virtual-price clock gets 8 days for Pareto's ~WEEKLY
                    // cadence (one +0.67% step in the last observed 7 days) — the slow CDO no longer loosens the feed
                    feedStalenessThresholdSeconds: 48 hours,
                    virtualPriceStalenessThresholdSeconds: 8 days
                })
            ),
            sequencerUptimeFeed: address(0),
            gracePeriodSeconds: 0,
            dustTolerance: 5 * 10 ** 12,
            kernelType: KernelType.RoycoDayBalancerV3Kernel,
            kernelSpecificParams: abi.encode(
                RoycoDayBalancerV3MarketDeploymentTemplate.BalancerV3LiquidityVenueDeploymentParams({
                    maxReinvestmentSlippageWAD: 0.001e18 // 10 bps single-sided liquidity-premium reinvestment slippage gate
                })
            ),
            stSelfLiquidationBonusWAD: 0.01e18,
            minCoverageWAD: 0.03e18,
            minLiquidityWAD: 0.1e18,
            // The caps must SUM to at most WAD; an even split never binds, both V2 curves top out at 0.31
            maxJTYieldShareWAD: 0.5e18,
            maxLPTYieldShareWAD: 0.5e18,
            coverageLiquidationUtilizationWAD: calculateCoverageLiquidationUtilizationWAD(0.03e18, 0.0299e18),
            fixedTermDurationSeconds: 7 days,
            fixedTermGracePeriodSeconds: 7 days,
            ydmType: YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.005e18, yieldShareAtTargetUtilWAD: 0.045e18, yieldShareAtFullUtilWAD: 0.31e18 })
            ),
            lptYdmSpecificParams: abi.encode(
                AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.051e18, yieldShareAtTargetUtilWAD: 0.091e18, yieldShareAtFullUtilWAD: 0.31e18 })
            ),
            poolInitialization: RoycoDayBalancerV3MarketDeploymentTemplate.PoolInitializationParams({
                collateralAmount: 0, quoteAmount: 0.5e18, minLPTAssetsOut: 0
            }),
            gyroECLPPoolParams: GyroECLPPoolParams({
                name: "Senior FalconX / Senior SrRoyUSDC",
                symbol: "srFalconX/srsrRoyUSDC",
                eclpParams: _srRoyUsdcEclpParams(),
                derivedEclpParams: _srRoyUsdcDerivedEclpParams(),
                quoteAsset: SRROYUSDC_SENIOR_TRANCHE,
                quoteAssetRateProvider: SRROYUSDC_KERNEL
            }),
            stEntryPointConfig: _defaultEntryPointTrancheConfig(),
            jtEntryPointConfig: _defaultEntryPointTrancheConfig(),
            lptEntryPointConfig: _defaultEntryPointTrancheConfig()
        });
    }

    /// @notice APYX, per the market sheet: underlying 10.23%, min coverage 15%, min liquidity 10%, JT yield share
    ///         15% @ target, LP yield share 8% @ target, 30-day observation period, protected exit at 3% coverage
    ///         remaining, NO self-liquidation bonus. 20-day redemption cooldown.
    function _initializeApyxConfig() internal {
        _marketConfigs[APYX] = MarketConfig({
            marketName: APYX,
            chainId: MAINNET,
            seniorTrancheName: "Senior apyUSD",
            seniorTrancheSymbol: "srapyUSD",
            juniorTrancheName: "Junior apyUSD",
            juniorTrancheSymbol: "jrapyUSD",
            liquidityProviderTrancheName: "Senior Liquidity apyUSD",
            liquidityProviderTrancheSymbol: "slapyUSD",
            // apyUSD (18 decimals), APYX's ERC4626 vault over apxUSD, per the dawn apyUSD market
            collateralAsset: 0x38EEb52F0771140d10c4E9A9a72349A329Fe8a6A,
            collateralAssetOracle: address(0),
            collateralAssetOracleType: OracleType.ERC4626SharePrice,
            collateralAssetOracleSpecificParams: abi.encode(
                // Chainlink apxUSD/USD exchange rate (https://data.chain.link/feeds/ethereum/mainnet/apxusd-usd-exchange-rate)
                ERC4626SharePriceOracleParams({
                    baseAssetToNavAssetFeed: 0x651b101f72F82630cf59c68E6EE4305aFBd3B1F5,
                    feedStalenessThresholdSeconds: 48 hours // the feed pushes ~every 12 hours; 48h mirrors dawn
                })
            ),
            sequencerUptimeFeed: address(0),
            gracePeriodSeconds: 0,
            dustTolerance: 5, // 18-decimal collateral, mirrors dawn
            kernelType: KernelType.RoycoDayBalancerV3Kernel,
            kernelSpecificParams: abi.encode(
                RoycoDayBalancerV3MarketDeploymentTemplate.BalancerV3LiquidityVenueDeploymentParams({ maxReinvestmentSlippageWAD: 0.001e18 })
            ),
            stSelfLiquidationBonusWAD: 0,
            minCoverageWAD: 0.15e18,
            minLiquidityWAD: 0.1e18,
            maxJTYieldShareWAD: 0.5e18,
            maxLPTYieldShareWAD: 0.5e18,
            coverageLiquidationUtilizationWAD: calculateCoverageLiquidationUtilizationWAD(0.15e18, 0.03e18),
            fixedTermDurationSeconds: 30 days,
            fixedTermGracePeriodSeconds: 1 days,
            ydmType: YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.11e18, yieldShareAtTargetUtilWAD: 0.15e18, yieldShareAtFullUtilWAD: 0.31e18 })
            ),
            lptYdmSpecificParams: abi.encode(
                AdaptiveCurveYDM_V2_Params({ yieldShareAtZeroUtilWAD: 0.04e18, yieldShareAtTargetUtilWAD: 0.08e18, yieldShareAtFullUtilWAD: 0.31e18 })
            ),
            poolInitialization: RoycoDayBalancerV3MarketDeploymentTemplate.PoolInitializationParams({
                collateralAmount: 0, quoteAmount: 0.5e18, minLPTAssetsOut: 0
            }),
            gyroECLPPoolParams: GyroECLPPoolParams({
                name: "Senior apyUSD / Senior SrRoyUSDC",
                symbol: "srapyUSD/srsrRoyUSDC",
                eclpParams: _srRoyUsdcEclpParams(),
                derivedEclpParams: _srRoyUsdcDerivedEclpParams(),
                quoteAsset: SRROYUSDC_SENIOR_TRANCHE,
                quoteAssetRateProvider: SRROYUSDC_KERNEL
            }),
            stEntryPointConfig: _defaultEntryPointTrancheConfig(),
            jtEntryPointConfig: _defaultEntryPointTrancheConfig(),
            lptEntryPointConfig: _defaultEntryPointTrancheConfig()
        });
    }

    /// @notice The default entry point config a tranche is enabled with at market deployment
    /// @dev The collateral asset oracle gate starts disabled and is armed post-deployment (the oracle itself is resolved live from the kernel)
    /// @dev Requests get a finite execution window (one delay-length each): once it elapses they may only be cancelled
    function _defaultEntryPointTrancheConfig() internal pure returns (IRoycoDayEntryPoint.TrancheConfig memory) {
        return IRoycoDayEntryPoint.TrancheConfig({
            enabled: true,
            depositDelaySeconds: 5 minutes,
            depositExpirySeconds: 5 minutes,
            redemptionDelaySeconds: 24 hours,
            redemptionExpirySeconds: 24 hours,
            gateByOracleUpdate: false
        });
    }
}
