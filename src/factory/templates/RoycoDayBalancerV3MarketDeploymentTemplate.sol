// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { ILPOracleFactoryBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { IProtocolFeeController } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IProtocolFeeController.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IVaultAdmin } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultAdmin.sol";
import { HooksConfig as BalancerV3HooksConfig } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { ERC20BurnableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoAuth } from "../../interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayEntryPoint } from "../../interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { IRoycoAccessManager } from "../../interfaces/factory/IRoycoAccessManager.sol";
import { IRoycoFactory } from "../../interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../interfaces/factory/IRoycoProtocolTemplate.sol";
import { RoycoDayBalancerV3Kernel } from "../../kernels/RoycoDayBalancerV3Kernel.sol";
import { BalancerV3LiquidityVenue } from "../../kernels/base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";
import { TrancheType } from "../../libraries/Types.sol";
import { BalancerV3PoolCreationParams, BalancerV3VenueCreationLogic } from "../../libraries/logic/liquidity-venue/BalancerV3VenueCreationLogic.sol";
import { RoycoLiquidityProviderTranche } from "../../tranches/RoycoLiquidityProviderTranche.sol";
import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_BALANCER_POOL_MANAGER_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_MARKET_OPS_ROLE,
    ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE,
    ADMIN_ORACLE_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    BURNER_ROLE,
    JT_LP_ROLE,
    LPT_LP_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE
} from "../Roles.sol";
import { BaseDeploymentTemplate } from "./base/BaseDeploymentTemplate.sol";
import { TAG_ACCOUNTANT_PROXY, TAG_BALANCER_V3_POOL, TAG_JT_PROXY, TAG_KERNEL_PROXY, TAG_LPT_PROXY, TAG_ST_PROXY } from "./base/Constants.sol";
import { YDMType } from "./base/Types.sol";
import { EntryPointConfigurer } from "./periphery/EntryPointConfigurer.sol";
import { MarketSyncerConfigurer } from "./periphery/MarketSyncerConfigurer.sol";

/**
 * @notice Local single-function redeclaration of Balancer v3's two-argument `withdrawPoolCreatorFees(address,address)`
 *         overload so the compiler can derive its selector. Balancer's real `IProtocolFeeController` also declares a
 *         one-argument overload of the same name, which makes `IProtocolFeeController.withdrawPoolCreatorFees.selector`
 *         ambiguous and non-compiling, so the selector is sourced from this unambiguous interface instead of a
 *         hand-hashed signature string
 */
interface IWithdrawPoolCreatorFeesTwoArgOverload {
    function withdrawPoolCreatorFees(address pool, address recipient) external;
}

/**
 * @title RoycoDayBalancerV3MarketDeploymentTemplate
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base for every Royco Day market that has their LPT deployed into a Balancer V3 Gyroscope ECLP pool
 */
contract RoycoDayBalancerV3MarketDeploymentTemplate is BaseDeploymentTemplate, EntryPointConfigurer, MarketSyncerConfigurer {
    // ═══════════════════════════════════════════════════════════════════════════
    // PARAM STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice The chain-wide contracts this template is pinned to at construction and reuses for every market it deploys
     * @custom:field factory - The Royco factory this template deploys through
     * @custom:field balancerV3PoolFactory - The Balancer V3 Gyro E-CLP pool factory
     * @custom:field eclpLPOracleFactory - The Balancer E-CLP LP oracle factory that creates each market's BPT TVL oracle
     * @custom:field bptOracleConstantPriceFeed - The shared stateless constant-1.0 price feed both pool legs are priced against
     * @custom:field roycoDayEntryPoint - The chain's entry point singleton, configured with each market's tranches
     * @custom:field roycoMarketSyncer - The chain's market syncer singleton, registered with each market's kernel
     * @custom:field seniorTrancheBeacon - The senior tranche beacon, holding the implementation every senior proxy resolves against
     * @custom:field juniorTrancheBeacon - The junior tranche beacon
     * @custom:field liquidityProviderTrancheBeacon - The liquidity provider tranche beacon
     * @custom:field kernelBeacon - The Day kernel beacon for this template's kernel family
     * @custom:field accountantBeacon - The accountant beacon
     * @custom:field jtYdms - The junior tranche's yield distribution model instance for each `YDMType`, indexed by the enum
     * @custom:field lptYdms - The liquidity provider tranche's model instance for each `YDMType`, indexed by the enum
     */
    struct TemplateConstructionParams {
        IRoycoFactory factory;
        GyroECLPPoolFactory balancerV3PoolFactory;
        ILPOracleFactoryBase eclpLPOracleFactory;
        address bptOracleConstantPriceFeed;
        address roycoDayEntryPoint;
        address roycoMarketSyncer;
        address seniorTrancheBeacon;
        address juniorTrancheBeacon;
        address liquidityProviderTrancheBeacon;
        address kernelBeacon;
        address accountantBeacon;
        address[3] jtYdms;
        address[3] lptYdms;
    }

    /**
     * @notice Per-tranche entry point configurations applied on the pre-deployed entry point after the market is deployed
     * @custom:field st - The entry point configuration for the senior tranche
     * @custom:field jt - The entry point configuration for the junior tranche
     * @custom:field lt - The entry point configuration for the liquidity provider tranche
     */
    struct EntryPointTrancheConfigs {
        IRoycoDayEntryPoint.TrancheConfig st;
        IRoycoDayEntryPoint.TrancheConfig jt;
        IRoycoDayEntryPoint.TrancheConfig lt;
    }

    /**
     * @notice Top-level params struct passed to `deployMarket(bytes)`
     * @custom:field marketId - A caller-supplied identifier for the market, mixed into the deterministic deployment salts
     * @custom:field stTranche - The senior tranche initialization params
     * @custom:field jtTranche - The junior tranche initialization params
     * @custom:field lptTranche - The liquidity provider tranche initialization params
     * @custom:field collateralAsset - The coinvested collateral asset underlying both the senior and junior tranches
     * @custom:field quoteAsset - The quote asset expected as the pool's second token, pinned during pool verification
     * @custom:field accountant - The accountant initialization params (coverage, premiums, and state machine config)
     * @custom:field poolParams - The Gyro E-CLP pool creation parameters, used to create the market's liquidity venue
     * @custom:field jtYdmType - The yield distribution model shape the junior tranche selects from the template's instances
     * @custom:field lptYdmType - The yield distribution model shape the liquidity provider tranche selects from the template's instances
     * @custom:field protocolFeeRecipient - The market's protocol fee recipient
     * @custom:field stSelfLiquidationBonusWAD - The ST self-liquidation bonus remitted to redeeming ST LPs once the liquidation coverage threshold is breached, scaled to WAD
     * @custom:field roycoBlacklist - The market's blacklist contract consulted on tranche balance updates (the null address disables screening)
     * @custom:field collateralAssetOracle - The collateral asset oracle pricing one whole collateral asset in NAV units
     * @custom:field stalenessThresholdSeconds - The maximum age in seconds an oracle price may have before it is considered stale
     * @custom:field sequencerUptimeFeed - The L2 sequencer uptime feed used to gate price queries (the null address when not applicable)
     * @custom:field gracePeriodSeconds - The grace period in seconds after the L2 sequencer is back up before oracle prices are trusted again
     * @custom:field collateralAssetOracleBindingSelectors - The oracle's restricted selectors to bind, declared per oracle kind by the deployer (empty when the kind has no restricted surface)
     * @custom:field collateralAssetOracleBindingRoleIds - The role ids bound to the oracle's restricted selectors, index-aligned with the selectors
     * @custom:field kernelSpecificParams - ABI-encoded liquidity venue initialization params
     * @custom:field entryPointTrancheConfigs - The per-tranche entry point configurations applied after the market is deployed (any oracle clock is deployed externally and passed by address)
     */
    struct MarketParams {
        bytes32 marketId;
        IRoycoVaultTranche.RoycoTrancheInitParams stTranche;
        IRoycoVaultTranche.RoycoTrancheInitParams jtTranche;
        IRoycoVaultTranche.RoycoTrancheInitParams lptTranche;
        address collateralAsset;
        address quoteAsset;
        IRoycoDayAccountant.RoycoDayAccountantInitParams accountant;
        BalancerV3PoolCreationParams poolParams;
        YDMType jtYdmType;
        YDMType lptYdmType;
        address protocolFeeRecipient;
        uint64 stSelfLiquidationBonusWAD;
        address roycoBlacklist;
        address collateralAssetOracle;
        uint48 stalenessThresholdSeconds;
        address sequencerUptimeFeed;
        uint48 gracePeriodSeconds;
        bytes4[] collateralAssetOracleBindingSelectors;
        uint64[] collateralAssetOracleBindingRoleIds;
        bytes kernelSpecificParams;
        EntryPointTrancheConfigs entryPointTrancheConfigs;
    }

    /**
     * @notice Balancer V3-specific addresses recorded for verification
     * @custom:field balancerPool - The deployed Gyro E-CLP pool (the liquidity provider tranche's BPT)
     * @custom:field bptOracle - The deployed BPT oracle adapter that reports lptRawNAV
     */
    struct ExtraContractsDeployedResult {
        address balancerPool;
        address bptOracle;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Thrown when the kernel proxy did not land on the address the market was wired against
    error KERNEL_PROXY_ADDRESS_MISMATCH(address expected, address deployed);
    /// @notice Thrown when the created Balancer pool is not a fresh, unseeded, hookless `{ST_share, quote}` pool
    error INVALID_POOL_CONFIGURATION(address pool);
    /// @notice Thrown when a construction parameter is the null address
    error NULL_CONSTRUCTION_PARAMETER();
    /// @notice Thrown when a junior and a liquidity provider yield distribution model share an instance, which the accountant rejects
    error YIELD_DISTRIBUTION_MODELS_NOT_DISTINCT();
    /// @notice Thrown when a deployed market contract's on-chain wiring does not match the expected configuration
    error MARKET_WIRING_VERIFICATION_FAILED(address subject);

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The Balancer V3 Gyro E-CLP pool factory
    GyroECLPPoolFactory public immutable BALANCER_V3_POOL_FACTORY;

    /// @notice The Balancer V3 vault
    IVault public immutable BALANCER_V3_VAULT;

    /// @notice The Balancer E-CLP LP oracle factory that creates each market's BPT TVL oracle
    ILPOracleFactoryBase public immutable ECLP_LP_ORACLE_FACTORY;

    /// @notice The shared stateless constant-1.0 price feed both of a pool's legs are priced against
    address public immutable BPT_ORACLE_CONSTANT_PRICE_FEED;

    /// @notice The senior tranche beacon every market's senior proxy resolves its implementation from
    address public immutable SENIOR_TRANCHE_BEACON;

    /// @notice The junior tranche beacon every market's junior proxy resolves its implementation from
    address public immutable JUNIOR_TRANCHE_BEACON;

    /// @notice The liquidity provider tranche beacon every market's liquidity proxy resolves its implementation from
    address public immutable LIQUIDITY_PROVIDER_TRANCHE_BEACON;

    /// @notice The Day kernel beacon every market's kernel proxy resolves its implementation from
    address public immutable KERNEL_BEACON;

    /// @notice The accountant beacon every market's accountant proxy resolves its implementation from
    address public immutable ACCOUNTANT_BEACON;

    /// @notice The junior tranche's yield distribution model instance for each `YDMType`, indexed by the enum
    address private immutable _JT_YDM_STATIC_CURVE;
    address private immutable _JT_YDM_ADAPTIVE_CURVE_V1;
    address private immutable _JT_YDM_ADAPTIVE_CURVE_V2;

    /// @notice The liquidity provider tranche's yield distribution model instance for each `YDMType`, indexed by the enum
    address private immutable _LPT_YDM_STATIC_CURVE;
    address private immutable _LPT_YDM_ADAPTIVE_CURVE_V1;
    address private immutable _LPT_YDM_ADAPTIVE_CURVE_V2;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Pins the template to the chain-wide contract set it deploys every market against
    /// @param _params The template's construction parameters
    constructor(TemplateConstructionParams memory _params)
        BaseDeploymentTemplate(_params.factory)
        EntryPointConfigurer(_params.roycoDayEntryPoint, _params.factory)
        MarketSyncerConfigurer(_params.roycoMarketSyncer)
    {
        require(
            address(_params.balancerV3PoolFactory) != address(0) && address(_params.eclpLPOracleFactory) != address(0)
                && _params.bptOracleConstantPriceFeed != address(0) && _params.seniorTrancheBeacon != address(0) && _params.juniorTrancheBeacon != address(0)
                && _params.liquidityProviderTrancheBeacon != address(0) && _params.kernelBeacon != address(0) && _params.accountantBeacon != address(0),
            NULL_CONSTRUCTION_PARAMETER()
        );

        BALANCER_V3_POOL_FACTORY = _params.balancerV3PoolFactory;
        BALANCER_V3_VAULT = IVault(address(_params.balancerV3PoolFactory.getVault()));
        ECLP_LP_ORACLE_FACTORY = _params.eclpLPOracleFactory;
        BPT_ORACLE_CONSTANT_PRICE_FEED = _params.bptOracleConstantPriceFeed;

        SENIOR_TRANCHE_BEACON = _params.seniorTrancheBeacon;
        JUNIOR_TRANCHE_BEACON = _params.juniorTrancheBeacon;
        LIQUIDITY_PROVIDER_TRANCHE_BEACON = _params.liquidityProviderTrancheBeacon;
        KERNEL_BEACON = _params.kernelBeacon;
        ACCOUNTANT_BEACON = _params.accountantBeacon;

        // The accountant rejects a market whose two models are the same instance, so establish once here that no
        // selection of shapes can ever produce one: every junior slot must differ from every liquidity provider slot
        for (uint256 i; i < 3; ++i) {
            require(_params.jtYdms[i] != address(0) && _params.lptYdms[i] != address(0), NULL_CONSTRUCTION_PARAMETER());
            for (uint256 j; j < 3; ++j) {
                require(_params.jtYdms[i] != _params.lptYdms[j], YIELD_DISTRIBUTION_MODELS_NOT_DISTINCT());
            }
        }

        _JT_YDM_STATIC_CURVE = _params.jtYdms[uint256(YDMType.StaticCurve)];
        _JT_YDM_ADAPTIVE_CURVE_V1 = _params.jtYdms[uint256(YDMType.AdaptiveCurve_V1)];
        _JT_YDM_ADAPTIVE_CURVE_V2 = _params.jtYdms[uint256(YDMType.AdaptiveCurve_V2)];
        _LPT_YDM_STATIC_CURVE = _params.lptYdms[uint256(YDMType.StaticCurve)];
        _LPT_YDM_ADAPTIVE_CURVE_V1 = _params.lptYdms[uint256(YDMType.AdaptiveCurve_V1)];
        _LPT_YDM_ADAPTIVE_CURVE_V2 = _params.lptYdms[uint256(YDMType.AdaptiveCurve_V2)];
    }

    /// @notice Returns the junior tranche's yield distribution model instance for a shape
    /// @param _ydmType The model shape the market selected
    /// @return ydm The junior tranche model instance this template deploys markets against
    function jtYdmFor(YDMType _ydmType) public view returns (address ydm) {
        if (_ydmType == YDMType.StaticCurve) return _JT_YDM_STATIC_CURVE;
        if (_ydmType == YDMType.AdaptiveCurve_V1) return _JT_YDM_ADAPTIVE_CURVE_V1;
        return _JT_YDM_ADAPTIVE_CURVE_V2;
    }

    /// @notice Returns the liquidity provider tranche's yield distribution model instance for a shape
    /// @param _ydmType The model shape the market selected
    /// @return ydm The liquidity provider tranche model instance this template deploys markets against
    function lptYdmFor(YDMType _ydmType) public view returns (address ydm) {
        if (_ydmType == YDMType.StaticCurve) return _LPT_YDM_STATIC_CURVE;
        if (_ydmType == YDMType.AdaptiveCurve_V1) return _LPT_YDM_ADAPTIVE_CURVE_V1;
        return _LPT_YDM_ADAPTIVE_CURVE_V2;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PER-KERNEL HOOKS (subclasses override)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Returns the ABI-encoded kernel `initialize(...)` calldata for the Day kernel
     * @param _bptOracle The externally deployed E-CLP BPT oracle for this market's pool, injected into the kernel's
     *        liquidity venue init params (overwriting any caller-supplied value)
     */
    function _kernelInitData(
        IRoycoDayKernel.RoycoDayKernelInitParams memory _kip,
        bytes memory _kernelSpecificParams,
        address _bptOracle
    )
        internal
        pure
        virtual
        returns (bytes memory)
    {
        BalancerV3LiquidityVenue.LiquidityVenueInitParams memory liquidityVenueParams =
            abi.decode(_kernelSpecificParams, (BalancerV3LiquidityVenue.LiquidityVenueInitParams));
        // Set the BPT oracle to the template-deployed oracle
        liquidityVenueParams.bptOracle = _bptOracle;
        return abi.encodeCall(RoycoDayBalancerV3Kernel.initialize, (_kip, liquidityVenueParams));
    }

    /**
     * @dev Verifies the concrete kernel family's kernel-specific wiring against the market's params blob, called from
     *      `_validateDeployment`.
     *   @param _kernel The deployed kernel proxy
     * @param _kernelSpecificParams The market's opaque kernel-specific params blob
     */
    function _validateKernelSpecifics(address _kernel, bytes memory _kernelSpecificParams) internal view virtual { }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOY
    // ═══════════════════════════════════════════════════════════════════════════

    ///  @inheritdoc IRoycoProtocolTemplate
    function deployMarket(bytes calldata _params) external override(IRoycoProtocolTemplate) onlyRoycoFactory returns (DeploymentResult memory result) {
        MarketParams memory p = abi.decode(_params, (MarketParams));

        // Predict the kernel's proxy address.
        bytes32 kernelSalt = _marketComponentSalt(p.marketId, TAG_KERNEL_PROXY);
        address kernel = ROYCO_FACTORY.predictDeterministicAddress(kernelSalt);
        result.ydm = jtYdmFor(p.jtYdmType);
        result.lptYdm = lptYdmFor(p.lptYdmType);

        // Deploy the senior tranche.
        result.seniorTranche = _deployProxy(
            SENIOR_TRANCHE_BEACON, _encodeTrancheInitData(p.stTranche, kernel, p.collateralAsset), _marketComponentSalt(p.marketId, TAG_ST_PROXY)
        );

        // Deploy the Balancer V3 pool and BPT oracle for the LP tranche.
        (address balancerPool, address bptOracle) = BalancerV3VenueCreationLogic.createPoolAndBPTOracle(
            BALANCER_V3_POOL_FACTORY,
            ECLP_LP_ORACLE_FACTORY,
            BPT_ORACLE_CONSTANT_PRICE_FEED,
            p.poolParams,
            result.seniorTranche,
            p.quoteAsset,
            kernel,
            ROYCO_FACTORY.ROYCO_AUTHORITY(),
            _marketComponentSalt(p.marketId, TAG_BALANCER_V3_POOL)
        );

        // Deploy the junior tranche.
        result.juniorTranche = _deployProxy(
            JUNIOR_TRANCHE_BEACON, _encodeTrancheInitData(p.jtTranche, kernel, p.collateralAsset), _marketComponentSalt(p.marketId, TAG_JT_PROXY)
        );

        // Deploy the liquidity provider tranche.
        result.liquidityProviderTranche = _deployProxy(
            LIQUIDITY_PROVIDER_TRANCHE_BEACON, _encodeTrancheInitData(p.lptTranche, kernel, balancerPool), _marketComponentSalt(p.marketId, TAG_LPT_PROXY)
        );

        // Deploy the accountant.
        result.accountant = _deployProxy(
            ACCOUNTANT_BEACON,
            _encodeAccountantInitData(p.accountant, kernel, result.ydm, result.lptYdm),
            _marketComponentSalt(p.marketId, TAG_ACCOUNTANT_PROXY)
        );

        // Verify the Balancer V3 pool.
        _verifyPool(balancerPool, result.seniorTranche, p.quoteAsset);

        // Deploy the kernel.
        result.kernel = _deployKernelProxy(p, result, balancerPool, bptOracle, kernelSalt);
        require(result.kernel == kernel, KERNEL_PROXY_ADDRESS_MISMATCH(kernel, result.kernel));

        // Verify the whole market's on-chain wiring.
        _validateDeployment(p, result, balancerPool);

        // Apply selector->role bindings + post-init grants.
        _applyRoleBindings(_buildRoleBindings(p, result));

        // Record the Balancer V3 pool and BPT oracle.
        result.extras = abi.encode(ExtraContractsDeployedResult({ balancerPool: balancerPool, bptOracle: bptOracle }));
    }

    /// @inheritdoc BaseDeploymentTemplate
    function _postMarketRegistration(DeploymentResult calldata _result, bytes calldata _params) internal override(BaseDeploymentTemplate) {
        MarketParams memory p = abi.decode(_params, (MarketParams));

        // Decode the market's tranches and entry point configs
        address[] memory tranches = new address[](3);
        IRoycoDayEntryPoint.TrancheConfig[] memory configs = new IRoycoDayEntryPoint.TrancheConfig[](3);
        (tranches[0], configs[0]) = (_result.seniorTranche, p.entryPointTrancheConfigs.st);
        (tranches[1], configs[1]) = (_result.juniorTranche, p.entryPointTrancheConfigs.jt);
        (tranches[2], configs[2]) = (_result.liquidityProviderTranche, p.entryPointTrancheConfigs.lt);

        // Configure the market's tranches on the entry point and register its kernel on the market syncer
        _configureEntryPointTrancheConfigs(ROYCO_FACTORY, tranches, configs);
        _registerMarketKernelOnSyncer(ROYCO_FACTORY, _result.kernel);
    }

    /**
     *  @notice Deploys the Day kernel proxy against the script-deployed kernel impl, injecting the externally deployed BPT oracle
     *  @param _p The market parameters
     *  @param _r The deployment result
     *  @param _balancerPool The Balancer V3 pool
     *  @param _bptOracle The BPT oracle
     *  @param _kernelProxySalt The kernel proxy salt
     *  @return kernel The deployed kernel proxy address
     */
    function _deployKernelProxy(
        MarketParams memory _p,
        DeploymentResult memory _r,
        address _balancerPool,
        address _bptOracle,
        bytes32 _kernelProxySalt
    )
        internal
        returns (address kernel)
    {
        IRoycoDayKernel.RoycoDayKernelInitParams memory kip = IRoycoDayKernel.RoycoDayKernelInitParams({
            initialAuthority: ROYCO_FACTORY.ROYCO_AUTHORITY(),
            seniorTranche: _r.seniorTranche,
            juniorTranche: _r.juniorTranche,
            liquidityProviderTranche: _r.liquidityProviderTranche,
            collateralAsset: _p.collateralAsset,
            lptAsset: _balancerPool,
            quoteAsset: _p.quoteAsset,
            accountant: _r.accountant,
            protocolFeeRecipient: _p.protocolFeeRecipient,
            stSelfLiquidationBonusWAD: _p.stSelfLiquidationBonusWAD,
            roycoBlacklist: _p.roycoBlacklist,
            collateralAssetOracle: _p.collateralAssetOracle,
            stalenessThresholdSeconds: _p.stalenessThresholdSeconds,
            sequencerUptimeFeed: _p.sequencerUptimeFeed,
            gracePeriodSeconds: _p.gracePeriodSeconds
        });
        kernel = _deployProxy(KERNEL_BEACON, _kernelInitData(kip, _p.kernelSpecificParams, _bptOracle), _kernelProxySalt);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Verifies the Gyro E-CLP pool this template just created before the market is wired against it
     * @dev Provenance needs no check: the pool came from this template's own call to its pool factory
     * @param _pool The created pool
     * @param _seniorTranche The senior tranche share expected as the pool's first token
     * @param _quoteAsset The quote asset expected as the pool's second token
     */
    function _verifyPool(address _pool, address _seniorTranche, address _quoteAsset) internal view {
        // Unseeded: no BPT has been minted
        require(IERC20(_pool).totalSupply() == 0, INVALID_POOL_CONFIGURATION(_pool));

        // Hookless: the kernel is the pool's senior-leg rate provider, and the market registers no hooks contract
        BalancerV3HooksConfig memory hooksConfig = BALANCER_V3_VAULT.getHooksConfig(_pool);
        require(hooksConfig.hooksContract == address(0), INVALID_POOL_CONFIGURATION(_pool));

        // Exactly {ST share, quote asset}: the market id guarantees the deployed ST share sorts "less" than the
        // quote token, so the Vault's ascending-order registration puts the senior leg first
        IERC20[] memory tokens = BALANCER_V3_VAULT.getPoolTokens(_pool);
        require(tokens.length == 2 && address(tokens[0]) == _seniorTranche && address(tokens[1]) == _quoteAsset, INVALID_POOL_CONFIGURATION(_pool));
    }

    /**
     * @notice Verifies the whole market's on-chain wiring after the proxies are deployed and initialized
     * @dev Cross-checks every deployed contract's immutables/state against the params and against each other, so a
     *      script-side deployment mistake (wrong impl, mis-encoded init data, swapped address) fails loud here rather
     *      than producing a subtly mis-wired live market. Modeled on royco-dawn's `RoycoFactory._validateDeployment`
     */
    function _validateDeployment(MarketParams memory _p, DeploymentResult memory _r, address _pool) internal view {
        address authority = ROYCO_FACTORY.ROYCO_AUTHORITY();
        address pool = _pool;

        // Shared market authority governs every component (tranches, kernel, and accountant)
        require(IAccessManaged(_r.seniorTranche).authority() == authority, MARKET_WIRING_VERIFICATION_FAILED(_r.seniorTranche));
        require(IAccessManaged(_r.juniorTranche).authority() == authority, MARKET_WIRING_VERIFICATION_FAILED(_r.juniorTranche));
        require(IAccessManaged(_r.liquidityProviderTranche).authority() == authority, MARKET_WIRING_VERIFICATION_FAILED(_r.liquidityProviderTranche));
        require(IAccessManaged(_r.kernel).authority() == authority, MARKET_WIRING_VERIFICATION_FAILED(_r.kernel));
        require(IAccessManaged(_r.accountant).authority() == authority, MARKET_WIRING_VERIFICATION_FAILED(_r.accountant));

        // Senior tranche: type, kernel binding, asset, and unseeded
        require(IRoycoVaultTranche(_r.seniorTranche).TRANCHE_TYPE() == TrancheType.SENIOR, MARKET_WIRING_VERIFICATION_FAILED(_r.seniorTranche));
        require(IRoycoVaultTranche(_r.seniorTranche).kernel() == _r.kernel, MARKET_WIRING_VERIFICATION_FAILED(_r.seniorTranche));
        require(IRoycoVaultTranche(_r.seniorTranche).asset() == _p.collateralAsset, MARKET_WIRING_VERIFICATION_FAILED(_r.seniorTranche));
        require(IERC20(_r.seniorTranche).totalSupply() == 0, MARKET_WIRING_VERIFICATION_FAILED(_r.seniorTranche));

        // Junior tranche: type, kernel binding, asset
        require(IRoycoVaultTranche(_r.juniorTranche).TRANCHE_TYPE() == TrancheType.JUNIOR, MARKET_WIRING_VERIFICATION_FAILED(_r.juniorTranche));
        require(IRoycoVaultTranche(_r.juniorTranche).kernel() == _r.kernel, MARKET_WIRING_VERIFICATION_FAILED(_r.juniorTranche));
        require(IRoycoVaultTranche(_r.juniorTranche).asset() == _p.collateralAsset, MARKET_WIRING_VERIFICATION_FAILED(_r.juniorTranche));

        // Liquidity provider tranche: type, kernel binding, asset is the pool BPT
        require(
            IRoycoVaultTranche(_r.liquidityProviderTranche).TRANCHE_TYPE() == TrancheType.LIQUIDITY_PROVIDER,
            MARKET_WIRING_VERIFICATION_FAILED(_r.liquidityProviderTranche)
        );
        require(IRoycoVaultTranche(_r.liquidityProviderTranche).kernel() == _r.kernel, MARKET_WIRING_VERIFICATION_FAILED(_r.liquidityProviderTranche));
        require(IRoycoVaultTranche(_r.liquidityProviderTranche).asset() == pool, MARKET_WIRING_VERIFICATION_FAILED(_r.liquidityProviderTranche));

        // Kernel: full tranche set, assets, and accountant
        IRoycoDayKernel kernel = IRoycoDayKernel(_r.kernel);
        require(kernel.seniorTranche() == _r.seniorTranche, MARKET_WIRING_VERIFICATION_FAILED(_r.kernel));
        require(kernel.juniorTranche() == _r.juniorTranche, MARKET_WIRING_VERIFICATION_FAILED(_r.kernel));
        require(kernel.liquidityProviderTranche() == _r.liquidityProviderTranche, MARKET_WIRING_VERIFICATION_FAILED(_r.kernel));
        require(kernel.accountant() == _r.accountant, MARKET_WIRING_VERIFICATION_FAILED(_r.kernel));
        require(kernel.collateralAsset() == _p.collateralAsset, MARKET_WIRING_VERIFICATION_FAILED(_r.kernel));
        require(kernel.lptAsset() == pool, MARKET_WIRING_VERIFICATION_FAILED(_r.kernel));

        // The market id should guarantee that the deployed ST share is "less" than the quote token
        IERC20[] memory tokens = BALANCER_V3_VAULT.getPoolTokens(pool);
        require(address(tokens[0]) == _r.seniorTranche, MARKET_WIRING_VERIFICATION_FAILED(pool));
        require(address(tokens[1]) == kernel.quoteAsset(), MARKET_WIRING_VERIFICATION_FAILED(pool));

        // Accountant: kernel binding and the injected JT YDM / LPT LDM instances
        IRoycoDayAccountant.RoycoDayAccountantState memory accountantState = IRoycoDayAccountant(_r.accountant).getState();
        require(accountantState.kernel == _r.kernel, MARKET_WIRING_VERIFICATION_FAILED(_r.accountant));
        require(accountantState.jtYDM == _r.ydm && accountantState.lptYDM == _r.lptYdm, MARKET_WIRING_VERIFICATION_FAILED(_r.accountant));

        // Pool: remains hookless, the kernel serves as its senior-leg rate provider
        require(BALANCER_V3_VAULT.getHooksConfig(pool).hooksContract == address(0), MARKET_WIRING_VERIFICATION_FAILED(pool));

        // Kernel-family-specific wiring (e.g. Makina machine, IdleCDO CDO)
        _validateKernelSpecifics(_r.kernel, _p.kernelSpecificParams);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLE BINDINGS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Assembles the market's full role-binding config, pairing each deployment's runtime target addresses with
    ///         the selector/role sets from the per-target binding helpers and the deployer-declared oracle bindings
    function _buildRoleBindings(MarketParams memory _p, DeploymentResult memory _r) internal view returns (RoleBindings memory) {
        // Runtime target addresses, index-aligned with the binding helpers below
        address[8] memory targets = [
            _r.seniorTranche,
            _r.juniorTranche,
            _r.liquidityProviderTranche,
            _r.kernel,
            _r.accountant,
            address(BALANCER_V3_VAULT),
            address(BALANCER_V3_VAULT.getProtocolFeeController()),
            _p.collateralAssetOracle
        ];

        IRoycoAccessManager accessManager = IRoycoAccessManager(ROYCO_FACTORY.ROYCO_AUTHORITY());

        TargetBinding[] memory targetBindings = new TargetBinding[](targets.length);
        bytes4[] memory s;
        uint64[] memory r;
        (s, r) = _trancheBinding(ST_LP_ROLE, ST_LP_ROLE, false); // 0: senior tranche
        targetBindings[0] = TargetBinding({ target: targets[0], selectors: s, roleIds: r });
        (s, r) = _trancheBinding(JT_LP_ROLE, JT_LP_ROLE, false); // 1: junior tranche
        targetBindings[1] = TargetBinding({ target: targets[1], selectors: s, roleIds: r });
        (s, r) = _trancheBinding(LPT_LP_ROLE, LPT_LP_ROLE, true); // 2: liquidity provider tranche
        targetBindings[2] = TargetBinding({ target: targets[2], selectors: s, roleIds: r });
        (s, r) = _kernelBinding(); // 3: kernel
        targetBindings[3] = TargetBinding({ target: targets[3], selectors: s, roleIds: r });
        (s, r) = _accountantBinding(); // 4: accountant
        targetBindings[4] = TargetBinding({ target: targets[4], selectors: s, roleIds: r });
        // 5: Balancer vault, skipped once any market has configured it
        if (accessManager.wasEverConfigured(targets[5])) (s, r) = (new bytes4[](0), new uint64[](0));
        else (s, r) = _balancerVaultBinding();
        targetBindings[5] = TargetBinding({ target: targets[5], selectors: s, roleIds: r });
        // 6: protocol fee controller, skipped once configured.
        if (accessManager.wasEverConfigured(targets[6])) (s, r) = (new bytes4[](0), new uint64[](0));
        else (s, r) = _balancerProtocolFeeControllerBinding();
        targetBindings[6] = TargetBinding({ target: targets[6], selectors: s, roleIds: r });
        // 7: collateral asset oracle restricted surface, declared per oracle kind by the deployer .
        if (accessManager.wasEverConfigured(targets[7])) (s, r) = (new bytes4[](0), new uint64[](0));
        else (s, r) = (_p.collateralAssetOracleBindingSelectors, _p.collateralAssetOracleBindingRoleIds);
        targetBindings[7] = TargetBinding({ target: targets[7], selectors: s, roleIds: r });

        // Post-init grants: accountant SYNC (zero execution delay)
        RoleGrant[] memory grants = new RoleGrant[](1);
        grants[0] = RoleGrant({ roleId: SYNC_ROLE, account: _r.accountant, executionDelay: 0 });

        return RoleBindings({ targetBindings: targetBindings, postInitGrants: grants });
    }

    /// @dev The Day kernel's pricing admin selectors: the Balancer liquidity venue setters and the kernel's collateral
    ///      asset oracle setters, all bound to ADMIN_ORACLE_ROLE
    /// @dev Overridable so a kernel variant can restate its pricing surface; the result is appended to the kernel's
    ///      operational selectors by `_kernelBinding` rather than declared as a second binding on the same target
    function _kernelPricingBinding() internal view virtual returns (bytes4[] memory s, uint64[] memory r) {
        s = new bytes4[](4);
        r = new uint64[](4);
        s[0] = BalancerV3LiquidityVenue.setBPTOracle.selector;
        r[0] = ADMIN_ORACLE_ROLE;
        s[1] = BalancerV3LiquidityVenue.setMaxReinvestmentSlippage.selector;
        r[1] = ADMIN_ORACLE_ROLE;
        s[2] = IRoycoDayKernel.setCollateralAssetOracle.selector;
        r[2] = ADMIN_ORACLE_ROLE;
        s[3] = IRoycoDayKernel.setSequencerUptimeFeed.selector;
        r[3] = ADMIN_ORACLE_ROLE;
    }

    /// @dev `mint` carries no binding: it is gated by the tranche's own `onlyKernel` check (an immutable-address
    ///      check), which scopes minting to THIS market's kernel in a way a shared AccessManager role could not
    function _trancheBinding(uint64 _depositRole, uint64 _redeemRole, bool _isLiquidity) private pure returns (bytes4[] memory s, uint64[] memory r) {
        // Base tranche surface (6 selectors) + the two LPT-only multi-asset selectors when binding the liquidity provider tranche
        // Upgrades are not bound here: a beacon proxy has no per-proxy upgrade entrypoint, its beacon carries that authority
        uint256 n = _isLiquidity ? 8 : 6;
        s = new bytes4[](n);
        r = new uint64[](n);
        s[0] = IRoycoVaultTranche.deposit.selector;
        r[0] = _depositRole;
        s[1] = IRoycoVaultTranche.redeem.selector;
        r[1] = _redeemRole;
        s[2] = IRoycoAuth.pause.selector;
        r[2] = ADMIN_PAUSER_ROLE;
        s[3] = IRoycoAuth.unpause.selector;
        r[3] = ADMIN_UNPAUSER_ROLE;
        s[4] = ERC20BurnableUpgradeable.burn.selector;
        r[4] = BURNER_ROLE;
        s[5] = ERC20BurnableUpgradeable.burnFrom.selector;
        r[5] = BURNER_ROLE;
        if (_isLiquidity) {
            s[6] = RoycoLiquidityProviderTranche.depositMultiAsset.selector;
            r[6] = _depositRole;
            s[7] = RoycoLiquidityProviderTranche.redeemMultiAsset.selector;
            r[7] = _redeemRole;
        }
    }

    /// @dev The kernel's operational surface
    function _kernelBinding() private view returns (bytes4[] memory s, uint64[] memory r) {
        (bytes4[] memory ps, uint64[] memory pr) = _kernelPricingBinding();
        // Upgrades are not bound here: the kernel's beacon carries that authority for every market at once
        uint256 n = 8 + ps.length;
        s = new bytes4[](n);
        r = new uint64[](n);
        for (uint256 i; i < ps.length; ++i) {
            s[8 + i] = ps[i];
            r[8 + i] = pr[i];
        }
        s[0] = IRoycoDayKernel.setProtocolFeeRecipient.selector;
        r[0] = ADMIN_KERNEL_ROLE;
        s[1] = IRoycoAuth.pause.selector;
        r[1] = ADMIN_PAUSER_ROLE;
        s[2] = IRoycoAuth.unpause.selector;
        r[2] = ADMIN_UNPAUSER_ROLE;
        s[3] = IRoycoDayKernel.syncTrancheAccounting.selector;
        r[3] = SYNC_ROLE;
        s[4] = IRoycoDayKernel.setSeniorTrancheSelfLiquidationBonus.selector;
        r[4] = ADMIN_KERNEL_ROLE;
        s[5] = IRoycoDayKernel.reinvestLiquidityPremium.selector;
        r[5] = ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE;
        s[6] = IRoycoDayKernel.setRoycoBlacklist.selector;
        r[6] = ADMIN_MARKET_OPS_ROLE;
        s[7] = IRoycoDayKernel.syncTrancheAccountingFor.selector;
        r[7] = SYNC_ROLE;
    }

    /// @dev Upgrades are not bound here: the accountant's beacon carries that authority for every market at once
    function _accountantBinding() private pure returns (bytes4[] memory s, uint64[] memory r) {
        s = new bytes4[](14);
        r = new uint64[](14);
        s[0] = IRoycoDayAccountant.setJuniorTrancheYDM.selector;
        r[0] = ADMIN_ACCOUNTANT_ROLE;
        s[1] = IRoycoDayAccountant.setLiquidityProviderTrancheYDM.selector;
        r[1] = ADMIN_ACCOUNTANT_ROLE;
        s[2] = IRoycoDayAccountant.setSeniorTrancheProtocolFee.selector;
        r[2] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        s[3] = IRoycoDayAccountant.setJuniorTrancheProtocolFee.selector;
        r[3] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        s[4] = IRoycoDayAccountant.setJTYieldShareProtocolFee.selector;
        r[4] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        s[5] = IRoycoDayAccountant.setLPTYieldShareProtocolFee.selector;
        r[5] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        s[6] = IRoycoDayAccountant.setMinCoverage.selector;
        r[6] = ADMIN_ACCOUNTANT_ROLE;
        s[7] = IRoycoDayAccountant.setLiquidationCoverageUtilization.selector;
        r[7] = ADMIN_ACCOUNTANT_ROLE;
        s[8] = IRoycoDayAccountant.setMinLiquidity.selector;
        r[8] = ADMIN_ACCOUNTANT_ROLE;
        s[9] = IRoycoDayAccountant.setMaxYieldShares.selector;
        r[9] = ADMIN_ACCOUNTANT_ROLE;
        s[10] = IRoycoDayAccountant.setFixedTermDuration.selector;
        r[10] = ADMIN_ACCOUNTANT_ROLE;
        s[11] = IRoycoAuth.pause.selector;
        r[11] = ADMIN_PAUSER_ROLE;
        s[12] = IRoycoAuth.unpause.selector;
        r[12] = ADMIN_UNPAUSER_ROLE;
        s[13] = IRoycoDayAccountant.setDustTolerance.selector;
        r[13] = ADMIN_MARKET_OPS_ROLE;
    }

    function _balancerVaultBinding() private pure returns (bytes4[] memory s, uint64[] memory r) {
        s = new bytes4[](3);
        r = new uint64[](3);
        s[0] = IVaultAdmin.pausePool.selector;
        r[0] = ADMIN_PAUSER_ROLE;
        s[1] = IVaultAdmin.unpausePool.selector;
        r[1] = ADMIN_UNPAUSER_ROLE;
        s[2] = IVaultAdmin.setStaticSwapFeePercentage.selector;
        r[2] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
    }

    function _balancerProtocolFeeControllerBinding() private pure returns (bytes4[] memory s, uint64[] memory r) {
        s = new bytes4[](3);
        r = new uint64[](3);
        s[0] = IProtocolFeeController.setPoolCreatorSwapFeePercentage.selector;
        r[0] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        s[1] = IProtocolFeeController.setPoolCreatorYieldFeePercentage.selector;
        r[1] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        s[2] = IWithdrawPoolCreatorFeesTwoArgOverload.withdrawPoolCreatorFees.selector;
        r[2] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
    }
}
