// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ILPOracleBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleBase.sol";
import { ILPOracleFactoryBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { TokenInfo, TokenType } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { LPOracleBase } from "../../../lib/balancer-v3-monorepo/pkg/oracles/contracts/LPOracleBase.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import {
    AggregatorV3Interface as BalancerAggregatorV3Interface
} from "../../../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { AccessManagedUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC20BurnableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoMarketSyncer } from "../../../lib/royco-periphery/src/syncer/RoycoMarketSyncer.sol";
import { RoycoDayBalancerV3MarketDeploymentTemplate } from "../../../src/factory/templates/RoycoDayBalancerV3MarketDeploymentTemplate.sol";
import { DeploymentResult } from "../../../script/config/DeploymentTypes.sol";
import { DayMarketConfig } from "../../../script/deploy/templates/royco-day-balancer-v3/DayMarketTypes.sol";
import { DeployMarketComponent } from "../../../script/deploy/templates/royco-day-balancer-v3/DeployMarket.s.sol";
import {
    ADMIN_BALANCER_POOL_MANAGER_ROLE,
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE,
    ADMIN_FACTORY_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_MARKET_OPS_ROLE,
    ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE,
    ADMIN_ORACLE_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    BURNER_ROLE,
    JT_LP_ROLE,
    LPT_LP_ROLE,
    PUBLIC_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE
} from "../../../src/factory/Roles.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayEntryPoint } from "../../../src/interfaces/IRoycoDayEntryPoint.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { IRoycoAccessManager } from "../../../src/interfaces/factory/IRoycoAccessManager.sol";
import { IRoycoFactoryGatekeeper } from "../../../src/interfaces/factory/IRoycoFactoryGatekeeper.sol";
import { BalancerV3LiquidityVenue } from "../../../src/kernels/base/liquidity-venue/balancer-v3/BalancerV3LiquidityVenue.sol";
import { TrancheType } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../../src/libraries/Units.sol";
import { RoycoLiquidityProviderTranche } from "../../../src/tranches/RoycoLiquidityProviderTranche.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { RoycoDayTestBase } from "../../utils/RoycoDayTestBase.sol";

/**
 * @title Test_DayMarketDeployment
 * @notice End-to-end deployment test: runs the real deployment pipeline against a mainnet fork to deploy a full Day snUSD
 *         market on the real Balancer V3 + Gyro E-CLP infra, then rigorously asserts every parameter, linkage, and
 *         AccessManager auth wiring.
 * @dev Scope: deploy + static assertions (no deposits/syncs). The BPT oracle is deployed by the template through the
 *      real Balancer E-CLP LP oracle factory and injected into the kernel (asserted here); the RedStone feed is the real
 *      (uncalled at deploy) base->NAV oracle. The ST/JT asset is the real snUSD ERC4626 vault (answers
 *      `decimals()`/`asset()` on the fork); the E-CLP curve params are a known-good set copied from Balancer's
 *      pool-gyro test util (the Gyro `create` validates them).
 *
 *      Requires env `MAINNET_RPC_URL` and (optionally) `FORK_BLOCK` (a block where the Gyro factory, Balancer V3 vault,
 *      E-CLP LP oracle factory, snUSD vault, USDC, and the RedStone feed all have code). Without an RPC the suite FAILS
 *      (no silent skip).
 */
contract Test_DayMarketDeployment is RoycoDayTestBase {
    // ── Real mainnet addresses (snUSD market) ────────────────────────────────────────────────────────────────────
    address internal constant SNUSD_VAULT = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313; // ST/JT ERC4626 asset
    address internal constant NUSD_REDSTONE_ORACLE = 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95; // base->NAV feed
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // pool quote asset
    address internal constant FACTORY_ADMIN = 0x7c405bbD131e42af506d14e752f2e59B19D49997; // ROOT_MULTISIG

    // Expected values asserted against the config-file `snUSD` market config.
    uint64 internal constant TARGET_UTIL = 0.9e18;
    uint256 internal constant SWAP_FEE = 1e14; // 1 bp

    // ── Deployed market (RoycoDayTestBase sets FACTORY/ACCESS_MANAGER/ST/JT/KERNEL/ACCOUNTANT/YDM/BLACKLIST via _setDeployedMarket) ──
    IRoycoVaultTranche internal LPT;
    address internal POOL; // the Gyro E-CLP BPT (== kernel.lptAsset())
    address internal LPT_YDM; // the LDM
    IVault internal VAULT;
    IRoycoDayEntryPoint internal ENTRY_POINT; // the pre-deployed entry point singleton the template configured
    RoycoMarketSyncer internal MARKET_SYNCER; // the pre-deployed syncer singleton the template registered the kernel on

    function _forkConfiguration() internal view override returns (uint256 forkBlock, string memory forkRpcUrl) {
        // No skip: the suite FAILS (env not found) when MAINNET_RPC_URL is unset, instead of silently passing.
        forkRpcUrl = vm.envString("MAINNET_RPC_URL");
        // A block where the Gyro E-CLP factory (deployed ~24.2M), the Balancer V3 vault, the E-CLP LP oracle factory,
        // the snUSD vault, USDC, and the RedStone nUSD feed all have code. Overridable via the FORK_BLOCK env var.
        forkBlock = vm.envOr("FORK_BLOCK", uint256(25_400_000));
    }

    function setUp() public {
        // Fork mainnet + create wallets + stand up the pipeline components.
        _setUpRoyco();
        // This suite deploys with the production ROOT_MULTISIG as the AccessManager admin (rather than the
        // fixture's OWNER), so its auth assertions read the production admin topology
        BOOTSTRAP.overrideFactoryAdminForTest(FACTORY_ADMIN);

        // Every market launches with genesis pool liquidity, pulled from the configured funder. In the script flow the
        // funder is the broadcasting deployer, which approves the template from inside the broadcast, so the suite only
        // has to make sure that deployer actually holds the quote.
        DayMarketConfig memory cfg = MARKET_REGISTRY.getDayMarketConfig("snUSD");
        deal(cfg.pool.quoteAsset, DEPLOYER.addr, cfg.poolInitialization.quoteAmount);

        // Deploy the Day-shaped SNUSD market end to end through the real pipeline, sourcing the market config from
        // the registry (single source of truth) — not an inline test fixture.
        DeploymentResult memory result = _deployMarketThroughPipeline(cfg);
        _setDeployedMarket(result);

        // The periphery singletons the script deploys before the market and the template configures for it.
        ENTRY_POINT = IRoycoDayEntryPoint(result.entryPoint);
        MARKET_SYNCER = RoycoMarketSyncer(result.marketSyncer);

        // Capture the Day-only addresses the script's DeploymentResult omits, by reading the deployed contracts.
        LPT = IRoycoVaultTranche(KERNEL.liquidityProviderTranche());
        POOL = KERNEL.lptAsset();
        LPT_YDM = ACCOUNTANT.getState().lptYDM;
        (address gyroECLPPoolFactory,) = BOOTSTRAP.venueFactories(block.chainid);
        VAULT = IVault(address(GyroECLPPoolFactory(gyroECLPPoolFactory).getVault()));
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // 1. RESULT COMPLETENESS
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Every component the deployment must produce is a distinct live contract with code
    function test_Deployment_AllAddressesLive() public view {
        address[11] memory a = [
            address(FACTORY),
            address(ACCESS_MANAGER),
            address(BLACKLIST),
            address(ST),
            address(JT),
            address(LPT),
            address(KERNEL),
            address(ACCOUNTANT),
            address(YDM),
            LPT_YDM,
            POOL
        ];
        for (uint256 i = 0; i < a.length; ++i) {
            assertTrue(a[i] != address(0), "zero address");
            assertGt(a[i].code.length, 0, "no code");
        }
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // 2. KERNEL <-> TRANCHE <-> ACCOUNTANT LINKAGE
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice The kernel, the three tranches, and the accountant all point at each other with the right tranche types
    function test_Linkage_KernelTranchesAccountant() public view {
        assertEq(KERNEL.seniorTranche(), address(ST), "kernel ST");
        assertEq(KERNEL.juniorTranche(), address(JT), "kernel JT");
        assertEq(KERNEL.liquidityProviderTranche(), address(LPT), "kernel LPT");
        assertEq(KERNEL.accountant(), address(ACCOUNTANT), "kernel accountant");
        assertEq(ACCOUNTANT.getState().kernel, address(KERNEL), "accountant kernel");

        assertEq(ST.kernel(), address(KERNEL), "ST kernel");
        assertEq(JT.kernel(), address(KERNEL), "JT kernel");
        assertEq(LPT.kernel(), address(KERNEL), "LPT kernel");

        assertTrue(ST.TRANCHE_TYPE() == TrancheType.SENIOR, "ST type");
        assertTrue(JT.TRANCHE_TYPE() == TrancheType.JUNIOR, "JT type");
        assertTrue(LPT.TRANCHE_TYPE() == TrancheType.LIQUIDITY_PROVIDER, "LPT type");
    }

    /// @notice ST/JT coinvest the snUSD vault as the kernel's single collateral asset and the LPT holds the Gyro E-CLP BPT
    function test_Linkage_TrancheAssets() public view {
        // The kernel carries ONE collateral asset for both coinvested tranches (ST_ASSET/JT_ASSET collapsed).
        assertEq(KERNEL.collateralAsset(), SNUSD_VAULT, "kernel collateral asset");
        assertEq(KERNEL.lptAsset(), POOL, "kernel LPT asset == pool");
        assertEq(ST.asset(), SNUSD_VAULT, "ST asset");
        assertEq(JT.asset(), SNUSD_VAULT, "JT asset");
        assertEq(LPT.asset(), POOL, "LPT asset == pool");
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // 3. BLACKLIST + WHITELIST WIRING (kernel-mediated)
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// The deployed RoycoBlacklist is the kernel's configured blacklist for the tranche balance-update hook
    function test_Linkage_BlacklistWiredToKernel() public view {
        // The tranche balance-update hook is kernel-mediated now: tranche._update -> kernel.preTrancheBalanceUpdateHook ->
        // BlacklistLogic(kernel.roycoBlacklist). The deployed RoycoBlacklist must be the kernel's configured blacklist.
        assertEq(KERNEL.getState().roycoBlacklist, address(BLACKLIST), "kernel blacklist");
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // 4. BALANCER POOL WIRING (rate provider + hook)
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice The pool is registered on the Balancer vault with exactly the senior tranche and USDC legs
    function test_Pool_RegisteredWithSeniorAndQuoteLegs() public view {
        assertTrue(VAULT.isPoolRegistered(POOL), "pool not registered");
        IERC20[] memory tokens = VAULT.getPoolTokens(POOL);
        assertEq(tokens.length, 2, "pool token count");
        bool seniorSeen;
        bool quoteSeen;
        for (uint256 i = 0; i < 2; ++i) {
            if (address(tokens[i]) == address(ST)) seniorSeen = true;
            if (address(tokens[i]) == MAINNET_USDC) quoteSeen = true;
        }
        assertTrue(seniorSeen, "senior leg missing");
        assertTrue(quoteSeen, "quote leg missing");
    }

    /// @notice The senior leg is WITH_RATE priced by the kernel and the quote leg is STANDARD, at the configured swap fee
    function test_Pool_SeniorLegRateProviderIsKernel() public view {
        (IERC20[] memory tokens, TokenInfo[] memory info,,) = VAULT.getPoolTokenInfo(POOL);
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (address(tokens[i]) == address(ST)) {
                assertTrue(info[i].tokenType == TokenType.WITH_RATE, "senior leg not WITH_RATE");
                assertEq(address(info[i].rateProvider), address(KERNEL), "rate provider != kernel");
                assertFalse(info[i].paysYieldFees, "senior leg must not pay Balancer yield fees per the config");
            } else {
                assertTrue(info[i].tokenType == TokenType.STANDARD, "quote leg not STANDARD");
                assertEq(address(info[i].rateProvider), address(0), "quote leg has rate provider");
                assertFalse(info[i].paysYieldFees, "quote leg must not pay Balancer yield fees per the config");
            }
        }
        assertEq(VAULT.getStaticSwapFeePercentage(POOL), SWAP_FEE, "swap fee");
    }

    /// The pool carries no hooks contract: the kernel is its senior-leg rate provider and nothing else is registered
    function test_Pool_IsHookless() public view {
        assertEq(VAULT.getHooksConfig(POOL).hooksContract, address(0), "pool must be hookless");
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // 5. YDM + LDM (both initialized — locks in the LDM-init fix)
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice The accountant wires two DISTINCT yield models: the JT YDM and the LPT LDM must never be the same contract
    function test_YDM_DistinctJTAndLPTModelsWired() public view {
        assertEq(ACCOUNTANT.getState().jtYDM, address(YDM), "accountant jtYDM");
        assertEq(ACCOUNTANT.getState().lptYDM, LPT_YDM, "accountant lptYDM");
        assertTrue(address(YDM) != LPT_YDM, "YDM == LDM");
    }

    /// @notice Both yield models carry an initialized curve keyed to this accountant (pins the LDM-init fix)
    function test_YDM_BothInitializedForThisAccountant() public view {
        (uint64 jtTarget,,,) = AdaptiveCurveYDM_V2(address(YDM)).accountantToCurve(address(ACCOUNTANT));
        (uint64 lptTarget,,,) = AdaptiveCurveYDM_V2(LPT_YDM).accountantToCurve(address(ACCOUNTANT));
        assertEq(jtTarget, 0.11e18, "JT YDM curve uninitialized");
        assertEq(lptTarget, 0.11e18, "LDM curve uninitialized");
    }

    /// @notice Both yield models were deployed at the config-file target utilization
    function test_YDM_TargetUtilizations() public view {
        assertEq(AdaptiveCurveYDM_V2(address(YDM)).TARGET_UTILIZATION_WAD(), TARGET_UTIL, "JT YDM target util");
        assertEq(AdaptiveCurveYDM_V2(LPT_YDM).TARGET_UTILIZATION_WAD(), TARGET_UTIL, "LDM target util");
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // 6. ACCOUNTANT CONFIG + 7. KERNEL / TRANCHE PARAMETERS
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Every accountant parameter matches the snUSD market config file, the single source of truth
    function test_Accountant_ConfigMatchesMarketConfigFile() public view {
        IRoycoDayAccountant.RoycoDayAccountantState memory s = ACCOUNTANT.getState();
        assertEq(s.minCoverageWAD, 0.1e18, "minCoverage");
        assertEq(s.coverageLiquidationUtilizationWAD, 1.0009009e18, "liquidationUtil");
        assertEq(s.stProtocolFeeWAD, 0.1e18, "stFee");
        assertEq(s.jtProtocolFeeWAD, 0, "jtFee");
        assertEq(s.jtYieldShareProtocolFeeWAD, 0.45e18, "jtYieldShareFee");
        assertEq(s.lptYieldShareProtocolFeeWAD, 0, "lptYieldShareFee");
        assertEq(s.maxJTYieldShareWAD, 1e18, "maxJTYieldShare == WAD");
        assertEq(s.maxLPTYieldShareWAD, 0, "maxLPTYieldShare == 0 (LPT off)");
        assertEq(s.minLiquidityWAD, 0, "minLiquidity == 0");
        assertEq(s.fixedTermDurationSeconds, 0, "fixedTerm");
    }

    /// @notice The kernel fee recipient, senior tranche self-liquidation bonus, and tranche names/symbols match the config
    function test_KernelAndTranches_ParamsMatchMarketConfigFile() public view {
        IRoycoDayKernel.RoycoDayKernelState memory ks = KERNEL.getState();
        // The recipient is template policy now: the fixture pins it to its prankable recipient wallet through the
        // chain-config override (`RoycoDayTestBase._setUpRoyco`), so the kernel inherits it at deployment
        assertEq(ks.protocolFeeRecipient, PROTOCOL_FEE_RECIPIENT_ADDRESS, "the kernel must carry the fixture's pinned protocol fee recipient");
        assertEq(ks.stSelfLiquidationBonusWAD, 0.005e18, "stSelfLiquidationBonus");

        // Tranche metadata is per-market config: assert against the config file itself so a rename never stales this
        DayMarketConfig memory cfg = MARKET_REGISTRY.getDayMarketConfig("snUSD");
        assertEq(ST.name(), cfg.stParams.name, "ST name");
        assertEq(ST.symbol(), cfg.stParams.symbol, "ST symbol");
        assertEq(LPT.symbol(), cfg.lptParams.symbol, "LPT symbol");
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // 8. AUTH — authorities + selector->role bindings + grants
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Every deployed contract answers to the one market AccessManager, so there is a single auth root
    function test_Auth_AllContractsShareTheAccessManagerAuthority() public view {
        address am = address(ACCESS_MANAGER);
        assertEq(AccessManagedUpgradeable(address(KERNEL)).authority(), am, "kernel authority");
        assertEq(AccessManagedUpgradeable(address(ACCOUNTANT)).authority(), am, "accountant authority");
        assertEq(AccessManagedUpgradeable(address(ST)).authority(), am, "ST authority");
        assertEq(AccessManagedUpgradeable(address(JT)).authority(), am, "JT authority");
        assertEq(AccessManagedUpgradeable(address(LPT)).authority(), am, "LPT authority");
    }

    /**
     * @notice The factory holds ONLY the narrow role set a deployment needs, and specifically NOT `ADMIN_ROLE`
     * @dev This is the containment property of the gatekeeper design. The factory's template-callable configuration
     *      primitive takes an arbitrary target, so `ADMIN_ROLE` on the factory handed every enabled template root-admin
     *      reach over the access manager's whole function map. That role now sits on the non-upgradeable gatekeeper,
     *      which admits only never-before-configured targets and applies the two grants a deployment makes. The factory
     *      keeps ONLY the two roles `executeAsFactory` forwards periphery configuration under
     */
    function test_Auth_FactoryHoldsOnlyItsNarrowRoleSetAndNotAdmin() public view {
        (bool isAdmin,) = ACCESS_MANAGER.hasRole(0, address(FACTORY)); // ADMIN_ROLE == 0
        assertFalse(isAdmin, "the factory must NOT hold ADMIN_ROLE: the gatekeeper holds it instead");

        // The periphery roles sit on the gatekeeper: it drives the entry point and the syncer itself, and the factory
        // only forwards into its fresh-only entrypoint
        (bool isEntry,) = ACCESS_MANAGER.hasRole(ADMIN_ENTRY_POINT_ROLE, address(FACTORY));
        assertFalse(isEntry, "the factory must NOT hold ADMIN_ENTRY_POINT_ROLE");
        (bool isSync,) = ACCESS_MANAGER.hasRole(SYNC_ROLE, address(FACTORY));
        assertFalse(isSync, "the factory must NOT hold SYNC_ROLE");

        // The role it lost lives on the gatekeeper the factory names, and the pairing is mutual
        address gatekeeper = FACTORY.ROYCO_FACTORY_GATEKEEPER();
        assertTrue(gatekeeper != address(0), "the factory must name a gatekeeper");
        (bool gatekeeperIsAdmin,) = ACCESS_MANAGER.hasRole(0, gatekeeper);
        assertTrue(gatekeeperIsAdmin, "the gatekeeper must hold ADMIN_ROLE");
        assertEq(IRoycoFactoryGatekeeper(gatekeeper).ROYCO_FACTORY(), address(FACTORY), "the gatekeeper must serve this factory");
        assertEq(IRoycoFactoryGatekeeper(gatekeeper).ROYCO_ACCESS_MANAGER(), address(ACCESS_MANAGER), "the gatekeeper must govern this access manager");
    }

    /**
     * @notice The market's own contracts are recorded as configured, so no later deployment can re-point them
     * @dev The invariant the gatekeeper enforces, observed on a real deployment: every contract this market stood up
     *      is now permanently off limits to any future template
     */
    function test_Auth_EveryMarketContractIsRecordedAsConfigured() public view {
        IRoycoAccessManager am = IRoycoAccessManager(address(ACCESS_MANAGER));
        assertTrue(am.wasEverConfigured(address(KERNEL)), "kernel must be recorded as configured");
        assertTrue(am.wasEverConfigured(address(ACCOUNTANT)), "accountant must be recorded as configured");
        assertTrue(am.wasEverConfigured(address(ST)), "senior tranche must be recorded as configured");
        assertTrue(am.wasEverConfigured(address(JT)), "junior tranche must be recorded as configured");
        assertTrue(am.wasEverConfigured(address(LPT)), "liquidity provider tranche must be recorded as configured");
        // The shared Balancer governance targets too, which is what makes a second market skip them
        assertTrue(am.wasEverConfigured(address(VAULT)), "the Balancer vault must be recorded as configured");
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // PERIPHERY SINGLETONS (entry point + market syncer)
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice The pre-deployed entry point was configured for all three tranches through the factory, with the
    ///         config-file delays, and shares the market's authority + factory binding
    function test_Periphery_EntryPointConfiguredForAllTranches() public view {
        assertEq(ENTRY_POINT.ROYCO_FACTORY(), address(FACTORY), "entry point factory binding");
        assertEq(AccessManagedUpgradeable(address(ENTRY_POINT)).authority(), address(ACCESS_MANAGER), "entry point authority");

        DayMarketConfig memory cfg = MARKET_REGISTRY.getDayMarketConfig("snUSD");
        _assertEntryPointConfig(address(ST), cfg.stEntryPointConfig, "ST");
        _assertEntryPointConfig(address(JT), cfg.jtEntryPointConfig, "JT");
        _assertEntryPointConfig(address(LPT), cfg.lptEntryPointConfig, "LPT");
    }

    function _assertEntryPointConfig(address _tranche, IRoycoDayEntryPoint.TrancheConfig memory _expected, string memory _ctx) internal view {
        IRoycoDayEntryPoint.EnrichedTrancheConfig memory stored = ENTRY_POINT.getTrancheConfig(_tranche);
        assertEq(stored.kernel, address(KERNEL), string.concat(_ctx, ": entry point config kernel"));
        assertEq(stored.baseConfig.enabled, _expected.enabled, string.concat(_ctx, ": entry point config enabled"));
        assertEq(stored.baseConfig.depositDelaySeconds, _expected.depositDelaySeconds, string.concat(_ctx, ": deposit delay"));
        assertEq(stored.baseConfig.redemptionDelaySeconds, _expected.redemptionDelaySeconds, string.concat(_ctx, ": redemption delay"));
        assertEq(stored.baseConfig.gateByOracleUpdate, _expected.gateByOracleUpdate, string.concat(_ctx, ": collateral asset oracle enabled"));
    }

    /// @notice The pre-deployed syncer registered the market's kernel, answers to the market authority, and has
    ///         its registration surface bound to SYNC_ROLE
    function test_Periphery_SyncerRegisteredKernel() public view {
        assertTrue(MARKET_SYNCER.isMarketKernelRegistered(address(KERNEL)), "kernel registered on the syncer");
        assertEq(AccessManagedUpgradeable(address(MARKET_SYNCER)).authority(), address(ACCESS_MANAGER), "syncer authority");
        assertEq(
            ACCESS_MANAGER.getTargetFunctionRole(address(MARKET_SYNCER), RoycoMarketSyncer.addMarketKernels.selector),
            SYNC_ROLE,
            "addMarketKernels bound to SYNC_ROLE"
        );
    }

    /// @notice The deploy script wires the entry point's full access model (previously the standalone entry point
    ///         deployment's Safe batch): public LP surface, role-gated config/fee/pause/upgrade selectors, and the
    ///         LP role grants the entry point needs to transact with the tranches
    function test_Periphery_EntryPointAccessModelWired() public view {
        address ep = address(ENTRY_POINT);
        // The user-facing request/execute/cancel surface is public (compliance is enforced by the tranches).
        assertEq(ACCESS_MANAGER.getTargetFunctionRole(ep, IRoycoDayEntryPoint.requestDeposit.selector), PUBLIC_ROLE, "requestDeposit public");
        assertEq(ACCESS_MANAGER.getTargetFunctionRole(ep, IRoycoDayEntryPoint.requestRedemption.selector), PUBLIC_ROLE, "requestRedemption public");
        assertEq(
            ACCESS_MANAGER.getTargetFunctionRole(ep, IRoycoDayEntryPoint.pokeCollateralAssetOracle.selector), PUBLIC_ROLE, "pokeCollateralAssetOracle public"
        );
        // The admin surface is bound to its dedicated roles.
        assertEq(
            ACCESS_MANAGER.getTargetFunctionRole(ep, IRoycoDayEntryPoint.modifyTrancheConfigs.selector), ADMIN_ENTRY_POINT_ROLE, "modifyTrancheConfigs role"
        );
        assertEq(
            ACCESS_MANAGER.getTargetFunctionRole(ep, IRoycoDayEntryPoint.collectProtocolFees.selector),
            ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE,
            "collectProtocolFees role"
        );
        assertEq(ACCESS_MANAGER.getTargetFunctionRole(ep, UUPSUpgradeable.upgradeToAndCall.selector), ADMIN_UPGRADER_ROLE, "upgrade role");
        // The entry point holds the three LP roles so it can deposit/redeem and receive escrowed shares.
        (bool st,) = ACCESS_MANAGER.hasRole(ST_LP_ROLE, ep);
        (bool jt,) = ACCESS_MANAGER.hasRole(JT_LP_ROLE, ep);
        (bool lt,) = ACCESS_MANAGER.hasRole(LPT_LP_ROLE, ep);
        assertTrue(st && jt && lt, "entry point holds the tranche LP roles");
        // The entry point holds SYNC_ROLE so it can sync the kernel when pricing its request-time references.
        (bool epSync,) = ACCESS_MANAGER.hasRole(SYNC_ROLE, ep);
        assertTrue(epSync, "entry point holds SYNC_ROLE");
        // The syncer holds SYNC_ROLE so its batch syncs can drive each kernel's SYNC_ROLE-gated accounting sync.
        (bool sync,) = ACCESS_MANAGER.hasRole(SYNC_ROLE, address(MARKET_SYNCER));
        assertTrue(sync, "syncer holds SYNC_ROLE");
    }

    /// @notice Each tranche entrypoint is bound to its intended role: LP-gated deposits and redeems on every
    ///         tranche, and the pause/unpause/upgrade/burn admin surface
    function test_Auth_TrancheSelectorRoleBindings() public view {
        _assertRole(address(ST), IRoycoVaultTranche.deposit.selector, ST_LP_ROLE);
        _assertRole(address(ST), IRoycoVaultTranche.redeem.selector, ST_LP_ROLE);
        _assertRole(address(JT), IRoycoVaultTranche.deposit.selector, JT_LP_ROLE);
        _assertRole(address(JT), IRoycoVaultTranche.redeem.selector, JT_LP_ROLE);
        _assertRole(address(LPT), IRoycoVaultTranche.deposit.selector, LPT_LP_ROLE);
        _assertRole(address(LPT), RoycoLiquidityProviderTranche.depositMultiAsset.selector, LPT_LP_ROLE);
        _assertRole(address(LPT), IRoycoVaultTranche.redeem.selector, LPT_LP_ROLE);
        _assertRole(address(LPT), RoycoLiquidityProviderTranche.redeemMultiAsset.selector, LPT_LP_ROLE);

        for (uint256 i = 0; i < 3; ++i) {
            address t = i == 0 ? address(ST) : i == 1 ? address(JT) : address(LPT);
            _assertRole(t, IRoycoAuth.pause.selector, ADMIN_PAUSER_ROLE);
            _assertRole(t, IRoycoAuth.unpause.selector, ADMIN_UNPAUSER_ROLE);
            _assertRole(t, ERC20BurnableUpgradeable.burn.selector, BURNER_ROLE);
            _assertRole(t, ERC20BurnableUpgradeable.burnFrom.selector, BURNER_ROLE);
            // `kernelMint` carries NO binding: it is gated by the tranche's own onlyKernel check (per-market, not AM-global).
            _assertRole(t, IRoycoVaultTranche.kernelMint.selector, 0);
        }
    }

    /// @notice The kernel setters, sync, market-ops, pricing-admin, and hook surfaces carry their intended role bindings
    function test_Auth_KernelAndHookSelectorRoleBindings() public view {
        _assertRole(address(KERNEL), IRoycoDayKernel.setProtocolFeeRecipient.selector, ADMIN_KERNEL_ROLE);
        _assertRole(address(KERNEL), IRoycoDayKernel.setSeniorTrancheSelfLiquidationBonus.selector, ADMIN_KERNEL_ROLE);
        _assertRole(address(KERNEL), IRoycoDayKernel.syncTrancheAccounting.selector, SYNC_ROLE);
        _assertRole(address(KERNEL), IRoycoDayKernel.syncTrancheAccountingFor.selector, SYNC_ROLE);
        _assertRole(address(KERNEL), IRoycoAuth.pause.selector, ADMIN_PAUSER_ROLE);

        // Operational maintenance surface -> ADMIN_MARKET_OPS_ROLE.
        _assertRole(address(KERNEL), IRoycoDayKernel.reinvestLiquidityPremium.selector, ADMIN_MARKET_REINVEST_LIQUIDITY_PREMIUM_ROLE);
        _assertRole(address(KERNEL), IRoycoDayKernel.setRoycoBlacklist.selector, ADMIN_MARKET_OPS_ROLE);
        _assertRole(address(ACCOUNTANT), IRoycoDayAccountant.setDustTolerance.selector, ADMIN_MARKET_OPS_ROLE);

        // Pricing admin surface -> ADMIN_ORACLE_ROLE (previously unbound => silently defaulted to ADMIN_ROLE).
        _assertRole(address(KERNEL), BalancerV3LiquidityVenue.setBPTOracle.selector, ADMIN_ORACLE_ROLE);
        _assertRole(address(KERNEL), BalancerV3LiquidityVenue.setMaxReinvestmentSlippage.selector, ADMIN_ORACLE_ROLE);
        _assertRole(address(KERNEL), IRoycoDayKernel.setCollateralAssetOracle.selector, ADMIN_ORACLE_ROLE);
        _assertRole(address(KERNEL), IRoycoDayKernel.setSequencerUptimeFeed.selector, ADMIN_ORACLE_ROLE);
    }

    /// @notice Every operationally bound role has a live grantee
    /// @dev A market deployment mints no roles at all any more: the gatekeeper's grant primitive is gone, so every
    ///      grant a live market needs comes from governance or the chain-level scaffolding, never from the template
    function test_Auth_EveryBoundRoleHasALiveGrantee() public view {
        // The kernel burns through the tranches' kernelBurn, an onlyKernel immutable-address check, so the deployment
        // grants BURNER_ROLE to nobody. The tranches' burn/burnFrom surface stays bound to BURNER_ROLE as a
        // dormant-by-design admin surface, grantable later by governance.
        (bool burner,) = ACCESS_MANAGER.hasRole(BURNER_ROLE, address(KERNEL));
        assertFalse(burner, "kernel must not hold BURNER_ROLE, it burns via onlyKernel kernelBurn");

        // Every bound role has a live grantee at deploy end (no memberless-role liveness cliffs), except the
        // dormant-by-design BURNER_ROLE above.
        (bool unpauser,) = ACCESS_MANAGER.hasRole(ADMIN_UNPAUSER_ROLE, UNPAUSER_ADDRESS);
        assertTrue(unpauser, "unpauser granted");
        (bool lptLp,) = ACCESS_MANAGER.hasRole(LPT_LP_ROLE, PROTOCOL_FEE_RECIPIENT_ADDRESS);
        assertTrue(lptLp, "LPT LP granted");
        (bool poolMgr,) = ACCESS_MANAGER.hasRole(ADMIN_BALANCER_POOL_MANAGER_ROLE, KERNEL_ADMIN_ADDRESS);
        assertTrue(poolMgr, "balancer pool manager granted");
        (bool marketOps,) = ACCESS_MANAGER.hasRole(ADMIN_MARKET_OPS_ROLE, KERNEL_ADMIN_ADDRESS);
        assertTrue(marketOps, "market ops granted");
    }

    /// The pipeline renounces the hot deployer key's ENTIRE admin surface: market deployment is PUBLIC, so the
    /// deployer key retains no standing at all once the bootstrap is finalized
    function test_Auth_DeployerPrivilegesDropped() public view {
        (bool isAdmin,) = ACCESS_MANAGER.hasRole(0, DEPLOYER_ADDRESS); // ADMIN_ROLE == 0
        assertFalse(isAdmin, "deployer still ADMIN_ROLE");
        (bool isFactoryAdmin,) = ACCESS_MANAGER.hasRole(ADMIN_FACTORY_ROLE, DEPLOYER_ADDRESS);
        assertFalse(isFactoryAdmin, "deployer still ADMIN_FACTORY_ROLE");
    }

    /// mint is an immutable-address check on THIS market's kernel, not an AccessManager role (cross-market bleed defense)
    function test_RevertIf_NonKernelMintsTrancheShares() public {
        // Cross-market bleed defense: kernelMint is an immutable-address check on THIS market's kernel, not an AM role.
        vm.prank(address(0xBAD));
        vm.expectRevert(IRoycoVaultTranche.ONLY_KERNEL.selector);
        ST.kernelMint(address(0xBAD), 1);
    }

    /// The template deployed the BPT oracle through Balancer's E-CLP oracle factory, priced on this market's pool with 1.0 rate-provider feeds
    function test_BPTOracle_DeployedByTemplateAndWired() public view {
        // The template deployed the BPT oracle through Balancer's E-CLP LP oracle factory and injected it into the kernel.
        address bptOracle = BalancerV3LiquidityVenue(address(KERNEL)).getBalancerV3LiquidityVenueState().bptOracle;
        assertTrue(bptOracle != address(0), "bptOracle unset");
        assertGt(bptOracle.code.length, 0, "bptOracle has no code");
        (, address eclpOracleFactory) = BOOTSTRAP.venueFactories(block.chainid);
        assertTrue(ILPOracleFactoryBase(eclpOracleFactory).isOracleFromFactory(ILPOracleBase(bptOracle)), "not from oracle factory");

        // The oracle prices THIS market's pool (the same identity the kernel's setBPTOracle guard enforces).
        assertEq(address(LPOracleBase(bptOracle).pool()), POOL, "oracle.pool() != market pool");

        // Both legs are priced by their rate providers (kernel NAV rate on the senior leg, the configured quote rate
        // provider — or an implicit rate of 1 when STANDARD — on the quote leg), so both use the constant-1.0 feed.
        IERC20[] memory tokens = VAULT.getPoolTokens(POOL);
        BalancerAggregatorV3Interface[] memory feeds = LPOracleBase(bptOracle).getFeeds();
        assertEq(feeds.length, tokens.length, "feed count");
        for (uint256 i = 0; i < tokens.length; ++i) {
            (, int256 answer,,,) = feeds[i].latestRoundData();
            assertEq(answer, 1e18, "leg feed must answer 1.0");
            assertEq(feeds[i].decimals(), 18, "leg feed decimals");
        }
    }

    /// Pinned real-stack behavior: the template mandates a genesis seed and locks DEAD_SHARES at 0xdEaD, so a live
    /// market's pool is never unseeded and the whole TVL path answers. The old unseeded computeTVL revert pin is
    /// unreachable through the factory. The pre-seed protection ("an uninitialized venue is never queried", the
    /// kernel's empty-ledger short-circuit) is pinned by the unit suites (Test_VenueBPTOracle)
    function test_BPTOracle_LiveOnGenesisSeededPool() public view {
        address bptOracle = BalancerV3LiquidityVenue(address(KERNEL)).getBalancerV3LiquidityVenueState().bptOracle;

        // Genesis-seeded: BPT minted, and the template's DEAD_SHARES (1e12) LPT lock parked at the dead address
        assertGt(IERC20(POOL).totalSupply(), 0, "pool must be genesis-seeded at deploy end");
        assertEq(IERC20(address(LPT)).balanceOf(0x000000000000000000000000000000000000dEaD), 1e12, "DEAD_SHARES must be locked at 0xdEaD");

        // The real oracle answers a positive TVL on the seeded pool
        assertGt(LPOracleBase(bptOracle).computeTVL(), 0, "computeTVL must answer a positive TVL on the seeded pool");

        // Both kernel LPT conversion directions price against the live oracle without reverting
        assertGt(
            NAV_UNIT.unwrap(BalancerV3LiquidityVenue(address(KERNEL)).convertLPTAssetsToValue(TRANCHE_UNIT.wrap(1e18))),
            0,
            "the BPT->NAV direction must price on the seeded pool"
        );
        assertGt(
            TRANCHE_UNIT.unwrap(BalancerV3LiquidityVenue(address(KERNEL)).convertValueToLPTAssets(NAV_UNIT.wrap(1e18))),
            0,
            "the NAV->BPT direction must price on the seeded pool"
        );
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // 9. AUTH — negative (unauthorized callers revert)
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice A random caller cannot pause the kernel: the pause surface is ADMIN_PAUSER_ROLE only
    function test_RevertIf_UnauthorizedCallerPausesKernel() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(0xBAD)));
        IRoycoAuth(address(KERNEL)).pause();
    }

    /// @notice A random caller cannot redirect protocol fees to itself: the setter is ADMIN_KERNEL_ROLE only
    function test_RevertIf_UnauthorizedCallerSetsProtocolFeeRecipient() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(0xBAD)));
        KERNEL.setProtocolFeeRecipient(address(0xBAD));
    }

    /// @notice snUSD tranche deposits are gated by ST_LP_ROLE: a random address reverts on auth before any value check
    function test_RevertIf_NonLPDepositsIntoSeniorTranche() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(0xBAD)));
        ST.deposit(TRANCHE_UNIT.wrap(0), address(0xBAD));
    }

    /**
     * @notice Post-deployment role escalation is dead: the renounced deployer key cannot grant itself
     *         ADMIN_ROLE back on the AccessManager, so a leaked hot key after deploy day yields nothing
     * @dev grantRole is guarded by the granted role's admin (ADMIN_ROLE = 0), which the deployer renounced,
     *      so the AccessManager rejects the call naming the deployer and the admin role it lacks
     */
    function test_RevertIf_RenouncedDeployerGrantsItselfAdmin() public {
        vm.prank(DEPLOYER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, DEPLOYER_ADDRESS, uint64(0)));
        ACCESS_MANAGER.grantRole(0, DEPLOYER_ADDRESS, 0);
    }

    function _assertRole(address _target, bytes4 _selector, uint64 _expectedRole) internal view {
        assertEq(ACCESS_MANAGER.getTargetFunctionRole(_target, _selector), _expectedRole, "role binding");
    }
}

/**
 * @title Test_DayMarketDeployment_GenesisSeedBoundary
 * @notice The template's genesis-seed floor on the real stack: `_seedPool` deposits the genesis seed through the
 *         LPT's multi-asset deposit, requires the minted shares to cover DEAD_SHARES (1e12), locks DEAD_SHARES at
 *         0xdEaD, and transfers the remainder to the funder. This suite pins the revert path a dust seed takes and
 *         the share split a barely-sufficient seed produces.
 * @dev Share-count derivation for a quote-only seed of q USDC wei on the real Balancer stack: the Vault's
 *      `initialize` computes the E-CLP invariant of the scaled seed (q x 1e12 at the constant-1.0 feeds), burns
 *      POOL_MINIMUM_TOTAL_SUPPLY (1e6) dead BPT to address(0), and mints `invariant - 1e6` BPT to the kernel. The
 *      LPT genesis mint then prices that BPT at the oracle mark (floor(1e18 x TVL / bptSupply) per whole BPT, with
 *      TVL ~= q x 1e12) through the virtual-shares bootstrap (1 share-wei per NAV-wei on an empty tranche), so
 *      lptShares ~= q x 1e12 x (invariant - 1e6) / invariant, STRICTLY below q x 1e12 because of the vault's dead
 *      BPT slice and the floor roundings. At this market's E-CLP params the one-wei seed's invariant measures
 *      ~2.66e8, so the dead slice shaves ~0.376% and the mint lands at ~0.99624e12 shares, just under the
 *      dead-share lock, tripping INSUFFICIENT_GENESIS_SHARES. minted(q) steps by ~0.99624e12 per quote wei and
 *      never lands on exactly 1e12, so the exact-equality boundary (funder left with zero shares) is not
 *      constructible on the fork and the nearest constructible property is pinned instead: funder balance ==
 *      minted - DEAD_SHARES for a small seed.
 * @dev Guard ordering pinned by the dust test: neither the entry floor (MUST_MINT_NON_ZERO_SHARES needs the
 *      deposit to price to ZERO shares, but a one-wei seed prices to ~0.996e12) nor Balancer's
 *      minimum-total-supply check (needs invariant < 1e6, but the one-wei seed's invariant is ~2.66e8) fires
 *      first, so the template's own INSUFFICIENT_GENESIS_SHARES is the operative dust-seed boundary.
 */
contract Test_DayMarketDeployment_GenesisSeedBoundary is RoycoDayTestBase {
    address internal constant FACTORY_ADMIN = 0x7c405bbD131e42af506d14e752f2e59B19D49997; // ROOT_MULTISIG
    address internal constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant DEAD_SHARES = 1e12;

    function _forkConfiguration() internal view override returns (uint256 forkBlock, string memory forkRpcUrl) {
        // No skip: the suite FAILS (env not found) when MAINNET_RPC_URL is unset, instead of silently passing.
        forkRpcUrl = vm.envString("MAINNET_RPC_URL");
        forkBlock = vm.envOr("FORK_BLOCK", uint256(25_400_000));
    }

    /// @dev Fork + wallets + script only: each test runs its own deployment with a modified genesis seed
    function setUp() public {
        _setUpRoyco();
    }

    /// @dev The snUSD market config repointed at the funded deployer with the specified quote-only genesis seed
    function _seededConfig(uint256 _quoteAmount) internal returns (DayMarketConfig memory cfg) {
        cfg = MARKET_REGISTRY.getDayMarketConfig("snUSD");
        cfg.poolInitialization.quoteAmount = _quoteAmount;
        deal(cfg.pool.quoteAsset, DEPLOYER.addr, _quoteAmount);
    }

    /**
     * @notice A one-USDC-wei genesis seed mints just under DEAD_SHARES LPT shares, so the whole deployment must
     *         revert with the template's INSUFFICIENT_GENESIS_SHARES carrying the sub-1e12 mint
     * @dev The carried share count also pins the guard ordering: a nonzero count proves the deposit's entry floor
     *      (MUST_MINT_NON_ZERO_SHARES) did not fire, and reaching the template's check at all proves Balancer's
     *      minimum-total-supply check passed, so the template's floor is the operative dust boundary
     */
    function test_RevertIf_DustGenesisSeedMintsFewerThanDeadShares() public {
        DayMarketConfig memory cfg = _seededConfig(1);
        DeployMarketComponent market = _marketComponent();
        try market.deployMarket(cfg, MARKET_REGISTRY.getMarketId("snUSD", CHAIN.factory), DEPLOYER.privateKey) {
            fail("a dust genesis seed minting fewer than DEAD_SHARES must revert the deployment");
        } catch (bytes memory err) {
            bytes4 sel;
            uint256 mintedShares;
            assembly ("memory-safe") {
                sel := mload(add(err, 0x20))
                mintedShares := mload(add(err, 0x24))
            }
            assertEq(
                sel,
                RoycoDayBalancerV3MarketDeploymentTemplate.INSUFFICIENT_GENESIS_SHARES.selector,
                "the dust seed must trip the template's genesis-share floor, not an earlier guard"
            );
            // A near-miss band, not merely nonzero: the mint sits ~0.376% below the lock (the vault's 1e6 dead
            // BPT out of the ~2.66e8 invariant), proving the entry floor was nowhere near firing
            assertGt(mintedShares, 0.99e12, "the dust seed must price to a near-miss mint, so the entry floor was not the operative guard");
            assertLt(mintedShares, DEAD_SHARES, "the dust seed's mint must fall below the dead-share lock");
        }
    }

    /**
     * @notice A two-USDC-wei genesis seed clears the floor: the deployment succeeds, exactly DEAD_SHARES sit at
     *         0xdEaD, and the funder holds exactly the minted remainder (minted - DEAD_SHARES, itself sub-1e12)
     * @dev The exact-equality boundary (a seed minting exactly DEAD_SHARES, funder left with zero) is not
     *      constructible on the fork: minted(q) ~= q x 1e12 net of the vault's 1e6 dead BPT slice never lands on
     *      1e12 for an integer q, so this pins the nearest constructible property instead (see the contract natspec)
     */
    function test_GenesisSeed_SmallSeedLocksDeadSharesAndFunderHoldsRemainder() public {
        DayMarketConfig memory cfg = _seededConfig(2);
        DeploymentResult memory result = _deployMarketThroughPipeline(cfg);

        IERC20 lpt = IERC20(result.kernel.liquidityProviderTranche());
        uint256 minted = lpt.totalSupply();

        // The genesis mint is the tranche's only mint, split exactly between the dead lock and the funder
        assertEq(lpt.balanceOf(DEAD_ADDRESS), DEAD_SHARES, "DEAD_SHARES must be locked at 0xdEaD");
        assertEq(lpt.balanceOf(DEPLOYER.addr), minted - DEAD_SHARES, "the funder must hold exactly the minted remainder");
        assertGe(minted, DEAD_SHARES, "a seed that deployed must have covered the dead-share lock");
        // The small seed brackets the boundary: the funder's remainder stays below one DEAD_SHARES unit, so the
        // deployment lives within one quote wei of the revert threshold the dust test pins from below
        assertLt(minted, 2 * DEAD_SHARES, "a two-wei seed must mint under twice the dead-share lock");
    }
}
