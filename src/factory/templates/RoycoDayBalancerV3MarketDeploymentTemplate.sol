// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { ILPOracleFactoryBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { IProtocolFeeController } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IProtocolFeeController.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IVaultAdmin } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultAdmin.sol";
import { HooksConfig as BalancerV3HooksConfig } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { ERC20BurnableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { AccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManaged.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRoycoAuth } from "../../interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayEntryPoint } from "../../interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { IRoycoAccessManager } from "../../interfaces/factory/IRoycoAccessManager.sol";
import { IRoycoFactory } from "../../interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../interfaces/factory/IRoycoProtocolTemplate.sol";
import { IBalancerV3LiquidityVenue } from "../../interfaces/liquidity-venue/IBalancerV3LiquidityVenue.sol";
import { RoycoDayBalancerV3Kernel } from "../../kernels/RoycoDayBalancerV3Kernel.sol";
import { BalancerV3LiquidityVenue } from "../../kernels/base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";
import { MarketDeploymentValidationLogic } from "../../libraries/logic/factory/MarketDeploymentValidationLogic.sol";
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
contract RoycoDayBalancerV3MarketDeploymentTemplate is BaseDeploymentTemplate, EntryPointConfigurer, MarketSyncerConfigurer, AccessManaged {
    using SafeERC20 for IERC20;

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
     * @custom:field roycoBlacklist - The chain's blacklist singleton every market this template deploys screens against
     * @custom:field seniorTrancheBeacon - The senior tranche beacon, holding the implementation every senior proxy resolves against
     * @custom:field juniorTrancheBeacon - The junior tranche beacon
     * @custom:field liquidityProviderTrancheBeacon - The liquidity provider tranche beacon
     * @custom:field kernelBeacon - The Day kernel beacon for this template's kernel family
     * @custom:field accountantBeacon - The accountant beacon
     */
    struct TemplateConstructionParams {
        IRoycoFactory factory;
        GyroECLPPoolFactory balancerV3PoolFactory;
        ILPOracleFactoryBase eclpLPOracleFactory;
        address bptOracleConstantPriceFeed;
        address roycoDayEntryPoint;
        address roycoMarketSyncer;
        address roycoBlacklist;
        address seniorTrancheBeacon;
        address juniorTrancheBeacon;
        address liquidityProviderTrancheBeacon;
        address kernelBeacon;
        address accountantBeacon;
    }

    /**
     * @notice The Balancer V3 liquidity venue's deployer-supplied initialization params, carried in `MarketParams.kernelSpecificParams`
     * @dev The venue's BPT oracle is deployed by the template and injected, so it is deliberately absent here
     * @custom:field maxReinvestmentSlippageWAD - The maximum slippage tolerated when reinvesting idle liquidity-premium senior shares into the pool, scaled to WAD precision
     */
    struct BalancerV3LiquidityVenueDeploymentParams {
        uint64 maxReinvestmentSlippageWAD;
    }

    /**
     * @notice Per-tranche entry point configurations applied on the pre-deployed entry point after the market is deployed
     * @custom:field st - The entry point configuration for the senior tranche
     * @custom:field jt - The entry point configuration for the junior tranche
     * @custom:field lpt - The entry point configuration for the liquidity provider tranche
     */
    struct EntryPointTrancheConfigs {
        IRoycoDayEntryPoint.TrancheConfig st;
        IRoycoDayEntryPoint.TrancheConfig jt;
        IRoycoDayEntryPoint.TrancheConfig lpt;
    }

    /**
     * @notice The genesis liquidity a market's pool is seeded with, routed through the liquidity provider tranche's multi-asset deposit
     * @dev The seed is pulled from the account that called the factory's deployment entrypoint
     * @custom:field collateralAmount - The collateral to seed the pool with, in the collateral asset's own units (zero seeds quote-only)
     * @custom:field quoteAmount - The quote to seed the pool with, in the quote asset's own units
     * @custom:field minLPTAssetsOut - The slippage bound on the liquidity add, in liquidity provider tranche asset units
     */
    struct PoolInitializationParams {
        uint256 collateralAmount;
        uint256 quoteAmount;
        uint256 minLPTAssetsOut;
    }

    /**
     * @notice Top-level params struct passed to a Balancer V3 Day template's `deployMarket(bytes)`
     * @custom:field marketId - A caller-supplied identifier for the market, mixed into the deterministic deployment salts
     * @custom:field stParams - The senior tranche's deployer-supplied params
     * @custom:field jtParams - The junior tranche's deployer-supplied params
     * @custom:field lptParams - The liquidity provider tranche's deployer-supplied params
     * @custom:field collateralAsset - The coinvested collateral asset underlying both the senior and junior tranches
     * @custom:field quoteAsset - The quote asset expected as the pool's second token, pinned during pool verification
     * @custom:field accountantParams - The accountant's deployer-supplied params (coverage, premiums, and state machine config)
     * @custom:field poolCreationParams - The Gyro E-CLP pool creation parameters, used to create the market's liquidity venue
     * @custom:field poolInitializationParams - The genesis liquidity the pool is seeded with once the market is wired
     * @custom:field jtYdmType - The yield distribution model shape the junior tranche selects from the template's instances
     * @custom:field lptYdmType - The yield distribution model shape the liquidity provider tranche selects from the template's instances
     * @custom:field protocolFeeRecipient - The market's protocol fee recipient
     * @custom:field stSelfLiquidationBonusWAD - The ST self-liquidation bonus remitted to redeeming ST LPs once the liquidation coverage threshold is breached, scaled to WAD
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
        TrancheDeploymentParams stParams;
        TrancheDeploymentParams jtParams;
        TrancheDeploymentParams lptParams;
        address collateralAsset;
        address quoteAsset;
        AccountantDeploymentParams accountantParams;
        BalancerV3PoolCreationParams poolCreationParams;
        PoolInitializationParams poolInitializationParams;
        string jtYdmType;
        string lptYdmType;
        address protocolFeeRecipient;
        uint64 stSelfLiquidationBonusWAD;
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

    /// @notice Thrown when a construction parameter is the null address
    error NULL_CONSTRUCTION_PARAMETER();

    /// @notice Thrown when a construction parameter that must name a live contract holds no code
    error CONSTRUCTION_PARAMETER_HAS_NO_CODE(address subject);

    /// @notice Thrown when a junior and a liquidity provider yield distribution model share an instance, which the accountant rejects
    error YIELD_DISTRIBUTION_MODELS_NOT_DISTINCT();

    /// @notice Thrown when a market selects a yield distribution model shape this template has no instances for
    error YDM_NOT_REGISTERED(string ydmType);

    /// @notice Thrown when registering a model shape under an empty name
    error INVALID_YDM_TYPE();

    /// @notice Thrown when the genesis deposit mints too few shares to cover the dead-share lock
    error INSUFFICIENT_GENESIS_SHARES(uint256 shares);

    /**
     * @notice Emitted when a model shape's instances are registered or replaced
     * @param ydmType The model shape's name
     * @param jtYdm The junior tranche's model instance for this shape
     * @param lptYdm The liquidity provider tranche's model instance for this shape
     */
    event YieldDistributionModelsRegistered(string ydmType, address jtYdm, address lptYdm);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The genesis LPT shares permanently locked at the dead address on every pool seed, so the tranche supply can never fully exit
    uint256 public constant DEAD_SHARES = 1e12;

    /// @notice The address the dead shares are locked at
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

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

    /// @notice The chain's blacklist singleton every market this template deploys screens tranche balance updates against
    address public immutable ROYCO_BLACKLIST;

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

    // ═══════════════════════════════════════════════════════════════════════════
    // YIELD DISTRIBUTION MODEL REGISTRY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The junior tranche's yield distribution model instance for each registered model shape
    mapping(string ydmType => address ydm) public jtYdms;

    /// @notice The liquidity provider tranche's model instance for each registered model shape
    mapping(string ydmType => address ydm) public lptYdms;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Pins the template to the chain-wide contract set it deploys every market against
    /// @param _params The template's construction parameters
    constructor(TemplateConstructionParams memory _params)
        AccessManaged(_params.factory.ROYCO_AUTHORITY())
        BaseDeploymentTemplate(_params.factory)
        EntryPointConfigurer(_params.roycoDayEntryPoint, _params.factory)
        MarketSyncerConfigurer(_params.roycoMarketSyncer)
    {
        require(
            address(_params.balancerV3PoolFactory) != address(0) && address(_params.eclpLPOracleFactory) != address(0)
                && _params.bptOracleConstantPriceFeed != address(0) && _params.roycoBlacklist != address(0) && _params.seniorTrancheBeacon != address(0)
                && _params.juniorTrancheBeacon != address(0) && _params.liquidityProviderTrancheBeacon != address(0) && _params.kernelBeacon != address(0)
                && _params.accountantBeacon != address(0),
            NULL_CONSTRUCTION_PARAMETER()
        );
        require(address(_params.balancerV3PoolFactory).code.length > 0, CONSTRUCTION_PARAMETER_HAS_NO_CODE(address(_params.balancerV3PoolFactory)));
        require(address(_params.eclpLPOracleFactory).code.length > 0, CONSTRUCTION_PARAMETER_HAS_NO_CODE(address(_params.eclpLPOracleFactory)));
        require(_params.bptOracleConstantPriceFeed.code.length > 0, CONSTRUCTION_PARAMETER_HAS_NO_CODE(_params.bptOracleConstantPriceFeed));
        require(_params.roycoBlacklist.code.length > 0, CONSTRUCTION_PARAMETER_HAS_NO_CODE(_params.roycoBlacklist));
        require(_params.seniorTrancheBeacon.code.length > 0, CONSTRUCTION_PARAMETER_HAS_NO_CODE(_params.seniorTrancheBeacon));
        require(_params.juniorTrancheBeacon.code.length > 0, CONSTRUCTION_PARAMETER_HAS_NO_CODE(_params.juniorTrancheBeacon));
        require(_params.liquidityProviderTrancheBeacon.code.length > 0, CONSTRUCTION_PARAMETER_HAS_NO_CODE(_params.liquidityProviderTrancheBeacon));
        require(_params.kernelBeacon.code.length > 0, CONSTRUCTION_PARAMETER_HAS_NO_CODE(_params.kernelBeacon));
        require(_params.accountantBeacon.code.length > 0, CONSTRUCTION_PARAMETER_HAS_NO_CODE(_params.accountantBeacon));

        BALANCER_V3_POOL_FACTORY = _params.balancerV3PoolFactory;
        BALANCER_V3_VAULT = IVault(address(_params.balancerV3PoolFactory.getVault()));
        ECLP_LP_ORACLE_FACTORY = _params.eclpLPOracleFactory;
        BPT_ORACLE_CONSTANT_PRICE_FEED = _params.bptOracleConstantPriceFeed;
        ROYCO_BLACKLIST = _params.roycoBlacklist;

        SENIOR_TRANCHE_BEACON = _params.seniorTrancheBeacon;
        JUNIOR_TRANCHE_BEACON = _params.juniorTrancheBeacon;
        LIQUIDITY_PROVIDER_TRANCHE_BEACON = _params.liquidityProviderTrancheBeacon;
        KERNEL_BEACON = _params.kernelBeacon;
        ACCOUNTANT_BEACON = _params.accountantBeacon;
    }

    /**
     * @notice Registers the junior and liquidity provider model instances for one model shape
     * @param _ydmType The model shape's name, which markets select by
     * @param _jtYdm The junior tranche's model instance for this shape
     * @param _lptYdm The liquidity provider tranche's model instance for this shape
     */
    function setYieldDistributionModels(string calldata _ydmType, address _jtYdm, address _lptYdm) external restricted {
        require(bytes(_ydmType).length != 0, INVALID_YDM_TYPE());
        require(_jtYdm != address(0) && _lptYdm != address(0), NULL_CONSTRUCTION_PARAMETER());
        require(_jtYdm != _lptYdm, YIELD_DISTRIBUTION_MODELS_NOT_DISTINCT());

        jtYdms[_ydmType] = _jtYdm;
        lptYdms[_ydmType] = _lptYdm;
        emit YieldDistributionModelsRegistered(_ydmType, _jtYdm, _lptYdm);
    }

    /**
     * @notice Returns the junior tranche's yield distribution model instance for a shape
     * @dev Reverts on an unregistered shape rather than returning the null address, which would otherwise reach the
     * accountant's initializer and produce a market wired to no model at all
     * @param _ydmType The model shape the market selected
     * @return ydm The junior tranche model instance this template deploys markets against
     */
    function jtYdmFor(string memory _ydmType) public view returns (address ydm) {
        ydm = jtYdms[_ydmType];
        require(ydm != address(0), YDM_NOT_REGISTERED(_ydmType));
    }

    /**
     * @notice Returns the liquidity provider tranche's yield distribution model instance for a shape
     * @dev Reverts on an unregistered shape, for the same reason as `jtYdmFor`
     * @param _ydmType The model shape the market selected
     * @return ydm The liquidity provider tranche model instance this template deploys markets against
     */
    function lptYdmFor(string memory _ydmType) public view returns (address ydm) {
        ydm = lptYdms[_ydmType];
        require(ydm != address(0), YDM_NOT_REGISTERED(_ydmType));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PER-KERNEL HOOKS (subclasses override)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Returns the ABI-encoded kernel `initialize(...)` calldata for the Day kernel
     * @param _bptOracle The externally deployed E-CLP BPT oracle for this market's pool, injected into the kernel's
     *        liquidity venue init params
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
        BalancerV3LiquidityVenueDeploymentParams memory venueParams = abi.decode(_kernelSpecificParams, (BalancerV3LiquidityVenueDeploymentParams));
        IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams memory liquidityVenueParams = IBalancerV3LiquidityVenue.BalancerV3LiquidityVenueInitParams({
            bptOracle: _bptOracle, maxReinvestmentSlippageWAD: venueParams.maxReinvestmentSlippageWAD
        });
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
        // Validate the deployer's params
        MarketDeploymentValidationLogic.validateMarketParams(_params);

        MarketParams memory params = abi.decode(_params, (MarketParams));

        // Predict the kernel's proxy address.
        bytes32 kernelSalt = _marketComponentSalt(params.marketId, TAG_KERNEL_PROXY);
        address kernel = ROYCO_FACTORY.predictDeterministicAddress(kernelSalt);
        result.ydm = jtYdmFor(params.jtYdmType);
        result.lptYdm = lptYdmFor(params.lptYdmType);
        require(result.ydm != result.lptYdm, YIELD_DISTRIBUTION_MODELS_NOT_DISTINCT());

        // Deploy the senior tranche.
        result.seniorTranche = _deployProxy(
            SENIOR_TRANCHE_BEACON, _encodeTrancheInitData(params.stParams, kernel, params.collateralAsset), _marketComponentSalt(params.marketId, TAG_ST_PROXY)
        );

        // Deploy the Balancer V3 pool and BPT oracle for the LP tranche.
        (address balancerPool, address bptOracle) = BalancerV3VenueCreationLogic.createPoolAndBPTOracle(
            BALANCER_V3_POOL_FACTORY,
            ECLP_LP_ORACLE_FACTORY,
            BPT_ORACLE_CONSTANT_PRICE_FEED,
            params.poolCreationParams,
            result.seniorTranche,
            params.quoteAsset,
            kernel,
            ROYCO_FACTORY.ROYCO_AUTHORITY(),
            _marketComponentSalt(params.marketId, TAG_BALANCER_V3_POOL)
        );

        // Deploy the junior tranche.
        result.juniorTranche = _deployProxy(
            JUNIOR_TRANCHE_BEACON, _encodeTrancheInitData(params.jtParams, kernel, params.collateralAsset), _marketComponentSalt(params.marketId, TAG_JT_PROXY)
        );

        // Deploy the liquidity provider tranche.
        result.liquidityProviderTranche = _deployProxy(
            LIQUIDITY_PROVIDER_TRANCHE_BEACON,
            _encodeTrancheInitData(params.lptParams, kernel, balancerPool),
            _marketComponentSalt(params.marketId, TAG_LPT_PROXY)
        );

        // Deploy the accountant.
        result.accountant = _deployProxy(
            ACCOUNTANT_BEACON,
            _encodeAccountantInitData(params.accountantParams, kernel, result.ydm, result.lptYdm),
            _marketComponentSalt(params.marketId, TAG_ACCOUNTANT_PROXY)
        );

        // Verify the Balancer V3 pool.
        MarketDeploymentValidationLogic.verifyPool(BALANCER_V3_VAULT, balancerPool, result.seniorTranche, params.quoteAsset);

        // Deploy the kernel.
        result.kernel = _deployKernelProxy(params, result, balancerPool, bptOracle, kernelSalt);
        require(result.kernel == kernel, KERNEL_PROXY_ADDRESS_MISMATCH(kernel, result.kernel));

        // Verify the whole market's on-chain wiring.
        _validateDeployment(params, result, balancerPool);

        // Apply selector->role bindings + post-init grants.
        _applyRoleBindings(_buildRoleBindings(params, result));

        // Record the Balancer V3 pool and BPT oracle.
        result.extras = abi.encode(ExtraContractsDeployedResult({ balancerPool: balancerPool, bptOracle: bptOracle }));
    }

    /// @inheritdoc BaseDeploymentTemplate
    function _postMarketRegistration(DeploymentResult calldata _result, bytes calldata _params) internal override(BaseDeploymentTemplate) {
        MarketParams memory params = abi.decode(_params, (MarketParams));

        // Decode the market's tranches and entry point configs
        address[] memory tranches = new address[](3);
        IRoycoDayEntryPoint.TrancheConfig[] memory configs = new IRoycoDayEntryPoint.TrancheConfig[](3);
        (tranches[0], configs[0]) = (_result.seniorTranche, params.entryPointTrancheConfigs.st);
        (tranches[1], configs[1]) = (_result.juniorTranche, params.entryPointTrancheConfigs.jt);
        (tranches[2], configs[2]) = (_result.liquidityProviderTranche, params.entryPointTrancheConfigs.lpt);

        // Configure the market's tranches on the entry point and register its kernel on the market syncer
        _configureEntryPointTrancheConfigs(ROYCO_FACTORY, tranches, configs);
        _registerMarketKernelOnSyncer(ROYCO_FACTORY, _result.kernel);

        // Seed the pool.
        _seedPool(params, _result.liquidityProviderTranche);
    }

    /**
     * @notice Seeds the market's pool with its genesis liquidity through the liquidity provider tranche's multi-asset deposit
     * @dev The seed is funded by the account that called the factory's deployment entrypoint, read from the factory's
     *      transient marketDeployer: it must have approved this template for both legs and receives the genesis shares
     *      net of the dead-share lock
     * @dev The quote leg is mandatory; the collateral leg is optional
     * @param _params The market's params, carrying the amounts and the slippage bound
     * @param _liquidityProviderTranche The market's liquidity provider tranche
     */
    function _seedPool(MarketParams memory _params, address _liquidityProviderTranche) internal {
        PoolInitializationParams memory initParams = _params.poolInitializationParams;

        // The deployment initiator funds the seed, held transiently by the factory for exactly this read
        address deployer = ROYCO_FACTORY.marketDeployer();

        // Pull each leg to the factory and approve the tranche for it. The tranche pulls from its caller, which is the factory.
        _pullAndApproveSeedLeg(_params.quoteAsset, deployer, _liquidityProviderTranche, initParams.quoteAmount);
        if (initParams.collateralAmount != 0) {
            _pullAndApproveSeedLeg(_params.collateralAsset, deployer, _liquidityProviderTranche, initParams.collateralAmount);
        }

        // Execute the deposit as the factory
        (uint256 lptShares,) = abi.decode(
            ROYCO_FACTORY.executeAsFactory(
                _liquidityProviderTranche,
                abi.encodeCall(
                    RoycoLiquidityProviderTranche.depositMultiAsset,
                    (initParams.collateralAmount, initParams.quoteAmount, initParams.minLPTAssetsOut, address(ROYCO_FACTORY))
                )
            ),
            (uint256, uint256)
        );

        // Lock the dead shares so the genesis supply can never fully exit (serve as virtual shares for inflation resistance)
        require(lptShares >= DEAD_SHARES, INSUFFICIENT_GENESIS_SHARES(lptShares));
        ROYCO_FACTORY.executeAsFactory(_liquidityProviderTranche, abi.encodeCall(IERC20.transfer, (DEAD_ADDRESS, DEAD_SHARES)));

        // Return the remaining genesis shares to the deployer
        uint256 excessLPTShares = lptShares - DEAD_SHARES;
        if (excessLPTShares > 0) ROYCO_FACTORY.executeAsFactory(_liquidityProviderTranche, abi.encodeCall(IERC20.transfer, (deployer, excessLPTShares)));
    }

    /**
     * @notice Pulls one seed leg from the deployer to the factory and approves the liquidity provider tranche to spend it
     * @param _asset The seed leg's asset
     * @param _deployer The address the leg is pulled from
     * @param _liquidityProviderTranche The market's liquidity provider tranche, the approved spender
     * @param _amount The leg's amount, in the asset's own units
     */
    function _pullAndApproveSeedLeg(address _asset, address _deployer, address _liquidityProviderTranche, uint256 _amount) internal {
        IERC20(_asset).safeTransferFrom(_deployer, address(ROYCO_FACTORY), _amount);
        ROYCO_FACTORY.executeAsFactory(_asset, abi.encodeCall(IERC20.approve, (_liquidityProviderTranche, _amount)));
    }

    /**
     *  @notice Deploys the Day kernel proxy against the script-deployed kernel impl, injecting the externally deployed BPT oracle
     *  @param _params The market parameters
     *  @param _result The deployment result
     *  @param _balancerPool The Balancer V3 pool
     *  @param _bptOracle The BPT oracle
     *  @param _kernelProxySalt The kernel proxy salt
     *  @return kernel The deployed kernel proxy address
     */
    function _deployKernelProxy(
        MarketParams memory _params,
        DeploymentResult memory _result,
        address _balancerPool,
        address _bptOracle,
        bytes32 _kernelProxySalt
    )
        internal
        returns (address kernel)
    {
        IRoycoDayKernel.RoycoDayKernelInitParams memory kip = IRoycoDayKernel.RoycoDayKernelInitParams({
            initialAuthority: ROYCO_FACTORY.ROYCO_AUTHORITY(),
            seniorTranche: _result.seniorTranche,
            juniorTranche: _result.juniorTranche,
            liquidityProviderTranche: _result.liquidityProviderTranche,
            collateralAsset: _params.collateralAsset,
            lptAsset: _balancerPool,
            quoteAsset: _params.quoteAsset,
            accountant: _result.accountant,
            protocolFeeRecipient: _params.protocolFeeRecipient,
            stSelfLiquidationBonusWAD: _params.stSelfLiquidationBonusWAD,
            roycoBlacklist: ROYCO_BLACKLIST,
            collateralAssetOracle: _params.collateralAssetOracle,
            stalenessThresholdSeconds: _params.stalenessThresholdSeconds,
            sequencerUptimeFeed: _params.sequencerUptimeFeed,
            gracePeriodSeconds: _params.gracePeriodSeconds
        });
        kernel = _deployProxy(KERNEL_BEACON, _kernelInitData(kip, _params.kernelSpecificParams, _bptOracle), _kernelProxySalt);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Verifies the whole market's on-chain wiring after the proxies are deployed and initialized
     * @param _params The market parameters
     * @param _result The deployment result
     * @param _pool The market's Gyro E-CLP pool
     */
    function _validateDeployment(MarketParams memory _params, DeploymentResult memory _result, address _pool) internal view {
        MarketDeploymentValidationLogic.validateDeployment(
            _result, BALANCER_V3_VAULT, _pool, _params.collateralAsset, ROYCO_BLACKLIST, ROYCO_FACTORY.ROYCO_AUTHORITY()
        );

        // Kernel-family-specific wiring (e.g. Makina machine, IdleCDO CDO)
        _validateKernelSpecifics(_result.kernel, _params.kernelSpecificParams);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLE BINDINGS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Assembles the market's full role-binding config, pairing each deployment's runtime target addresses with
    ///         the selector/role sets from the per-target binding helpers and the deployer-declared oracle bindings
    function _buildRoleBindings(MarketParams memory _params, DeploymentResult memory _result) internal view returns (RoleBindings memory) {
        // Runtime target addresses, index-aligned with the binding helpers below
        address[8] memory targets = [
            _result.seniorTranche,
            _result.juniorTranche,
            _result.liquidityProviderTranche,
            _result.kernel,
            _result.accountant,
            address(BALANCER_V3_VAULT),
            address(BALANCER_V3_VAULT.getProtocolFeeController()),
            _params.collateralAssetOracle
        ];

        IRoycoAccessManager accessManager = IRoycoAccessManager(ROYCO_FACTORY.ROYCO_AUTHORITY());

        TargetBinding[] memory targetBindings = new TargetBinding[](targets.length);
        bytes4[] memory selectors;
        uint64[] memory roleIds;
        (selectors, roleIds) = _trancheBinding(ST_LP_ROLE, ST_LP_ROLE, false); // 0: senior tranche
        targetBindings[0] = TargetBinding({ target: targets[0], selectors: selectors, roleIds: roleIds });
        (selectors, roleIds) = _trancheBinding(JT_LP_ROLE, JT_LP_ROLE, false); // 1: junior tranche
        targetBindings[1] = TargetBinding({ target: targets[1], selectors: selectors, roleIds: roleIds });
        (selectors, roleIds) = _trancheBinding(LPT_LP_ROLE, LPT_LP_ROLE, true); // 2: liquidity provider tranche
        targetBindings[2] = TargetBinding({ target: targets[2], selectors: selectors, roleIds: roleIds });
        (selectors, roleIds) = _kernelBinding(); // 3: kernel
        targetBindings[3] = TargetBinding({ target: targets[3], selectors: selectors, roleIds: roleIds });
        (selectors, roleIds) = _accountantBinding(); // 4: accountant
        targetBindings[4] = TargetBinding({ target: targets[4], selectors: selectors, roleIds: roleIds });
        // 5: Balancer vault, skipped once any market has configured it
        if (accessManager.wasEverConfigured(targets[5])) (selectors, roleIds) = (new bytes4[](0), new uint64[](0));
        else (selectors, roleIds) = _balancerVaultBinding();
        targetBindings[5] = TargetBinding({ target: targets[5], selectors: selectors, roleIds: roleIds });
        // 6: protocol fee controller, skipped once configured.
        if (accessManager.wasEverConfigured(targets[6])) (selectors, roleIds) = (new bytes4[](0), new uint64[](0));
        else (selectors, roleIds) = _balancerProtocolFeeControllerBinding();
        targetBindings[6] = TargetBinding({ target: targets[6], selectors: selectors, roleIds: roleIds });
        // 7: collateral asset oracle restricted surface, declared per oracle kind by the deployer .
        if (accessManager.wasEverConfigured(targets[7])) (selectors, roleIds) = (new bytes4[](0), new uint64[](0));
        else (selectors, roleIds) = (_params.collateralAssetOracleBindingSelectors, _params.collateralAssetOracleBindingRoleIds);
        targetBindings[7] = TargetBinding({ target: targets[7], selectors: selectors, roleIds: roleIds });

        // Post-init grants: accountant SYNC (zero execution delay)
        RoleGrant[] memory grants = new RoleGrant[](1);
        grants[0] = RoleGrant({ roleId: SYNC_ROLE, account: _result.accountant, executionDelay: 0 });

        return RoleBindings({ targetBindings: targetBindings, postInitGrants: grants });
    }

    /**
     * @dev The Day kernel's pricing admin selectors: the Balancer liquidity venue setters and the kernel's collateral
     * asset oracle setters, all bound to ADMIN_ORACLE_ROLE
     * @dev Overridable so a kernel variant can restate its pricing surface; the result is appended to the kernel's
     * operational selectors by `_kernelBinding` rather than declared as a second binding on the same target
     */
    function _kernelPricingBinding() internal view virtual returns (bytes4[] memory selectors, uint64[] memory roleIds) {
        selectors = new bytes4[](4);
        roleIds = new uint64[](4);
        selectors[0] = BalancerV3LiquidityVenue.setBPTOracle.selector;
        roleIds[0] = ADMIN_ORACLE_ROLE;
        selectors[1] = BalancerV3LiquidityVenue.setMaxReinvestmentSlippage.selector;
        roleIds[1] = ADMIN_ORACLE_ROLE;
        selectors[2] = IRoycoDayKernel.setCollateralAssetOracle.selector;
        roleIds[2] = ADMIN_ORACLE_ROLE;
        selectors[3] = IRoycoDayKernel.setSequencerUptimeFeed.selector;
        roleIds[3] = ADMIN_ORACLE_ROLE;
    }

    /// @dev `mint` carries no binding: it is gated by the tranche's own `onlyKernel` check (an immutable-address
    ///      check), which scopes minting to THIS market's kernel in a way a shared AccessManager role could not
    function _trancheBinding(
        uint64 _depositRole,
        uint64 _redeemRole,
        bool _isLiquidity
    )
        private
        pure
        returns (bytes4[] memory selectors, uint64[] memory roleIds)
    {
        // Base tranche surface (6 selectors) + the two LPT-only multi-asset selectors when binding the liquidity provider tranche
        // Upgrades are not bound here: a beacon proxy has no per-proxy upgrade entrypoint, its beacon carries that authority
        uint256 selectorCount = _isLiquidity ? 8 : 6;
        selectors = new bytes4[](selectorCount);
        roleIds = new uint64[](selectorCount);
        selectors[0] = IRoycoVaultTranche.deposit.selector;
        roleIds[0] = _depositRole;
        selectors[1] = IRoycoVaultTranche.redeem.selector;
        roleIds[1] = _redeemRole;
        selectors[2] = IRoycoAuth.pause.selector;
        roleIds[2] = ADMIN_PAUSER_ROLE;
        selectors[3] = IRoycoAuth.unpause.selector;
        roleIds[3] = ADMIN_UNPAUSER_ROLE;
        selectors[4] = ERC20BurnableUpgradeable.burn.selector;
        roleIds[4] = BURNER_ROLE;
        selectors[5] = ERC20BurnableUpgradeable.burnFrom.selector;
        roleIds[5] = BURNER_ROLE;
        if (_isLiquidity) {
            selectors[6] = RoycoLiquidityProviderTranche.depositMultiAsset.selector;
            roleIds[6] = _depositRole;
            selectors[7] = RoycoLiquidityProviderTranche.redeemMultiAsset.selector;
            roleIds[7] = _redeemRole;
        }
    }

    /// @dev The kernel's operational surface
    function _kernelBinding() private view returns (bytes4[] memory selectors, uint64[] memory roleIds) {
        (bytes4[] memory pricingSelectors, uint64[] memory pricingRoleIds) = _kernelPricingBinding();
        // Upgrades are not bound here: the kernel's beacon carries that authority for every market at once
        uint256 numPricingSelectors = pricingSelectors.length;
        uint256 selectorCount = 8 + numPricingSelectors;
        selectors = new bytes4[](selectorCount);
        roleIds = new uint64[](selectorCount);
        for (uint256 i; i < numPricingSelectors; ++i) {
            selectors[8 + i] = pricingSelectors[i];
            roleIds[8 + i] = pricingRoleIds[i];
        }
        selectors[0] = IRoycoDayKernel.setProtocolFeeRecipient.selector;
        roleIds[0] = ADMIN_KERNEL_ROLE;
        selectors[1] = IRoycoAuth.pause.selector;
        roleIds[1] = ADMIN_PAUSER_ROLE;
        selectors[2] = IRoycoAuth.unpause.selector;
        roleIds[2] = ADMIN_UNPAUSER_ROLE;
        selectors[3] = IRoycoDayKernel.syncTrancheAccounting.selector;
        roleIds[3] = SYNC_ROLE;
        selectors[4] = IRoycoDayKernel.setSeniorTrancheSelfLiquidationBonus.selector;
        roleIds[4] = ADMIN_KERNEL_ROLE;
        selectors[5] = IRoycoDayKernel.reinvestLiquidityPremium.selector;
        roleIds[5] = ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE;
        selectors[6] = IRoycoDayKernel.setRoycoBlacklist.selector;
        roleIds[6] = ADMIN_MARKET_OPS_ROLE;
        selectors[7] = IRoycoDayKernel.syncTrancheAccountingFor.selector;
        roleIds[7] = SYNC_ROLE;
    }

    /// @dev Upgrades are not bound here: the accountant's beacon carries that authority for every market at once
    function _accountantBinding() private pure returns (bytes4[] memory selectors, uint64[] memory roleIds) {
        selectors = new bytes4[](14);
        roleIds = new uint64[](14);
        selectors[0] = IRoycoDayAccountant.setJuniorTrancheYDM.selector;
        roleIds[0] = ADMIN_ACCOUNTANT_ROLE;
        selectors[1] = IRoycoDayAccountant.setLiquidityProviderTrancheYDM.selector;
        roleIds[1] = ADMIN_ACCOUNTANT_ROLE;
        selectors[2] = IRoycoDayAccountant.setSeniorTrancheProtocolFee.selector;
        roleIds[2] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        selectors[3] = IRoycoDayAccountant.setJuniorTrancheProtocolFee.selector;
        roleIds[3] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        selectors[4] = IRoycoDayAccountant.setJTYieldShareProtocolFee.selector;
        roleIds[4] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        selectors[5] = IRoycoDayAccountant.setLPTYieldShareProtocolFee.selector;
        roleIds[5] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        selectors[6] = IRoycoDayAccountant.setMinCoverage.selector;
        roleIds[6] = ADMIN_ACCOUNTANT_ROLE;
        selectors[7] = IRoycoDayAccountant.setLiquidationCoverageUtilization.selector;
        roleIds[7] = ADMIN_ACCOUNTANT_ROLE;
        selectors[8] = IRoycoDayAccountant.setMinLiquidity.selector;
        roleIds[8] = ADMIN_ACCOUNTANT_ROLE;
        selectors[9] = IRoycoDayAccountant.setMaxYieldShares.selector;
        roleIds[9] = ADMIN_ACCOUNTANT_ROLE;
        selectors[10] = IRoycoDayAccountant.setFixedTermDuration.selector;
        roleIds[10] = ADMIN_ACCOUNTANT_ROLE;
        selectors[11] = IRoycoAuth.pause.selector;
        roleIds[11] = ADMIN_PAUSER_ROLE;
        selectors[12] = IRoycoAuth.unpause.selector;
        roleIds[12] = ADMIN_UNPAUSER_ROLE;
        selectors[13] = IRoycoDayAccountant.setDustTolerance.selector;
        roleIds[13] = ADMIN_MARKET_OPS_ROLE;
    }

    function _balancerVaultBinding() private pure returns (bytes4[] memory selectors, uint64[] memory roleIds) {
        selectors = new bytes4[](3);
        roleIds = new uint64[](3);
        selectors[0] = IVaultAdmin.pausePool.selector;
        roleIds[0] = ADMIN_PAUSER_ROLE;
        selectors[1] = IVaultAdmin.unpausePool.selector;
        roleIds[1] = ADMIN_UNPAUSER_ROLE;
        selectors[2] = IVaultAdmin.setStaticSwapFeePercentage.selector;
        roleIds[2] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
    }

    function _balancerProtocolFeeControllerBinding() private pure returns (bytes4[] memory selectors, uint64[] memory roleIds) {
        selectors = new bytes4[](3);
        roleIds = new uint64[](3);
        selectors[0] = IProtocolFeeController.setPoolCreatorSwapFeePercentage.selector;
        roleIds[0] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        selectors[1] = IProtocolFeeController.setPoolCreatorYieldFeePercentage.selector;
        roleIds[1] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        selectors[2] = IWithdrawPoolCreatorFeesTwoArgOverload.withdrawPoolCreatorFees.selector;
        roleIds[2] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
    }
}
