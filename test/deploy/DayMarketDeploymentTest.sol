// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { HooksConfig, TokenInfo, TokenType } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPPoolFactory } from "../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { AccessManagedUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC20BurnableUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { DeployScript } from "../../script/Deploy.s.sol";
import {
    ADMIN_ENTRY_POINT_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    BURNER_ROLE,
    JT_LP_ROLE,
    LT_LP_ROLE,
    SHARE_MINTER_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE
} from "../../src/factory/RolesConfiguration.sol";
import { IRoycoAuth } from "../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDayAccountant } from "../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { RoycoDayKernel } from "../../src/kernels/base/RoycoDayKernel.sol";
import { RoycoDayBalancerV3Hooks } from "../../src/kernels/base/quoter/liquidity-tranche/balancer-v3/RoycoDayBalancerV3Hooks.sol";
import { TrancheType } from "../../src/libraries/Types.sol";
import { TRANCHE_UNIT } from "../../src/libraries/Units.sol";
import { RoycoLiquidityTranche } from "../../src/tranches/RoycoLiquidityTranche.sol";
import { AdaptiveCurveYDM_V2 } from "../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { BaseTest } from "../base/BaseTest.sol";

/**
 * @title DayMarketDeploymentTest
 * @notice End-to-end deployment test: runs the real `DeployScript` against a mainnet fork to deploy a full Day snUSD
 *         market on the real Balancer V3 + Gyro E-CLP infra, then rigorously asserts every parameter, linkage, and
 *         AccessManager auth wiring.
 * @dev Scope: deploy + static assertions (no deposits/syncs). The deploy only *stores* the BPT/base->NAV oracles, so a
 *      non-zero placeholder BPT oracle + the real (uncalled) RedStone feed suffice. The ST/JT asset is the real snUSD
 *      ERC4626 vault (answers `decimals()`/`asset()` on the fork); the E-CLP curve params are a known-good set copied from
 *      Balancer's pool-gyro test util (the Gyro `create` validates them).
 *
 *      Requires env `MAINNET_RPC_URL` and (optionally) `FORK_BLOCK` (a block where the Gyro factory, Balancer V3 vault,
 *      snUSD vault, USDC, and the RedStone feed all have code). Without an RPC the whole suite is skipped.
 */
contract DayMarketDeploymentTest is BaseTest {
    // ── Real mainnet addresses (snUSD market) ────────────────────────────────────────────────────────────────────
    address internal constant SNUSD_VAULT = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313; // ST/JT ERC4626 asset
    address internal constant NUSD_REDSTONE_ORACLE = 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95; // base->NAV feed
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // pool quote token
    address internal constant BPT_ORACLE_PLACEHOLDER = 0x000000000000000000000000000000000000dEaD; // stored-only at deploy
    address internal constant FACTORY_ADMIN = 0x7c405bbD131e42af506d14e752f2e59B19D49997; // ROOT_MULTISIG

    // Expected values asserted against the config-file `snUSD` market config.
    uint64 internal constant TARGET_UTIL = 0.9e18;
    uint256 internal constant SWAP_FEE = 1e14; // 1 bp

    // ── Deployed market (BaseTest sets FACTORY/ACCESS_MANAGER/ST/JT/KERNEL/ACCOUNTANT/YDM/BLACKLIST via _setDeployedMarket) ──
    IRoycoVaultTranche internal LT;
    address internal POOL; // the Gyro E-CLP BPT (== kernel.LT_ASSET())
    address internal BALANCER_HOOK; // the pool's hooks contract (the kernel-bound RoycoDayBalancerV3Hooks proxy)
    address internal LT_YDM; // the LDM
    IVault internal VAULT;

    function _forkConfiguration() internal view override returns (uint256 forkBlock, string memory forkRpcUrl) {
        forkRpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        // A block where the Gyro E-CLP factory (deployed ~24.2M), the Balancer V3 vault, the snUSD vault, USDC, and the
        // RedStone nUSD feed all have code. Overridable via the FORK_BLOCK env var.
        forkBlock = vm.envOr("FORK_BLOCK", uint256(25_400_000));
    }

    function setUp() public {
        (, string memory rpc) = _forkConfiguration();
        if (bytes(rpc).length == 0) {
            // No mainnet RPC configured — this suite requires a fork (real Balancer V3 + Gyro + snUSD vault).
            vm.skip(true);
            return;
        }

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
        BALANCER_HOOK = VAULT.getHooksConfig(POOL).hooksContract;
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // 1. RESULT COMPLETENESS
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_deployment_allAddressesLive() public view {
        address[12] memory a = [
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
            POOL,
            BALANCER_HOOK
        ];
        for (uint256 i = 0; i < a.length; ++i) {
            assertTrue(a[i] != address(0), "zero address");
            assertGt(a[i].code.length, 0, "no code");
        }
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // 2. KERNEL <-> TRANCHE <-> ACCOUNTANT LINKAGE
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_linkage_kernelTranchesAccountant() public view {
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

    function test_linkage_assets() public view {
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

    function test_linkage_blacklistWiredToKernel() public view {
        // The tranche balance-update hook is kernel-mediated now: tranche._update -> kernel.preTrancheBalanceUpdateHook ->
        // BlacklistLogic(kernel.roycoBlacklist). The deployed RoycoBlacklist must be the kernel's configured blacklist.
        assertEq(KERNEL.getState().roycoBlacklist, address(BLACKLIST), "kernel blacklist");
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // 4. BALANCER POOL WIRING (rate provider + hook)
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_pool_registeredAndTokens() public view {
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

    function test_pool_rateProviderIsKernel() public view {
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

    function test_pool_hookUpgradedAndBound() public view {
        HooksConfig memory hc = VAULT.getHooksConfig(POOL);
        assertEq(hc.hooksContract, BALANCER_HOOK, "pool hook mismatch");
        // The stand-in advertised the real hook's flags; they are frozen at registration.
        assertTrue(hc.shouldCallBeforeSwap, "beforeSwap flag");
        assertTrue(hc.shouldCallBeforeAddLiquidity, "beforeAdd flag");
        assertTrue(hc.shouldCallBeforeRemoveLiquidity, "beforeRemove flag");

        // The proxy was upgraded to the real kernel-bound hook and initialized.
        RoycoDayBalancerV3Hooks hook = RoycoDayBalancerV3Hooks(BALANCER_HOOK);
        assertEq(hook.ROYCO_DAY_KERNEL(), address(KERNEL), "hook -> kernel");
        assertEq(hook.LIQUIDITY_TRANCHE_BALANCER_V3_POOL(), POOL, "hook -> pool");
        assertEq(AccessManagedUpgradeable(BALANCER_HOOK).authority(), address(ACCESS_MANAGER), "hook authority");
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // 5. YDM + LDM (both initialized — locks in the LDM-init fix)
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_ydm_distinctAndWired() public view {
        assertEq(ACCOUNTANT.getState().jtYDM, address(YDM), "accountant jtYDM");
        assertEq(ACCOUNTANT.getState().ltYDM, LT_YDM, "accountant ltYDM");
        assertTrue(address(YDM) != LT_YDM, "YDM == LDM");
    }

    function test_ydm_bothInitializedForThisAccountant() public view {
        (uint64 jtTarget,,,,) = AdaptiveCurveYDM_V2(address(YDM)).accountantToCurve(address(ACCOUNTANT));
        (uint64 ltTarget,,,,) = AdaptiveCurveYDM_V2(LT_YDM).accountantToCurve(address(ACCOUNTANT));
        assertEq(jtTarget, 0.11e18, "JT YDM curve uninitialized");
        assertEq(ltTarget, 0.11e18, "LDM curve uninitialized");
    }

    function test_ydm_targetUtilizations() public view {
        assertEq(AdaptiveCurveYDM_V2(address(YDM)).TARGET_UTILIZATION_WAD(), TARGET_UTIL, "JT YDM target util");
        assertEq(AdaptiveCurveYDM_V2(LT_YDM).TARGET_UTILIZATION_WAD(), TARGET_UTIL, "LDM target util");
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // 6. ACCOUNTANT CONFIG + 7. KERNEL / TRANCHE PARAMETERS
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_accountant_config() public view {
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

    function test_kernel_and_tranche_params() public view {
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

    function test_auth_authorities() public view {
        address am = address(ACCESS_MANAGER);
        assertEq(AccessManagedUpgradeable(address(KERNEL)).authority(), am, "kernel authority");
        assertEq(AccessManagedUpgradeable(address(ACCOUNTANT)).authority(), am, "accountant authority");
        assertEq(AccessManagedUpgradeable(address(ST)).authority(), am, "ST authority");
        assertEq(AccessManagedUpgradeable(address(JT)).authority(), am, "JT authority");
        assertEq(AccessManagedUpgradeable(address(LT)).authority(), am, "LT authority");
        assertEq(AccessManagedUpgradeable(BALANCER_HOOK).authority(), am, "balancer hook authority");
    }

    function test_auth_factoryRoles() public view {
        (bool isAdmin,) = ACCESS_MANAGER.hasRole(0, address(FACTORY)); // ADMIN_ROLE == 0
        assertTrue(isAdmin, "factory not ADMIN_ROLE");
        (bool isEntry,) = ACCESS_MANAGER.hasRole(ADMIN_ENTRY_POINT_ROLE, address(FACTORY));
        assertTrue(isEntry, "factory not ADMIN_ENTRY_POINT_ROLE");
    }

    function test_auth_trancheBindings() public view {
        _assertRole(address(ST), IRoycoVaultTranche.deposit.selector, ST_LP_ROLE);
        _assertRole(address(ST), IRoycoVaultTranche.redeem.selector, ST_LP_ROLE);
        _assertRole(address(JT), IRoycoVaultTranche.deposit.selector, JT_LP_ROLE);
        _assertRole(address(LT), IRoycoVaultTranche.deposit.selector, LT_LP_ROLE);
        _assertRole(address(LT), RoycoLiquidityTranche.depositMultiAsset.selector, LT_LP_ROLE);
        _assertRole(address(LT), RoycoLiquidityTranche.redeemMultiAsset.selector, LT_LP_ROLE);

        for (uint256 i = 0; i < 3; ++i) {
            address t = i == 0 ? address(ST) : i == 1 ? address(JT) : address(LT);
            _assertRole(t, IRoycoAuth.pause.selector, ADMIN_PAUSER_ROLE);
            _assertRole(t, IRoycoAuth.unpause.selector, ADMIN_UNPAUSER_ROLE);
            _assertRole(t, UUPSUpgradeable.upgradeToAndCall.selector, ADMIN_UPGRADER_ROLE);
            _assertRole(t, ERC20BurnableUpgradeable.burn.selector, BURNER_ROLE);
            _assertRole(t, ERC20BurnableUpgradeable.burnFrom.selector, BURNER_ROLE);
            _assertRole(t, IRoycoVaultTranche.mint.selector, SHARE_MINTER_ROLE);
        }
    }

    function test_auth_kernelAndHookBindings() public view {
        _assertRole(address(KERNEL), IRoycoDayKernel.setProtocolFeeRecipient.selector, ADMIN_KERNEL_ROLE);
        _assertRole(address(KERNEL), IRoycoDayKernel.setSeniorTrancheSelfLiquidationBonus.selector, ADMIN_KERNEL_ROLE);
        _assertRole(address(KERNEL), IRoycoDayKernel.syncTrancheAccounting.selector, SYNC_ROLE);
        _assertRole(address(KERNEL), IRoycoAuth.pause.selector, ADMIN_PAUSER_ROLE);

        _assertRole(BALANCER_HOOK, IRoycoAuth.pause.selector, ADMIN_PAUSER_ROLE);
        _assertRole(BALANCER_HOOK, IRoycoAuth.unpause.selector, ADMIN_UNPAUSER_ROLE);
        _assertRole(BALANCER_HOOK, UUPSUpgradeable.upgradeToAndCall.selector, ADMIN_UPGRADER_ROLE);
    }

    function test_auth_grants() public view {
        (bool syncAcc,) = ACCESS_MANAGER.hasRole(SYNC_ROLE, address(ACCOUNTANT));
        assertTrue(syncAcc, "accountant SYNC_ROLE");
        (bool syncHook,) = ACCESS_MANAGER.hasRole(SYNC_ROLE, BALANCER_HOOK);
        assertTrue(syncHook, "balancer hook SYNC_ROLE");
        (bool minter,) = ACCESS_MANAGER.hasRole(SHARE_MINTER_ROLE, address(KERNEL));
        assertTrue(minter, "kernel SHARE_MINTER_ROLE");
        (bool burner,) = ACCESS_MANAGER.hasRole(BURNER_ROLE, address(KERNEL));
        assertTrue(burner, "kernel BURNER_ROLE");
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════
    // 9. AUTH — negative (unauthorized callers revert)
    // ════════════════════════════════════════════════════════════════════════════════════════════════════════════

    function test_auth_negative_randomCannotPauseKernel() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        IRoycoAuth(address(KERNEL)).pause();
    }

    function test_auth_negative_randomCannotSetProtocolFeeRecipient() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        KERNEL.setProtocolFeeRecipient(address(0xBAD));
    }

    function test_auth_negative_nonLpCannotDeposit() public {
        // snUSD tranche deposit is gated by ST_LP_ROLE; a random address is not an LP (reverts on auth before value checks).
        vm.prank(address(0xBAD));
        vm.expectRevert();
        ST.deposit(TRANCHE_UNIT.wrap(0), address(0xBAD));
    }

    function _assertRole(address _target, bytes4 _selector, uint64 _expectedRole) internal view {
        assertEq(ACCESS_MANAGER.getTargetFunctionRole(_target, _selector), _expectedRole, "role binding");
    }
}
