// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { Math } from "../../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoDayEntryPoint } from "../../../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { WAD } from "../../../../../src/libraries/Constants.sol";
import { EnvConfig } from "../../../config/EnvConfig.sol";
import { RoycoDeterministic } from "../../../utils/RoycoDeterministic.sol";
import { DayMarketConfig } from "../DayMarketTypes.sol";

/**
 * @title DayMarketRegistryBase
 * @notice Shared storage and helpers every per-market config file builds against: the name-keyed config mapping, the
 *         chain-guarded getter, the test override seam, and the curve/entry-point defaults the markets share.
 * @dev One market per file on top of this base — the per-function struct literals are what used to push the old
 *      monolithic config file into solc's "Tag too large for reserved space" ICE territory.
 */
abstract contract DayMarketRegistryBase is EnvConfig {
    using Math for uint256;

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET NAMES
    // ═══════════════════════════════════════════════════════════════════════════

    string public constant SNUSD = "snUSD";
    string public constant SRROYUSDC = "srRoyUSDC";
    string public constant FALCONX = "FalconX";
    string public constant APYX = "APYX";

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    mapping(string marketName => DayMarketConfig) internal _dayMarketConfigs;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error MarketConfigNotFound(string marketName);
    error MarketChainIdMismatch(string marketName, uint256 expectedChainId, uint256 actualChainId);
    error MarketIdNotConfigured(string marketName, address factory);

    // ═══════════════════════════════════════════════════════════════════════════
    // MINED MARKET IDs (per market, per factory)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The mined marketId SEED to use for `marketName` when deploying against `factory`, keyed by the factory
    ///         proxy address predicted from this build's creation code
    mapping(bytes32 marketNameHash => mapping(address factory => bytes32 marketId)) internal _marketIds;

    /// @notice Registers each market's mined marketId seed, keyed by the factory it deploys against
    function _initializeMinedMarketIds() internal {
        bytes32 snUSDHash = keccak256(bytes(SNUSD));
        // snUSD against the production factory (prod deployer, "_PROD" salts), mined offline at nonce 0.
        _marketIds[snUSDHash][RoycoDeterministic.predictFactoryProxy(DEPLOYER, false)] = 0xb3d433a58a0d62af783a1fcb783e83f5efc3867dfa2e807ed7455be4373d0bda;
        // snUSD against the local test-harness factory ("_PROD" salts, the suite runs on the prod config).
        address localFactory = RoycoDeterministic.predictFactoryProxy(TEST_HARNESS_DEPLOYER, false);
        _marketIds[snUSDHash][localFactory] = RoycoDeterministic.marketIdSeed(SNUSD, localFactory);
        // snUSD against the test-environment factory (test salts, prod deployer key).
        address testEnvFactory = RoycoDeterministic.predictFactoryProxy(DEPLOYER, true);
        _marketIds[snUSDHash][testEnvFactory] = RoycoDeterministic.marketIdSeed(SNUSD, testEnvFactory);

        // Every other market, seeded per factory from the build-time seed the params builder mines on top of
        _seedMarketIdsForAllFactories(SRROYUSDC);
        _seedMarketIdsForAllFactories(FALCONX);
        _seedMarketIdsForAllFactories(APYX);
    }

    /// @notice Seeds `_name`'s market id for the production, local test-harness, and test-environment factories
    function _seedMarketIdsForAllFactories(string memory _name) internal {
        bytes32 nameHash = keccak256(bytes(_name));
        address prodFactory = RoycoDeterministic.predictFactoryProxy(DEPLOYER, false);
        address localFactory = RoycoDeterministic.predictFactoryProxy(TEST_HARNESS_DEPLOYER, false);
        address testEnvFactory = RoycoDeterministic.predictFactoryProxy(DEPLOYER, true);
        _marketIds[nameHash][prodFactory] = RoycoDeterministic.marketIdSeed(_name, prodFactory);
        _marketIds[nameHash][localFactory] = RoycoDeterministic.marketIdSeed(_name, localFactory);
        _marketIds[nameHash][testEnvFactory] = RoycoDeterministic.marketIdSeed(_name, testEnvFactory);
    }

    /// @notice The market id SEED for `_marketName` against `_factory`, which the params builder mines on top of
    /// @dev Reverts if none is configured
    function getMarketId(string memory _marketName, address _factory) public view returns (bytes32 marketId) {
        marketId = _marketIds[keccak256(bytes(_marketName))][_factory];
        require(marketId != bytes32(0), MarketIdNotConfigured(_marketName, _factory));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GETTER + TEST OVERRIDE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The market's full config, guarded against a chain mismatch
    function getDayMarketConfig(string memory _marketName) public view returns (DayMarketConfig memory config) {
        config = _dayMarketConfigs[_marketName];
        if (bytes(config.marketName).length == 0) revert MarketConfigNotFound(_marketName);
        if (config.chainId != block.chainid) revert MarketChainIdMismatch(_marketName, config.chainId, block.chainid);
    }

    /// @notice Overrides a market's config in place (keyed by `_config.marketName`), for tests whose calibrated
    ///         expectations must not drift with the canonical parameters
    function overrideDayMarketConfigForTest(DayMarketConfig memory _config) public {
        _dayMarketConfigs[_config.marketName] = _config;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SHARED HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Calculates the coverage liquidation utilization WAD from the min coverage and the coverage remaining
    function calculateCoverageLiquidationUtilizationWAD(uint256 _minCoverageWAD, uint256 _coverageRemainingWAD) internal pure returns (uint256) {
        return _minCoverageWAD.mulDiv(WAD, _coverageRemainingWAD, Math.Rounding.Floor);
    }

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

    /// @dev The srRoyUSDC market's senior tranche and kernel under the CURRENT test-salt deployment: the sheet
    ///      markets pair against this ST with the srRoyUSDC KERNEL as the leg's rate provider. RE-DERIVE both for
    ///      any other environment or salt — they are deployment-specific addresses.
    address internal constant SRROYUSDC_SENIOR_TRANCHE = 0x8246872B500ac07eD372aE4df9389687aA018853;
    address internal constant SRROYUSDC_KERNEL = 0x5ab0d3845b937C136DE156981C80811159C0fD7a;

    /// @notice The default entry point config a tranche is enabled with at market deployment
    /// @dev The collateral asset oracle gate starts disabled and is armed post-deployment; requests get a finite
    ///      execution window (one delay-length each) after which they may only be cancelled
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
