// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManager } from "../../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoAccessManager } from "../../../../src/factory/RoycoAccessManager.sol";
import { RoycoFactory } from "../../../../src/factory/RoycoFactory.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { IRoycoDayAccountant } from "../../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../../../../src/interfaces/IYDM.sol";
import { IBaseTemplate } from "../../../../src/interfaces/factory/IBaseTemplate.sol";
import { IRoycoProtocolTemplate } from "../../../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { TrancheType } from "../../../../src/libraries/Types.sol";
import { toNAVUnits } from "../../../../src/libraries/Units.sol";
import { BalancerV3PoolCreationParams } from "../../../../src/libraries/logic/liquidity-venue/BalancerV3VenueCreationLogic.sol";
import { DeploymentResult, MarketUpstream } from "../../../config/DeploymentTypes.sol";
import { DeployScriptBase } from "../../core/DeployScriptBase.sol";
import { RoycoDeterministic } from "../../utils/RoycoDeterministic.sol";
import { YDMLib } from "../../utils/YDMLib.sol";
import { DayMarketRegistry } from "./DayMarketRegistry.sol";
import { DayMarketConfig } from "./DayMarketTypes.sol";
import { CollateralOracleDeployer } from "./DeployCollateralOracle.s.sol";
import { YDMDeployer } from "./DeployYDM.s.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/**
 * @title DeployMarketComponent
 * @notice Deploys ONE Royco Day market GIVEN ITS CONFIG STRUCT against a fully bootstrapped chain: resolves (or
 *         deploys) the collateral oracle, maps the template-shaped config onto the template's `MarketParams`, mines
 *         the market id so the senior-tranche proxy sorts below the quote asset (pool token0), approves the genesis
 *         seed legs, and executes the factory's single wiring transaction.
 * @dev Upstream chain addresses arrive at CONSTRUCTION in a struct; the market config arrives as a VALUE — no name
 *      lookup is baked in (the CLI wrapper resolves MARKET_NAME through the family registry). The wiring tx carries
 *      the explicit 16.7M gas stipend, deliberately just under the EIP-7825 per-transaction cap of 16,777,216.
 */
contract DeployMarketComponent is CollateralOracleDeployer, YDMDeployer {
    MarketUpstream internal UP;

    constructor(MarketUpstream memory _up) {
        UP = _up;
    }

    /// @notice Deploys the market under its own broadcast
    function deployMarket(DayMarketConfig memory _config, bytes32 _marketIdSeed, uint256 _deployerPrivateKey) public returns (DeploymentResult memory result) {
        vm.startBroadcast(_deployerPrivateKey);
        result = _deployMarket(_config, _marketIdSeed, vm.addr(_deployerPrivateKey));
        vm.stopBroadcast();
    }

    function _deployMarket(DayMarketConfig memory _config, bytes32 _marketIdSeed, address _deployer) internal returns (DeploymentResult memory) {
        if (ENABLE_LOGGING) {
            console2.log(string.concat("  marketId seed (", _config.marketName, "):"));
            console2.logBytes32(_marketIdSeed);
        }

        // Resolve the kernel's collateral asset oracle before params are built (deployed here when the config leaves it unset)
        if (_config.oracle.deployed == address(0)) {
            _config.oracle.deployed = deployCollateralOracle(_config, _marketIdSeed);
        }

        // Resolve the market's yield distribution models before params are built (deployed here when the config leaves them unset)
        // The junior and liquidity provider selections may resolve to the same instance since curves are keyed per tranche type
        if (_config.accountant.jtYdm.deployed == address(0)) _config.accountant.jtYdm.deployed = deployYDM("JT model  ", _config.accountant.jtYdm);
        if (_config.accountant.lptYdm.deployed == address(0)) _config.accountant.lptYdm.deployed = deployYDM("LPT model ", _config.accountant.lptYdm);
        RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory params = buildMarketParams(_config, _marketIdSeed, UP.factory, _deployer);

        // The template pulls the market's genesis pool liquidity from the account calling the factory's deployment
        // entrypoint (the broadcasting deployer here), so approve the template from inside the broadcast
        IERC20(_config.pool.quoteAsset).approve(UP.template, _config.poolInitialization.quoteAmount);
        uint256 collateralSeed = _config.poolInitialization.collateralAmount;
        if (collateralSeed != 0) IERC20(_config.collateralAsset).approve(UP.template, collateralSeed);

        IRoycoProtocolTemplate.DeploymentResult memory r = RoycoFactory(UP.factory).executeMarketDeployment{ gas: 16_700_000 }(UP.template, abi.encode(params));

        // The template deploys the entire market in this one transaction: every tranche proxy, the Gyro E-CLP pool and
        // its BPT oracle, the accountant, and the kernel, all against the implementations it was constructed with.
        _logSection("Market deployment transaction (executeMarketDeployment)");
        _logCreated("SeniorTranche (proxy)  ", r.seniorTranche);
        _logCreated("JuniorTranche (proxy)  ", r.juniorTranche);
        _logCreated("LiquidityProviderTranche (proxy)", r.liquidityProviderTranche);
        _logCreated("Accountant (proxy)     ", r.accountant);
        _logCreated("Kernel (proxy)         ", r.kernel);
        {
            RoycoDayBalancerV3MarketDeploymentTemplate.ExtraContractsDeployedResult memory extras =
                abi.decode(r.extras, (RoycoDayBalancerV3MarketDeploymentTemplate.ExtraContractsDeployedResult));
            _logCreated("Balancer E-CLP pool    ", extras.balancerPool);
            _logCreated("BPT oracle             ", extras.bptOracle);
        }

        return DeploymentResult({
            factory: RoycoFactory(UP.factory),
            accessManager: AccessManager(UP.accessManager),
            ydm: IYDM(r.ydm),
            seniorTranche: IRoycoVaultTranche(r.seniorTranche),
            juniorTranche: IRoycoVaultTranche(r.juniorTranche),
            accountant: IRoycoDayAccountant(r.accountant),
            kernel: IRoycoDayKernel(r.kernel),
            roycoBlacklist: UP.roycoBlacklist,
            entryPoint: UP.entryPoint,
            marketSyncer: UP.marketSyncer
        });
    }

    /**
     * @notice Builds the template `MarketParams` from the template-shaped market config — a thin mapping now that the
     *         config mirrors the template's own structs — and mines the market id last
     * @dev The component salts hash the WHOLE params struct plus the deployer, so the id can only be mined once every
     *      other field is settled: it is what makes the senior tranche's CREATE3 proxy sort below the quote asset
     */
    function buildMarketParams(
        DayMarketConfig memory _config,
        bytes32 _marketIdSeed,
        address _factory,
        address _deployer
    )
        public
        pure
        returns (RoycoDayBalancerV3MarketDeploymentTemplate.MarketParams memory params)
    {
        params.stParams = _config.stParams;
        params.jtParams = _config.jtParams;
        params.lptParams = _config.lptParams;
        params.collateralAsset = _config.collateralAsset;
        params.quoteAsset = _config.pool.quoteAsset;

        // The Gyro E-CLP pool the template creates for this market's liquidity venue
        params.poolCreationParams = BalancerV3PoolCreationParams({
            name: _config.pool.name,
            symbol: _config.pool.symbol,
            eclpParams: _config.pool.eclpParams,
            derivedEclpParams: _config.pool.derivedEclpParams,
            quoteAssetRateProvider: _config.pool.quoteAssetRateProvider
        });

        // Genesis pool liquidity, seeded by the template as a multi-asset deposit once the market is wired
        params.poolInitializationParams = _config.poolInitialization;

        // The market's yield distribution models, resolved (or deployed) by the pipeline and passed by address
        params.jtYdm = _config.accountant.jtYdm.deployed;
        params.lptYdm = _config.accountant.lptYdm.deployed;

        // Accountant params. BOTH YDM curves get initialization data so the accountant initializes each of them.
        params.accountantParams = IBaseTemplate.AccountantDeploymentParams({
            fixedTermGracePeriodSeconds: _config.accountant.fixedTermGracePeriodSeconds,
            minCoverageWAD: _config.accountant.minCoverageWAD,
            coverageLiquidationUtilizationWAD: _config.accountant.coverageLiquidationUtilizationWAD,
            minLiquidityWAD: _config.accountant.minLiquidityWAD,
            jtYDMInitializationData: YDMLib.buildYDMInitializationData(TrancheType.JUNIOR, _config.accountant.jtYdm.ydmType, _config.accountant.jtYdm.curveParams),
            lptYDMInitializationData: YDMLib.buildYDMInitializationData(
                TrancheType.LIQUIDITY_PROVIDER, _config.accountant.lptYdm.ydmType, _config.accountant.lptYdm.curveParams
            ),
            maxJTYieldShareWAD: _config.accountant.maxJTYieldShareWAD,
            maxLPTYieldShareWAD: _config.accountant.maxLPTYieldShareWAD,
            fixedTermDurationSeconds: _config.accountant.fixedTermDurationSeconds,
            dustTolerance: toNAVUnits(_config.accountant.dustTolerance)
        });

        params.kernelSpecificParams = _config.kernel.kernelSpecificParams; // the venue params blob
        params.stSelfLiquidationBonusWAD = _config.kernel.stSelfLiquidationBonusWAD;
        params.collateralAssetOracle = _config.oracle.deployed;
        params.sequencerUptimeFeed = _config.kernel.sequencerUptimeFeed;
        params.gracePeriodSeconds = _config.kernel.gracePeriodSeconds;
        // Per-tranche entry point configs applied by the template (via the factory) after the market is deployed.
        params.entryPointTrancheConfigs = RoycoDayBalancerV3MarketDeploymentTemplate.EntryPointTrancheConfigs({
            st: _config.stEntryPointConfig, jt: _config.jtEntryPointConfig, lpt: _config.lptEntryPointConfig
        });

        params.marketId = RoycoDeterministic.mineMarketId(params, _marketIdSeed, _factory, _deployer);
    }
}

/// @notice CLI entrypoint: resolves MARKET_NAME through the family registry against the predicted chain addresses
contract DeployMarket is DeployMarketComponent, DayMarketRegistry {
    constructor() DeployMarketComponent(_predictUpstream()) { }

    function _predictUpstream() internal view returns (MarketUpstream memory up) {
        bool isTest = vm.envOr("IS_TEST_DEPLOYMENT", false);
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        up.accessManager = RoycoDeterministic.create2Address(
            RoycoDeterministic.singletonSalt("ROYCO_ACCESS_MANAGER", isTest),
            keccak256(abi.encodePacked(type(RoycoAccessManager).creationCode, abi.encode(deployer)))
        );
        up.factory = RoycoDeterministic.predictFactoryProxy(deployer, isTest);
        (up.entryPoint, up.marketSyncer) = RoycoDeterministic.predictPeripherySingletons(up.accessManager, up.factory, isTest);
        // The blacklist proxy and template addresses depend on live construction params; the standalone run()
        // resolves them from the chain (TEMPLATE_ADDRESS env + the template's recorded blacklist) before deploying
    }

    function run() external {
        enableLogging();
        string memory marketName = vm.envString("MARKET_NAME");
        DayMarketConfig memory cfg = getDayMarketConfig(marketName);

        // Resolve the live template + blacklist off the chain (the factory has exactly the registered Day template)
        UP.template = _resolveEnabledTemplate();
        UP.roycoBlacklist = RoycoDayBalancerV3MarketDeploymentTemplate(UP.template).ROYCO_BLACKLIST();

        deployMarket(cfg, getMarketId(marketName, UP.factory), vm.envUint("DEPLOYER_PRIVATE_KEY"));
    }

    /// @dev The chain has ONE enabled Day template at a time; resolve it from the factory's registry
    function _resolveEnabledTemplate() internal view returns (address) {
        return vm.envAddress("TEMPLATE_ADDRESS");
    }
}
