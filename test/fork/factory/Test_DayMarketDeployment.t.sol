// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ILPOracleBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleBase.sol";
import { ILPOracleFactoryBase } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/oracles/ILPOracleFactoryBase.sol";
import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { HooksConfig, TokenInfo, TokenType } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
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
import { SafeCast } from "../../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { DeployScript } from "../../../script/Deploy.s.sol";
import {
    ADMIN_BALANCER_POOL_MANAGER_ROLE,
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_FACTORY_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_MARKET_OPS_ROLE,
    ADMIN_ORACLE_QUOTER_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    BURNER_ROLE,
    DEPLOYER_ROLE,
    JT_LP_ROLE,
    LT_LP_ROLE,
    PUBLIC_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE
} from "../../../src/factory/RolesConfiguration.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { RoycoDayKernel } from "../../../src/kernels/base/RoycoDayKernel.sol";
import { BalancerV3_LT_BPTOracle_Quoter } from "../../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/BalancerV3_LT_BPTOracle_Quoter.sol";
import { TrancheType } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../../src/libraries/Units.sol";
import { RoycoLiquidityTranche } from "../../../src/tranches/RoycoLiquidityTranche.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { RoycoDayTestBase } from "../../utils/RoycoDayTestBase.sol";

/**
 * @title Test_DayMarketDeployment
 * @notice End-to-end deployment test: runs the real `DeployScript` against a mainnet fork to deploy a full Day snUSD
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
    IRoycoVaultTranche internal LT;
    address internal POOL; // the Gyro E-CLP BPT (== kernel.LT_ASSET())
    address internal LT_YDM; // the LDM
    IVault internal VAULT;

    function _forkConfiguration() internal view override returns (uint256 forkBlock, string memory forkRpcUrl) {
        // No skip: the suite FAILS (env not found) when MAINNET_RPC_URL is unset, instead of silently passing.
        forkRpcUrl = vm.envString("MAINNET_RPC_URL");
        // A block where the Gyro E-CLP factory (deployed ~24.2M), the Balancer V3 vault, the E-CLP LP oracle factory,
        // the snUSD vault, USDC, and the RedStone nUSD feed all have code. Overridable via the FORK_BLOCK env var.
        forkBlock = vm.envOr("FORK_BLOCK", uint256(25_400_000));
    }

    function setUp() public {
        // Fork mainnet + create wallets + `new DeployScript()`.
        _setUpRoyco();

        // Deploy the Day-shaped SNUSD market end to end through the real script, sourcing the market config from the config
        // file (single source of truth) — not an inline test fixture.
        DeployScript.DeploymentResult memory result = DEPLOY_SCRIPT.deploy(
            DEPLOY_SCRIPT.getMarketConfig("snUSD"),
            FACTORY_ADMIN, // factory admin (holds AccessManager ADMIN_ROLE)
            PROTOCOL_FEE_RECIPIENT_ADDRESS,
            0,
            _generateRoleAssignments(),
            DEPLOYER.privateKey
        );
        _setDeployedMarket(result);

        // Capture the Day-only addresses the script's DeploymentResult omits, by reading the deployed contracts.
        LT = IRoycoVaultTranche(KERNEL.LIQUIDITY_TRANCHE());
        POOL = KERNEL.LT_ASSET();
        LT_YDM = ACCOUNTANT.getState().ltYDM;
        VAULT = IVault(address(GyroECLPPoolFactory(DEPLOY_SCRIPT.getChainConfig(block.chainid).gyroECLPPoolFactory).getVault()));
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
            address(LT),
            address(KERNEL),
            address(ACCOUNTANT),
            address(YDM),
            LT_YDM,
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
        assertEq(KERNEL.SENIOR_TRANCHE(), address(ST), "kernel ST");
        assertEq(KERNEL.JUNIOR_TRANCHE(), address(JT), "kernel JT");
        assertEq(KERNEL.LIQUIDITY_TRANCHE(), address(LT), "kernel LT");
        assertEq(KERNEL.ACCOUNTANT(), address(ACCOUNTANT), "kernel accountant");
        assertEq(address(IRoycoDayAccountant(ACCOUNTANT).KERNEL()), address(KERNEL), "accountant kernel");

        assertEq(ST.KERNEL(), address(KERNEL), "ST kernel");
        assertEq(JT.KERNEL(), address(KERNEL), "JT kernel");
        assertEq(LT.KERNEL(), address(KERNEL), "LT kernel");

        assertTrue(ST.TRANCHE_TYPE() == TrancheType.SENIOR, "ST type");
        assertTrue(JT.TRANCHE_TYPE() == TrancheType.JUNIOR, "JT type");
        assertTrue(LT.TRANCHE_TYPE() == TrancheType.LIQUIDITY, "LT type");
    }

    /// @notice ST/JT hold the snUSD vault as their asset and the LT holds the Gyro E-CLP BPT
    function test_Linkage_TrancheAssets() public view {
        assertEq(KERNEL.ST_ASSET(), SNUSD_VAULT, "kernel ST asset");
        assertEq(KERNEL.JT_ASSET(), SNUSD_VAULT, "kernel JT asset");
        assertEq(KERNEL.LT_ASSET(), POOL, "kernel LT asset == pool");
        assertEq(ST.asset(), SNUSD_VAULT, "ST asset");
        assertEq(JT.asset(), SNUSD_VAULT, "JT asset");
        assertEq(LT.asset(), POOL, "LT asset == pool");
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
            } else {
                assertTrue(info[i].tokenType == TokenType.STANDARD, "quote leg not STANDARD");
                assertEq(address(info[i].rateProvider), address(0), "quote leg has rate provider");
            }
        }
        assertEq(VAULT.getStaticSwapFeePercentage(POOL), SWAP_FEE, "swap fee");
    }

    /// The pool ships with no hook: an external pool operation needs no pre-operation sync, so the pool registers the
    /// zero hooks address and no before-operation callback flags
    function test_Pool_NoHook() public view {
        HooksConfig memory hc = VAULT.getHooksConfig(POOL);
        assertEq(hc.hooksContract, address(0), "pool must ship with no hook");
        assertFalse(hc.shouldCallBeforeSwap, "beforeSwap flag must be unset");
        assertFalse(hc.shouldCallBeforeAddLiquidity, "beforeAdd flag must be unset");
        assertFalse(hc.shouldCallBeforeRemoveLiquidity, "beforeRemove flag must be unset");
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // 5. YDM + LDM (both initialized — locks in the LDM-init fix)
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice The accountant wires two DISTINCT yield models: the JT YDM and the LT LDM must never be the same contract
    function test_YDM_DistinctJTAndLTModelsWired() public view {
        assertEq(ACCOUNTANT.getState().jtYDM, address(YDM), "accountant jtYDM");
        assertEq(ACCOUNTANT.getState().ltYDM, LT_YDM, "accountant ltYDM");
        assertTrue(address(YDM) != LT_YDM, "YDM == LDM");
    }

    /// @notice Both yield models carry an initialized curve keyed to this accountant (pins the LDM-init fix)
    function test_YDM_BothInitializedForThisAccountant() public view {
        (uint64 jtTarget,,,) = AdaptiveCurveYDM_V2(address(YDM)).accountantToCurve(address(ACCOUNTANT));
        (uint64 ltTarget,,,) = AdaptiveCurveYDM_V2(LT_YDM).accountantToCurve(address(ACCOUNTANT));
        assertEq(jtTarget, 0.11e18, "JT YDM curve uninitialized");
        assertEq(ltTarget, 0.11e18, "LDM curve uninitialized");
    }

    /// @notice Both yield models were deployed at the config-file target utilization
    function test_YDM_TargetUtilizations() public view {
        assertEq(AdaptiveCurveYDM_V2(address(YDM)).TARGET_UTILIZATION_WAD(), TARGET_UTIL, "JT YDM target util");
        assertEq(AdaptiveCurveYDM_V2(LT_YDM).TARGET_UTILIZATION_WAD(), TARGET_UTIL, "LDM target util");
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
        assertEq(s.ltYieldShareProtocolFeeWAD, 0, "ltYieldShareFee");
        assertEq(s.maxJTYieldShareWAD, 1e18, "maxJTYieldShare == WAD");
        assertEq(s.maxLTYieldShareWAD, 0, "maxLTYieldShare == 0 (LT off)");
        assertEq(s.minLiquidityWAD, 0, "minLiquidity == 0");
        assertEq(s.fixedTermDurationSeconds, 0, "fixedTerm");
        assertTrue(ACCOUNTANT.JT_COINVESTED(), "jtCoinvested");
    }

    /// @notice The kernel fee recipient, senior tranche self-liquidation bonus, tranche names/symbols, and whitelist flag match the config
    function test_KernelAndTranches_ParamsMatchMarketConfigFile() public view {
        IRoycoDayKernel.RoycoDayKernelState memory ks = KERNEL.getState();
        assertEq(ks.protocolFeeRecipient, PROTOCOL_FEE_RECIPIENT_ADDRESS, "protocolFeeRecipient");
        assertEq(ks.stSelfLiquidationBonusWAD, 0.005e18, "stSelfLiquidationBonus");

        assertEq(ST.name(), "Royco Senior Tranche snUSD", "ST name");
        assertEq(ST.symbol(), "ROY-ST-snUSD", "ST symbol");
        assertEq(LT.symbol(), "ROY-LT-snUSD", "LT symbol");
        // The transfer-whitelist gate is a kernel immutable now (enforced in kernel.preTrancheBalanceUpdateHook), not per-tranche.
        assertFalse(RoycoDayKernel(address(KERNEL)).ENFORCE_TRANCHE_WHITELIST_ON_TRANSFER(), "kernel enforce flag");
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
        assertEq(AccessManagedUpgradeable(address(LT)).authority(), am, "LT authority");
    }

    /// @notice The factory retains ADMIN_ROLE and ADMIN_ENTRY_POINT_ROLE on the AccessManager after deployment
    function test_Auth_FactoryHoldsAdminAndEntryPointRoles() public view {
        (bool isAdmin,) = ACCESS_MANAGER.hasRole(0, address(FACTORY)); // ADMIN_ROLE == 0
        assertTrue(isAdmin, "factory not ADMIN_ROLE");
        (bool isEntry,) = ACCESS_MANAGER.hasRole(ADMIN_ENTRY_POINT_ROLE, address(FACTORY));
        assertTrue(isEntry, "factory not ADMIN_ENTRY_POINT_ROLE");
    }

    /// @notice Each tranche entrypoint is bound to its intended role: LP-gated deposits/redeems, open LT deposits,
    ///         and the pause/unpause/upgrade/burn admin surface
    function test_Auth_TrancheSelectorRoleBindings() public view {
        _assertRole(address(ST), IRoycoVaultTranche.deposit.selector, ST_LP_ROLE);
        _assertRole(address(ST), IRoycoVaultTranche.redeem.selector, ST_LP_ROLE);
        _assertRole(address(JT), IRoycoVaultTranche.deposit.selector, JT_LP_ROLE);
        _assertRole(address(JT), IRoycoVaultTranche.redeem.selector, JT_LP_ROLE);
        // LT deposits are open (they only deepen senior liquidity); LT redemptions stay role-gated.
        _assertRole(address(LT), IRoycoVaultTranche.deposit.selector, PUBLIC_ROLE);
        _assertRole(address(LT), RoycoLiquidityTranche.depositMultiAsset.selector, PUBLIC_ROLE);
        _assertRole(address(LT), IRoycoVaultTranche.redeem.selector, LT_LP_ROLE);
        _assertRole(address(LT), RoycoLiquidityTranche.redeemMultiAsset.selector, LT_LP_ROLE);

        for (uint256 i = 0; i < 3; ++i) {
            address t = i == 0 ? address(ST) : i == 1 ? address(JT) : address(LT);
            _assertRole(t, IRoycoAuth.pause.selector, ADMIN_PAUSER_ROLE);
            _assertRole(t, IRoycoAuth.unpause.selector, ADMIN_UNPAUSER_ROLE);
            _assertRole(t, UUPSUpgradeable.upgradeToAndCall.selector, ADMIN_UPGRADER_ROLE);
            _assertRole(t, ERC20BurnableUpgradeable.burn.selector, BURNER_ROLE);
            _assertRole(t, ERC20BurnableUpgradeable.burnFrom.selector, BURNER_ROLE);
            // `mint` carries NO binding: it is gated by the tranche's own onlyKernel check (per-market, not AM-global).
            _assertRole(t, IRoycoVaultTranche.mint.selector, 0);
        }
    }

    /// @notice The kernel setters, sync, market-ops, and quoter-admin surfaces carry their intended role bindings
    function test_Auth_KernelSelectorRoleBindings() public view {
        _assertRole(address(KERNEL), IRoycoDayKernel.setProtocolFeeRecipient.selector, ADMIN_KERNEL_ROLE);
        _assertRole(address(KERNEL), IRoycoDayKernel.setSeniorTrancheSelfLiquidationBonus.selector, ADMIN_KERNEL_ROLE);
        _assertRole(address(KERNEL), IRoycoDayKernel.syncTrancheAccounting.selector, SYNC_ROLE);
        _assertRole(address(KERNEL), IRoycoAuth.pause.selector, ADMIN_PAUSER_ROLE);

        // Operational maintenance surface -> ADMIN_MARKET_OPS_ROLE.
        _assertRole(address(KERNEL), IRoycoDayKernel.reinvestLiquidityPremium.selector, ADMIN_MARKET_OPS_ROLE);
        _assertRole(address(KERNEL), IRoycoDayKernel.setRoycoBlacklist.selector, ADMIN_MARKET_OPS_ROLE);
        _assertRole(address(ACCOUNTANT), IRoycoDayAccountant.setSeniorTrancheDustTolerance.selector, ADMIN_MARKET_OPS_ROLE);
        _assertRole(address(ACCOUNTANT), IRoycoDayAccountant.setJuniorTrancheDustTolerance.selector, ADMIN_MARKET_OPS_ROLE);

        // Quoter admin surface -> ADMIN_ORACLE_QUOTER_ROLE (previously unbound => silently defaulted to ADMIN_ROLE).
        _assertRole(address(KERNEL), BalancerV3_LT_BPTOracle_Quoter.setBPTOracle.selector, ADMIN_ORACLE_QUOTER_ROLE);
        _assertRole(address(KERNEL), BalancerV3_LT_BPTOracle_Quoter.setMaxReinvestmentSlippage.selector, ADMIN_ORACLE_QUOTER_ROLE);
        _assertRole(address(KERNEL), bytes4(keccak256("setConversionRate(uint256,bool)")), ADMIN_ORACLE_QUOTER_ROLE);
        _assertRole(address(KERNEL), bytes4(keccak256("setChainlinkOracle(address,uint48,bool)")), ADMIN_ORACLE_QUOTER_ROLE);
        _assertRole(address(KERNEL), bytes4(keccak256("setSequencerUptimeFeed(address,uint48)")), ADMIN_ORACLE_QUOTER_ROLE);
    }

    /// @notice Key grants exist (the accountant can sync, the kernel can burn) and every bound role has a live grantee
    function test_Auth_EveryBoundRoleHasALiveGrantee() public view {
        (bool syncAcc,) = ACCESS_MANAGER.hasRole(SYNC_ROLE, address(ACCOUNTANT));
        assertTrue(syncAcc, "accountant SYNC_ROLE");
        (bool burner,) = ACCESS_MANAGER.hasRole(BURNER_ROLE, address(KERNEL));
        assertTrue(burner, "kernel BURNER_ROLE");

        // Every bound role has a live grantee at deploy end (no memberless-role liveness cliffs).
        (bool unpauser,) = ACCESS_MANAGER.hasRole(ADMIN_UNPAUSER_ROLE, UNPAUSER_ADDRESS);
        assertTrue(unpauser, "unpauser granted");
        (bool ltLp,) = ACCESS_MANAGER.hasRole(LT_LP_ROLE, PROTOCOL_FEE_RECIPIENT_ADDRESS);
        assertTrue(ltLp, "LT LP granted");
        (bool poolMgr,) = ACCESS_MANAGER.hasRole(ADMIN_BALANCER_POOL_MANAGER_ROLE, KERNEL_ADMIN_ADDRESS);
        assertTrue(poolMgr, "balancer pool manager granted");
        (bool marketOps,) = ACCESS_MANAGER.hasRole(ADMIN_MARKET_OPS_ROLE, KERNEL_ADMIN_ADDRESS);
        assertTrue(marketOps, "market ops granted");
    }

    /// The deploy script renounces the hot deployer key's super-admin surface, keeping only DEPLOYER_ROLE
    function test_Auth_DeployerPrivilegesDropped() public view {
        // The deploy script renounces the hot deployer key's super-admin surface after deployment completes.
        (bool isAdmin,) = ACCESS_MANAGER.hasRole(0, DEPLOYER_ADDRESS); // ADMIN_ROLE == 0
        assertFalse(isAdmin, "deployer still ADMIN_ROLE");
        (bool isFactoryAdmin,) = ACCESS_MANAGER.hasRole(ADMIN_FACTORY_ROLE, DEPLOYER_ADDRESS);
        assertFalse(isFactoryAdmin, "deployer still ADMIN_FACTORY_ROLE");
        // DEPLOYER_ROLE (executeMarketDeployment only) is retained.
        (bool isDeployer,) = ACCESS_MANAGER.hasRole(DEPLOYER_ROLE, DEPLOYER_ADDRESS);
        assertTrue(isDeployer, "deployer lost DEPLOYER_ROLE");
    }

    /// mint is an immutable-address check on THIS market's kernel, not an AccessManager role (cross-market bleed defense)
    function test_RevertIf_NonKernelMintsTrancheShares() public {
        // Cross-market bleed defense: mint is an immutable-address check on THIS market's kernel, not an AM role.
        vm.prank(address(0xBAD));
        vm.expectRevert(IRoycoVaultTranche.ONLY_KERNEL.selector);
        ST.mint(address(0xBAD), 1);
    }

    /// The template deployed the BPT oracle through Balancer's E-CLP oracle factory, priced on this market's pool with 1.0 rate-provider feeds
    function test_BPTOracle_DeployedByTemplateAndWired() public view {
        // The template deployed the BPT oracle through Balancer's E-CLP LP oracle factory and injected it into the kernel.
        address bptOracle = BalancerV3_LT_BPTOracle_Quoter(address(KERNEL)).getBalancerV3QuoterState().bptOracle;
        assertTrue(bptOracle != address(0), "bptOracle unset");
        assertGt(bptOracle.code.length, 0, "bptOracle has no code");
        address eclpOracleFactory = DEPLOY_SCRIPT.getChainConfig(block.chainid).eclpLPOracleFactory;
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

    /// Pinned real-stack behavior: computeTVL reverts on the unseeded pool while the kernel's zero-supply short-circuit stays immune
    function test_BPTOracle_ComputeTVLRevertsOnUnseededPool_KernelShortCircuits() public {
        // Pinned real-stack behavior: on the freshly deployed, UNSEEDED pool the E-CLP invariant math produces a small
        // negative intermediate on zero balances, so a direct computeTVL() call reverts with a SafeCast int->uint
        // overflow (argument value depends on the curve params, so only the selector is pinned). The kernel is immune:
        // both ltConvert directions short-circuit to zero on a zero BPT supply BEFORE reading the oracle
        // (BalancerV3_LT_BPTOracle_Quoter.sol:133-134,142-143) — asserted against the real oracle below.
        address bptOracle = BalancerV3_LT_BPTOracle_Quoter(address(KERNEL)).getBalancerV3QuoterState().bptOracle;
        vm.expectPartialRevert(SafeCast.SafeCastOverflowedIntToUint.selector);
        LPOracleBase(bptOracle).computeTVL();

        assertEq(
            TRANCHE_UNIT.unwrap(BalancerV3_LT_BPTOracle_Quoter(address(KERNEL)).ltConvertNAVUnitsToTrancheUnits(NAV_UNIT.wrap(1e18))),
            0,
            "zero-supply short-circuit must protect the NAV->BPT direction"
        );
        assertEq(
            NAV_UNIT.unwrap(BalancerV3_LT_BPTOracle_Quoter(address(KERNEL)).ltConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT.wrap(1e18))),
            0,
            "zero-supply short-circuit must protect the BPT->NAV direction"
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
