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
    string public constant DMG = "DMG";
    string public constant DUSD = "DUSD";
    string public constant SUSDAI = "sUSDai";

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    mapping(string marketName => DayMarketConfig) internal _dayMarketConfigs;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error MarketConfigNotFound(string marketName);
    error MarketChainIdMismatch(string marketName, uint256 expectedChainId, uint256 actualChainId);

    // ═══════════════════════════════════════════════════════════════════════════
    // MINED MARKET IDs (per market, per factory)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice PRE-MINED marketId seed overrides, keyed by (market, factory). Only entries mined offline live here —
    ///         every other (market, factory) pair derives its seed on demand in `getMarketId`
    mapping(bytes32 marketNameHash => mapping(address factory => bytes32 marketId)) internal _marketIds;

    /// @notice The production factory the pre-mined seeds were mined against (pinned by Test_DeterministicAddresses)
    address internal constant PROD_FACTORY = 0xaAAaaAAAaE46cA12Bf3810DF8C13c5E8A4400812;

    /// @notice Registers the pre-mined marketId seeds, keyed by the factory address each was mined against
    function _initializeMinedMarketIds() internal {
        // snUSD against the production factory, mined offline at nonce 0
        _marketIds[keccak256(bytes(SNUSD))][PROD_FACTORY] = 0xb3d433a58a0d62af783a1fcb783e83f5efc3867dfa2e807ed7455be4373d0bda;
    }

    /// @notice The market id SEED for `_marketName` against `_factory`, which the params builder mines on top of
    /// @dev A pre-mined override wins when one is registered; otherwise the seed derives purely from the
    ///      (market, factory) pair, so ANY factory works — no deployer address enters the derivation
    function getMarketId(string memory _marketName, address _factory) public view returns (bytes32 marketId) {
        marketId = _marketIds[keccak256(bytes(_marketName))][_factory];
        if (marketId == bytes32(0)) marketId = RoycoDeterministic.marketIdSeed(_marketName, _factory);
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

    /// @dev The exit-liquidity-prioritized E-CLP curve (price band [0.98, 1.0003], 45° rotation, lambda 250): the tight
    ///      band caps the discount at which senior shares can exit through the pool. Every market deliberately
    ///      shares it.
    function _exitLiquidityPrioritizedEclpParams() internal pure returns (IGyroECLPPool.EclpParams memory) {
        return IGyroECLPPool.EclpParams({
            alpha: 980_000_000_000_000_000,
            beta: 1_000_300_000_000_000_000,
            c: 707_106_781_186_547_524,
            s: 707_106_781_186_547_524,
            lambda: 250_000_000_000_000_000_000
        });
    }

    /// @dev The high-precision derived params matching `_exitLiquidityPrioritizedEclpParams`.
    function _exitLiquidityPrioritizedDerivedEclpParams() internal pure returns (IGyroECLPPool.DerivedEclpParams memory) {
        return IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({ x: -92_975_357_432_315_416_605_491_371_255_356_493_443, y: 36_818_241_543_196_904_975_774_583_017_121_171_403 }),
            tauBeta: IGyroECLPPool.Vector2({ x: 3_746_804_827_358_009_532_998_249_894_673_148_143, y: 99_929_782_615_523_019_584_751_990_190_862_643_080 }),
            u: 48_361_081_129_836_713_014_414_996_374_502_815_654,
            v: 68_374_012_079_359_962_202_743_630_490_639_666_742,
            w: 31_555_770_536_163_057_268_712_062_638_611_327_323,
            z: -44_614_276_302_478_703_485_664_720_423_548_546_517,
            dSq: 99_999_999_999_999_999_886_624_093_342_106_115_200
        });
    }

    /// @dev The srRoyUSDC market's senior tranche and kernel
    address internal constant SRROYUSDC_SENIOR_TRANCHE = address(0); // TODO
    address internal constant SRROYUSDC_KERNEL = address(0); // TODO

    /// @notice The default entry point config a tranche is enabled with at market deployment
    function _defaultEntryPointTrancheConfig() internal pure returns (IRoycoDayEntryPoint.TrancheConfig memory) {
        return IRoycoDayEntryPoint.TrancheConfig({
            enabled: true,
            depositDelaySeconds: 5 minutes,
            depositExpirySeconds: 24 hours,
            redemptionDelaySeconds: 24 hours,
            redemptionExpirySeconds: 24 hours,
            gateByOracleUpdate: false
        });
    }
}
