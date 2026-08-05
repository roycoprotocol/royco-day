// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ChainlinkPriceOracle } from "../../../../src/oracle/ChainlinkPriceOracle.sol";
import { ERC4626SharePriceOracle } from "../../../../src/oracle/ERC4626SharePriceOracle.sol";
import { IdleCDOTranchePriceOracle } from "../../../../src/oracle/IdleCDOTranchePriceOracle.sol";
import { MakinaSharePriceOracle } from "../../../../src/oracle/MakinaSharePriceOracle.sol";
import {
    ChainlinkPriceOracleParams,
    ERC4626SharePriceOracleParams,
    IdleCDOTranchePriceOracleParams,
    MakinaSharePriceOracleParams,
    OracleType
} from "../../../config/DeploymentTypes.sol";
import { DeployScriptBase } from "../../core/DeployScriptBase.sol";
import { CollateralOracleConfig, DayMarketConfig } from "./DayMarketTypes.sol";

/**
 * @title CollateralOracleDeployer
 * @notice Deploys a market's collateral-asset oracle adapter from its config recipe, at the market-scoped CREATE2
 *         salt derived from the market-id SEED (not the mined final id), so a previously deployed oracle keeps its
 *         address across re-runs and re-mines.
 * @dev A mixin: inherited by the market script (which auto-deploys an unset oracle) and by the standalone CLI
 *      wrapper. Every adapter kind is a fully immutable, unpermissioned direct deployment — reconfiguration is a
 *      redeploy plus a kernel oracle repoint.
 */
abstract contract CollateralOracleDeployer is DeployScriptBase {
    error UnsupportedOracleType(OracleType oracleType);

    /**
     * @notice A market-scoped CREATE2 salt for the one market contract still deployed outside the template
     * @dev Shares the template's `keccak256("ROYCO_MARKET_" ‖ marketId ‖ tag)` preimage so a previously deployed
     *      oracle keeps its address, but the tags used with it are disjoint from the template's component tags
     */
    function _marketScopedSalt(bytes32 _marketId, bytes32 _componentTag) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("ROYCO_MARKET_", _marketId, _componentTag));
    }

    /// @notice CREATE2-deploys the collateral oracle adapter selected by the market's oracle recipe
    function deployCollateralOracle(DayMarketConfig memory _config, bytes32 _marketIdSeed) public returns (address oracle) {
        _logSection("Collateral asset oracle");
        CollateralOracleConfig memory o = _config.oracle;
        bytes memory ctorArgs;
        bytes memory creationCode;
        if (o.oracleType == OracleType.ChainlinkPrice) {
            ChainlinkPriceOracleParams memory p = abi.decode(o.specificParams, (ChainlinkPriceOracleParams));
            creationCode = type(ChainlinkPriceOracle).creationCode;
            ctorArgs = abi.encode(_config.collateralAsset, p.collateralToNavAssetFeed, p.feedStalenessThresholdSeconds);
        } else if (o.oracleType == OracleType.ERC4626SharePrice) {
            ERC4626SharePriceOracleParams memory p = abi.decode(o.specificParams, (ERC4626SharePriceOracleParams));
            creationCode = type(ERC4626SharePriceOracle).creationCode;
            ctorArgs = abi.encode(_config.collateralAsset, p.baseAssetToNavAssetFeed, p.feedStalenessThresholdSeconds);
        } else if (o.oracleType == OracleType.MakinaSharePrice) {
            MakinaSharePriceOracleParams memory p = abi.decode(o.specificParams, (MakinaSharePriceOracleParams));
            creationCode = type(MakinaSharePriceOracle).creationCode;
            ctorArgs = abi.encode(p.makinaMachine, p.accountingAssetToNavAssetFeed, p.feedStalenessThresholdSeconds);
        } else if (o.oracleType == OracleType.IdleCDOTranchePrice) {
            IdleCDOTranchePriceOracleParams memory p = abi.decode(o.specificParams, (IdleCDOTranchePriceOracleParams));
            creationCode = type(IdleCDOTranchePriceOracle).creationCode;
            ctorArgs = abi.encode(
                p.idleCDO,
                _config.collateralAsset,
                p.underlyingTokenToNavAssetFeed,
                p.minDeviationWAD,
                p.lastUpdate,
                p.feedStalenessThresholdSeconds,
                p.virtualPriceStalenessThresholdSeconds
            );
        } else {
            revert UnsupportedOracleType(o.oracleType);
        }
        bool existed;
        (oracle, existed) = deployWithSanityChecks(_marketScopedSalt(_marketIdSeed, "COLLATERAL_ASSET_ORACLE"), abi.encodePacked(creationCode, ctorArgs), false);
        _logDeploy("CollateralAssetOracle  ", oracle, existed);
    }
}
