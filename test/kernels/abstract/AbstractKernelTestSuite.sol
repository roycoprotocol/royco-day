// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { DeployScript } from "../../../script/Deploy.s.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { TrancheType } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../src/libraries/Units.sol";
import { BaseTest } from "../../base/BaseTest.sol";
import { IKernelTestHooks } from "../../interfaces/IKernelTestHooks.sol";

/**
 * @title AbstractKernelTestSuite
 * @notice The shared, config-driven base every Day kernel test extends. `setUp` reads the concrete kernel's `TestConfig`,
 *         forks the configured network, deploys the market end-to-end through the real `DeployScript` (via the concrete
 *         `_deployKernelAndMarket` hook, which selects a market config by name from the config file), wires every deployed
 *         contract into member vars (including the Day-only LT/pool/hook/LDM topology the script's result omits), and
 *         funds the ST/JT providers. Concrete kernel tests then only supply the per-kernel `IKernelTestHooks` and the market
 *         name — mirroring the Royco Dawn "abstract kernel test per kernel type" pattern.
 * @dev No `test_*` methods live here yet; the shared test battery is added on top of this scaffolding later.
 */
abstract contract AbstractKernelTestSuite is BaseTest, IKernelTestHooks {
    /// @notice The concrete kernel's static test configuration (assets, fork, funding).
    TestConfig internal testConfig;

    /// @notice Snapshots used by NAV-tracking tests (populated by future tests, not by `setUp`).
    TrancheState internal stState;
    TrancheState internal jtState;

    // ── Day market-topology addresses the script's `DeploymentResult` does not surface ──
    /// @notice The liquidity tranche (holds the Gyro E-CLP BPT).
    IRoycoVaultTranche internal LT;
    /// @notice The liquidity tranche's Gyro E-CLP pool (the BPT, == `KERNEL.LT_ASSET()`).
    address internal POOL;
    /// @notice The pool's kernel-bound hook (the upgraded `RoycoDayBalancerV3Hooks` proxy).
    address internal BALANCER_HOOK;
    /// @notice The liquidity-premium model (LDM), distinct from the JT YDM.
    address internal LT_YDM;
    /// @notice The Balancer V3 Vault the pool is registered with.
    IVault internal VAULT;

    // ═══════════════════════════════════════════════════════════════════════════
    // HOOKS IMPLEMENTED BY CONCRETE KERNEL TESTS / PER-KERNEL-TYPE BASES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the kernel + market for this test, typically `DEPLOY_SCRIPT.deploy(getMarketConfig("<name>"), ...)`.
    function _deployKernelAndMarket() internal virtual returns (DeployScript.DeploymentResult memory result);

    /// @inheritdoc IKernelTestHooks
    function getTestConfig() public view virtual override(IKernelTestHooks) returns (TestConfig memory);

    /// @inheritdoc IKernelTestHooks
    function simulateSTYield(uint256 _percentageWAD) public virtual override(IKernelTestHooks);
    /// @inheritdoc IKernelTestHooks
    function simulateJTYield(uint256 _percentageWAD) public virtual override(IKernelTestHooks);
    /// @inheritdoc IKernelTestHooks
    function simulateSTLoss(uint256 _percentageWAD) public virtual override(IKernelTestHooks);
    /// @inheritdoc IKernelTestHooks
    function simulateJTLoss(uint256 _percentageWAD) public virtual override(IKernelTestHooks);

    /// @inheritdoc IKernelTestHooks
    function dealSTAsset(address _to, uint256 _amount) public virtual override(IKernelTestHooks);
    /// @inheritdoc IKernelTestHooks
    function dealJTAsset(address _to, uint256 _amount) public virtual override(IKernelTestHooks);
    /// @inheritdoc IKernelTestHooks
    function dealQuoteAsset(address _to, uint256 _amount) public virtual override(IKernelTestHooks);

    /// @inheritdoc IKernelTestHooks
    function maxTrancheUnitDelta() public view virtual override(IKernelTestHooks) returns (TRANCHE_UNIT);
    /// @inheritdoc IKernelTestHooks
    function maxNAVDelta() public view virtual override(IKernelTestHooks) returns (NAV_UNIT);

    // ── Optional seams (override for time-sensitive oracles) ──

    /// @dev Called by yield tests after a `vm.warp`. Override for Chainlink/time-sensitive oracles that must be re-mocked.
    function _refreshOraclesAfterWarp() internal virtual { }

    /// @dev Whether yield realization requires a time warp (e.g. rebasing/streaming vaults). Default true.
    function _requiresTimeWarpForYield() internal virtual returns (bool) {
        return true;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        testConfig = getTestConfig();

        // Config-driven fork. A market with a fork RPC env var but no RPC configured skips the whole suite.
        if (bytes(testConfig.forkRpcUrlEnvVar).length > 0) {
            string memory rpc = vm.envOr(testConfig.forkRpcUrlEnvVar, string(""));
            if (bytes(rpc).length == 0) {
                vm.skip(true);
                return;
            }
            vm.createSelectFork(rpc, testConfig.forkBlock);
        }

        _setupWallets();
        DEPLOY_SCRIPT = new DeployScript();

        // Deploy the market end-to-end through the real script (concrete test selects the config by name).
        _setDeployedMarket(_deployKernelAndMarket());

        // Capture the Day LT topology the script result omits, by reading the deployed contracts.
        if (testConfig.hasLiquidityTranche) {
            LT = IRoycoVaultTranche(KERNEL.LIQUIDITY_TRANCHE());
            POOL = KERNEL.LT_ASSET();
            LT_YDM = ACCOUNTANT.getState().ltYDM;
            VAULT = IVault(address(GyroECLPPoolFactory(DEPLOY_SCRIPT.getChainConfig(block.chainid).gyroECLPPoolFactory).getVault()));
            BALANCER_HOOK = VAULT.getHooksConfig(POOL).hooksContract;
            vm.label(address(LT), "LT");
            vm.label(POOL, "BalancerPool");
            vm.label(BALANCER_HOOK, "BalancerHook");
            vm.label(LT_YDM, "LDM");
        }

        _setupProviders();
        _fundAllProviders();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REUSABLE HELPERS (used by future tests)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deals each provider the ST/JT (and, if the market has an LT, the quote) asset with `initialFunding`.
    function _fundAllProviders() internal {
        for (uint256 i = 0; i < providers.length; ++i) {
            dealSTAsset(providers[i], testConfig.initialFunding);
            dealJTAsset(providers[i], testConfig.initialFunding);
            if (testConfig.hasLiquidityTranche) dealQuoteAsset(providers[i], testConfig.initialFunding);
        }
    }

    /// @notice Deposits `_amount` (asset units) of the ST asset from `_lp` into the senior tranche; returns shares.
    function _depositST(address _lp, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_lp);
        IERC20(testConfig.stAsset).approve(address(ST), _amount);
        shares = ST.deposit(toTrancheUnits(_amount), _lp);
        vm.stopPrank();
    }

    /// @notice Deposits `_amount` (asset units) of the JT asset from `_lp` into the junior tranche; returns shares.
    function _depositJT(address _lp, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_lp);
        IERC20(testConfig.jtAsset).approve(address(JT), _amount);
        shares = JT.deposit(toTrancheUnits(_amount), _lp);
        vm.stopPrank();
    }

    /// @notice Asserts two-term NAV conservation (`stRaw + jtRaw ≈ stEff + jtEff`) within the kernel's NAV tolerance.
    function _assertNAVConservation() internal view {
        NAV_UNIT stRaw = ST.getRawNAV();
        NAV_UNIT jtRaw = JT.getRawNAV();
        NAV_UNIT stEff = ST.totalAssets().nav;
        NAV_UNIT jtEff = JT.totalAssets().nav;
        assertApproxEqAbs(stRaw + jtRaw, stEff + jtEff, maxNAVDelta(), "NAV conservation");
    }
}
