// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { IProtocolFeeController } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IProtocolFeeController.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IVaultAdmin } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultAdmin.sol";
import { HooksConfig as BalancerV3HooksConfig } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { UUPSUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC20BurnableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SSTORE2 } from "../../../lib/solady/src/utils/SSTORE2.sol";
import { IRoycoAuth } from "../../interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayEntryPoint } from "../../interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { IRoycoFactory } from "../../interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../interfaces/factory/IRoycoProtocolTemplate.sol";
import { RoycoDayBalancerV3Kernel } from "../../kernels/RoycoDayBalancerV3Kernel.sol";
import { BalancerV3LiquidityVenue } from "../../kernels/base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";
import { RoycoDayBalancerV3Hooks } from "../../kernels/base/liquidity-venue/balancer-v3/hooks/RoycoDayBalancerV3Hooks.sol";
import { RoycoDayBalancerV3HooksStandIn } from "../../kernels/base/liquidity-venue/balancer-v3/hooks/RoycoDayBalancerV3HooksStandIn.sol";
import { TrancheType } from "../../libraries/Types.sol";
import { OracleClockBase } from "../../oracle/base/clock/OracleClockBase.sol";
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
import { TAG_ACCOUNTANT_PROXY, TAG_BALANCER_HOOK_PROXY, TAG_JT_PROXY, TAG_KERNEL_PROXY, TAG_LPT_PROXY, TAG_ST_PROXY } from "./base/Constants.sol";
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
     * @notice The externally (script) deployed market contracts the template wires into proxies and verifies
     * @custom:field jtImpl - The junior tranche implementation (immutables `(collateralAsset, kernel)` pinned at deployment)
     * @custom:field lptImpl - The liquidity provider tranche implementation (immutables `(balancerPool, kernel)` pinned at deployment)
     * @custom:field accountantImpl - The accountant implementation (immutable `kernel` pinned at deployment)
     * @custom:field kernelImpl - The Day kernel implementation for this market's kernel family
     * @custom:field jtYdm - The junior tranche's YDM (risk-premium model) instance
     * @custom:field lptYdm - The liquidity provider tranche's LDM (liquidity-premium model) instance, distinct from `jtYdm`
     * @custom:field balancerPool - The pre-created Gyro E-CLP `{ST_share, quote}` pool (the liquidity provider tranche's BPT / asset)
     * @custom:field bptOracle - The externally deployed manipulation-resistant E-CLP BPT TVL oracle for the pool, injected
     *               into the kernel's liquidity venue init (the venue's `_setBPTOracle` verifies `oracle.pool() == LPT_ASSET` on-chain)
     */
    struct MarketContracts {
        address jtImpl;
        address lptImpl;
        address accountantImpl;
        address kernelImpl;
        address jtYdm;
        address lptYdm;
        address balancerPool;
        address bptOracle;
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
     * @custom:field jtTranche - The junior tranche initialization params
     * @custom:field lptTranche - The liquidity provider tranche initialization params
     * @custom:field collateralAsset - The coinvested collateral asset underlying both the senior and junior tranches
     * @custom:field quoteAsset - The quote asset expected as the pool's second token, pinned during pool verification
     * @custom:field accountant - The accountant initialization params (coverage, premiums, and state machine config)
     * @custom:field marketContracts - The externally (script) deployed implementations, YDMs, and Gyro E-CLP pool the template wires and verifies
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
     * @custom:field enforceVaultSharesTransferWhitelist - Whether to enforce the vault shares transfer whitelist (verified against the kernel's immutable)
     * @custom:field entryPointTrancheConfigs - The per-tranche entry point configurations applied after the market is deployed (any oracle clock is deployed externally and passed by address)
     * @custom:field deployPoolHook - Whether the market's pool carries the Balancer hook
     * @dev The senior tranche proxy (and, for a hooked market, the Balancer pool-hook proxy) are pre-deployed by the
     *      deployer via `factory.deployDeterministicProxy` (the pool needs the ST share as a token, and a hooked pool
     *      must register against its hook, before the wiring transaction), so `stTranche`'s init data is built
     *      script-side and only `jtTranche`/`lptTranche` are consumed here
     */
    struct MarketParams {
        bytes32 marketId;
        IRoycoVaultTranche.RoycoTrancheInitParams jtTranche;
        IRoycoVaultTranche.RoycoTrancheInitParams lptTranche;
        address collateralAsset;
        address quoteAsset;
        IRoycoDayAccountant.RoycoDayAccountantInitParams accountant;
        MarketContracts marketContracts;
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
        bool enforceVaultSharesTransferWhitelist;
        EntryPointTrancheConfigs entryPointTrancheConfigs;
        bool deployPoolHook;
    }

    /**
     * @notice Balancer V3-specific addresses recorded for verification
     * @custom:field balancerPool - The deployed Gyro E-CLP pool (the liquidity provider tranche's BPT)
     * @custom:field balancerHook - The deployed pool hook, or address(0) for a hookless market
     * @custom:field bptOracle - The deployed BPT oracle adapter that reports lptRawNAV
     */
    struct ExtraContractsDeployedResult {
        address balancerPool;
        address balancerHook;
        address bptOracle;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Thrown when the pre-deployed senior tranche proxy is missing or was not deployed via the factory's `deployDeterministicProxy`
    error INVALID_SENIOR_TRANCHE_PROXY(address seniorTranche);
    /// @notice Thrown when the pre-deployed pool-hook proxy was not deployed via the factory against the stand-in implementation
    error INVALID_HOOK_PROXY(address hook);
    /// @notice Thrown when the pre-created Balancer pool did not originate from the expected Gyro E-CLP pool factory
    error POOL_NOT_FROM_FACTORY(address pool);
    /// @notice Thrown when the pre-created Balancer pool is not a fresh, unseeded `{ST_share, quote}` pool hooked to the market's hook
    error INVALID_POOL_CONFIGURATION(address pool);
    /// @notice Thrown when a deployed market contract's on-chain wiring does not match the expected configuration
    error MARKET_WIRING_VERIFICATION_FAILED(address subject);
    /// @notice Thrown when the CREATE of the real kernel-bound hook implementation returns the zero address
    error HOOK_IMPL_DEPLOYMENT_FAILED();

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The Balancer V3 Gyro E-CLP pool factory
    GyroECLPPoolFactory public immutable BALANCER_V3_POOL_FACTORY;

    /// @notice The Balancer V3 vault
    IVault public immutable BALANCER_V3_VAULT;

    /// @notice Shared registration-time stand-in hook implementation, deployed once here and reused as the initial
    ///         implementation behind every market's pool-hook proxy (it is stateless, so one instance serves all markets)
    address public immutable BALANCER_HOOK_STANDIN_IMPL;

    /// @notice SSTORE2 pointer holding the real kernel-bound hook's creation code.
    address private immutable _hookCreationCodePointer;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTION
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(
        IRoycoFactory _factory,
        GyroECLPPoolFactory _balancerV3PoolFactory,
        address _roycoDayEntryPoint,
        address _roycoMarketSyncer
    )
        BaseDeploymentTemplate(_factory)
        EntryPointConfigurer(_roycoDayEntryPoint, _factory)
        MarketSyncerConfigurer(_roycoMarketSyncer)
    {
        BALANCER_V3_POOL_FACTORY = _balancerV3PoolFactory;
        BALANCER_V3_VAULT = IVault(address(_balancerV3PoolFactory.getVault()));
        BALANCER_HOOK_STANDIN_IMPL = address(new RoycoDayBalancerV3HooksStandIn());

        // Store the real hook's creation code as SSTORE2 data
        _hookCreationCodePointer = SSTORE2.write(type(RoycoDayBalancerV3Hooks).creationCode);
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

    /// @inheritdoc IRoycoProtocolTemplate
    function deployMarket(bytes calldata _params) external override(IRoycoProtocolTemplate) onlyRoycoFactory returns (DeploymentResult memory result) {
        MarketParams memory p = abi.decode(_params, (MarketParams));
        MarketContracts memory mc = p.marketContracts;

        // 1. Predict the senior tranche (and, for a hooked market, the pool-hook) market proxy addresses.
        //    The senior tranche and pool-hook (if expected) proxies are pre-deployed by the deployer
        result.seniorTranche = ROYCO_FACTORY.predictDeterministicAddress(_marketComponentSalt(p.marketId, TAG_ST_PROXY));
        address balancerHook =
            p.deployPoolHook ? ROYCO_FACTORY.predictDeterministicAddress(_marketComponentSalt(p.marketId, TAG_BALANCER_HOOK_PROXY)) : address(0);
        result.ydm = mc.jtYdm;
        result.lptYdm = mc.lptYdm;

        // 2. Verify the pre-deployed proxies by re-deriving their addresses from the shared salt and confirming
        //    they are deployed (the hook proxy only exists for a hooked market).
        require(result.seniorTranche.code.length > 0, INVALID_SENIOR_TRANCHE_PROXY(result.seniorTranche));
        require(!p.deployPoolHook || balancerHook.code.length > 0, INVALID_HOOK_PROXY(balancerHook));

        // 3. Verify the pre-created Gyro E-CLP pool
        _verifyPool(mc.balancerPool, result.seniorTranche, p.quoteAsset, balancerHook);

        // 4. Deploy the JT and LPT tranche proxies against the script-deployed implementations
        result.juniorTranche = _deployProxy(mc.jtImpl, _encodeTrancheInitData(p.jtTranche), _marketComponentSalt(p.marketId, TAG_JT_PROXY));
        result.liquidityProviderTranche = _deployProxy(mc.lptImpl, _encodeTrancheInitData(p.lptTranche), _marketComponentSalt(p.marketId, TAG_LPT_PROXY));

        // 5. Deploy the accountant proxy, injecting the deployed JT YDM / LPT LDM instances into its init data
        result.accountant = _deployProxy(
            mc.accountantImpl, _encodeAccountantInitData(p.accountant, mc.jtYdm, mc.lptYdm), _marketComponentSalt(p.marketId, TAG_ACCOUNTANT_PROXY)
        );

        // 6. Deploy the kernel proxy, injecting the externally deployed BPT oracle into the kernel's liquidity venue init
        //    (the venue's `_setBPTOracle` verifies `bptOracle.pool() == LPT_ASSET` on-chain during kernel initialization)
        result.kernel = _deployKernelProxy(p, mc.bptOracle, _marketComponentSalt(p.marketId, TAG_KERNEL_PROXY));

        // 7. Now that the kernel has code, deploy the real kernel-bound hook implementation from
        //    its SSTORE2-stored creation code
        if (p.deployPoolHook) {
            address realHookImpl = _deployRealHookImpl(result.kernel);
            UUPSUpgradeable(balancerHook).upgradeToAndCall(realHookImpl, abi.encodeCall(RoycoDayBalancerV3Hooks.initialize, (ROYCO_FACTORY.ROYCO_AUTHORITY())));
        }

        // 8. Verify the whole market's on-chain wiring before granting it any roles
        _validateDeployment(p, result, balancerHook);

        // 9. Apply selector->role bindings + post-init grants (including SYNC_ROLE for the pool hook so it can sync the kernel)
        _applyRoleBindings(_buildRoleBindings(p, result, balancerHook));

        // 10. Record + verify extras
        result.extras = abi.encode(ExtraContractsDeployedResult({ balancerPool: mc.balancerPool, balancerHook: balancerHook, bptOracle: mc.bptOracle }));
    }

    /**
     * @notice Deploys the real kernel-bound hook implementation from its SSTORE2-stored creation code, appending the
     * kernel as its constructor arg
     * @dev The hook constructor reads `kernel.LPT_ASSET()`, so the kernel proxy must already have code
     */
    function _deployRealHookImpl(address _kernel) internal returns (address impl) {
        bytes memory initCode = abi.encodePacked(SSTORE2.read(_hookCreationCodePointer), abi.encode(_kernel));
        assembly ("memory-safe") {
            impl := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(impl != address(0), HOOK_IMPL_DEPLOYMENT_FAILED());
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

    /// @notice Deploys the Day kernel proxy against the script-deployed kernel impl, injecting the externally deployed BPT oracle
    function _deployKernelProxy(MarketParams memory _p, address _bptOracle, bytes32 _kernelProxySalt) internal returns (address kernel) {
        IRoycoDayKernel.RoycoDayKernelInitParams memory kip = IRoycoDayKernel.RoycoDayKernelInitParams({
            initialAuthority: ROYCO_FACTORY.ROYCO_AUTHORITY(),
            protocolFeeRecipient: _p.protocolFeeRecipient,
            stSelfLiquidationBonusWAD: _p.stSelfLiquidationBonusWAD,
            roycoBlacklist: _p.roycoBlacklist,
            collateralAssetOracle: _p.collateralAssetOracle,
            stalenessThresholdSeconds: _p.stalenessThresholdSeconds,
            sequencerUptimeFeed: _p.sequencerUptimeFeed,
            gracePeriodSeconds: _p.gracePeriodSeconds
        });
        kernel = _deployProxy(_p.marketContracts.kernelImpl, _kernelInitData(kip, _p.kernelSpecificParams, _bptOracle), _kernelProxySalt);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Verifies the pre-created Gyro E-CLP pool before the market is wired against it
     * @param _pool The pre-created pool
     * @param _seniorTranche The senior tranche share expected as the pool's first token
     * @param _quoteAsset The quote asset expected as the pool's second token
     * @param _hook The hook expected as the pool's hook
     */
    function _verifyPool(address _pool, address _seniorTranche, address _quoteAsset, address _hook) internal view {
        // Provenance: the pool was created by our Gyro E-CLP pool factory
        require(BALANCER_V3_POOL_FACTORY.isPoolFromFactory(_pool), POOL_NOT_FROM_FACTORY(_pool));

        // Unseeded: no BPT has been minted (belt-and-suspenders against a pool seeded during the cross-tx window)
        require(IERC20(_pool).totalSupply() == 0, INVALID_POOL_CONFIGURATION(_pool));

        // Registered against this market's stand-in hook proxy
        BalancerV3HooksConfig memory hooksConfig = BALANCER_V3_VAULT.getHooksConfig(_pool);
        require(hooksConfig.hooksContract == _hook, INVALID_POOL_CONFIGURATION(_pool));

        // Exactly {ST share, quote asset}: the market id guarantees the deployed ST share sorts "less" than the
        // quote token, and the quote leg must be the deployer-intended asset
        IERC20[] memory tokens = BALANCER_V3_VAULT.getPoolTokens(_pool);
        require(tokens.length == 2 && address(tokens[0]) == _seniorTranche && address(tokens[1]) == _quoteAsset, INVALID_POOL_CONFIGURATION(_pool));
    }

    /**
     * @notice Verifies the whole market's on-chain wiring after the proxies are deployed and the hook is upgraded
     * @dev Cross-checks every deployed contract's immutables/state against the params and against each other, so a
     *      script-side deployment mistake (wrong impl, mis-encoded init data, swapped address) fails loud here rather
     *      than producing a subtly mis-wired live market. Modeled on royco-dawn's `RoycoFactory._validateDeployment`
     */
    function _validateDeployment(MarketParams memory _p, DeploymentResult memory _r, address _hook) internal view {
        address authority = ROYCO_FACTORY.ROYCO_AUTHORITY();
        address pool = _p.marketContracts.balancerPool;

        // Shared market authority governs every component (tranches, kernel, accountant, and the hook when deployed)
        require(IAccessManaged(_r.seniorTranche).authority() == authority, MARKET_WIRING_VERIFICATION_FAILED(_r.seniorTranche));
        require(IAccessManaged(_r.juniorTranche).authority() == authority, MARKET_WIRING_VERIFICATION_FAILED(_r.juniorTranche));
        require(IAccessManaged(_r.liquidityProviderTranche).authority() == authority, MARKET_WIRING_VERIFICATION_FAILED(_r.liquidityProviderTranche));
        require(IAccessManaged(_r.kernel).authority() == authority, MARKET_WIRING_VERIFICATION_FAILED(_r.kernel));
        require(IAccessManaged(_r.accountant).authority() == authority, MARKET_WIRING_VERIFICATION_FAILED(_r.accountant));
        require(!_p.deployPoolHook || IAccessManaged(_hook).authority() == authority, MARKET_WIRING_VERIFICATION_FAILED(_hook));

        // Senior tranche: type, kernel binding, asset, and unseeded
        require(IRoycoVaultTranche(_r.seniorTranche).TRANCHE_TYPE() == TrancheType.SENIOR, MARKET_WIRING_VERIFICATION_FAILED(_r.seniorTranche));
        require(IRoycoVaultTranche(_r.seniorTranche).KERNEL() == _r.kernel, MARKET_WIRING_VERIFICATION_FAILED(_r.seniorTranche));
        require(IRoycoVaultTranche(_r.seniorTranche).asset() == _p.collateralAsset, MARKET_WIRING_VERIFICATION_FAILED(_r.seniorTranche));
        require(IERC20(_r.seniorTranche).totalSupply() == 0, MARKET_WIRING_VERIFICATION_FAILED(_r.seniorTranche));

        // Junior tranche: type, kernel binding, asset
        require(IRoycoVaultTranche(_r.juniorTranche).TRANCHE_TYPE() == TrancheType.JUNIOR, MARKET_WIRING_VERIFICATION_FAILED(_r.juniorTranche));
        require(IRoycoVaultTranche(_r.juniorTranche).KERNEL() == _r.kernel, MARKET_WIRING_VERIFICATION_FAILED(_r.juniorTranche));
        require(IRoycoVaultTranche(_r.juniorTranche).asset() == _p.collateralAsset, MARKET_WIRING_VERIFICATION_FAILED(_r.juniorTranche));

        // Liquidity provider tranche: type, kernel binding, asset is the pool BPT
        require(
            IRoycoVaultTranche(_r.liquidityProviderTranche).TRANCHE_TYPE() == TrancheType.LIQUIDITY_PROVIDER,
            MARKET_WIRING_VERIFICATION_FAILED(_r.liquidityProviderTranche)
        );
        require(IRoycoVaultTranche(_r.liquidityProviderTranche).KERNEL() == _r.kernel, MARKET_WIRING_VERIFICATION_FAILED(_r.liquidityProviderTranche));
        require(IRoycoVaultTranche(_r.liquidityProviderTranche).asset() == pool, MARKET_WIRING_VERIFICATION_FAILED(_r.liquidityProviderTranche));

        // Kernel: full tranche set, assets, accountant, and the whitelist-enforcement flag
        IRoycoDayKernel kernel = IRoycoDayKernel(_r.kernel);
        require(kernel.SENIOR_TRANCHE() == _r.seniorTranche, MARKET_WIRING_VERIFICATION_FAILED(_r.kernel));
        require(kernel.JUNIOR_TRANCHE() == _r.juniorTranche, MARKET_WIRING_VERIFICATION_FAILED(_r.kernel));
        require(kernel.LIQUIDITY_PROVIDER_TRANCHE() == _r.liquidityProviderTranche, MARKET_WIRING_VERIFICATION_FAILED(_r.kernel));
        require(kernel.ACCOUNTANT() == _r.accountant, MARKET_WIRING_VERIFICATION_FAILED(_r.kernel));
        require(kernel.COLLATERAL_ASSET() == _p.collateralAsset, MARKET_WIRING_VERIFICATION_FAILED(_r.kernel));
        require(kernel.LPT_ASSET() == pool, MARKET_WIRING_VERIFICATION_FAILED(_r.kernel));
        require(kernel.ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER() == _p.enforceVaultSharesTransferWhitelist, MARKET_WIRING_VERIFICATION_FAILED(_r.kernel));

        // The market id should guarantee that the deployed ST share is "less" than the quote token
        IERC20[] memory tokens = BALANCER_V3_VAULT.getPoolTokens(pool);
        require(address(tokens[0]) == _r.seniorTranche, MARKET_WIRING_VERIFICATION_FAILED(pool));
        require(address(tokens[1]) == kernel.QUOTE_ASSET(), MARKET_WIRING_VERIFICATION_FAILED(pool));

        // Accountant: kernel binding and the injected JT YDM / LPT LDM instances
        require(IRoycoDayAccountant(_r.accountant).KERNEL() == _r.kernel, MARKET_WIRING_VERIFICATION_FAILED(_r.accountant));
        IRoycoDayAccountant.RoycoDayAccountantState memory accountantState = IRoycoDayAccountant(_r.accountant).getState();
        require(
            accountantState.jtYDM == _p.marketContracts.jtYdm && accountantState.lptYDM == _p.marketContracts.lptYdm,
            MARKET_WIRING_VERIFICATION_FAILED(_r.accountant)
        );

        // Hook: bound to this market's kernel and pool when deployed
        if (_p.deployPoolHook) {
            require(RoycoDayBalancerV3Hooks(_hook).ROYCO_DAY_KERNEL() == _r.kernel, MARKET_WIRING_VERIFICATION_FAILED(_hook));
            require(RoycoDayBalancerV3Hooks(_hook).LIQUIDITY_PROVIDER_TRANCHE_BALANCER_V3_POOL() == pool, MARKET_WIRING_VERIFICATION_FAILED(_hook));
        } else {
            require(BALANCER_V3_VAULT.getHooksConfig(pool).hooksContract == address(0), MARKET_WIRING_VERIFICATION_FAILED(pool));
        }

        // Kernel-family-specific wiring (e.g. Makina machine, IdleCDO CDO)
        _validateKernelSpecifics(_r.kernel, _p.kernelSpecificParams);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLE BINDINGS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Assembles the market's full role-binding config, pairing each deployment's runtime target addresses with
    ///         the selector/role sets from the per-target binding helpers and the deployer-declared oracle bindings
    function _buildRoleBindings(MarketParams memory _p, DeploymentResult memory _r, address _balancerHook) internal view returns (RoleBindings memory) {
        // Runtime target addresses, index-aligned with the binding helpers below
        address[10] memory targets = [
            _r.seniorTranche,
            _r.juniorTranche,
            _r.liquidityProviderTranche,
            _r.kernel,
            _r.accountant,
            address(BALANCER_V3_VAULT),
            address(BALANCER_V3_VAULT.getProtocolFeeController()),
            _balancerHook,
            _r.kernel,
            _p.collateralAssetOracle
        ];

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
        (s, r) = _balancerVaultBinding(); // 5: Balancer vault
        targetBindings[5] = TargetBinding({ target: targets[5], selectors: s, roleIds: r });
        (s, r) = _balancerProtocolFeeControllerBinding(); // 6: protocol fee controller
        targetBindings[6] = TargetBinding({ target: targets[6], selectors: s, roleIds: r });
        if (_p.deployPoolHook) {
            (s, r) = _balancerHookBinding();
        } else {
            // Skipped
            (s, r) = (new bytes4[](0), new uint64[](0));
        }
        targetBindings[7] = TargetBinding({ target: targets[7], selectors: s, roleIds: r });
        (s, r) = _kernelPricingBinding(); // 8: kernel pricing admin surface
        targetBindings[8] = TargetBinding({ target: targets[8], selectors: s, roleIds: r });
        // 9: collateral asset oracle restricted surface, declared per oracle kind by the deployer (empty for kinds with no restricted surface)
        targetBindings[9] =
            TargetBinding({ target: targets[9], selectors: _p.collateralAssetOracleBindingSelectors, roleIds: _p.collateralAssetOracleBindingRoleIds });

        // Post-init grants: accountant SYNC, kernel BURNER, entry point SYNC, and (hooked markets only) hook SYNC (all zero execution delay)
        // The entry point singleton is re-granted on every deployment: the grant is idempotent and the role is market-agnostic
        RoleGrant[] memory grants = new RoleGrant[](_p.deployPoolHook ? 4 : 3);
        grants[0] = RoleGrant({ roleId: SYNC_ROLE, account: _r.accountant, executionDelay: 0 });
        grants[1] = RoleGrant({ roleId: BURNER_ROLE, account: _r.kernel, executionDelay: 0 });
        grants[2] = RoleGrant({ roleId: SYNC_ROLE, account: ROYCO_DAY_ENTRY_POINT, executionDelay: 0 });
        if (_p.deployPoolHook) grants[3] = RoleGrant({ roleId: SYNC_ROLE, account: _balancerHook, executionDelay: 0 });

        return RoleBindings({ targetBindings: targetBindings, postInitGrants: grants });
    }

    /// @dev The Day kernel's pricing admin selectors: the Balancer liquidity venue setters and the kernel's collateral
    ///      asset oracle setters, all bound to ADMIN_ORACLE_ROLE
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

    /// @notice Admin surface for the Balancer pool hook (a RoycoBase UUPS contract): pause/unpause/upgrade
    function _balancerHookBinding() private pure returns (bytes4[] memory s, uint64[] memory r) {
        s = new bytes4[](3);
        r = new uint64[](3);
        s[0] = IRoycoAuth.pause.selector;
        r[0] = ADMIN_PAUSER_ROLE;
        s[1] = IRoycoAuth.unpause.selector;
        r[1] = ADMIN_UNPAUSER_ROLE;
        s[2] = UUPSUpgradeable.upgradeToAndCall.selector;
        r[2] = ADMIN_UPGRADER_ROLE;
    }

    /// @dev `mint` carries no binding: it is gated by the tranche's own `onlyKernel` check (an immutable-address
    ///      check), which scopes minting to THIS market's kernel in a way a shared AccessManager role could not
    function _trancheBinding(uint64 _depositRole, uint64 _redeemRole, bool _isLiquidity) private pure returns (bytes4[] memory s, uint64[] memory r) {
        // Base tranche surface (7 selectors) + the two LPT-only multi-asset selectors when binding the liquidity provider tranche
        uint256 n = _isLiquidity ? 9 : 7;
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
        s[4] = UUPSUpgradeable.upgradeToAndCall.selector;
        r[4] = ADMIN_UPGRADER_ROLE;
        s[5] = ERC20BurnableUpgradeable.burn.selector;
        r[5] = BURNER_ROLE;
        s[6] = ERC20BurnableUpgradeable.burnFrom.selector;
        r[6] = BURNER_ROLE;
        if (_isLiquidity) {
            s[7] = RoycoLiquidityProviderTranche.depositMultiAsset.selector;
            r[7] = _depositRole;
            s[8] = RoycoLiquidityProviderTranche.redeemMultiAsset.selector;
            r[8] = _redeemRole;
        }
    }

    function _kernelBinding() private pure returns (bytes4[] memory s, uint64[] memory r) {
        s = new bytes4[](9);
        r = new uint64[](9);
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
        r[6] = ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE;
        s[7] = IRoycoDayKernel.setRoycoBlacklist.selector;
        r[7] = ADMIN_MARKET_OPS_ROLE;
        s[8] = IRoycoDayKernel.syncTrancheAccountingFor.selector;
        r[8] = SYNC_ROLE;
    }

    function _accountantBinding() private pure returns (bytes4[] memory s, uint64[] memory r) {
        s = new bytes4[](15);
        r = new uint64[](15);
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
        s[13] = UUPSUpgradeable.upgradeToAndCall.selector;
        r[13] = ADMIN_UPGRADER_ROLE;
        s[14] = IRoycoDayAccountant.setDustTolerance.selector;
        r[14] = ADMIN_MARKET_OPS_ROLE;
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
