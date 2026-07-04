// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ILPOracleBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleBase.sol";
import { ILPOracleFactoryBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { IGyroECLPPool } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { IRateProvider } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IBasePool } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IBasePool.sol";
import { IProtocolFeeController } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IProtocolFeeController.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IVaultAdmin } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultAdmin.sol";
import {
    PoolRoleAccounts as BalancerV3PoolRoleAccounts,
    TokenConfig as BalancerV3TokenConfig,
    TokenType as BalancerV3TokenType
} from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { ConstantPriceFeed } from "../../../lib/balancer-v3-monorepo/pkg/oracles/contracts/ConstantPriceFeed.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { BalancerPoolToken } from "../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { SingletonAuthentication } from "../../../lib/balancer-v3-monorepo/pkg/vault/contracts/SingletonAuthentication.sol";
import {
    AggregatorV3Interface as BalancerAggregatorV3Interface
} from "../../../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { AccessManagedUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC20BurnableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoAuth } from "../../interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { IRoycoFactory } from "../../interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../interfaces/factory/IRoycoProtocolTemplate.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { RoycoDayBalancerV3Hooks } from "../../kernels/base/quoter/liquidity-tranche/balancer-v3/RoycoDayBalancerV3Hooks.sol";
import { RoycoDayBalancerV3HooksStandIn } from "../../kernels/base/quoter/liquidity-tranche/balancer-v3/RoycoDayBalancerV3HooksStandIn.sol";
import { TrancheType } from "../../libraries/Types.sol";
import { RoycoLiquidityTranche } from "../../tranches/RoycoLiquidityTranche.sol";
import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_BALANCER_POOL_MANAGER_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_MARKET_OPS_ROLE,
    ADMIN_ORACLE_QUOTER_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    BURNER_ROLE,
    JT_LP_ROLE,
    LT_LP_ROLE,
    PUBLIC_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE
} from "../RolesConfiguration.sol";
import { BaseDeploymentTemplate } from "./base/BaseDeploymentTemplate.sol";
import {
    COMPONENT_ID_DAY_BALANCER_HOOKS,
    TAG_ACCOUNTANT_IMPL,
    TAG_ACCOUNTANT_PROXY,
    TAG_BALANCER_HOOK,
    TAG_BALANCER_HOOK_IMPL,
    TAG_BALANCER_V3_POOL,
    TAG_JT_IMPL,
    TAG_JT_PROXY,
    TAG_KERNEL_IMPL,
    TAG_KERNEL_PROXY,
    TAG_LDM,
    TAG_LT_IMPL,
    TAG_LT_PROXY,
    TAG_ST_IMPL,
    TAG_ST_PROXY,
    TAG_YDM
} from "./base/Components.sol";

/**
 * @title BalancerV3DeploymentTemplate
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base for every Royco Day market deployment template (ST + JT + LT).
 */
abstract contract BalancerV3DeploymentTemplate is BaseDeploymentTemplate {
    // ═══════════════════════════════════════════════════════════════════════════
    // PARAM STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Gyro E-CLP pool params for the LT's `{ST_share, quote}` pool.
     * @custom:field name - The name of the Gyro E-CLP BPT.
     * @custom:field symbol - The symbol of the Gyro E-CLP BPT.
     * @custom:field eclpParams - The E-CLP curve parameters (price bounds and rotation) defining the pool's rate-scaled AMM.
     * @custom:field derivedEclpParams - The high-precision derived E-CLP parameters computed off-chain from `eclpParams`.
     * @custom:field swapFeePercentage - The pool's swap fee, scaled to WAD (1e18 = 100%).
     * @custom:field enableDonation - Whether unbalanced donation-style adds are permitted on the pool.
     * @custom:field disableUnbalancedLiquidity - Whether to disable unbalanced add/remove liquidity, forcing proportional-only.
     * @custom:field quoteAsset - The quote asset (stablecoin) paired against the senior tranche share in the pool.
     * @custom:field quoteAssetRateProvider - The rate provider supplying the quote leg's rate to the pool. The BPT oracle then prices this leg with the shared constant-1.0 feed.
     */
    struct GyroECLPPoolParams {
        string name;
        string symbol;
        IGyroECLPPool.EclpParams eclpParams;
        IGyroECLPPool.DerivedEclpParams derivedEclpParams;
        uint256 swapFeePercentage;
        bool enableDonation;
        bool disableUnbalancedLiquidity;
        address quoteAsset;
        address quoteAssetRateProvider;
    }

    /**
     * @notice Top-level params struct passed to `deployMarket(bytes)`.
     * @custom:field marketId - A caller-supplied identifier for the market, mixed into the deterministic deployment salts.
     * @custom:field stTranche - The senior tranche initialization params.
     * @custom:field jtTranche - The junior tranche initialization params.
     * @custom:field ltTranche - The liquidity tranche initialization params.
     * @custom:field stAsset - The senior tranche's underlying yield-bearing asset.
     * @custom:field jtAsset - The junior tranche's underlying asset (the same yield-bearing asset as ST or the RFR).
     * @custom:field jtCoinvested - Whether the junior tranche is co-invested in the same yield-bearing asset as the senior tranche.
     * @custom:field accountant - The accountant initialization params (coverage, premiums, and state machine config).
     * @custom:field gyroECLPPoolParams - The Gyro E-CLP pool params for the liquidity tranche's `{ST_share, quote}` pool.
     * @custom:field jtYDMTargetUtilizationWAD - The junior tranche YDM's target coverage utilization, scaled to WAD.
     * @custom:field ltYDMTargetUtilizationWAD - The liquidity tranche LDM's target liquidity utilization, scaled to WAD.
     * @custom:field protocolFeeRecipient - The market's protocol fee recipient.
     * @custom:field stSelfLiquidationBonusWAD - The ST self-liquidation bonus remitted to redeeming ST LPs once the liquidation coverage threshold is breached, scaled to WAD.
     * @custom:field roycoBlacklist - The market's blacklist contract consulted on tranche balance updates (the null address disables screening).
     * @custom:field kernelSpecificParams - ABI-encoded kernel/quoter-specific initialization params.
     * @custom:field enforceVaultSharesTransferWhitelist - Whether to enforce the vault shares transfer whitelist.
     */
    struct DayParams {
        bytes32 marketId;
        IRoycoVaultTranche.RoycoTrancheInitParams stTranche;
        IRoycoVaultTranche.RoycoTrancheInitParams jtTranche;
        IRoycoVaultTranche.RoycoTrancheInitParams ltTranche;
        address stAsset;
        address jtAsset;
        bool jtCoinvested;
        IRoycoDayAccountant.RoycoDayAccountantInitParams accountant;
        GyroECLPPoolParams gyroECLPPoolParams;
        uint256 jtYDMTargetUtilizationWAD;
        uint256 ltYDMTargetUtilizationWAD;
        address protocolFeeRecipient;
        uint64 stSelfLiquidationBonusWAD;
        address roycoBlacklist;
        bytes kernelSpecificParams;
        bool enforceVaultSharesTransferWhitelist;
    }

    /**
     * @notice Balancer V3-specific addresses recorded for verification.
     * @custom:field balancerPool - The deployed Gyro E-CLP pool (the liquidity tranche's BPT).
     * @custom:field balancerHook - The deployed pool hook enforcing the kernel-only LP and same-block-swap rules.
     * @custom:field bptOracle - The deployed BPT oracle adapter that reports ltRawNAV.
     */
    struct ExtraContractsDeployedResult {
        address balancerPool;
        address balancerHook;
        address bptOracle;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error INVALID_ACCESS_MANAGER();
    error INVALID_TRANCHE_TYPE_ON_SENIOR_TRANCHE();
    error INVALID_TRANCHE_TYPE_ON_JUNIOR_TRANCHE();
    error INVALID_TRANCHE_TYPE_ON_LIQUIDITY_TRANCHE();
    error INVALID_KERNEL_ON_SENIOR_TRANCHE();
    error INVALID_KERNEL_ON_JUNIOR_TRANCHE();
    error INVALID_KERNEL_ON_LIQUIDITY_TRANCHE();
    error INVALID_SENIOR_TRANCHE_ON_KERNEL();
    error INVALID_JUNIOR_TRANCHE_ON_KERNEL();
    error INVALID_LIQUIDITY_TRANCHE_ON_KERNEL();
    error INVALID_ST_ASSET_ON_KERNEL();
    error INVALID_JT_ASSET_ON_KERNEL();
    error INVALID_LT_ASSET_ON_KERNEL();
    error INVALID_ACCOUNTANT_ON_KERNEL();
    error INVALID_KERNEL_ON_ACCOUNTANT();
    error POOL_NOT_REGISTERED_WITH_VAULT();
    error POOL_TOKEN_CONFIGURATION_MISMATCH();
    error INVALID_KERNEL_ON_BALANCER_HOOK();
    error INVALID_ECLP_LP_ORACLE_FACTORY();
    error INVALID_BPT_ORACLE_ON_KERNEL();

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The Balancer V3 Gyro E-CLP pool factory.
    GyroECLPPoolFactory public immutable BALANCER_V3_POOL_FACTORY;

    /// @notice The Balancer V3 vault.
    IVault public immutable BALANCER_V3_VAULT;

    /// @notice Shared registration-time stand-in hook implementation, deployed once here and reused as the initial
    ///         implementation behind every market's pool-hook proxy (it is stateless, so one instance serves all markets).
    address public immutable BALANCER_HOOK_STANDIN_IMPL;

    /// @notice Balancer's E-CLP LP oracle factory: the template deploys each market's manipulation-resistant BPT
    ///         TVL oracle through it, immediately after the market's pool is created.
    ILPOracleFactoryBase public immutable ECLP_LP_ORACLE_FACTORY;

    /// @notice Shared Balancer constant-1.0 price feed for both pool legs of the BPT oracle, deployed once here (it is
    ///         stateless): each leg's live balance is already priced by its rate provider, so the residual feed is 1.
    address public immutable CONSTANT_PRICE_FEED;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTION
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(
        IRoycoFactory _factory,
        GyroECLPPoolFactory _balancerV3PoolFactory,
        ILPOracleFactoryBase _eclpLPOracleFactory
    )
        BaseDeploymentTemplate(_factory)
    {
        BALANCER_V3_POOL_FACTORY = _balancerV3PoolFactory;
        BALANCER_V3_VAULT = IVault(address(_balancerV3PoolFactory.getVault()));
        BALANCER_HOOK_STANDIN_IMPL = address(new RoycoDayBalancerV3HooksStandIn());
        require(address(SingletonAuthentication(address(_eclpLPOracleFactory)).getVault()) == address(BALANCER_V3_VAULT), INVALID_ECLP_LP_ORACLE_FACTORY());
        ECLP_LP_ORACLE_FACTORY = _eclpLPOracleFactory;
        CONSTANT_PRICE_FEED = address(new ConstantPriceFeed());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PER-KERNEL HOOKS (subclasses override)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Returns the SSTORE2 component ID that holds the Day kernel's creation code.
    function _kernelComponentId() internal pure virtual returns (bytes32);

    /**
     * @dev Returns the ABI-encoded kernel `initialize(...)` calldata for the concrete Day kernel.
     * @param _bptOracle The template-deployed E-CLP BPT oracle for this market's pool. The concrete template must
     *        inject it into the kernel's LT-quoter init params (overwriting any caller-supplied value).
     */
    function _kernelInitData(
        IRoycoDayKernel.RoycoDayKernelInitParams memory _kip,
        bytes memory _kernelSpecificParams,
        address _bptOracle
    )
        internal
        pure
        virtual
        returns (bytes memory);

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoProtocolTemplate
    function deployMarket(bytes calldata _params) external override(IRoycoProtocolTemplate) onlyRoycoFactory returns (DeploymentResult memory result) {
        DayParams memory p = abi.decode(_params, (DayParams));

        // 1. Predict the 5 market proxy addresses.
        result.seniorTranche = ROYCO_FACTORY.predictDeterministicAddress(_marketComponentSalt(p.marketId, TAG_ST_PROXY));
        result.juniorTranche = ROYCO_FACTORY.predictDeterministicAddress(_marketComponentSalt(p.marketId, TAG_JT_PROXY));
        result.liquidityTranche = ROYCO_FACTORY.predictDeterministicAddress(_marketComponentSalt(p.marketId, TAG_LT_PROXY));
        result.kernel = ROYCO_FACTORY.predictDeterministicAddress(_marketComponentSalt(p.marketId, TAG_KERNEL_PROXY));
        result.accountant = ROYCO_FACTORY.predictDeterministicAddress(_marketComponentSalt(p.marketId, TAG_ACCOUNTANT_PROXY));

        // 2. Deploy the JT YDM (driven by coverage utilization) and the LT YDM / LDM (driven by liquidity utilization), each
        //    pinning its own target-utilization curve kink.
        (result.ydm,) = _deployYDM(_marketComponentSalt(p.marketId, TAG_YDM), p.jtYDMTargetUtilizationWAD);
        (result.ltYdm,) = _deployYDM(_marketComponentSalt(p.marketId, TAG_LDM), p.ltYDMTargetUtilizationWAD);

        // 3. Deploy ST impl + proxy first — the pool needs ST_PROXY as one of its tokens.
        address stImpl = _deploySeniorTrancheImpl(p.stAsset, result.kernel, _marketComponentSalt(p.marketId, TAG_ST_IMPL));
        _deployProxy(stImpl, _encodeTrancheInitData(p.stTranche), _marketComponentSalt(p.marketId, TAG_ST_PROXY));

        // 4. Deploy the pool hooks proxy against the shared stand-in implementation (returns true from onRegister and advertises
        //    the real hook's flags) so the pool can register now; it is upgraded to the real kernel-bound hook after step 9.
        address balancerHook = _deployProxy(BALANCER_HOOK_STANDIN_IMPL, bytes("no-op"), _marketComponentSalt(p.marketId, TAG_BALANCER_HOOK));

        // 5. Create the Gyro E-CLP pool `{ST_share, quote}`: senior leg WITH_RATE (rate provider = the predicted kernel),
        //    hooked to the stand-in proxy. LT asset = pool.
        address balancerPool = _createBalancerV3Pool(
            p.gyroECLPPoolParams, result.seniorTranche, result.kernel, balancerHook, _marketComponentSalt(p.marketId, TAG_BALANCER_V3_POOL)
        );

        // 6. Now that the pool is registered, deploy its manipulation-resistant BPT TVL oracle through Balancer's E-CLP LP oracle factory
        address bptOracle = _deployBPTOracle(balancerPool);

        // 7. Deploy JT impl + proxy (plain first-loss asset).
        address jtImpl = _deployJuniorTrancheImpl(p.jtAsset, result.kernel, _marketComponentSalt(p.marketId, TAG_JT_IMPL));
        _deployProxy(jtImpl, _encodeTrancheInitData(p.jtTranche), _marketComponentSalt(p.marketId, TAG_JT_PROXY));

        // 8. Deploy LT impl + proxy (asset = the pool BPT).
        address ltImpl = _deployLiquidityTrancheImpl(balancerPool, result.kernel, _marketComponentSalt(p.marketId, TAG_LT_IMPL));
        _deployProxy(ltImpl, _encodeTrancheInitData(p.ltTranche), _marketComponentSalt(p.marketId, TAG_LT_PROXY));

        // 9. Deploy accountant impl + proxy (Day accountant bytecode registered under the accountant component ID).
        address accountantImpl = _deployAccountantImpl(result.kernel, p.jtCoinvested, _marketComponentSalt(p.marketId, TAG_ACCOUNTANT_IMPL));
        _deployProxy(accountantImpl, _encodeAccountantInitData(p.accountant, result.ydm, result.ltYdm), _marketComponentSalt(p.marketId, TAG_ACCOUNTANT_PROXY));

        // 10. Deploy kernel impl + proxy, injecting the template-deployed BPT oracle into the kernel's LT quoter init.
        _deployKernelImplAndProxy(p, result, balancerPool, bptOracle, _marketComponentSalt(p.marketId, TAG_KERNEL_PROXY));

        // 11. Now that the kernel exists, deploy the real kernel-bound hook implementation and upgrade the pool hook proxy to it
        address realHookImpl = _deployImpl(COMPONENT_ID_DAY_BALANCER_HOOKS, abi.encode(result.kernel), _marketComponentSalt(p.marketId, TAG_BALANCER_HOOK_IMPL));
        UUPSUpgradeable(balancerHook).upgradeToAndCall(realHookImpl, abi.encodeCall(RoycoDayBalancerV3Hooks.initialize, (ROYCO_FACTORY.ROYCO_AUTHORITY())));

        // 12. Apply selector->role bindings + post-init grants (including SYNC_ROLE for the pool hook so it can sync the kernel).
        _applyRoleBindings(_buildRoleBindings(result, balancerHook));

        // 13. Record + verify-friendly extras.
        result.extras = abi.encode(ExtraContractsDeployedResult({ balancerPool: balancerPool, balancerHook: balancerHook, bptOracle: bptOracle }));
    }

    /**
     * @notice Deploys the market's E-CLP BPT TVL oracle through Balancer's LP oracle factory.
     */
    function _deployBPTOracle(address _balancerPool) internal returns (address) {
        IERC20[] memory poolTokens = BALANCER_V3_VAULT.getPoolTokens(_balancerPool);
        BalancerAggregatorV3Interface[] memory feeds = new BalancerAggregatorV3Interface[](poolTokens.length);
        for (uint256 i; i < poolTokens.length; ++i) {
            feeds[i] = BalancerAggregatorV3Interface(CONSTANT_PRICE_FEED);
        }

        return address(
            ECLP_LP_ORACLE_FACTORY.create({
                pool: IBasePool(_balancerPool), shouldUseBlockTimeForOldestFeedUpdate: false, shouldRevertIfVaultUnlocked: false, feeds: feeds
            })
        );
    }

    /// @notice Deploys the Day kernel impl + proxy, injecting the template-deployed BPT oracle into the kernel init.
    function _deployKernelImplAndProxy(
        DayParams memory _p,
        DeploymentResult memory _result,
        address _balancerPool,
        address _bptOracle,
        bytes32 _kernelProxySalt
    )
        internal
    {
        IRoycoDayKernel.RoycoDayKernelConstructionParams memory cp = IRoycoDayKernel.RoycoDayKernelConstructionParams({
            seniorTranche: _result.seniorTranche,
            stAsset: _p.stAsset,
            juniorTranche: _result.juniorTranche,
            jtAsset: _p.jtAsset,
            accountant: _result.accountant,
            liquidityTranche: _result.liquidityTranche,
            ltAsset: _balancerPool,
            enforceVaultSharesTransferWhitelist: _p.enforceVaultSharesTransferWhitelist
        });
        address kernelImpl = _deployImpl(_kernelComponentId(), abi.encode(cp), _marketComponentSalt(_p.marketId, TAG_KERNEL_IMPL));

        IRoycoDayKernel.RoycoDayKernelInitParams memory kip = IRoycoDayKernel.RoycoDayKernelInitParams({
            initialAuthority: ROYCO_FACTORY.ROYCO_AUTHORITY(),
            protocolFeeRecipient: _p.protocolFeeRecipient,
            stSelfLiquidationBonusWAD: _p.stSelfLiquidationBonusWAD,
            roycoBlacklist: _p.roycoBlacklist
        });
        _deployProxy(kernelImpl, _kernelInitData(kip, _p.kernelSpecificParams, _bptOracle), _kernelProxySalt);
    }

    /**
     * @notice Creates the Gyro E-CLP pool with tokens `{ST_share, quote}`:
     * @param _p The Gyro E-CLP pool parameters
     * @param _seniorTranche The senior tranche address
     * @param _rateProvider The rate provider address
     * @param _hook The hook address
     * @param _salt The salt for the pool
     * @return balancerV3Pool The address of the created Gyro E-CLP pool
     */
    function _createBalancerV3Pool(
        GyroECLPPoolParams memory _p,
        address _seniorTranche,
        address _rateProvider,
        address _hook,
        bytes32 _salt
    )
        internal
        returns (address balancerV3Pool)
    {
        // Balancer V3 requires a pool's tokens registered in ascending address order
        (address token0, address token1) = uint160(_seniorTranche) < uint160(_p.quoteAsset) ? (_seniorTranche, _p.quoteAsset) : (_p.quoteAsset, _seniorTranche);

        BalancerV3TokenConfig[] memory tokens = new BalancerV3TokenConfig[](2);
        tokens[0] = _buildTokenConfig(token0, _seniorTranche, _rateProvider, _p.quoteAssetRateProvider);
        tokens[1] = _buildTokenConfig(token1, _seniorTranche, _rateProvider, _p.quoteAssetRateProvider);

        address authority = ROYCO_FACTORY.ROYCO_AUTHORITY();
        BalancerV3PoolRoleAccounts memory roleAccounts =
            BalancerV3PoolRoleAccounts({ pauseManager: authority, swapFeeManager: authority, poolCreator: authority });

        balancerV3Pool = BALANCER_V3_POOL_FACTORY.create(
            _p.name,
            _p.symbol,
            tokens,
            _p.eclpParams,
            _p.derivedEclpParams,
            roleAccounts,
            _p.swapFeePercentage,
            _hook,
            _p.enableDonation,
            _p.disableUnbalancedLiquidity,
            _salt
        );
    }

    /// @dev Token config for a pool leg: the senior-tranche leg is `WITH_RATE` (priced by the kernel rate provider). Every other leg is `STANDARD`.
    function _buildTokenConfig(
        address _token,
        address _seniorTranche,
        address _seniorRateProvider,
        address _quoteRateProvider
    )
        private
        pure
        returns (BalancerV3TokenConfig memory)
    {
        address rateProvider = _token == _seniorTranche ? _seniorRateProvider : _quoteRateProvider;
        return BalancerV3TokenConfig({
            token: IERC20(_token),
            tokenType: rateProvider == address(0) ? BalancerV3TokenType.STANDARD : BalancerV3TokenType.WITH_RATE,
            rateProvider: IRateProvider(rateProvider),
            paysYieldFees: false
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLE BINDINGS
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildRoleBindings(DeploymentResult memory _r, address _balancerHook) internal view virtual returns (RoleBindings memory) {
        TargetBinding[] memory targets = new TargetBinding[](9);
        targets[0] = _trancheBinding(_r.seniorTranche, ST_LP_ROLE, ST_LP_ROLE, false);
        targets[1] = _trancheBinding(_r.juniorTranche, JT_LP_ROLE, JT_LP_ROLE, false);
        targets[2] = _trancheBinding(_r.liquidityTranche, PUBLIC_ROLE, LT_LP_ROLE, true);
        targets[3] = _kernelBinding(_r.kernel);
        targets[4] = _accountantBinding(_r.accountant);
        targets[5] = _balancerVaultBinding(address(BALANCER_V3_VAULT));
        targets[6] = _balancerProtocolFeeControllerBinding(address(BALANCER_V3_VAULT.getProtocolFeeController()));
        targets[7] = _balancerHookBinding(_balancerHook);
        targets[8] = _kernelQuoterBinding(_r.kernel);

        RoleGrant[] memory grants = new RoleGrant[](3);
        grants[0] = RoleGrant({ roleId: SYNC_ROLE, account: _r.accountant, executionDelay: 0 });
        grants[1] = RoleGrant({ roleId: BURNER_ROLE, account: _r.kernel, executionDelay: 0 });
        grants[2] = RoleGrant({ roleId: SYNC_ROLE, account: _balancerHook, executionDelay: 0 });

        return RoleBindings({ targetBindings: targets, postInitGrants: grants });
    }

    /// @dev The concrete Day kernel's quoter admin selectors (its ST/JT quoter family varies per kernel type). The
    ///      base binds the universal Balancer LT-quoter setters. Subclasses extend with their ST/JT quoter setters.
    function _kernelQuoterBinding(address _kernel) internal view virtual returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](2);
        uint64[] memory r = new uint64[](2);
        s[0] = BalancerV3_LT_BPTOracle_Quoter.setBPTOracle.selector;
        r[0] = ADMIN_ORACLE_QUOTER_ROLE;
        s[1] = BalancerV3_LT_BPTOracle_Quoter.setMaxReinvestmentSlippage.selector;
        r[1] = ADMIN_ORACLE_QUOTER_ROLE;
        return TargetBinding({ target: _kernel, selectors: s, roleIds: r });
    }

    /// @notice Admin surface for the Balancer pool hook (a RoycoBase UUPS contract): pause/unpause/upgrade.
    function _balancerHookBinding(address _hook) private pure returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](3);
        uint64[] memory r = new uint64[](3);
        s[0] = IRoycoAuth.pause.selector;
        r[0] = ADMIN_PAUSER_ROLE;
        s[1] = IRoycoAuth.unpause.selector;
        r[1] = ADMIN_UNPAUSER_ROLE;
        s[2] = UUPSUpgradeable.upgradeToAndCall.selector;
        r[2] = ADMIN_UPGRADER_ROLE;
        return TargetBinding({ target: _hook, selectors: s, roleIds: r });
    }

    /// @dev `mint` carries no binding: it is gated by the tranche's own `onlyKernel` check (an immutable-address
    ///      check), which scopes minting to THIS market's kernel — a shared AccessManager role could not.
    function _trancheBinding(address _tranche, uint64 _depositRole, uint64 _redeemRole, bool _isLiquidity) private pure returns (TargetBinding memory) {
        // Base tranche surface (7 selectors) + the two LT-only multi-asset selectors when binding the liquidity tranche
        uint256 n = _isLiquidity ? 9 : 7;
        bytes4[] memory s = new bytes4[](n);
        uint64[] memory r = new uint64[](n);
        s[0] = IRoycoVaultTranche.deposit.selector;
        r[0] = _depositRole;
        s[1] = IRoycoVaultTranche.redeem.selector;
        r[1] = _redeemRole;
        s[2] = IRoycoAuth.pause.selector;
        r[2] = ADMIN_PAUSER_ROLE;
        s[3] = IRoycoAuth.unpause.selector;
        r[3] = ADMIN_UNPAUSER_ROLE;
        s[4] = UUPSUpgradeable.upgradeToAndCall.selector;
        r[4] = ADMIN_UPGRADER_ROLE;
        s[5] = ERC20BurnableUpgradeable.burn.selector;
        r[5] = BURNER_ROLE;
        s[6] = ERC20BurnableUpgradeable.burnFrom.selector;
        r[6] = BURNER_ROLE;
        if (_isLiquidity) {
            s[7] = RoycoLiquidityTranche.depositMultiAsset.selector;
            r[7] = _depositRole;
            s[8] = RoycoLiquidityTranche.redeemMultiAsset.selector;
            r[8] = _redeemRole;
        }
        return TargetBinding({ target: _tranche, selectors: s, roleIds: r });
    }

    function _kernelBinding(address _kernel) private pure returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](8);
        uint64[] memory r = new uint64[](8);
        s[0] = IRoycoDayKernel.setProtocolFeeRecipient.selector;
        r[0] = ADMIN_KERNEL_ROLE;
        s[1] = IRoycoAuth.pause.selector;
        r[1] = ADMIN_PAUSER_ROLE;
        s[2] = IRoycoAuth.unpause.selector;
        r[2] = ADMIN_UNPAUSER_ROLE;
        s[3] = UUPSUpgradeable.upgradeToAndCall.selector;
        r[3] = ADMIN_UPGRADER_ROLE;
        s[4] = IRoycoDayKernel.syncTrancheAccounting.selector;
        r[4] = SYNC_ROLE;
        s[5] = IRoycoDayKernel.setSeniorTrancheSelfLiquidationBonus.selector;
        r[5] = ADMIN_KERNEL_ROLE;
        s[6] = IRoycoDayKernel.reinvestLiquidityPremium.selector;
        r[6] = ADMIN_MARKET_OPS_ROLE;
        s[7] = IRoycoDayKernel.setRoycoBlacklist.selector;
        r[7] = ADMIN_MARKET_OPS_ROLE;
        return TargetBinding({ target: _kernel, selectors: s, roleIds: r });
    }

    function _accountantBinding(address _accountant) private pure returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](16);
        uint64[] memory r = new uint64[](16);
        s[0] = IRoycoDayAccountant.setJuniorTrancheYDM.selector;
        r[0] = ADMIN_ACCOUNTANT_ROLE;
        s[1] = IRoycoDayAccountant.setLiquidityTrancheYDM.selector;
        r[1] = ADMIN_ACCOUNTANT_ROLE;
        s[2] = IRoycoDayAccountant.setSeniorTrancheProtocolFee.selector;
        r[2] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        s[3] = IRoycoDayAccountant.setJuniorTrancheProtocolFee.selector;
        r[3] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        s[4] = IRoycoDayAccountant.setJTYieldShareProtocolFee.selector;
        r[4] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        s[5] = IRoycoDayAccountant.setLTYieldShareProtocolFee.selector;
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
        s[13] = UUPSUpgradeable.upgradeToAndCall.selector;
        r[13] = ADMIN_UPGRADER_ROLE;
        s[14] = IRoycoDayAccountant.setSeniorTrancheDustTolerance.selector;
        r[14] = ADMIN_MARKET_OPS_ROLE;
        s[15] = IRoycoDayAccountant.setJuniorTrancheDustTolerance.selector;
        r[15] = ADMIN_MARKET_OPS_ROLE;
        return TargetBinding({ target: _accountant, selectors: s, roleIds: r });
    }

    function _balancerVaultBinding(address _vault) private pure returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](3);
        uint64[] memory r = new uint64[](3);
        s[0] = IVaultAdmin.pausePool.selector;
        r[0] = ADMIN_PAUSER_ROLE;
        s[1] = IVaultAdmin.unpausePool.selector;
        r[1] = ADMIN_UNPAUSER_ROLE;
        s[2] = IVaultAdmin.setStaticSwapFeePercentage.selector;
        r[2] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        return TargetBinding({ target: _vault, selectors: s, roleIds: r });
    }

    function _balancerProtocolFeeControllerBinding(address _feeController) private pure returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](3);
        uint64[] memory r = new uint64[](3);
        s[0] = IProtocolFeeController.setPoolCreatorSwapFeePercentage.selector;
        r[0] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        s[1] = IProtocolFeeController.setPoolCreatorYieldFeePercentage.selector;
        r[1] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        s[2] = bytes4(keccak256("withdrawPoolCreatorFees(address,address)"));
        r[2] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        return TargetBinding({ target: _feeController, selectors: s, roleIds: r });
    }
}
