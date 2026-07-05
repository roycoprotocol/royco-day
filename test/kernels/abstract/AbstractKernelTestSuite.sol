// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IVaultErrors } from "../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultErrors.sol";
import { GyroECLPPoolFactory } from "../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { Vm } from "../../../lib/forge-std/src/Vm.sol";
import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IERC20Errors } from "../../../lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { DeployScript } from "../../../script/Deploy.s.sol";
import { ADMIN_ACCOUNTANT_ROLE, ADMIN_UNPAUSER_ROLE, LT_LP_ROLE } from "../../../src/factory/RolesConfiguration.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoBlacklist } from "../../../src/interfaces/IRoycoBlacklist.sol";
import { IRoycoDayAccountant } from "../../../src/interfaces/IRoycoDayAccountant.sol";
import { IRoycoDayKernel } from "../../../src/interfaces/IRoycoDayKernel.sol";
import { IRoycoLiquidityTranche } from "../../../src/interfaces/IRoycoLiquidityTranche.sol";
import { IRoycoSeniorTranche } from "../../../src/interfaces/IRoycoSeniorTranche.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../../../src/interfaces/IYDM.sol";
import { MAX_TRANCHE_UNITS, WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../../src/libraries/Constants.sol";
import { AssetClaims, MarketState, Operation, SyncedAccountingState, TrancheType } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { BaseTest } from "../../base/BaseTest.sol";
import { IKernelTestHooks } from "../../interfaces/IKernelTestHooks.sol";

/**
 * @title AbstractKernelTestSuite
 * @notice The shared, config-driven base every Day kernel test extends. `setUp` reads the concrete kernel's `TestConfig`,
 *         forks the configured network, deploys the market end-to-end through the real `DeployScript` (via the concrete
 *         `_deployKernelAndMarket` hook, which selects a market config by name from the config file), wires every deployed
 *         contract into member vars (including the Day-only LT/pool/hook/LDM topology the script's result omits), and
 *         funds the ST/JT providers. Concrete kernel tests then only supply the per-kernel `IKernelTestHooks` and the market
 *         name — following an "abstract kernel test per kernel type" pattern.
 * @dev The shared test battery lives here on top of the scaffolding, added section by section (S2 is the deposit battery).
 */
abstract contract AbstractKernelTestSuite is BaseTest, IKernelTestHooks {
    /// @notice The concrete kernel's static test configuration (assets, fork, funding).
    TestConfig internal testConfig;

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
            _fundActor(providers[i]);
        }
    }

    /// @notice Deposits `_amount` (asset units) of the ST asset from `_lp` into the senior tranche, returning the shares.
    function _depositST(address _lp, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_lp);
        IERC20(testConfig.stAsset).approve(address(ST), _amount);
        shares = ST.deposit(toTrancheUnits(_amount), _lp);
        vm.stopPrank();
    }

    /// @notice Deposits `_amount` (asset units) of the JT asset from `_lp` into the junior tranche, returning the shares.
    function _depositJT(address _lp, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_lp);
        IERC20(testConfig.jtAsset).approve(address(JT), _amount);
        shares = JT.deposit(toTrancheUnits(_amount), _lp);
        vm.stopPrank();
    }

    /// @notice Asserts two-term NAV conservation on the LIVE view marks within the kernel's NAV tolerance.
    /// @dev Committed-checkpoint conservation is wei-exact and asserted via `_assertCommittedConservation` instead.
    function _assertNAVConservation() internal view {
        NAV_UNIT stRaw = ST.getRawNAV();
        NAV_UNIT jtRaw = JT.getRawNAV();
        NAV_UNIT stEff = ST.totalAssets().nav;
        NAV_UNIT jtEff = JT.totalAssets().nav;
        assertApproxEqAbs(stRaw + jtRaw, stEff + jtEff, maxNAVDelta(), "NAV conservation");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S1 — SHARED HELPERS + SNAPSHOT MACHINERY (no tests)
    // ═══════════════════════════════════════════════════════════════════════════

    // ── S1.1 Snapshot struct + capture ──

    /// @notice One actor's share balances across the three tranches at snapshot time.
    struct ActorShares {
        address actor;
        uint256 stShares;
        uint256 jtShares;
        uint256 ltShares;
    }

    /**
     * @notice Full market snapshot. Every mutating test diffs pre vs post against independently
     *         computed expectations.
     * @dev Utilizations are recomputed from the committed checkpoint fields via the S1.4 pure helpers,
     *      never by re-calling an accountant view, so gate assertions stay independent.
     */
    struct MarketSnapshot {
        // Live raw NAVs (quoter conversions of owned assets). ltRaw is 0 when the market has no LT
        NAV_UNIT stRaw;
        NAV_UNIT jtRaw;
        NAV_UNIT ltRaw;
        // Committed accountant checkpoint (ACCOUNTANT.getState())
        NAV_UNIT lastSTRaw;
        NAV_UNIT lastJTRaw;
        NAV_UNIT lastLTRaw;
        NAV_UNIT lastSTEff;
        NAV_UNIT lastJTEff;
        NAV_UNIT lastIL;
        MarketState marketState;
        uint32 fixedTermEnd;
        uint32 lastAccrualTs;
        uint32 lastPremiumTs;
        uint192 twJT;
        uint192 twLT;
        // Utilizations recomputed live from committed inputs via _expectedCovUtil/_expectedLiqUtil
        uint256 covUtilWAD;
        uint256 liqUtilWAD;
        // Supplies
        uint256 stSupply;
        uint256 jtSupply;
        uint256 ltSupply;
        // Kernel owned-asset accounting (KERNEL.getState())
        TRANCHE_UNIT stOwned;
        TRANCHE_UNIT jtOwned;
        TRANCHE_UNIT ltOwned;
        uint256 idleSTShares;
        // Kernel token balances (solvency side). When stAsset == jtAsset the two balances mirror each other
        uint256 kernelSTAssetBal;
        uint256 kernelJTAssetBal;
        uint256 kernelBPTBal;
        uint256 kernelSTShareBal;
        // Fee recipient share balances
        uint256 feeRecipientSTShares;
        uint256 feeRecipientJTShares;
        uint256 feeRecipientLTShares;
        ActorShares[] actors;
    }

    /// @notice Captures a full market snapshot plus the per-actor share balances for `_actors`.
    function _snap(address[] memory _actors) internal view returns (MarketSnapshot memory s) {
        bool hasLT = testConfig.hasLiquidityTranche;

        // Live raw NAVs through the production quoter path
        s.stRaw = ST.getRawNAV();
        s.jtRaw = JT.getRawNAV();
        if (hasLT) s.ltRaw = LT.getRawNAV();

        // Committed accountant checkpoint
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        s.lastSTRaw = a.lastSTRawNAV;
        s.lastJTRaw = a.lastJTRawNAV;
        s.lastLTRaw = a.lastLTRawNAV;
        s.lastSTEff = a.lastSTEffectiveNAV;
        s.lastJTEff = a.lastJTEffectiveNAV;
        s.lastIL = a.lastJTCoverageImpermanentLoss;
        s.marketState = a.lastMarketState;
        s.fixedTermEnd = a.fixedTermEndTimestamp;
        s.lastAccrualTs = a.lastYieldShareAccrualTimestamp;
        s.lastPremiumTs = a.lastPremiumPaymentTimestamp;
        s.twJT = a.twJTYieldShareAccruedWAD;
        s.twLT = a.twLTYieldShareAccruedWAD;

        // Utilizations recomputed independently from the committed checkpoint
        s.covUtilWAD = _expectedCovUtil(a.lastSTRawNAV, a.lastJTRawNAV, ACCOUNTANT.JT_COINVESTED(), a.minCoverageWAD, a.lastJTEffectiveNAV);
        s.liqUtilWAD = _expectedLiqUtil(a.lastSTEffectiveNAV, a.minLiquidityWAD, a.lastLTRawNAV);

        // Supplies
        s.stSupply = ST.totalSupply();
        s.jtSupply = JT.totalSupply();
        if (hasLT) s.ltSupply = LT.totalSupply();

        // Kernel owned-asset ledger
        IRoycoDayKernel.RoycoDayKernelState memory k = KERNEL.getState();
        s.stOwned = k.stOwnedYieldBearingAssets;
        s.jtOwned = k.jtOwnedYieldBearingAssets;
        s.ltOwned = k.ltOwnedYieldBearingAssets;
        s.idleSTShares = k.ltOwnedSeniorTrancheShares;

        // Kernel token balances (solvency side)
        s.kernelSTAssetBal = IERC20(testConfig.stAsset).balanceOf(address(KERNEL));
        s.kernelJTAssetBal = IERC20(testConfig.jtAsset).balanceOf(address(KERNEL));
        if (hasLT) {
            s.kernelBPTBal = IERC20(POOL).balanceOf(address(KERNEL));
            s.kernelSTShareBal = ST.balanceOf(address(KERNEL));
        }

        // Fee recipient share balances
        s.feeRecipientSTShares = ST.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);
        s.feeRecipientJTShares = JT.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);
        if (hasLT) s.feeRecipientLTShares = LT.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);

        // Per-actor share balances
        s.actors = new ActorShares[](_actors.length);
        for (uint256 i = 0; i < _actors.length; ++i) {
            s.actors[i] = ActorShares({
                actor: _actors[i], stShares: ST.balanceOf(_actors[i]), jtShares: JT.balanceOf(_actors[i]), ltShares: hasLT ? LT.balanceOf(_actors[i]) : 0
            });
        }
    }

    /// @notice Captures a full market snapshot with an empty actor list.
    function _snap() internal view returns (MarketSnapshot memory s) {
        return _snap(new address[](0));
    }

    // ── S1.2 Solvency + conservation asserts ──

    /// @notice Asserts kernel token balances cover its owned-asset ledger (>= to tolerate donations).
    function _assertSolvency() internal view {
        IRoycoDayKernel.RoycoDayKernelState memory k = KERNEL.getState();
        uint256 stAssetBal = IERC20(testConfig.stAsset).balanceOf(address(KERNEL));
        if (testConfig.stAsset == testConfig.jtAsset) {
            assertGe(
                stAssetBal,
                toUint256(k.stOwnedYieldBearingAssets) + toUint256(k.jtOwnedYieldBearingAssets),
                "solvency: shared ST/JT asset balance below the owned-asset ledger"
            );
        } else {
            assertGe(stAssetBal, toUint256(k.stOwnedYieldBearingAssets), "solvency: ST asset balance below the owned-asset ledger");
            assertGe(
                IERC20(testConfig.jtAsset).balanceOf(address(KERNEL)),
                toUint256(k.jtOwnedYieldBearingAssets),
                "solvency: JT asset balance below the owned-asset ledger"
            );
        }
        if (testConfig.hasLiquidityTranche) {
            assertGe(IERC20(POOL).balanceOf(address(KERNEL)), toUint256(k.ltOwnedYieldBearingAssets), "solvency: BPT balance below the owned-asset ledger");
            assertGe(ST.balanceOf(address(KERNEL)), k.ltOwnedSeniorTrancheShares, "solvency: ST share balance below the idle premium ledger");
        }
    }

    /// @notice Wei-exact two-term conservation on the COMMITTED checkpoint (the spec guarantees byte-exact).
    function _assertCommittedConservation() internal view {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertNAVConservation(a.lastSTRawNAV, a.lastJTRawNAV, a.lastSTEffectiveNAV, a.lastJTEffectiveNAV, "committed checkpoint");
    }

    // ── S1.3 Actors, roles, gating ──

    /// @notice The two LT liquidity providers, lazily created by `_setupLTProviders`.
    address internal LT_ALICE_ADDRESS;
    address internal LT_BOB_ADDRESS;

    /// @dev Monotonic nonce so every `_randomOutsider` address is unique within a test.
    uint256 private _outsiderNonce;

    /// @notice Skips the test when the market has no liquidity tranche.
    modifier whenLT() {
        if (!testConfig.hasLiquidityTranche) vm.skip(true);
        _;
    }

    /// @notice Lazily creates + funds the two LT providers with `LT_LP_ROLE` (idempotent).
    function _setupLTProviders() internal {
        if (LT_ALICE_ADDRESS == address(0)) {
            LT_ALICE_ADDRESS = _generateProvider("LT_ALICE", LT_LP_ROLE).addr;
            _fundActor(LT_ALICE_ADDRESS);
        }
        if (LT_BOB_ADDRESS == address(0)) {
            LT_BOB_ADDRESS = _generateProvider("LT_BOB", LT_LP_ROLE).addr;
            _fundActor(LT_BOB_ADDRESS);
        }
    }

    /// @notice Returns a fresh role-less address funded with every market asset.
    function _randomOutsider() internal returns (address outsider) {
        outsider = makeAddr(string.concat("OUTSIDER_", vm.toString(_outsiderNonce++)));
        _fundActor(outsider);
    }

    /// @dev Funds an actor with `initialFunding` of the ST/JT (and, when the market has an LT, the quote) asset.
    function _fundActor(address _actor) private {
        dealSTAsset(_actor, testConfig.initialFunding);
        dealJTAsset(_actor, testConfig.initialFunding);
        if (testConfig.hasLiquidityTranche) dealQuoteAsset(_actor, testConfig.initialFunding);
    }

    // ── S1.4 Independent expected-value math (pure, Math.mulDiv only) ──

    /**
     * @dev The share-pricing denominator used when a tranche has live supply but zero effective NAV.
     *      Mirrors `ValuationLogic._convertToShares`, which substitutes ONE_NAV_UNIT (1 wei of NAV) so
     *      new depositors dilute the existing unbacked holders (src/libraries/logic/ValuationLogic.sol).
     */
    uint256 internal constant ZERO_NAV_SHARE_PRICING_DENOMINATOR = 1;

    /// @notice Expected shares minted for `_value` against `_supply` shares backed by `_totalNAV` (floor).
    /// @dev Mirrors `ValuationLogic._convertToShares` including its zero-supply and zero-NAV boundaries.
    function _expectedShares(NAV_UNIT _value, uint256 _supply, NAV_UNIT _totalNAV) internal pure returns (uint256) {
        if (_supply == 0) return toUint256(_value);
        uint256 denominator = toUint256(_totalNAV) == 0 ? ZERO_NAV_SHARE_PRICING_DENOMINATOR : toUint256(_totalNAV);
        return Math.mulDiv(toUint256(_value), _supply, denominator);
    }

    /// @notice Expected value redeemed for `_shares` against `_supply` shares backed by `_totalNAV` (floor).
    /// @dev Mirrors `ValuationLogic._convertToValue` including its zero-supply boundary.
    function _expectedValue(uint256 _shares, uint256 _supply, NAV_UNIT _totalNAV) internal pure returns (NAV_UNIT) {
        if (_supply == 0) return toNAVUnits(uint256(0));
        return toNAVUnits(Math.mulDiv(toUint256(_totalNAV), _shares, _supply));
    }

    /// @notice Independent coverage utilization recomputation (ceil), mirroring `UtilizationLogic._computeCoverageUtilization`.
    function _expectedCovUtil(NAV_UNIT _stRaw, NAV_UNIT _jtRaw, bool _coinvested, uint64 _minCovWAD, NAV_UNIT _jtEff) internal pure returns (uint256) {
        if (_minCovWAD == 0) return 0;
        uint256 totalCoveredExposure = toUint256(_stRaw) + (_coinvested ? toUint256(_jtRaw) : 0);
        if (totalCoveredExposure == 0) return 0;
        if (toUint256(_jtEff) == 0) return type(uint256).max;
        return Math.mulDiv(totalCoveredExposure, _minCovWAD, toUint256(_jtEff), Math.Rounding.Ceil);
    }

    /// @notice Independent liquidity utilization recomputation (ceil), mirroring `UtilizationLogic._computeLiquidityUtilization`.
    function _expectedLiqUtil(NAV_UNIT _stEff, uint64 _minLiqWAD, NAV_UNIT _ltRaw) internal pure returns (uint256) {
        if (toUint256(_stEff) == 0 || _minLiqWAD == 0) return 0;
        if (toUint256(_ltRaw) == 0) return type(uint256).max;
        return Math.mulDiv(toUint256(_stEff), _minLiqWAD, toUint256(_ltRaw), Math.Rounding.Ceil);
    }

    /**
     * @notice Previews a YDM's yield share as the accountant, capped at `_maxYieldShareWAD`.
     * @dev YDM curve state is keyed by the accountant address, so the preview must be staticcalled with the
     *      accountant as `msg.sender`. The cap mirrors the accountant's `Math.min(..., max*YieldShareWAD)`.
     */
    function _previewYieldShareAsAccountant(
        address _ydm,
        MarketState _marketState,
        uint256 _utilizationWAD,
        uint64 _maxYieldShareWAD
    )
        internal
        returns (uint256 yieldShareWAD)
    {
        vm.prank(address(ACCOUNTANT));
        yieldShareWAD = Math.min(IYDM(_ydm).previewYieldShare(_marketState, _utilizationWAD), _maxYieldShareWAD);
    }

    /**
     * @notice Input/output packet for the independent two-term waterfall recomputation.
     * @dev Inputs are the committed checkpoint, the MEASURED post-simulate raw NAVs, the premium-window
     *      inputs (the stored time-weighted accumulators plus this sync's YDM previews weighted by the
     *      accrual window), the fee rates, and the effective dust. Outputs are every committed field the
     *      sync produces, filled in by `_expectedSync`.
     */
    struct SyncExpectation {
        // Inputs: measured raw NAVs + committed checkpoint
        NAV_UNIT stRawNew;
        NAV_UNIT jtRawNew;
        NAV_UNIT lastSTRaw;
        NAV_UNIT lastJTRaw;
        NAV_UNIT lastSTEff;
        NAV_UNIT lastJTEff;
        NAV_UNIT lastIL;
        // Inputs: the premium window (yield shares capped at the max* config, accumulators as stored)
        uint256 jtYieldShareWAD;
        uint256 ltYieldShareWAD;
        uint256 twJTStart;
        uint256 twLTStart;
        uint256 elapsed;
        uint256 premiumElapsed;
        // Inputs: fee rates and dust
        uint64 stFeeWAD;
        uint64 jtFeeWAD;
        uint64 jtYsFeeWAD;
        uint64 ltYsFeeWAD;
        NAV_UNIT effectiveDust;
        // Input: whether the resulting market state zeroes the LT premium and all fees
        bool fixedTermActive;
        // Outputs
        NAV_UNIT stEff;
        NAV_UNIT jtEff;
        NAV_UNIT il;
        NAV_UNIT ltPremium;
        NAV_UNIT stFee;
        NAV_UNIT jtFee;
        NAV_UNIT ltFee;
        NAV_UNIT jtRiskPremium;
        bool premiumsPaid;
    }

    /**
     * @notice Re-derives the full accountant waterfall from the spec, independently of production code.
     * @dev Mirrors `RoycoDayAccountant._previewSyncTrancheAccounting`: claim decomposition, floor-on-magnitude
     *      attribution with JT absorbing the rounding residual, JT loss/gain booking with the dust-gated JT fee,
     *      coverage `min(stLoss, jtEff)` with the JT-fee recompute, IL recovery `min(stGain, IL)`, premiums
     *      `floor(stGain * (twStart + yieldShare * elapsed) / (premiumElapsed * WAD))` — the time-weighted
     *      average yield share over the full window since the last premium payment, which reduces to
     *      `floor(stGain * yieldShare / WAD)` for a single constant-share window — with the same-block
     *      (`premiumElapsed == 0`) instantaneous-share path, fee floors, `premiumsPaid = stGain > dust` gating
     *      every fee, the LT premium folded back into stEff, and the FIXED_TERM zeroing of the LT premium plus
     *      all fees (but NOT the JT risk premium, which is already booked into jtEff).
     */
    function _expectedSync(SyncExpectation memory _e) internal pure returns (SyncExpectation memory) {
        uint256 stEff = toUint256(_e.lastSTEff);
        uint256 jtEff = toUint256(_e.lastJTEff);
        uint256 il = toUint256(_e.lastIL);
        uint256 dust = toUint256(_e.effectiveDust);

        // STEP_APPLY_PNL_ATTRIBUTION: decompose the checkpointed claims and attribute each raw delta
        int256 dStEff;
        int256 dJtEff;
        {
            uint256 lastSTRaw = toUint256(_e.lastSTRaw);
            uint256 lastJTRaw = toUint256(_e.lastJTRaw);
            uint256 stClaimOnJTRaw = stEff > lastSTRaw ? stEff - lastSTRaw : 0;
            uint256 jtClaimOnSTRaw = jtEff > lastJTRaw ? jtEff - lastJTRaw : 0;
            uint256 stClaimOnSTRaw = lastSTRaw - jtClaimOnSTRaw;
            int256 deltaSTRaw = int256(toUint256(_e.stRawNew)) - int256(lastSTRaw);
            int256 deltaJTRaw = int256(toUint256(_e.jtRawNew)) - int256(lastJTRaw);
            int256 dStOnSTRaw = lastSTRaw == 0 ? (stEff > 0 ? deltaSTRaw : int256(0)) : _attributeDelta(deltaSTRaw, stClaimOnSTRaw, lastSTRaw);
            int256 dStOnJTRaw = _attributeDelta(deltaJTRaw, stClaimOnJTRaw, lastJTRaw);
            dStEff = dStOnSTRaw + dStOnJTRaw;
            dJtEff = (deltaSTRaw + deltaJTRaw) - dStEff;
        }

        // STEP_APPLY_JT_LOSS / STEP_APPLY_JT_GAIN
        uint256 jtNetGain;
        uint256 jtFee;
        if (dJtEff < 0) {
            jtEff -= uint256(-dJtEff);
        } else if (dJtEff > 0) {
            jtNetGain = uint256(dJtEff);
            if (jtNetGain > dust) jtFee = Math.mulDiv(jtNetGain, _e.jtFeeWAD, WAD);
            jtEff += jtNetGain;
        }

        uint256 ltPremium;
        uint256 stFee;
        uint256 ltFee;
        uint256 jtRiskPremium;
        bool premiumsPaid;
        if (dStEff < 0) {
            // STEP_APPLY_JT_COVERAGE_TO_ST + STEP_ST_INCURS_RESIDUAL_LOSSES
            uint256 stLoss = uint256(-dStEff);
            uint256 coverageApplied = Math.min(stLoss, jtEff);
            if (coverageApplied != 0) {
                if (jtFee != 0) {
                    jtNetGain = jtNetGain > coverageApplied ? jtNetGain - coverageApplied : 0;
                    jtFee = jtNetGain > dust ? Math.mulDiv(jtNetGain, _e.jtFeeWAD, WAD) : 0;
                }
                jtEff -= coverageApplied;
                il += coverageApplied;
                stLoss -= coverageApplied;
            }
            if (stLoss != 0) stEff -= stLoss;
        } else if (dStEff > 0) {
            // STEP_JT_COVERAGE_IMPERMANENT_LOSS_RECOVERY + STEP_PAY_PREMIUMS
            uint256 stGain = uint256(dStEff);
            uint256 ilRecovery = Math.min(stGain, il);
            if (ilRecovery != 0) {
                il -= ilRecovery;
                jtEff += ilRecovery;
                stGain -= ilRecovery;
            }
            if (stGain != 0) {
                if (stGain > dust) premiumsPaid = true;
                (jtRiskPremium, ltPremium) = _expectedPremiums(_e, stGain);
                if (jtRiskPremium != 0) {
                    if (premiumsPaid) jtFee += Math.mulDiv(jtRiskPremium, _e.jtYsFeeWAD, WAD);
                    jtEff += jtRiskPremium;
                    stGain -= jtRiskPremium;
                }
                if (ltPremium != 0) {
                    if (premiumsPaid) ltFee = Math.mulDiv(ltPremium, _e.ltYsFeeWAD, WAD);
                    stGain -= ltPremium;
                }
                if (premiumsPaid) stFee = Math.mulDiv(stGain, _e.stFeeWAD, WAD);
                stEff += stGain + ltPremium;
            }
        }

        // A FIXED_TERM-resulting sync pays no LT premium and takes no fees
        if (_e.fixedTermActive) {
            ltPremium = 0;
            stFee = 0;
            jtFee = 0;
            ltFee = 0;
        }

        _e.stEff = toNAVUnits(stEff);
        _e.jtEff = toNAVUnits(jtEff);
        _e.il = toNAVUnits(il);
        _e.ltPremium = toNAVUnits(ltPremium);
        _e.stFee = toNAVUnits(stFee);
        _e.jtFee = toNAVUnits(jtFee);
        _e.ltFee = toNAVUnits(ltFee);
        _e.jtRiskPremium = toNAVUnits(jtRiskPremium);
        _e.premiumsPaid = premiumsPaid;
        return _e;
    }

    /**
     * @notice The JT risk and LT liquidity premiums for `_stGain`, from the full time-weighted accumulators
     *         at sync time averaged over the premium window.
     * @dev A same-block window (`premiumElapsed == 0`) uses the instantaneous shares over one second, exactly
     *      mirroring the accountant's `STEP_PAY_PREMIUMS` handling.
     */
    function _expectedPremiums(SyncExpectation memory _e, uint256 _stGain) internal pure returns (uint256 jtRiskPremium, uint256 ltPremium) {
        uint256 twJT = _e.twJTStart + _e.jtYieldShareWAD * _e.elapsed;
        uint256 twLT = _e.twLTStart + _e.ltYieldShareWAD * _e.elapsed;
        uint256 premiumElapsed = _e.premiumElapsed;
        if (premiumElapsed == 0) {
            premiumElapsed = 1;
            twJT = _e.jtYieldShareWAD;
            twLT = _e.ltYieldShareWAD;
        }
        jtRiskPremium = Math.mulDiv(_stGain, twJT, premiumElapsed * WAD);
        ltPremium = Math.mulDiv(_stGain, twLT, premiumElapsed * WAD);
    }

    /// @notice Floor-on-magnitude proportional attribution, mirroring `RoycoDayAccountant._attributeDeltaToClaimOnRawNAV`.
    function _attributeDelta(int256 _delta, uint256 _claimOnRaw, uint256 _lastRaw) internal pure returns (int256) {
        if (_delta == 0 || _claimOnRaw == 0 || _lastRaw == 0) return 0;
        uint256 absDelta = _delta < 0 ? uint256(-_delta) : uint256(_delta);
        uint256 attributedMagnitude = Math.mulDiv(absDelta, _claimOnRaw, _lastRaw);
        return _delta < 0 ? -int256(attributedMagnitude) : int256(attributedMagnitude);
    }

    /**
     * @notice Expected LT premium and ST fee share mints, both floor-priced against the retained senior NAV
     *         `(stEffPost - prem - fee)` at the pre-sync supply.
     * @dev Mirrors `FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint` (F11).
     */
    function _expectedPremiumShares(
        NAV_UNIT _prem,
        NAV_UNIT _fee,
        NAV_UNIT _stEffPost,
        uint256 _preSupply
    )
        internal
        pure
        returns (uint256 premShares, uint256 feeShares)
    {
        NAV_UNIT retainedSeniorNAV = toNAVUnits(toUint256(_stEffPost) - toUint256(_prem) - toUint256(_fee));
        premShares = _expectedShares(_prem, _preSupply, retainedSeniorNAV);
        feeShares = _expectedShares(_fee, _preSupply, retainedSeniorNAV);
    }

    // ── S1.5 Flow executors ──

    /// @notice Receipt returned by every flow executor: the pre/post snapshots plus the operation's outputs.
    struct OpReceipt {
        MarketSnapshot pre;
        MarketSnapshot post;
        uint256 shares;
        AssetClaims claims;
        uint256 quoteAssets;
    }

    /// @notice Executes an ST deposit for `_lp` with an exact approval, snapshotting around it.
    function _doDepositST(address _lp, uint256 _assets) internal returns (OpReceipt memory r) {
        r.pre = _snap(_actorArray(_lp));
        vm.startPrank(_lp);
        IERC20(testConfig.stAsset).approve(address(ST), _assets);
        r.shares = ST.deposit(toTrancheUnits(_assets), _lp);
        vm.stopPrank();
        r.post = _snap(_actorArray(_lp));
        _assertSolvency();
    }

    /// @notice Executes a JT deposit for `_lp` with an exact approval, snapshotting around it.
    function _doDepositJT(address _lp, uint256 _assets) internal returns (OpReceipt memory r) {
        r.pre = _snap(_actorArray(_lp));
        vm.startPrank(_lp);
        IERC20(testConfig.jtAsset).approve(address(JT), _assets);
        r.shares = JT.deposit(toTrancheUnits(_assets), _lp);
        vm.stopPrank();
        r.post = _snap(_actorArray(_lp));
        _assertSolvency();
    }

    /// @notice Executes an in-kind LT deposit of `_bptAssets` for `_lp`, snapshotting around it.
    function _doDepositLT(address _lp, uint256 _bptAssets) internal returns (OpReceipt memory r) {
        r.pre = _snap(_actorArray(_lp));
        vm.startPrank(_lp);
        IERC20(POOL).approve(address(LT), _bptAssets);
        r.shares = LT.deposit(toTrancheUnits(_bptAssets), _lp);
        vm.stopPrank();
        r.post = _snap(_actorArray(_lp));
        _assertSolvency();
    }

    /// @notice Executes a multi-asset LT deposit for `_lp` with exact approvals, snapshotting around it.
    function _doDepositLTMulti(address _lp, uint256 _stAssets, uint256 _quoteAssets, uint256 _minLTAssetsOut) internal returns (OpReceipt memory r) {
        r.pre = _snap(_actorArray(_lp));
        vm.startPrank(_lp);
        IERC20(testConfig.stAsset).approve(address(LT), _stAssets);
        IERC20(testConfig.quoteAsset).approve(address(LT), _quoteAssets);
        r.shares = IRoycoLiquidityTranche(address(LT)).depositMultiAsset(_stAssets, _quoteAssets, _minLTAssetsOut, _lp);
        vm.stopPrank();
        r.post = _snap(_actorArray(_lp));
        _assertSolvency();
    }

    /// @notice Executes an ST redemption of `_shares` for `_lp`, snapshotting around it.
    function _doRedeemST(address _lp, uint256 _shares) internal returns (OpReceipt memory r) {
        r.pre = _snap(_actorArray(_lp));
        vm.prank(_lp);
        r.claims = ST.redeem(_shares, _lp, _lp);
        r.post = _snap(_actorArray(_lp));
        _assertSolvency();
    }

    /// @notice Executes a JT redemption of `_shares` for `_lp`, snapshotting around it.
    function _doRedeemJT(address _lp, uint256 _shares) internal returns (OpReceipt memory r) {
        r.pre = _snap(_actorArray(_lp));
        vm.prank(_lp);
        r.claims = JT.redeem(_shares, _lp, _lp);
        r.post = _snap(_actorArray(_lp));
        _assertSolvency();
    }

    /// @notice Executes an in-kind LT redemption of `_shares` for `_lp`, snapshotting around it.
    function _doRedeemLT(address _lp, uint256 _shares) internal returns (OpReceipt memory r) {
        r.pre = _snap(_actorArray(_lp));
        vm.prank(_lp);
        r.claims = LT.redeem(_shares, _lp, _lp);
        r.post = _snap(_actorArray(_lp));
        _assertSolvency();
    }

    /// @notice Executes a multi-asset LT redemption of `_shares` for `_lp`, snapshotting around it.
    function _doRedeemLTMulti(address _lp, uint256 _shares, uint256 _minSTSharesOut, uint256 _minQuoteOut) internal returns (OpReceipt memory r) {
        r.pre = _snap(_actorArray(_lp));
        vm.prank(_lp);
        (r.claims, r.quoteAssets) = IRoycoLiquidityTranche(address(LT)).redeemMultiAsset(_shares, _minSTSharesOut, _minQuoteOut, _lp, _lp);
        r.post = _snap(_actorArray(_lp));
        _assertSolvency();
    }

    /// @dev Wraps a single actor into the array shape `_snap` takes.
    function _actorArray(address _actor) private pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = _actor;
    }

    // ── S1.6 Market staging helpers ──

    /// @notice Standard ST/JT seed: JT first (the coverage denominator), then ST sized under the coverage gate.
    function _seedMarket(uint256 _stAssets, uint256 _jtAssets) internal {
        _depositJT(JT_ALICE_ADDRESS, _jtAssets);
        _depositST(ST_ALICE_ADDRESS, _stAssets);
    }

    /**
     * @notice First LT entry via the multi-asset flow (the pool starts empty). Returns the LT shares minted.
     * @dev The quote amount must be sized in the quote asset's own decimals.
     * @dev The entry ramps geometrically: the venue bootstrap leaves only a dust-deep pool and Balancer bounds
     *      each unbalanced add's invariant growth (about 5x), so every chunk is capped at roughly 3x the
     *      current depth. The near-peg quote valuation here only sizes the chunks, never an assertion.
     */
    function _seedLT(address _lp, uint256 _stAssets, uint256 _quoteAssets) internal returns (uint256 shares) {
        _initializeLTVenueIfNeeded();
        uint256 quoteUnitScale = 10 ** IERC20Metadata(testConfig.quoteAsset).decimals();
        uint256 stAssetsRemaining = _stAssets;
        uint256 quoteAssetsRemaining = _quoteAssets;
        for (uint256 i = 0; i < 64 && (stAssetsRemaining != 0 || quoteAssetsRemaining != 0); ++i) {
            // The invariant-ratio bound is against the WHOLE pool, so depth is the full BPT supply's value
            uint256 depthValue = toUint256(KERNEL.ltConvertTrancheUnitsToNAVUnits(toTrancheUnits(IERC20(POOL).totalSupply())));
            uint256 remainingValue =
                toUint256(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(stAssetsRemaining))) + Math.mulDiv(quoteAssetsRemaining, 1e18, quoteUnitScale);
            uint256 stAssetsChunk = stAssetsRemaining;
            uint256 quoteAssetsChunk = quoteAssetsRemaining;
            uint256 maxChunkValue = 3 * depthValue;
            if (remainingValue > maxChunkValue) {
                stAssetsChunk = Math.mulDiv(stAssetsRemaining, maxChunkValue, remainingValue);
                quoteAssetsChunk = Math.mulDiv(quoteAssetsRemaining, maxChunkValue, remainingValue);
            }
            shares += _doDepositLTMulti(_lp, stAssetsChunk, quoteAssetsChunk, 0).shares;
            stAssetsRemaining -= stAssetsChunk;
            quoteAssetsRemaining -= quoteAssetsChunk;
        }
        if (stAssetsRemaining != 0 || quoteAssetsRemaining != 0) fail("_seedLT: could not fully seed the LT within the chunk budget");
    }

    /**
     * @dev One-time bootstrap of the LT's market-making venue, invoked by `_seedLT` before the first entry.
     *      Default no-op for venues that need none. The BalancerV3 family overrides this to initialize the
     *      freshly created pool through Balancer's canonical Router, because the repo ships no production
     *      initialization path for the pool (see the family override for the finding note).
     */
    function _initializeLTVenueIfNeeded() internal virtual { }

    /**
     * @notice Returns the raw NAV inputs the LAST sync committed (the measured post-simulate raws, D2).
     * @dev A live pre-sync `getRawNAV()` read can be stale against the transient quoter cache left populated
     *      by an earlier kernel op in the same test, while the sync itself re-caches the live rate. Measured
     *      deltas must therefore be read from the committed checkpoint right after the sync under test.
     */
    function _committedRawNAVs() internal view returns (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        return (a.lastSTRawNAV, a.lastJTRawNAV);
    }

    /// @notice Enables the LT overlay: `setMaxYieldShares(maxJT, maxLT)` then `setMinLiquidity(minLiq)`.
    function _enableLTOverlay(uint64 _maxJTShareWAD, uint64 _maxLTShareWAD, uint64 _minLiquidityWAD) internal {
        _executeAccountantAdminOperationFresh(abi.encodeCall(ACCOUNTANT.setMaxYieldShares, (_maxJTShareWAD, _maxLTShareWAD)));
        _executeAccountantAdminOperationFresh(abi.encodeCall(ACCOUNTANT.setMinLiquidity, (_minLiquidityWAD)));
    }

    /// @notice Sets the market's fixed term duration through the scheduled accountant admin path.
    function _setFixedTermDuration(uint24 _secs) internal {
        _executeAccountantAdminOperationFresh(abi.encodeCall(ACCOUNTANT.setFixedTermDuration, (_secs)));
    }

    /// @notice Sets the market's minimum liquidity requirement through the scheduled accountant admin path.
    function _setMinLiquidityWAD(uint64 _wad) internal {
        _executeAccountantAdminOperationFresh(abi.encodeCall(ACCOUNTANT.setMinLiquidity, (_wad)));
    }

    /// @notice Establishes a nonzero senior self-liquidation bonus when the deployed market config ships zero.
    /// @dev The setter is bound to the delay-0 kernel admin role, so no scheduling is needed.
    function _ensureSelfLiquidationBonusConfigured() internal {
        if (KERNEL.getState().stSelfLiquidationBonusWAD != 0) return;
        vm.prank(KERNEL_ADMIN_ADDRESS);
        KERNEL.setSeniorTrancheSelfLiquidationBonus(0.005e18);
    }

    /// @notice Raises ST's dust tolerance via the delay-0 market ops role (held by the kernel admin wallet).
    function _raiseSTDustTolerance(NAV_UNIT _tol) internal {
        vm.prank(KERNEL_ADMIN_ADDRESS);
        ACCOUNTANT.setSeniorTrancheDustTolerance(_tol);
    }

    /**
     * @dev Schedules and executes an accountant admin operation, re-stamping the oracles after the schedule
     *      delay warp so the setter's inline `withSyncedAccounting` sync quotes a fresh (non-stale) oracle.
     *      This is the S1 replacement for BaseTest's `_executeAccountantAdminOperation`, whose warp would
     *      otherwise leave a Chainlink-family feed stale at execute time (D5).
     */
    function _executeAccountantAdminOperationFresh(bytes memory _data) internal {
        _scheduleAccountantOperation(_data);
        _executeScheduledAccountantOperation(_data);
    }

    /**
     * @notice Warps forward by `_secs`, re-stamping the oracles both sides of the warp. The ONLY sanctioned warp call in tests.
     * @dev The pre-warp refresh seeds a lazily-mocked oracle from its still-fresh live feed, because a stale
     *      live feed can refuse to answer the seeding read after the warp.
     */
    function _warpForward(uint256 _secs) internal {
        _refreshOraclesAfterWarp();
        vm.warp(block.timestamp + _secs);
        _refreshOraclesAfterWarp();
    }

    /// @notice Applies ST yield through the hook, warping first when `_requiresTimeWarpForYield()`.
    function _applySTYield(uint256 _pctWAD) internal {
        if (_requiresTimeWarpForYield()) _warpForward(1 days);
        simulateSTYield(_pctWAD);
    }

    /// @notice Applies an ST loss through the hook, warping first when `_requiresTimeWarpForYield()`.
    function _applySTLoss(uint256 _pctWAD) internal {
        if (_requiresTimeWarpForYield()) _warpForward(1 days);
        simulateSTLoss(_pctWAD);
    }

    /// @notice Applies JT yield through the hook, warping first when `_requiresTimeWarpForYield()`.
    function _applyJTYield(uint256 _pctWAD) internal {
        if (_requiresTimeWarpForYield()) _warpForward(1 days);
        simulateJTYield(_pctWAD);
    }

    /// @notice Applies a JT loss through the hook, warping first when `_requiresTimeWarpForYield()`.
    function _applyJTLoss(uint256 _pctWAD) internal {
        if (_requiresTimeWarpForYield()) _warpForward(1 days);
        simulateJTLoss(_pctWAD);
    }

    /// @notice Drives `covUtil >= coverageLiquidationUtilizationWAD` via measured-loss iteration, syncing each step.
    /// @dev Fails the test (never silently gives up) if the threshold is not reached within the iteration bound.
    function _breachLiquidation() internal {
        bool coinvested = ACCOUNTANT.JT_COINVESTED();
        for (uint256 i = 0; i < 60; ++i) {
            _applySTLoss(0.05e18);
            _sync();
            IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
            uint256 covUtilWAD = _expectedCovUtil(a.lastSTRawNAV, a.lastJTRawNAV, coinvested, a.minCoverageWAD, a.lastJTEffectiveNAV);
            if (covUtilWAD >= a.coverageLiquidationUtilizationWAD) return;
        }
        fail("_breachLiquidation: liquidation coverage utilization threshold not reached");
    }

    /// @notice Enters FIXED_TERM: nonzero duration, a covered loss (below jtEff), then a sync, with an arrange-guard.
    function _enterFixedTerm() internal {
        _setFixedTermDuration(7 days);
        _applySTLoss(0.02e18);
        _sync();
        assertTrue(ACCOUNTANT.getState().lastMarketState == MarketState.FIXED_TERM, "arrange: market must be in a fixed term state");
    }

    /// @notice Stages idle premium: reinvest gate forced shut, warp, yield, sync. Returns the idle ST share balance.
    /// @dev Skips the test when the venue exposes no reinvestment slippage seam (capability gate, D7).
    function _stageIdlePremium() internal returns (uint256 idleShares) {
        vm.skip(!_trySetReinvestmentSlippage(0));
        _sync();
        _warpForward(1 days);
        _applySTYield(0.05e18);
        _sync();
        idleShares = KERNEL.getState().ltOwnedSeniorTrancheShares;
        assertGt(idleShares, 0, "arrange: no liquidity premium ST shares were staged");
    }

    // ── S1.7 Preview + pause + blacklist utilities ──

    /**
     * @notice Simulates the non-view LT multi-asset deposit preview through the venue's query mode.
     * @dev Executed as a regular call pranked to a zero tx.origin (Balancer V3's off-chain query context, the
     *      same pattern Balancer's own test base uses), wrapped in a state snapshot so no query-mode side
     *      effect can leak into the test. A revert is re-raised after the state rollback.
     */
    function _previewDepositLTMulti(uint256 _stAssets, uint256 _quoteAssets) internal returns (uint256 shares) {
        uint256 snapshotId = vm.snapshotState();
        vm.prank(address(0), address(0));
        (bool ok, bytes memory ret) = address(LT).call(abi.encodeCall(IRoycoLiquidityTranche.previewDepositMultiAsset, (_stAssets, _quoteAssets)));
        vm.revertToState(snapshotId);
        if (!ok) _bubbleRevert(ret);
        shares = abi.decode(ret, (uint256));
    }

    /**
     * @notice Simulates the non-view LT multi-asset redemption preview through the venue's query mode.
     * @dev Executed as a regular call pranked to a zero tx.origin (Balancer V3's off-chain query context, the
     *      same pattern Balancer's own test base uses), wrapped in a state snapshot so no query-mode side
     *      effect can leak into the test. A revert is re-raised after the state rollback.
     */
    function _previewRedeemLTMulti(uint256 _shares) internal returns (AssetClaims memory stClaims, uint256 quoteAssets) {
        uint256 snapshotId = vm.snapshotState();
        vm.prank(address(0), address(0));
        (bool ok, bytes memory ret) = address(LT).call(abi.encodeCall(IRoycoLiquidityTranche.previewRedeemMultiAsset, (_shares)));
        vm.revertToState(snapshotId);
        if (!ok) _bubbleRevert(ret);
        (stClaims, quoteAssets) = abi.decode(ret, (AssetClaims, uint256));
    }

    /// @dev Re-raises a failed call's revert data so the caller's `vm.expectRevert` sees the inner error.
    function _bubbleRevert(bytes memory _returnData) internal pure {
        assembly ("memory-safe") {
            revert(add(_returnData, 0x20), mload(_returnData))
        }
    }

    /// @notice Pauses the kernel via the delay-0 pauser role. Every tranche flow routes through the kernel, so this pauses the market.
    function _pauseKernel() internal {
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(KERNEL)).pause();
    }

    /// @notice Unpauses the kernel via the unpauser role, scheduling through the AccessManager when the role carries a delay.
    function _unpauseKernel() internal {
        (, uint32 delay) = ACCESS_MANAGER.hasRole(ADMIN_UNPAUSER_ROLE, UNPAUSER_ADDRESS);
        if (delay == 0) {
            vm.prank(UNPAUSER_ADDRESS);
            IRoycoAuth(address(KERNEL)).unpause();
        } else {
            bytes memory data = abi.encodeCall(IRoycoAuth.unpause, ());
            vm.prank(UNPAUSER_ADDRESS);
            ACCESS_MANAGER.schedule(address(KERNEL), data, 0);
            _warpForward(uint256(delay) + 1);
            vm.prank(UNPAUSER_ADDRESS);
            ACCESS_MANAGER.execute(address(KERNEL), data);
        }
    }

    /// @notice Blacklists `_account` on the market's shared blacklist via the AccessManager admin.
    /// @dev The blacklist's restricted selectors are unbound, so they resolve to the AccessManager ADMIN_ROLE holder.
    function _blacklist(address _account) internal {
        (bool ownerIsAdmin,) = ACCESS_MANAGER.hasRole(0, OWNER_ADDRESS);
        address admin = ownerIsAdmin ? OWNER_ADDRESS : 0x7c405bbD131e42af506d14e752f2e59B19D49997;
        address[] memory accounts = new address[](1);
        accounts[0] = _account;
        vm.prank(admin);
        BLACKLIST.blacklistAccounts(accounts);
    }

    // ── S1.8 Event helpers ──

    /// @notice Expects an exact-args `Deposit` event on the specified tranche.
    function _expectDeposit(address _tranche, address _sender, address _receiver, TRANCHE_UNIT _assets, uint256 _shares) internal {
        vm.expectEmit(true, true, false, true, _tranche);
        emit IRoycoVaultTranche.Deposit(_sender, _receiver, _assets, _shares);
    }

    /// @notice Expects an exact-args `Redeem` event on the specified tranche, with every claims field independently computed.
    function _expectRedeem(address _tranche, address _sender, address _receiver, AssetClaims memory _claims, uint256 _shares) internal {
        vm.expectEmit(true, true, false, true, _tranche);
        emit IRoycoVaultTranche.Redeem(_sender, _receiver, _claims, _shares);
    }

    // ── S1.9 New virtual seams (safe defaults, per-family overrides allowed) ──

    /// @notice The venue's oracle-staleness error selector, or `bytes4(0)` when staleness is not testable here.
    function _oracleStalenessSelector() internal virtual returns (bytes4) {
        return bytes4(0);
    }

    /**
     * @notice Attempts to set the venue's liquidity-premium reinvestment slippage gate, returning whether the
     *         setter exists and succeeded. `0` forces the gate shut (premium stays idle) and `WAD - 1`
     *         effectively always opens it.
     * @dev Only a missing selector (an empty-data revert on a kernel without the seam) reads as "capability
     *      absent" and lets callers skip. A revert WITH data means the seam exists but is broken (for example
     *      a wrong role binding), which fails the test loudly instead of silently skipping the premium battery.
     */
    function _trySetReinvestmentSlippage(uint64 _slippageWAD) internal virtual returns (bool ok) {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        bytes memory returnData;
        (ok, returnData) = address(KERNEL).call(abi.encodeWithSignature("setMaxReinvestmentSlippage(uint64)", _slippageWAD));
        if (!ok && returnData.length != 0) fail("the reinvestment slippage seam exists but its setter reverted");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S2 — DEPOSIT BATTERY
    // ═══════════════════════════════════════════════════════════════════════════

    // ── S2.0 Section-local helpers ──

    /**
     * @notice Measures the fresh post-simulate sync inputs (committed raw NAVs and the deposit valuation) under a
     *         reverted state snapshot, so a pending oracle move is read at the rate execution will actually use.
     * @dev A live pre-sync `getRawNAV()` view is stale against the transient quoter cache left by an earlier kernel
     *      op in the same test transaction, so the raws are read from the checkpoint a throwaway sync commits and
     *      the whole probe is rolled back. Raw NAVs and quoter conversions are waterfall INPUTS (testing-strategy
     *      D2), so this read is not circular with any assertion.
     */
    function _measureFreshSyncInputs(TRANCHE_UNIT _stAssets) internal returns (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, NAV_UNIT stValue) {
        uint256 snapshotId = vm.snapshotState();
        _sync();
        (stRawNAV, jtRawNAV) = _committedRawNAVs();
        stValue = KERNEL.stConvertTrancheUnitsToNAVUnits(_stAssets);
        vm.revertToState(snapshotId);
    }

    /**
     * @notice Simulates the kernel's non-view LT multi-asset deposit preview through the venue's query mode.
     * @dev Same query-context and state-rollback pattern as `_previewDepositLTMulti`, but against the kernel
     *      surface so the previewed `ltAssetsOut` (the venue add's mint) is observable for event expectations.
     */
    function _previewKernelDepositLTMulti(
        uint256 _stAssets,
        uint256 _quoteAssets
    )
        internal
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt, TRANCHE_UNIT ltAssetsOut, uint256 ltTotalSupplyAfterMints)
    {
        uint256 snapshotId = vm.snapshotState();
        vm.prank(address(0), address(0));
        (bool ok, bytes memory ret) =
            address(KERNEL).call(abi.encodeCall(IRoycoDayKernel.ltPreviewDepositMultiAsset, (toTrancheUnits(_stAssets), _quoteAssets)));
        vm.revertToState(snapshotId);
        if (!ok) _bubbleRevert(ret);
        (valueAllocated, navToMintSharesAt, ltAssetsOut, ltTotalSupplyAfterMints) = abi.decode(ret, (NAV_UNIT, NAV_UNIT, TRANCHE_UNIT, uint256));
    }

    /// @notice Sizes a quote-asset amount whose near-peg value approximates `_value` (one whole quote token per WAD of NAV).
    /// @dev Sizing only, mirroring `_seedLT`'s near-peg valuation, never an assertion input.
    function _quoteAssetsForValue(NAV_UNIT _value) internal view returns (uint256 quoteAssets) {
        return Math.mulDiv(toUint256(_value), 10 ** IERC20Metadata(testConfig.quoteAsset).decimals(), WAD);
    }

    /// @notice Seeds the LT with a value-matched two-leg entry: `_stLegAssets` of the ST asset plus a near-peg quote leg of equal value.
    function _seedLTBalanced(address _lp, uint256 _stLegAssets) internal returns (uint256 shares) {
        return _seedLT(_lp, _stLegAssets, _quoteAssetsForValue(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(_stLegAssets))));
    }

    /// @notice Seeds the LT with a market-scaled two-leg entry: an ST leg of `initialFunding / 100` and a value-matched quote leg.
    function _seedDefaultLT() internal {
        _setupLTProviders();
        _seedLTBalanced(LT_ALICE_ADDRESS, testConfig.initialFunding / 100);
    }

    /**
     * @notice Derives the `minLiquidityWAD` that puts the committed liquidity utilization at `_targetUtilWAD`.
     * @dev Callers must have synced in the same block so the committed checkpoint is fresh. The narrowing cast
     *      is guarded, since a pool deeper than about twenty times the senior tranche would otherwise truncate
     *      the requirement silently into an arbitrary value.
     */
    function _minLiquidityForTargetUtil(uint256 _targetUtilWAD) internal view returns (uint64 minLiquidityWAD) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 requirementWAD = Math.mulDiv(_targetUtilWAD, toUint256(a.lastLTRawNAV), toUint256(a.lastSTEffectiveNAV));
        assertGt(requirementWAD, 0, "arrange: the computed minimum liquidity must be nonzero");
        assertLe(requirementWAD, uint256(type(uint64).max), "arrange: the computed minimum liquidity must fit uint64");
        minLiquidityWAD = uint64(requirementWAD);
    }

    /// @notice Arrange guard asserting that removing `_shares`' proportional BPT slice from the committed mark
    ///         would push the liquidity utilization above WAD.
    function _assertSliceWouldBreachLiquidity(uint256 _shares, uint64 _minLiquidityWAD, MarketSnapshot memory _pre) internal view {
        uint256 sliceValue = Math.mulDiv(toUint256(_pre.lastLTRaw), _shares, LT.totalSupply());
        assertGt(
            _expectedLiqUtil(_pre.lastSTEff, _minLiquidityWAD, toNAVUnits(toUint256(_pre.lastLTRaw) - sliceValue)),
            WAD,
            "arrange: the redemption must breach the liquidity requirement"
        );
    }

    /**
     * @notice Senior-deposit slack (in ST tranche units) whose addition to `stMaxDeposit` guarantees a coverage breach.
     * @dev Derivation (testing-strategy F15): `maxSTDeposit` under-reports the true breach boundary by exactly the
     *      two raw-NAV dust tolerances, so a deposit must exceed it by more than `stDust + jtDust` in NAV to
     *      guarantee `covUtil > WAD`. Each quoter conversion floors (up to one NAV-per-tranche-unit of error in
     *      each of the three conversions involved), so the dust sum is converted to tranche units, doubled, and
     *      padded by six tranche-unit wei to strictly dominate the floor drift and the boundary itself.
     */
    function _stMaxDepositBreachSlackAssets() internal view returns (uint256 slackAssets) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        slackAssets = 2 * toUint256(KERNEL.stConvertNAVUnitsToTrancheUnits(a.stNAVDustTolerance + a.jtNAVDustTolerance)) + 6;
    }

    /// @notice Asserts that a fresh snapshot matches `_pre` on every supply, ledger, checkpoint, and balance field (atomicity check).
    function _assertMarketUnchanged(MarketSnapshot memory _pre) internal view {
        MarketSnapshot memory post = _snap();
        assertEq(post.stSupply, _pre.stSupply, "atomicity: ST supply moved");
        assertEq(post.jtSupply, _pre.jtSupply, "atomicity: JT supply moved");
        assertEq(post.ltSupply, _pre.ltSupply, "atomicity: LT supply moved");
        assertEq(post.stOwned, _pre.stOwned, "atomicity: stOwned moved");
        assertEq(post.jtOwned, _pre.jtOwned, "atomicity: jtOwned moved");
        assertEq(post.ltOwned, _pre.ltOwned, "atomicity: ltOwned moved");
        assertEq(post.idleSTShares, _pre.idleSTShares, "atomicity: idle premium shares moved");
        assertEq(post.lastSTRaw, _pre.lastSTRaw, "atomicity: committed ST raw NAV moved");
        assertEq(post.lastJTRaw, _pre.lastJTRaw, "atomicity: committed JT raw NAV moved");
        assertEq(post.lastLTRaw, _pre.lastLTRaw, "atomicity: committed LT raw NAV moved");
        assertEq(post.lastSTEff, _pre.lastSTEff, "atomicity: committed ST effective NAV moved");
        assertEq(post.lastJTEff, _pre.lastJTEff, "atomicity: committed JT effective NAV moved");
        assertEq(post.lastIL, _pre.lastIL, "atomicity: committed JT coverage IL moved");
        assertTrue(post.marketState == _pre.marketState, "atomicity: market state moved");
        assertEq(post.kernelSTAssetBal, _pre.kernelSTAssetBal, "atomicity: kernel ST asset balance moved");
        assertEq(post.kernelJTAssetBal, _pre.kernelJTAssetBal, "atomicity: kernel JT asset balance moved");
        assertEq(post.kernelBPTBal, _pre.kernelBPTBal, "atomicity: kernel BPT balance moved");
        assertEq(post.kernelSTShareBal, _pre.kernelSTShareBal, "atomicity: kernel ST share balance moved");
        assertEq(post.feeRecipientSTShares, _pre.feeRecipientSTShares, "atomicity: fee recipient ST shares moved");
        assertEq(post.feeRecipientJTShares, _pre.feeRecipientJTShares, "atomicity: fee recipient JT shares moved");
        assertEq(post.feeRecipientLTShares, _pre.feeRecipientLTShares, "atomicity: fee recipient LT shares moved");
    }

    // ── S2.1 ST/JT first deposits ──

    /**
     * @notice A first JT deposit mints shares 1:1 with the deposited value and commits `jtRaw == jtEff` exactly.
     * @dev The deposited value is captured through the quoter before the first kernel op of the test, so it is the
     *      same live rate the deposit's own quoter cache resolves (D6).
     */
    function test_JTDeposit_firstDeposit_mintsSharesOneToOne() public {
        uint256 assets = testConfig.initialFunding / 10;
        NAV_UNIT value = KERNEL.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets));
        assertGt(toUint256(value), 0, "arrange: the deposit value must be nonzero");
        MarketSnapshot memory pre = _snap();

        vm.startPrank(JT_ALICE_ADDRESS);
        IERC20(testConfig.jtAsset).approve(address(JT), assets);
        _expectDeposit(address(JT), JT_ALICE_ADDRESS, JT_ALICE_ADDRESS, toTrancheUnits(assets), toUint256(value));
        uint256 shares = JT.deposit(toTrancheUnits(assets), JT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        MarketSnapshot memory post = _snap();
        assertEq(shares, toUint256(value), "first JT mint must be 1:1 with the deposited value");
        assertEq(JT.balanceOf(JT_ALICE_ADDRESS), shares, "receiver JT share balance");
        assertEq(post.jtOwned, pre.jtOwned + toTrancheUnits(assets), "jtOwned must grow by the deposited assets");
        assertEq(post.jtSupply, pre.jtSupply + shares, "JT supply must grow by exactly the minted shares");
        assertEq(post.lastJTRaw, value, "committed JT raw NAV must equal the deposited value");
        assertEq(post.lastJTEff, post.lastJTRaw, "committed JT effective NAV must equal its raw NAV");
        assertEq(post.lastSTRaw, ZERO_NAV_UNITS, "committed ST raw NAV must stay zero");
        assertEq(post.lastSTEff, ZERO_NAV_UNITS, "committed ST effective NAV must stay zero");
        // With jtRaw == jtEff the coinvested coverage utilization is exactly minCoverage, and zero without coinvestment
        // The production value is read via a same-block flat sync (a no-op on the committed state), never recomputed by the suite
        uint256 expectedCovUtilWAD = ACCOUNTANT.JT_COINVESTED() ? uint256(ACCOUNTANT.getState().minCoverageWAD) : 0;
        assertEq(_syncWithState().coverageUtilizationWAD, expectedCovUtilWAD, "production coverage utilization of a JT-only market");
        _assertCommittedConservation();
    }

    /// @notice A first ST deposit mints shares 1:1 with the deposited value and lands the independently computed
    ///         coverage utilization.
    function test_STDeposit_firstDeposit_mintsSharesOneToOne() public {
        _depositJT(JT_ALICE_ADDRESS, testConfig.initialFunding / 10);
        // Size the entry from the live coverage headroom so the arrange holds for any configured minimum coverage
        uint256 assets = Math.min((testConfig.initialFunding / 10) * 4, toUint256(ST.maxDeposit(ST_ALICE_ADDRESS)) / 2);
        NAV_UNIT value = KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets));
        MarketSnapshot memory pre = _snap();
        uint256 expectedCovUtilWAD =
            _expectedCovUtil(pre.lastSTRaw + value, pre.lastJTRaw, ACCOUNTANT.JT_COINVESTED(), ACCOUNTANT.getState().minCoverageWAD, pre.lastJTEff);
        assertLe(expectedCovUtilWAD, WAD, "arrange: the deposit must satisfy coverage");

        vm.startPrank(ST_ALICE_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), assets);
        _expectDeposit(address(ST), ST_ALICE_ADDRESS, ST_ALICE_ADDRESS, toTrancheUnits(assets), toUint256(value));
        uint256 shares = ST.deposit(toTrancheUnits(assets), ST_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        MarketSnapshot memory post = _snap();
        assertEq(shares, toUint256(value), "first ST mint must be 1:1 with the deposited value");
        assertEq(ST.balanceOf(ST_ALICE_ADDRESS), shares, "receiver ST share balance");
        assertEq(post.stOwned, pre.stOwned + toTrancheUnits(assets), "stOwned must grow by the deposited assets");
        assertEq(post.stSupply, pre.stSupply + shares, "ST supply must grow by exactly the minted shares");
        assertEq(post.lastSTRaw, value, "committed ST raw NAV must equal the deposited value");
        assertEq(post.lastSTEff, value, "committed ST effective NAV must equal the deposited value");
        assertEq(post.lastJTRaw, pre.lastJTRaw, "the junior raw NAV must be untouched");
        assertEq(post.lastJTEff, pre.lastJTEff, "the junior effective NAV must be untouched");
        // The production value is read via a same-block flat sync (a no-op on the committed state), never recomputed by the suite
        assertEq(_syncWithState().coverageUtilizationWAD, expectedCovUtilWAD, "production coverage utilization must match the independent recompute");
        _assertCommittedConservation();
    }

    // ── S2.2 ST deposit pricing, previews, and gates ──

    /// @notice After committed yield an ST deposit mints exactly `floor(value * supply / stEff)` shares and the
    ///         post-op checkpoint books exactly the measured raw-NAV delta into the senior effective NAV.
    function test_STDeposit_exactSharePricing_afterYield() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applySTYield(0.05e18);
        _sync();

        uint256 assets = testConfig.initialFunding / 10;
        NAV_UNIT value = KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets));
        uint256 stSupply = ST.totalSupply();
        NAV_UNIT stEff = ACCOUNTANT.getState().lastSTEffectiveNAV;
        uint256 expectedShares = _expectedShares(value, stSupply, stEff);
        MarketSnapshot memory pre = _snap();

        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), assets);
        _expectDeposit(address(ST), ST_BOB_ADDRESS, ST_BOB_ADDRESS, toTrancheUnits(assets), expectedShares);
        uint256 shares = ST.deposit(toTrancheUnits(assets), ST_BOB_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        MarketSnapshot memory post = _snap();
        assertEq(shares, expectedShares, "deposit shares must match the independent floor pricing exactly");
        NAV_UNIT measuredRawDelta = post.lastSTRaw - pre.lastSTRaw;
        assertEq(post.lastSTEff, pre.lastSTEff + measuredRawDelta, "post ST effective NAV must grow by exactly the measured raw delta");
        assertApproxEqAbs(measuredRawDelta, value, maxNAVDelta(), "the raw delta must round-trip the deposited value through the quoter");
        assertEq(post.stSupply, pre.stSupply + shares, "no fee mint may accompany a same-block deposit");
        assertEq(post.stOwned, pre.stOwned + toTrancheUnits(assets), "stOwned must grow by the deposited assets");
        assertEq(post.lastJTRaw, pre.lastJTRaw, "the junior raw NAV must be untouched");
        assertEq(post.lastJTEff, pre.lastJTEff, "the junior effective NAV must be untouched");
        _assertCommittedConservation();
    }

    /**
     * @notice `previewDeposit` equals the executed deposit exactly in the same block, at a non-1:1 share price after
     *         a warped accrual window.
     * @dev The final `_sync()` commits the window's rate drift so preview and execution price off one rate: in a
     *      single-transaction test the quoter's transient cache makes an uncommitted rate move invisible to view
     *      previews while execution re-caches live, so a pending-PnL parity is structurally unobservable here. The
     *      pending-PnL deposit pricing itself is pinned independently in `test_STDeposit_emitsDepositEvent` via the
     *      full waterfall recomputation.
     */
    function test_STDeposit_previewParity() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applySTYield(0.04e18);
        _sync();
        _warpForward(1 days);
        _sync();

        uint256 assets = testConfig.initialFunding / 20;
        (, NAV_UNIT valueAllocated,) = KERNEL.stPreviewDeposit(toTrancheUnits(assets));
        uint256 previewShares = ST.previewDeposit(toTrancheUnits(assets));
        OpReceipt memory r = _doDepositST(ST_BOB_ADDRESS, assets);

        assertEq(r.shares, previewShares, "previewDeposit must equal the executed deposit exactly");
        assertApproxEqAbs(r.post.lastSTRaw - r.pre.lastSTRaw, valueAllocated, maxNAVDelta(), "the previewed valueAllocated must match the deposited raw delta");
        assertEq(r.post.stSupply, r.pre.stSupply + r.shares, "supply must grow by exactly the minted shares");
        _assertCommittedConservation();
    }

    /// @notice A zero-asset ST deposit reverts with the accountant's exact-arg `INVALID_POST_OP_STATE(ST_DEPOSIT)`.
    /// @dev The post-op sync's `deltaSTRawNAV > 0` requirement fires before the tranche's `INVALID_VALUE_ALLOCATED` check can.
    function test_STDeposit_reverts_zeroAssets() public {
        vm.prank(ST_ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        ST.deposit(ZERO_TRANCHE_UNITS, ST_ALICE_ADDRESS);
    }

    /// @notice An ST deposit to the zero receiver reverts with the exact OZ `ERC20InvalidReceiver` error.
    function test_STDeposit_reverts_zeroReceiver() public {
        uint256 assets = testConfig.initialFunding / 10;
        vm.prank(ST_ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        ST.deposit(toTrancheUnits(assets), address(0));
    }

    /// @notice While the kernel is paused an ST deposit reverts with `EnforcedPause`, `maxDeposit` reports zero, and
    ///         the market resumes after unpause.
    function test_STDeposit_reverts_whenPaused() public {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 10);
        _pauseKernel();
        assertEq(ST.maxDeposit(ST_ALICE_ADDRESS), ZERO_TRANCHE_UNITS, "maxDeposit must report zero while paused");

        uint256 assets = testConfig.initialFunding / 100;
        vm.startPrank(ST_ALICE_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), assets);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        ST.deposit(toTrancheUnits(assets), ST_ALICE_ADDRESS);
        vm.stopPrank();

        _unpauseKernel();
        assertGt(_doDepositST(ST_ALICE_ADDRESS, assets).shares, 0, "the market must resume after unpause");
        _assertCommittedConservation();
    }

    /// @notice In a fixed-term market an ST deposit reverts with `DISABLED_IN_FIXED_TERM_STATE` and `maxDeposit` reports zero.
    function test_STDeposit_reverts_inFixedTerm() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _enterFixedTerm();
        assertEq(ST.maxDeposit(ST_BOB_ADDRESS), ZERO_TRANCHE_UNITS, "stMaxDeposit must report zero in a fixed term");

        uint256 assets = testConfig.initialFunding / 100;
        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), assets);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        ST.deposit(toTrancheUnits(assets), ST_BOB_ADDRESS);
        vm.stopPrank();
    }

    /// @notice An ST deposit past `maxDeposit` plus the documented dust slack reverts with `COVERAGE_REQUIREMENT_VIOLATED`.
    function test_STDeposit_reverts_coverageBreach() public {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 20);
        _sync();
        TRANCHE_UNIT maxAssets = ST.maxDeposit(ST_BOB_ADDRESS);
        assertGt(maxAssets, ZERO_TRANCHE_UNITS, "arrange: the coverage headroom must be nonzero");
        assertLt(maxAssets, MAX_TRANCHE_UNITS, "arrange: coverage must bound the deposit");
        MarketSnapshot memory pre = _snap();

        uint256 breachAssets = toUint256(maxAssets) + _stMaxDepositBreachSlackAssets();
        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), breachAssets);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        ST.deposit(toTrancheUnits(breachAssets), ST_BOB_ADDRESS);
        vm.stopPrank();
        _assertMarketUnchanged(pre);
    }

    /**
     * @notice A senior deposit that satisfies coverage but overruns the market's minimum-liquidity requirement
     *         reverts with `LIQUIDITY_REQUIREMENT_VIOLATED`.
     * @dev Pins that senior deposits ARE liquidity-gated, contra the CLAUDE.md prose (testing-strategy Appendix B.1).
     */
    function test_STDeposit_reverts_liquidityBreach() public whenLT {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 2);
        _seedDefaultLT();
        _setMinLiquidityWAD(0.1e18);
        _sync();
        MarketSnapshot memory pre = _snap();
        assertLe(pre.liqUtilWAD, WAD, "arrange: liquidity must start satisfied");

        uint256 assets = (testConfig.initialFunding / 10) * 3;
        NAV_UNIT value = KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets));
        assertGt(_expectedLiqUtil(pre.lastSTEff + value, 0.1e18, pre.lastLTRaw), WAD, "arrange: the deposit must breach the liquidity requirement");
        assertLe(
            _expectedCovUtil(pre.lastSTRaw + value, pre.lastJTRaw, ACCOUNTANT.JT_COINVESTED(), ACCOUNTANT.getState().minCoverageWAD, pre.lastJTEff),
            WAD,
            "arrange: coverage must not be the binding gate"
        );

        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), assets);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        ST.deposit(toTrancheUnits(assets), ST_BOB_ADDRESS);
        vm.stopPrank();
        _assertMarketUnchanged(pre);
    }

    /// @notice `stMaxDeposit` inverts the coverage gate: a max-size deposit lands under it and the same deposit plus
    ///         the documented dust slack reverts.
    function test_STDeposit_maxDepositInversion() public {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 20);
        _sync();
        TRANCHE_UNIT maxAssets = ST.maxDeposit(ST_BOB_ADDRESS);
        assertGt(maxAssets, ZERO_TRANCHE_UNITS, "arrange: the coverage headroom must be nonzero");
        assertLt(maxAssets, MAX_TRANCHE_UNITS, "arrange: coverage must bound the deposit");

        uint256 snapshotId = vm.snapshotState();
        OpReceipt memory r = _doDepositST(ST_BOB_ADDRESS, toUint256(maxAssets));
        assertGt(r.shares, 0, "the max-size deposit must mint shares");
        assertLe(r.post.covUtilWAD, WAD, "a max-size deposit must leave coverage satisfied");
        _assertCommittedConservation();
        vm.revertToState(snapshotId);

        uint256 breachAssets = toUint256(maxAssets) + _stMaxDepositBreachSlackAssets();
        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), breachAssets);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        ST.deposit(toTrancheUnits(breachAssets), ST_BOB_ADDRESS);
        vm.stopPrank();
    }

    /**
     * @notice With a nonzero minimum liquidity whose headroom undercuts the coverage headroom, `stMaxDeposit`
     *         reports the liquidity-leg F15 recompute: the max-size deposit lands under the gate and the same
     *         deposit plus the documented slack reverts with `LIQUIDITY_REQUIREMENT_VIOLATED`.
     * @dev The liquidity leg mirrors `RoycoDayAccountant.maxSTDeposit`: `floor(ltRaw * WAD / minLiquidity) -
     *      stEff - stDust`. The coverage-derived breach slack strictly dominates the liquidity boundary's
     *      under-report (the single ST dust tolerance plus conversion floors), so it is reused.
     */
    function test_STDeposit_maxDepositInversion_liquidityBound() public whenLT {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 2);
        _seedDefaultLT();
        _setMinLiquidityWAD(_minLiquidityForTargetUtil(0.5e18));
        _sync();

        // Independent two-leg recompute with the liquidity leg binding
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 liquidityHeadroomValue = Math.mulDiv(toUint256(a.lastLTRawNAV), WAD, a.minLiquidityWAD) - toUint256(a.lastSTEffectiveNAV)
            - toUint256(a.stNAVDustTolerance);
        uint256 coverageHeadroomValue = Math.mulDiv(toUint256(a.lastJTEffectiveNAV), WAD, a.minCoverageWAD)
            - ((ACCOUNTANT.JT_COINVESTED() ? toUint256(a.lastJTRawNAV) : 0) + toUint256(a.jtNAVDustTolerance))
            - (toUint256(a.lastSTRawNAV) + toUint256(a.stNAVDustTolerance));
        assertLt(liquidityHeadroomValue, coverageHeadroomValue, "arrange: liquidity must be the binding leg");
        TRANCHE_UNIT maxAssets = ST.maxDeposit(ST_BOB_ADDRESS);
        assertEq(
            maxAssets,
            KERNEL.stConvertNAVUnitsToTrancheUnits(toNAVUnits(liquidityHeadroomValue)),
            "stMaxDeposit must match the liquidity-leg F15 recompute"
        );

        uint256 snapshotId = vm.snapshotState();
        OpReceipt memory r = _doDepositST(ST_BOB_ADDRESS, toUint256(maxAssets));
        assertGt(r.shares, 0, "the max-size deposit must mint shares");
        assertLe(r.post.liqUtilWAD, WAD, "a max-size deposit must leave the liquidity requirement satisfied");
        _assertCommittedConservation();
        vm.revertToState(snapshotId);

        uint256 breachAssets = toUint256(maxAssets) + _stMaxDepositBreachSlackAssets();
        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), breachAssets);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        ST.deposit(toTrancheUnits(breachAssets), ST_BOB_ADDRESS);
        vm.stopPrank();
    }

    /**
     * @notice A deposit following unsynced yield emits exact-args `ProtocolFeeSharesMinted` (on ST and JT) and
     *         `Deposit` events, with every value derived from the independent waterfall recomputation.
     * @dev The measured post-simulate raw NAVs and the deposit valuation are read via `_measureFreshSyncInputs`
     *      (inputs only, D2). The YDM yield-share previews are captured at sync time as accrual inputs.
     */
    function test_STDeposit_emitsDepositEvent() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        uint256 stSupplyPre = ST.totalSupply();
        uint256 jtSupplyPre = JT.totalSupply();

        _warpForward(1 days);
        _applySTYield(0.05e18);

        // Build the independent waterfall expectation for the deposit's inline pre-op sync from measured inputs
        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(e.elapsed, 0, "arrange: the accrual window must be nonzero");
        assertGt(e.stRawNew, e.lastSTRaw, "arrange: the senior raw NAV must have appreciated");
        uint256 assets = testConfig.initialFunding / 10;
        (,, NAV_UNIT value) = _measureFreshSyncInputs(toTrancheUnits(assets));
        assertTrue(e.premiumsPaid, "arrange: the yield must clear the dust gate");
        assertGt(toUint256(e.stFee), 0, "arrange: an ST protocol fee must accrue");
        assertGt(toUint256(e.jtFee), 0, "arrange: a JT yield-share protocol fee must accrue");

        (uint256 premShares, uint256 stFeeShares) = _expectedPremiumShares(e.ltPremium, e.stFee, e.stEff, stSupplyPre);
        uint256 jtFeeShares = _expectedShares(e.jtFee, jtSupplyPre, e.jtEff - e.jtFee);
        uint256 expectedDepositShares = _expectedShares(value, stSupplyPre + premShares + stFeeShares, e.stEff);
        uint256 feeRecipientSTPre = ST.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);
        uint256 feeRecipientJTPre = JT.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);

        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), assets);
        vm.expectEmit(true, false, false, true, address(ST));
        emit IRoycoVaultTranche.ProtocolFeeSharesMinted(PROTOCOL_FEE_RECIPIENT_ADDRESS, stFeeShares, stSupplyPre + premShares + stFeeShares);
        vm.expectEmit(true, false, false, true, address(JT));
        emit IRoycoVaultTranche.ProtocolFeeSharesMinted(PROTOCOL_FEE_RECIPIENT_ADDRESS, jtFeeShares, jtSupplyPre + jtFeeShares);
        _expectDeposit(address(ST), ST_BOB_ADDRESS, ST_BOB_ADDRESS, toTrancheUnits(assets), expectedDepositShares);
        uint256 shares = ST.deposit(toTrancheUnits(assets), ST_BOB_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        assertEq(shares, expectedDepositShares, "deposit shares must match the waterfall-derived pricing");
        assertEq(ST.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS) - feeRecipientSTPre, stFeeShares, "ST fee shares minted to the recipient");
        assertEq(JT.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS) - feeRecipientJTPre, jtFeeShares, "JT fee shares minted to the recipient");
        IRoycoDayAccountant.RoycoDayAccountantState memory aPost = ACCOUNTANT.getState();
        assertEq(aPost.lastJTRawNAV, e.jtRawNew, "committed JT raw NAV must equal the measured input");
        assertEq(aPost.lastJTEffectiveNAV, e.jtEff, "committed JT effective NAV must match the independent waterfall");
        assertEq(
            aPost.lastSTEffectiveNAV, e.stEff + (aPost.lastSTRawNAV - e.stRawNew), "committed ST effective NAV must be the waterfall output plus the deposit"
        );
        assertEq(aPost.lastJTCoverageImpermanentLoss, e.il, "committed IL must match the independent waterfall");
        assertEq(uint256(aPost.lastPremiumPaymentTimestamp), block.timestamp, "the premium payment must stamp");
        assertEq(uint256(aPost.twJTYieldShareAccruedWAD), 0, "the accrual accumulators must reset after payment");
        _assertCommittedConservation();
    }

    // ── S2.3 JT deposit pricing, previews, and gates ──

    /// @notice After committed yield a JT deposit mints exactly `floor(value * supply / jtEff)` shares, books exactly
    ///         the measured junior raw delta, and lowers coverage utilization to the independent recompute.
    function test_JTDeposit_exactSharePricing_afterYield() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applyJTYield(0.05e18);
        _sync();

        uint256 assets = testConfig.initialFunding / 10;
        NAV_UNIT value = KERNEL.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets));
        uint256 jtSupply = JT.totalSupply();
        NAV_UNIT jtEff = ACCOUNTANT.getState().lastJTEffectiveNAV;
        uint256 expectedShares = _expectedShares(value, jtSupply, jtEff);

        MarketSnapshot memory pre = _snap();
        vm.startPrank(JT_BOB_ADDRESS);
        IERC20(testConfig.jtAsset).approve(address(JT), assets);
        _expectDeposit(address(JT), JT_BOB_ADDRESS, JT_BOB_ADDRESS, toTrancheUnits(assets), expectedShares);
        uint256 shares = JT.deposit(toTrancheUnits(assets), JT_BOB_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        MarketSnapshot memory post = _snap();
        assertEq(shares, expectedShares, "deposit shares must match the independent floor pricing exactly");
        NAV_UNIT measuredRawDelta = post.lastJTRaw - pre.lastJTRaw;
        assertEq(post.lastJTEff, pre.lastJTEff + measuredRawDelta, "post JT effective NAV must grow by exactly the measured raw delta");
        assertApproxEqAbs(measuredRawDelta, value, maxNAVDelta(), "the raw delta must round-trip the deposited value through the quoter");
        assertEq(post.lastSTRaw, pre.lastSTRaw, "the senior raw NAV must be untouched");
        assertEq(post.lastSTEff, pre.lastSTEff, "the senior effective NAV must be untouched");
        assertEq(post.jtSupply, pre.jtSupply + shares, "no fee mint may accompany a same-block deposit");
        assertEq(post.jtOwned, pre.jtOwned + toTrancheUnits(assets), "jtOwned must grow by the deposited assets");
        uint256 expectedCovUtilWAD = _expectedCovUtil(
            pre.lastSTRaw, pre.lastJTRaw + measuredRawDelta, ACCOUNTANT.JT_COINVESTED(), ACCOUNTANT.getState().minCoverageWAD, pre.lastJTEff + measuredRawDelta
        );
        // The production value is read via a same-block flat sync (a no-op on the committed state), never recomputed by the suite
        uint256 productionCovUtilWAD = _syncWithState().coverageUtilizationWAD;
        assertEq(productionCovUtilWAD, expectedCovUtilWAD, "production coverage utilization must match the independent recompute");
        assertLt(productionCovUtilWAD, pre.covUtilWAD, "the JT deposit must lower coverage utilization");
        _assertCommittedConservation();
    }

    /// @notice `previewDeposit` on the JT equals the executed deposit exactly in the same block.
    /// @dev Same warped-window-then-sync arrangement as the ST parity test (see its natspec for the D6 rationale).
    function test_JTDeposit_previewParity() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applyJTYield(0.04e18);
        _sync();
        _warpForward(1 days);
        _sync();

        uint256 assets = testConfig.initialFunding / 20;
        (, NAV_UNIT valueAllocated,) = KERNEL.jtPreviewDeposit(toTrancheUnits(assets));
        uint256 previewShares = JT.previewDeposit(toTrancheUnits(assets));
        OpReceipt memory r = _doDepositJT(JT_BOB_ADDRESS, assets);

        assertEq(r.shares, previewShares, "previewDeposit must equal the executed deposit exactly");
        assertApproxEqAbs(r.post.lastJTRaw - r.pre.lastJTRaw, valueAllocated, maxNAVDelta(), "the previewed valueAllocated must match the deposited raw delta");
        assertEq(r.post.jtSupply, r.pre.jtSupply + r.shares, "supply must grow by exactly the minted shares");
        _assertCommittedConservation();
    }

    /// @notice A zero-asset JT deposit reverts with the accountant's exact-arg `INVALID_POST_OP_STATE(JT_DEPOSIT)`.
    /// @dev The post-op sync's `deltaJTRawNAV > 0` requirement fires before the tranche's `INVALID_VALUE_ALLOCATED` check can.
    function test_JTDeposit_reverts_zeroAssets() public {
        vm.prank(JT_ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        JT.deposit(ZERO_TRANCHE_UNITS, JT_ALICE_ADDRESS);
    }

    /// @notice In a fixed-term market a JT deposit reverts with `DISABLED_IN_FIXED_TERM_STATE` and `maxDeposit` reports zero.
    function test_JTDeposit_reverts_inFixedTerm() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _enterFixedTerm();
        assertEq(JT.maxDeposit(JT_BOB_ADDRESS), ZERO_TRANCHE_UNITS, "jtMaxDeposit must report zero in a fixed term");

        uint256 assets = testConfig.initialFunding / 100;
        vm.startPrank(JT_BOB_ADDRESS);
        IERC20(testConfig.jtAsset).approve(address(JT), assets);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        JT.deposit(toTrancheUnits(assets), JT_BOB_ADDRESS);
        vm.stopPrank();
    }

    /// @notice JT deposits are never coverage-gated: with coverage utilization at the brink a JT deposit still
    ///         succeeds and `jtMaxDeposit` reports the unbounded sentinel.
    function test_JTDeposit_neverGated() public {
        _depositJT(JT_ALICE_ADDRESS, testConfig.initialFunding / 10);
        _sync();
        TRANCHE_UNIT maxAssets = ST.maxDeposit(ST_ALICE_ADDRESS);
        assertGt(maxAssets, ZERO_TRANCHE_UNITS, "arrange: the coverage headroom must be nonzero");
        assertLt(maxAssets, MAX_TRANCHE_UNITS, "arrange: coverage must bound the deposit");
        OpReceipt memory rST = _doDepositST(ST_ALICE_ADDRESS, toUint256(maxAssets));
        assertLe(rST.post.covUtilWAD, WAD, "arrange: coverage must be satisfied at the brink");
        assertGt(rST.post.covUtilWAD, (WAD * 99) / 100, "arrange: coverage utilization must sit at the brink");

        assertEq(JT.maxDeposit(JT_BOB_ADDRESS), MAX_TRANCHE_UNITS, "jtMaxDeposit must report the unbounded sentinel");
        OpReceipt memory rJT = _doDepositJT(JT_BOB_ADDRESS, testConfig.initialFunding / 10);
        assertGt(rJT.shares, 0, "the coverage-improving JT deposit must succeed");
        assertLt(rJT.post.covUtilWAD, rST.post.covUtilWAD, "the JT deposit must lower coverage utilization");
        _assertCommittedConservation();
    }

    // ── S2.4 LT deposits ──

    /**
     * @notice The first LT multi-asset deposit mints LT shares 1:1 with the minted BPT value, mints the senior leg
     *         at the committed senior rate, and emits an exact-args `MultiAssetDeposit`.
     * @dev The freshly initialized venue holds only dust depth and Balancer bounds each unbalanced add's invariant
     *      growth, so the first entry is capped at the live venue depth (each leg at most the whole pool's value)
     *      rather than a funding-derived constant. `minLTAssetsOut` is set to the previewed venue mint, doubling as
     *      a min-out-passes-at-equality check.
     */
    function test_LTDepositMultiAsset_firstDeposit_exactPricing() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _setupLTProviders();
        _initializeLTVenueIfNeeded();
        _sync();

        uint256 depthCapAssets =
            toUint256(KERNEL.stConvertNAVUnitsToTrancheUnits(KERNEL.ltConvertTrancheUnitsToNAVUnits(toTrancheUnits(IERC20(POOL).totalSupply()))));
        assertGt(depthCapAssets, 0, "arrange: the initialized venue must carry nonzero depth");
        uint256 stAssets = Math.min(testConfig.initialFunding / 1_000_000, depthCapAssets);
        NAV_UNIT stValue = KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(stAssets));
        uint256 quoteAssets = _quoteAssetsForValue(stValue);
        assertGt(quoteAssets, 0, "arrange: the quote leg must be nonzero");
        uint256 expectedSTSharesMinted = _expectedShares(stValue, ST.totalSupply(), ACCOUNTANT.getState().lastSTEffectiveNAV);
        (NAV_UNIT previewValue,, TRANCHE_UNIT previewLtAssetsOut, uint256 previewLtSupply) = _previewKernelDepositLTMulti(stAssets, quoteAssets);
        assertEq(previewLtSupply, 0, "arrange: the first LT mint must price against zero supply");
        uint256 expectedShares = toUint256(previewValue);
        MarketSnapshot memory pre = _snap();
        uint256 quoteBalPre = IERC20(testConfig.quoteAsset).balanceOf(LT_ALICE_ADDRESS);

        vm.startPrank(LT_ALICE_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(LT), stAssets);
        IERC20(testConfig.quoteAsset).approve(address(LT), quoteAssets);
        vm.expectEmit(true, true, false, true, address(LT));
        emit IRoycoLiquidityTranche.MultiAssetDeposit(LT_ALICE_ADDRESS, LT_ALICE_ADDRESS, stAssets, quoteAssets, toUint256(previewLtAssetsOut), expectedShares);
        uint256 shares = IRoycoLiquidityTranche(address(LT)).depositMultiAsset(stAssets, quoteAssets, toUint256(previewLtAssetsOut), LT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        MarketSnapshot memory post = _snap();
        // The independent first-mint pin: shares equal the EXECUTED venue mint valued through the quoter (an input,
        // D2), so a shared preview/execution valuation bug cannot hide. The preview equality below is parity only
        assertEq(shares, toUint256(KERNEL.ltConvertTrancheUnitsToNAVUnits(post.ltOwned - pre.ltOwned)), "the first LT mint must be 1:1 with the minted BPT value");
        assertEq(shares, expectedShares, "the previewed valueAllocated must equal the executed mint (parity)");
        assertEq(LT.balanceOf(LT_ALICE_ADDRESS), shares, "receiver LT share balance");
        assertEq(post.ltOwned, pre.ltOwned + previewLtAssetsOut, "ltOwned must grow by exactly the previewed venue mint");
        assertEq(post.stOwned, pre.stOwned + toTrancheUnits(stAssets), "stOwned must grow by the senior leg");
        assertEq(post.stSupply, pre.stSupply + expectedSTSharesMinted, "the senior leg must mint at the committed senior rate");
        assertEq(post.ltSupply, pre.ltSupply + shares, "LT supply must grow by exactly the minted shares");
        assertEq(post.idleSTShares, pre.idleSTShares, "no idle premium may be staged by a deposit");
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal, "the minted senior shares must all land in the venue");
        assertEq(quoteBalPre - IERC20(testConfig.quoteAsset).balanceOf(LT_ALICE_ADDRESS), quoteAssets, "the quote leg must be pulled exactly");
        assertEq(post.lastLTRaw, KERNEL.ltConvertTrancheUnitsToNAVUnits(post.ltOwned), "committed LT raw NAV must be the fresh venue mark");
        assertLe(post.liqUtilWAD, pre.liqUtilWAD, "an LT deposit can only improve liquidity utilization");
        _assertCommittedConservation();
    }

    /// @notice The LT multi-asset deposit preview equals execution exactly, both for the minted shares and the
    ///         venue's LT assets out.
    function test_LTDepositMultiAsset_previewParity() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _sync();

        uint256 stAssets = testConfig.initialFunding / 500;
        uint256 quoteAssets = _quoteAssetsForValue(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(stAssets)));
        uint256 previewShares = _previewDepositLTMulti(stAssets, quoteAssets);
        (,, TRANCHE_UNIT previewLtAssetsOut,) = _previewKernelDepositLTMulti(stAssets, quoteAssets);

        OpReceipt memory r = _doDepositLTMulti(LT_BOB_ADDRESS, stAssets, quoteAssets, 0);
        assertEq(r.shares, previewShares, "the previewed shares must equal execution exactly");
        assertEq(r.post.ltOwned, r.pre.ltOwned + previewLtAssetsOut, "the previewed LT assets out must equal the executed venue mint");
        assertEq(r.post.ltSupply, r.pre.ltSupply + r.shares, "LT supply must grow by exactly the minted shares");
        _assertCommittedConservation();
    }

    /// @notice A multi-asset LT deposit with zero of both constituent legs reverts with `MUST_DEPOSIT_NON_ZERO_ASSETS`.
    /// @dev The selector is declared identically on `IRoycoDayKernel` and `IRoycoLiquidityTranche`, the kernel's declaration reverts.
    function test_LTDepositMultiAsset_reverts_bothLegsZero() public whenLT {
        _setupLTProviders();
        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayKernel.MUST_DEPOSIT_NON_ZERO_ASSETS.selector);
        IRoycoLiquidityTranche(address(LT)).depositMultiAsset(0, 0, 0, LT_ALICE_ADDRESS);
    }

    /**
     * @notice A multi-asset LT deposit whose `minLTAssetsOut` exceeds the venue mint reverts inside Balancer with
     *         `BptAmountOutBelowMin` and leaves the whole market state untouched (atomicity).
     * @dev No deadline parameter exists anywhere on this surface (spec D1), only the min-out bound asserted here.
     */
    function test_LTDepositMultiAsset_reverts_minLTAssetsOutBreach_atomic() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _sync();

        uint256 stAssets = testConfig.initialFunding / 500;
        uint256 quoteAssets = _quoteAssetsForValue(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(stAssets)));
        (,, TRANCHE_UNIT previewLtAssetsOut,) = _previewKernelDepositLTMulti(stAssets, quoteAssets);
        uint256 breachingMinOut = toUint256(previewLtAssetsOut) + 1;
        MarketSnapshot memory pre = _snap();

        vm.startPrank(LT_ALICE_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(LT), stAssets);
        IERC20(testConfig.quoteAsset).approve(address(LT), quoteAssets);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.BptAmountOutBelowMin.selector, toUint256(previewLtAssetsOut), breachingMinOut));
        IRoycoLiquidityTranche(address(LT)).depositMultiAsset(stAssets, quoteAssets, breachingMinOut, LT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertMarketUnchanged(pre);
    }

    /// @notice In a fixed-term market a quote-only multi-asset LT deposit succeeds (minting no senior shares) while
    ///         any ST-leg deposit reverts, and the preview returns zero shares for the disabled shape.
    function test_LTDepositMultiAsset_quoteOnly_allowedInFixedTerm_stLegReverts() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _enterFixedTerm();

        uint256 quoteAssets = _quoteAssetsForValue(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(testConfig.initialFunding / 1000)));
        uint256 ltSupplyPre = LT.totalSupply();
        MarketSnapshot memory pre = _snap();
        assertEq(pre.idleSTShares, 0, "arrange: no staged premium may exist");
        uint256 previewShares = _previewDepositLTMulti(0, quoteAssets);

        OpReceipt memory r = _doDepositLTMulti(LT_BOB_ADDRESS, 0, quoteAssets, 0);
        assertEq(r.shares, previewShares, "the quote-only preview must equal execution");
        NAV_UNIT valueAllocated = KERNEL.ltConvertTrancheUnitsToNAVUnits(r.post.ltOwned - r.pre.ltOwned);
        assertEq(r.shares, _expectedShares(valueAllocated, ltSupplyPre, pre.lastLTRaw), "quote-only shares must price at the pre-deposit LT effective NAV");
        assertEq(r.post.stSupply, r.pre.stSupply, "a quote-only deposit must mint no senior shares");
        assertEq(r.post.stOwned, r.pre.stOwned, "a quote-only deposit must add no senior assets");
        assertTrue(r.post.marketState == MarketState.FIXED_TERM, "the market must remain in the fixed term");

        uint256 stAssets = testConfig.initialFunding / 1000;
        vm.startPrank(LT_BOB_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(LT), stAssets);
        IERC20(testConfig.quoteAsset).approve(address(LT), quoteAssets);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        IRoycoLiquidityTranche(address(LT)).depositMultiAsset(stAssets, quoteAssets, 0, LT_BOB_ADDRESS);
        vm.stopPrank();

        assertEq(_previewDepositLTMulti(stAssets, quoteAssets), 0, "the preview must return zero shares for the disabled ST-leg shape");
        _assertCommittedConservation();
    }

    /**
     * @notice An in-kind LT deposit of BPT mints exactly `floor(value * supply / ltEffectiveNAV)` shares against the
     *         committed LT mark, with an exact-args `Deposit` event.
     * @dev The BPT is obtained through the only user path to holding it, a prior in-kind redemption.
     */
    function test_LTDeposit_inKind_exactSharePricing() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        OpReceipt memory rRedeem = _doRedeemLT(LT_ALICE_ADDRESS, LT.balanceOf(LT_ALICE_ADDRESS) / 4);
        uint256 bptAssets = toUint256(rRedeem.claims.ltAssets);
        assertGt(bptAssets, 0, "arrange: the redemption must pay out BPT");
        assertEq(IERC20(POOL).balanceOf(LT_ALICE_ADDRESS), bptAssets, "arrange: the redeemer must hold the BPT");
        _sync();

        NAV_UNIT value = KERNEL.ltConvertTrancheUnitsToNAVUnits(toTrancheUnits(bptAssets));
        uint256 ltSupply = LT.totalSupply();
        MarketSnapshot memory pre = _snap();
        assertEq(pre.idleSTShares, 0, "arrange: no staged premium may exist");
        uint256 expectedShares = _expectedShares(value, ltSupply, pre.lastLTRaw);

        vm.startPrank(LT_ALICE_ADDRESS);
        IERC20(POOL).approve(address(LT), bptAssets);
        _expectDeposit(address(LT), LT_ALICE_ADDRESS, LT_ALICE_ADDRESS, toTrancheUnits(bptAssets), expectedShares);
        uint256 shares = LT.deposit(toTrancheUnits(bptAssets), LT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        MarketSnapshot memory post = _snap();
        assertEq(shares, expectedShares, "in-kind LT shares must match the independent floor pricing exactly");
        assertEq(post.ltOwned, pre.ltOwned + toTrancheUnits(bptAssets), "ltOwned must grow by the deposited BPT");
        assertEq(post.ltSupply, pre.ltSupply + shares, "LT supply must grow by exactly the minted shares");
        assertApproxEqAbs(post.lastLTRaw - pre.lastLTRaw, value, maxNAVDelta(), "the committed LT mark must grow by the deposited value");
        _assertCommittedConservation();
    }

    /// @notice LT deposits are never gated: the in-kind and quote-only flows succeed with the liquidity requirement
    ///         breached and in a fixed term, `ltMaxDeposit` stays unbounded, and only a pause zeroes it.
    function test_LTDeposit_neverGated_evenInFixedTermOrLiquidityBreach() public whenLT {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 2);
        _seedDefaultLT();
        // Obtain BPT while the liquidity gate is still open (baseline minLiquidity is zero)
        OpReceipt memory rRedeem = _doRedeemLT(LT_ALICE_ADDRESS, LT.balanceOf(LT_ALICE_ADDRESS) / 2);
        uint256 bptAssets = toUint256(rRedeem.claims.ltAssets);
        assertGt(bptAssets, 0, "arrange: the redemption must pay out BPT");

        // Arrange A: breach the liquidity requirement outright
        _setMinLiquidityWAD(0.9e18);
        _sync();
        assertGt(_snap().liqUtilWAD, WAD, "arrange: the liquidity requirement must be breached");
        assertEq(LT.maxDeposit(LT_ALICE_ADDRESS), MAX_TRANCHE_UNITS, "ltMaxDeposit must stay unbounded while breached");
        vm.startPrank(LT_ALICE_ADDRESS);
        IERC20(POOL).approve(address(LT), bptAssets / 2);
        uint256 inKindShares = LT.deposit(toTrancheUnits(bptAssets / 2), LT_ALICE_ADDRESS);
        vm.stopPrank();
        assertGt(inKindShares, 0, "the in-kind deposit must succeed while breached");
        uint256 quoteAssets = _quoteAssetsForValue(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(testConfig.initialFunding / 1000)));
        assertGt(_doDepositLTMulti(LT_ALICE_ADDRESS, 0, quoteAssets, 0).shares, 0, "the quote-only deposit must succeed while breached");

        // Arrange B: fixed term
        _enterFixedTerm();
        assertEq(LT.maxDeposit(LT_ALICE_ADDRESS), MAX_TRANCHE_UNITS, "ltMaxDeposit must stay unbounded in a fixed term");
        uint256 remainingBptAssets = IERC20(POOL).balanceOf(LT_ALICE_ADDRESS);
        assertGt(remainingBptAssets, 0, "arrange: BPT must remain for the fixed-term deposit");
        vm.startPrank(LT_ALICE_ADDRESS);
        IERC20(POOL).approve(address(LT), remainingBptAssets);
        uint256 fixedTermShares = LT.deposit(toTrancheUnits(remainingBptAssets), LT_ALICE_ADDRESS);
        vm.stopPrank();
        assertGt(fixedTermShares, 0, "the in-kind deposit must succeed in a fixed term");
        _assertCommittedConservation();
        _assertSolvency();

        // Only a pause zeroes the LT deposit capacity
        _pauseKernel();
        assertEq(LT.maxDeposit(LT_ALICE_ADDRESS), ZERO_TRANCHE_UNITS, "ltMaxDeposit must report zero while paused");
    }

    /**
     * @notice A multi-asset LT deposit whose senior leg overruns the coverage headroom reverts with
     *         `COVERAGE_REQUIREMENT_VIOLATED` and leaves the market untouched: the ST-leg flow is the only
     *         deposit besides the plain senior deposit that adds senior exposure, so it carries the same gate.
     * @dev The market is driven to the coverage brink with a plain senior deposit sized from the live
     *      `maxDeposit`, keeping a small pool-scaled headroom so the breaching venue add stays well within
     *      Balancer's unbalanced-add invariant bound.
     */
    function test_LTDepositMultiAsset_reverts_coverageBreach_atomic() public whenLT {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 25);
        _setupLTProviders();
        uint256 poolLegAssets = testConfig.initialFunding / 50;
        _seedLTBalanced(LT_ALICE_ADDRESS, poolLegAssets);
        _sync();

        // Fill the coverage headroom down to a pool-scaled remainder
        uint256 headroomTargetAssets = poolLegAssets / 4;
        uint256 maxAssets = toUint256(ST.maxDeposit(ST_BOB_ADDRESS));
        assertLt(maxAssets, toUint256(MAX_TRANCHE_UNITS), "arrange: coverage must bound the senior deposit");
        assertGt(maxAssets, headroomTargetAssets, "arrange: the coverage headroom must exceed the target remainder");
        _doDepositST(ST_BOB_ADDRESS, maxAssets - headroomTargetAssets);

        uint256 breachAssets = toUint256(ST.maxDeposit(ST_BOB_ADDRESS)) + _stMaxDepositBreachSlackAssets();
        uint256 quoteAssets = _quoteAssetsForValue(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(breachAssets)));
        MarketSnapshot memory pre = _snap();
        assertLe(pre.liqUtilWAD, WAD, "arrange: liquidity must not be the binding gate");

        vm.startPrank(LT_BOB_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(LT), breachAssets);
        IERC20(testConfig.quoteAsset).approve(address(LT), quoteAssets);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        IRoycoLiquidityTranche(address(LT)).depositMultiAsset(breachAssets, quoteAssets, 0, LT_BOB_ADDRESS);
        vm.stopPrank();
        _assertMarketUnchanged(pre);
    }

    /**
     * @notice With the liquidity requirement already breached a multi-asset LT deposit carrying a senior leg
     *         reverts with `LIQUIDITY_REQUIREMENT_VIOLATED` and leaves the market untouched, while coverage
     *         stays satisfied (liquidity is the binding gate).
     * @dev A small two-leg add cannot heal a deeply-breached requirement, so the post-op state stays above
     *      WAD and the ST-leg-enforced liquidity gate fires.
     */
    function test_LTDepositMultiAsset_reverts_liquidityBreach_atomic() public whenLT {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 2);
        _seedDefaultLT();
        _setMinLiquidityWAD(0.9e18);
        _sync();
        MarketSnapshot memory pre = _snap();
        assertGt(pre.liqUtilWAD, WAD, "arrange: the liquidity requirement must be breached");

        uint256 stAssets = testConfig.initialFunding / 1000;
        NAV_UNIT stValue = KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(stAssets));
        uint256 quoteAssets = _quoteAssetsForValue(stValue);
        assertLe(
            _expectedCovUtil(pre.lastSTRaw + stValue, pre.lastJTRaw, ACCOUNTANT.JT_COINVESTED(), ACCOUNTANT.getState().minCoverageWAD, pre.lastJTEff),
            WAD,
            "arrange: coverage must not be the binding gate"
        );
        // Even crediting both legs fully to the pooled depth, the post-op utilization stays breached
        assertGt(
            _expectedLiqUtil(pre.lastSTEff + stValue, 0.9e18, pre.lastLTRaw + stValue + stValue),
            WAD,
            "arrange: the deposit must not heal the breached requirement"
        );

        vm.startPrank(LT_BOB_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(LT), stAssets);
        IERC20(testConfig.quoteAsset).approve(address(LT), quoteAssets);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        IRoycoLiquidityTranche(address(LT)).depositMultiAsset(stAssets, quoteAssets, 0, LT_BOB_ADDRESS);
        vm.stopPrank();
        _assertMarketUnchanged(pre);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S3 — REDEMPTION BATTERY
    // ═══════════════════════════════════════════════════════════════════════════

    // ── S3.0 Section-local helpers ──

    /**
     * @notice Derives a tranche's cumulative asset claims independently from the committed checkpoint plus quoter
     *         conversions, mirroring `TrancheClaimsLogic._deriveTrancheAssetClaims` on the documented decomposition.
     * @dev `stClaimOnJTRaw = sat(stEff - stRaw)`, `jtClaimOnSTRaw = sat(jtEff - jtRaw)`, self-backed legs are the
     *      raw remainders. The quoter conversions of the claim NAVs are inputs (D2), not the function under test.
     *      Callers must have synced in the same block so the committed checkpoint equals the live state.
     */
    function _expectedTrancheClaims(TrancheType _trancheType) internal view returns (AssetClaims memory claims) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        if (_trancheType == TrancheType.LIQUIDITY) {
            if (a.lastLTRawNAV != ZERO_NAV_UNITS) claims.ltAssets = KERNEL.ltConvertNAVUnitsToTrancheUnits(a.lastLTRawNAV);
            claims.stShares = KERNEL.getState().ltOwnedSeniorTrancheShares;
            claims.nav = a.lastLTRawNAV + _expectedValue(claims.stShares, ST.totalSupply(), a.lastSTEffectiveNAV);
            return claims;
        }
        uint256 stRaw = toUint256(a.lastSTRawNAV);
        uint256 jtRaw = toUint256(a.lastJTRawNAV);
        uint256 stEff = toUint256(a.lastSTEffectiveNAV);
        uint256 jtEff = toUint256(a.lastJTEffectiveNAV);
        uint256 stClaimOnJTRawNAV = stEff > stRaw ? stEff - stRaw : 0;
        uint256 jtClaimOnSTRawNAV = jtEff > jtRaw ? jtEff - jtRaw : 0;
        if (_trancheType == TrancheType.SENIOR) {
            uint256 stClaimOnSTRawNAV = stRaw - jtClaimOnSTRawNAV;
            if (stClaimOnSTRawNAV != 0) claims.stAssets = KERNEL.stConvertNAVUnitsToTrancheUnits(toNAVUnits(stClaimOnSTRawNAV));
            if (stClaimOnJTRawNAV != 0) claims.jtAssets = KERNEL.jtConvertNAVUnitsToTrancheUnits(toNAVUnits(stClaimOnJTRawNAV));
            claims.nav = a.lastSTEffectiveNAV;
        } else {
            uint256 jtClaimOnJTRawNAV = jtRaw - stClaimOnJTRawNAV;
            if (jtClaimOnSTRawNAV != 0) claims.stAssets = KERNEL.stConvertNAVUnitsToTrancheUnits(toNAVUnits(jtClaimOnSTRawNAV));
            if (jtClaimOnJTRawNAV != 0) claims.jtAssets = KERNEL.jtConvertNAVUnitsToTrancheUnits(toNAVUnits(jtClaimOnJTRawNAV));
            claims.nav = a.lastJTEffectiveNAV;
        }
    }

    /// @notice Floor-scales every claims field by `_shares / _totalShares`, mirroring `TrancheClaimsLogic._scaleAssetClaims`.
    function _scaleExpectedClaims(AssetClaims memory _claims, uint256 _shares, uint256 _totalShares) internal pure returns (AssetClaims memory scaled) {
        scaled.nav = toNAVUnits(Math.mulDiv(toUint256(_claims.nav), _shares, _totalShares));
        scaled.stAssets = toTrancheUnits(Math.mulDiv(toUint256(_claims.stAssets), _shares, _totalShares));
        scaled.jtAssets = toTrancheUnits(Math.mulDiv(toUint256(_claims.jtAssets), _shares, _totalShares));
        scaled.ltAssets = toTrancheUnits(Math.mulDiv(toUint256(_claims.ltAssets), _shares, _totalShares));
        scaled.stShares = Math.mulDiv(_claims.stShares, _shares, _totalShares);
    }

    /**
     * @notice Applies the expected ST self-liquidation bonus to a redeemer's base claims, mirroring
     *         `SelfLiquidationLogic.applySeniorTrancheSelfLiquidationBonus` on the committed checkpoint.
     * @dev The bonus is `min(floor(nav * bonusWAD / WAD), jtEff, maxUtilizationNeutralBonus)` with the neutral cap's
     *      two sourcing cases from the library's documented derivation, sourced ST-assets-first. Quoter conversions
     *      of the claim legs are inputs. Callers must have synced in the same block.
     */
    function _expectedClaimsWithSelfLiquidationBonus(AssetClaims memory _userClaims)
        internal
        view
        returns (AssetClaims memory claimsWithBonus, NAV_UNIT bonusNAV)
    {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        bool coinvested = ACCOUNTANT.JT_COINVESTED();
        uint256 covUtilWAD = _expectedCovUtil(a.lastSTRawNAV, a.lastJTRawNAV, coinvested, a.minCoverageWAD, a.lastJTEffectiveNAV);
        if (covUtilWAD < a.coverageLiquidationUtilizationWAD) return (_userClaims, ZERO_NAV_UNITS);

        uint256 jtEff = toUint256(a.lastJTEffectiveNAV);
        uint256 jtRaw = toUint256(a.lastJTRawNAV);
        uint256 desiredBonus = Math.mulDiv(toUint256(_userClaims.nav), KERNEL.getState().stSelfLiquidationBonusWAD, WAD);
        uint256 jtClaimOnSTRawNAV = jtEff > jtRaw ? jtEff - jtRaw : 0;

        // The maximum bonus that does not raise coverage utilization (the bank-run-neutral cap)
        uint256 maxNeutralBonus;
        if (jtEff != 0) {
            uint256 exposure = toUint256(a.lastSTRawNAV) + (coinvested ? jtRaw : 0);
            uint256 weightedClaimNAV = toUint256(KERNEL.stConvertTrancheUnitsToNAVUnits(_userClaims.stAssets))
                + (coinvested ? toUint256(KERNEL.jtConvertTrancheUnitsToNAVUnits(_userClaims.jtAssets)) : 0);
            if (weightedClaimNAV != 0) {
                uint256 stSourcedMaxBonus = Math.mulDiv(weightedClaimNAV, jtEff, exposure - jtEff);
                if (stSourcedMaxBonus <= jtClaimOnSTRawNAV) {
                    maxNeutralBonus = stSourcedMaxBonus;
                } else {
                    maxNeutralBonus = Math.mulDiv(weightedClaimNAV + (coinvested ? 0 : jtClaimOnSTRawNAV), jtEff, exposure - (coinvested ? jtEff : 0));
                }
            }
        }

        uint256 bonus = Math.min(Math.min(desiredBonus, jtEff), maxNeutralBonus);
        if (bonus == 0) return (_userClaims, ZERO_NAV_UNITS);
        bonusNAV = toNAVUnits(bonus);
        uint256 bonusFromSTRawNAV = Math.min(bonus, jtClaimOnSTRawNAV);
        claimsWithBonus.stAssets = _userClaims.stAssets + KERNEL.stConvertNAVUnitsToTrancheUnits(toNAVUnits(bonusFromSTRawNAV));
        claimsWithBonus.jtAssets = _userClaims.jtAssets + KERNEL.jtConvertNAVUnitsToTrancheUnits(toNAVUnits(bonus - bonusFromSTRawNAV));
        claimsWithBonus.nav = _userClaims.nav + bonusNAV;
    }

    /**
     * @notice The smallest junior redemption NAV guaranteed to leave coverage utilization above WAD, from the
     *         committed checkpoint plus a documented drift margin.
     * @dev Derivation (post covUtil > WAD, the gate rounds up in favor of breach): redeeming `x` NAV removes
     *      `x * exposureFrac` from the covered exposure (the full `x` when coinvested, the ST-leg claim fraction
     *      otherwise), so the exact boundary solves `(E - x*f)*minCov > (J - x)*WAD`, giving
     *      `x > (J*WAD - E*minCov) / (WAD - minCov*f)`. The margin adds the two raw-NAV dust tolerances plus four
     *      `maxNAVDelta()` quoter round-trips (claim NAV -> tranche units -> measured raw delta on each leg) plus two
     *      wei, so the realized removal strictly dominates the boundary. Requires pre covUtil <= WAD.
     */
    function _jtCoverageBreachRedemptionNAV() internal view returns (uint256 breachNAV) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        bool coinvested = ACCOUNTANT.JT_COINVESTED();
        uint256 stRaw = toUint256(a.lastSTRawNAV);
        uint256 jtRaw = toUint256(a.lastJTRawNAV);
        uint256 stEff = toUint256(a.lastSTEffectiveNAV);
        uint256 jtEff = toUint256(a.lastJTEffectiveNAV);
        uint256 exposure = stRaw + (coinvested ? jtRaw : 0);

        uint256 exposureFracWAD = WAD;
        if (!coinvested) {
            uint256 jtClaimOnSTRawNAV = jtEff > jtRaw ? jtEff - jtRaw : 0;
            uint256 jtClaimOnJTRawNAV = jtRaw - (stEff > stRaw ? stEff - stRaw : 0);
            exposureFracWAD = Math.mulDiv(jtClaimOnSTRawNAV, WAD, jtClaimOnSTRawNAV + jtClaimOnJTRawNAV);
        }

        uint256 boundary = Math.ceilDiv(jtEff * WAD - exposure * a.minCoverageWAD, WAD - Math.mulDiv(a.minCoverageWAD, exposureFracWAD, WAD));
        breachNAV = boundary + toUint256(a.stNAVDustTolerance + a.jtNAVDustTolerance) + 4 * toUint256(maxNAVDelta()) + 2;
    }

    /// @notice Asserts field-by-field equality of two `AssetClaims`.
    function _assertClaimsEq(AssetClaims memory _actual, AssetClaims memory _expected, string memory _ctx) internal pure {
        assertEq(_actual.stAssets, _expected.stAssets, string.concat(_ctx, ": stAssets claim"));
        assertEq(_actual.jtAssets, _expected.jtAssets, string.concat(_ctx, ": jtAssets claim"));
        assertEq(_actual.ltAssets, _expected.ltAssets, string.concat(_ctx, ": ltAssets claim"));
        assertEq(_actual.stShares, _expected.stShares, string.concat(_ctx, ": stShares claim"));
        assertEq(_actual.nav, _expected.nav, string.concat(_ctx, ": claim NAV"));
    }

    /// @notice Asserts the receiver's token balances grew by exactly the ST and JT asset claims, batching when the
    ///         two tranches share one asset.
    function _assertSTAndJTClaimsPaid(address _receiver, uint256 _stAssetBalPre, uint256 _jtAssetBalPre, AssetClaims memory _claims) internal view {
        if (testConfig.stAsset == testConfig.jtAsset) {
            assertEq(
                IERC20(testConfig.stAsset).balanceOf(_receiver) - _stAssetBalPre,
                toUint256(_claims.stAssets + _claims.jtAssets),
                "receiver must be paid the combined ST and JT asset claims exactly"
            );
        } else {
            assertEq(IERC20(testConfig.stAsset).balanceOf(_receiver) - _stAssetBalPre, toUint256(_claims.stAssets), "receiver must be paid the ST asset claim exactly");
            assertEq(IERC20(testConfig.jtAsset).balanceOf(_receiver) - _jtAssetBalPre, toUint256(_claims.jtAssets), "receiver must be paid the JT asset claim exactly");
        }
    }

    /**
     * @notice Arranges the LT state shared by the staged-premium redemption tests: seeded ST/JT market, a deliberately
     *         dust-sized LT pool, overlay on with the liquidity utilization near its target, and a staged idle premium.
     * @dev The pool is sized to roughly 1/10000 of the funding so the accrued premium overruns the venue's unbalanced-add
     *      invariant-ratio cap and the single-sided reinvestment reverts, staying idle. The zero-slippage seam inside
     *      `_stageIdlePremium` is a second belt (on this venue the BPT oracle can mark under the mint rate, so the
     *      slippage gate alone does not guarantee staging). The minimum liquidity is sized so utilization sits at about
     *      80 percent, keeping the LDM paying while leaving the redemption tests headroom under the 100 percent gate.
     */
    function _arrangeLTWithStagedIdlePremium() internal returns (uint256 idleShares) {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _setupLTProviders();
        uint256 stLegAssets = testConfig.initialFunding / 10_000;
        _seedLTBalanced(LT_ALICE_ADDRESS, stLegAssets);
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtil(0.8e18);
        _enableLTOverlay(0.1e18, 0.5e18, minLiquidityWAD);
        idleShares = _stageIdlePremium();
        _sync();
    }

    // ── S3.1 ST redemptions ──

    /**
     * @notice An ST redemption pays exactly the per-field floor-scaled slice of the senior tranche's decomposed
     *         claims, debits the owned-asset ledgers by the claims, and books the measured redemption NAV out of the
     *         committed senior effective NAV, with an exact-args `Redeem` event.
     */
    function test_STRedeem_exactClaimScaling() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applySTYield(0.05e18);
        _sync();

        uint256 stSupply = ST.totalSupply();
        uint256 shares = ST.balanceOf(ST_ALICE_ADDRESS) / 2;
        AssetClaims memory expectedClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.SENIOR), shares, stSupply);
        assertGt(toUint256(expectedClaims.stAssets), 0, "arrange: the redemption must claim senior assets");
        MarketSnapshot memory pre = _snap();
        uint256 stAssetBalPre = IERC20(testConfig.stAsset).balanceOf(ST_ALICE_ADDRESS);
        uint256 jtAssetBalPre = IERC20(testConfig.jtAsset).balanceOf(ST_ALICE_ADDRESS);

        vm.startPrank(ST_ALICE_ADDRESS);
        _expectRedeem(address(ST), ST_ALICE_ADDRESS, ST_ALICE_ADDRESS, expectedClaims, shares);
        AssetClaims memory claims = ST.redeem(shares, ST_ALICE_ADDRESS, ST_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        _assertClaimsEq(claims, expectedClaims, "executed claims");
        _assertSTAndJTClaimsPaid(ST_ALICE_ADDRESS, stAssetBalPre, jtAssetBalPre, expectedClaims);
        MarketSnapshot memory post = _snap();
        assertEq(post.stSupply, pre.stSupply - shares, "ST supply must fall by exactly the redeemed shares");
        assertEq(post.stOwned, pre.stOwned - expectedClaims.stAssets, "stOwned must fall by the ST asset claim");
        assertEq(post.jtOwned, pre.jtOwned - expectedClaims.jtAssets, "jtOwned must fall by the JT asset claim");
        NAV_UNIT redemptionNAV = (pre.lastSTRaw - post.lastSTRaw) + (pre.lastJTRaw - post.lastJTRaw);
        assertEq(post.lastSTEff, pre.lastSTEff - redemptionNAV, "the senior effective NAV must fall by exactly the measured redemption NAV");
        assertEq(post.lastJTEff, pre.lastJTEff, "the junior effective NAV must be untouched with no liquidation bonus");
        assertApproxEqAbs(redemptionNAV, expectedClaims.nav, maxNAVDelta(), "the measured redemption NAV must round-trip the claim NAV");
        _assertCommittedConservation();
    }

    /// @notice `previewRedeem` on the ST equals the executed redemption exactly on every claims field in the same block.
    /// @dev The warped window is committed by the final sync so preview and execution price off one committed rate (D6).
    function test_STRedeem_previewParity() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applySTYield(0.04e18);
        _sync();
        _warpForward(1 days);
        _sync();

        uint256 shares = ST.balanceOf(ST_ALICE_ADDRESS) / 3;
        AssetClaims memory previewClaims = ST.previewRedeem(shares);
        OpReceipt memory r = _doRedeemST(ST_ALICE_ADDRESS, shares);

        _assertClaimsEq(r.claims, previewClaims, "previewRedeem parity");
        assertEq(r.post.stSupply, r.pre.stSupply - shares, "ST supply must fall by exactly the redeemed shares");
        _assertCommittedConservation();
    }

    /// @notice A zero-share ST redemption reverts with `MUST_REQUEST_NON_ZERO_SHARES`.
    function test_STRedeem_reverts_zeroShares() public {
        vm.prank(ST_ALICE_ADDRESS);
        vm.expectRevert(IRoycoVaultTranche.MUST_REQUEST_NON_ZERO_SHARES.selector);
        ST.redeem(0, ST_ALICE_ADDRESS, ST_ALICE_ADDRESS);
    }

    /// @notice In a fixed-term market an ST redemption reverts with `DISABLED_IN_FIXED_TERM_STATE` and `maxRedeem` reports zero.
    function test_STRedeem_reverts_inFixedTerm() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        uint256 shares = ST.balanceOf(ST_ALICE_ADDRESS) / 2;
        _enterFixedTerm();
        assertEq(ST.maxRedeem(ST_ALICE_ADDRESS), 0, "stMaxRedeem must report zero in a fixed term");

        vm.prank(ST_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        ST.redeem(shares, ST_ALICE_ADDRESS, ST_ALICE_ADDRESS);
    }

    /// @notice A third party may only redeem an owner's ST shares with an allowance: it reverts with the exact OZ
    ///         `ERC20InsufficientAllowance` without one, and consumes an exact allowance to zero with one.
    function test_STRedeem_allowancePath() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        uint256 stSupply = ST.totalSupply();
        uint256 shares = ST.balanceOf(ST_ALICE_ADDRESS) / 4;
        AssetClaims memory expectedClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.SENIOR), shares, stSupply);

        vm.prank(ST_BOB_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ST_BOB_ADDRESS, 0, shares));
        ST.redeem(shares, ST_BOB_ADDRESS, ST_ALICE_ADDRESS);

        vm.prank(ST_ALICE_ADDRESS);
        ST.approve(ST_BOB_ADDRESS, shares);
        uint256 aliceSharesPre = ST.balanceOf(ST_ALICE_ADDRESS);
        uint256 stAssetBalPre = IERC20(testConfig.stAsset).balanceOf(ST_BOB_ADDRESS);
        uint256 jtAssetBalPre = IERC20(testConfig.jtAsset).balanceOf(ST_BOB_ADDRESS);
        vm.prank(ST_BOB_ADDRESS);
        AssetClaims memory claims = ST.redeem(shares, ST_BOB_ADDRESS, ST_ALICE_ADDRESS);
        _assertSolvency();

        _assertClaimsEq(claims, expectedClaims, "allowance-path claims");
        assertEq(ST.allowance(ST_ALICE_ADDRESS, ST_BOB_ADDRESS), 0, "the exact allowance must be consumed to zero");
        assertEq(ST.balanceOf(ST_ALICE_ADDRESS), aliceSharesPre - shares, "the owner's shares must be burned");
        _assertSTAndJTClaimsPaid(ST_BOB_ADDRESS, stAssetBalPre, jtAssetBalPre, expectedClaims);
        _assertCommittedConservation();
    }

    /// @notice Past the liquidation coverage utilization threshold an ST redemption pays exactly the derived
    ///         self-liquidation bonus, sourced from the junior effective NAV, without raising coverage utilization.
    function test_STRedeem_selfLiquidationBonus_exactAmount() public {
        _ensureSelfLiquidationBonusConfigured();
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _breachLiquidation();

        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        MarketSnapshot memory pre = _snap();
        assertGe(pre.covUtilWAD, a.coverageLiquidationUtilizationWAD, "arrange: the liquidation threshold must be breached");
        assertGt(toUint256(a.lastJTEffectiveNAV), 0, "arrange: the junior tranche must not be exhausted");

        uint256 stSupply = ST.totalSupply();
        uint256 shares = ST.balanceOf(ST_ALICE_ADDRESS) / 2;
        AssetClaims memory baseClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.SENIOR), shares, stSupply);
        (AssetClaims memory expectedClaims, NAV_UNIT bonusNAV) = _expectedClaimsWithSelfLiquidationBonus(baseClaims);
        assertGt(toUint256(bonusNAV), 0, "arrange: the bonus must be nonzero");

        vm.startPrank(ST_ALICE_ADDRESS);
        _expectRedeem(address(ST), ST_ALICE_ADDRESS, ST_ALICE_ADDRESS, expectedClaims, shares);
        AssetClaims memory claims = ST.redeem(shares, ST_ALICE_ADDRESS, ST_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        _assertClaimsEq(claims, expectedClaims, "bonus-adjusted claims");
        MarketSnapshot memory post = _snap();
        assertEq(post.lastJTEff, pre.lastJTEff - bonusNAV, "the junior effective NAV must fund exactly the bonus");
        NAV_UNIT redemptionNAV = (pre.lastSTRaw - post.lastSTRaw) + (pre.lastJTRaw - post.lastJTRaw);
        assertEq(post.lastSTEff, pre.lastSTEff - (redemptionNAV - bonusNAV), "the senior effective NAV must fall by the redemption net of the bonus");
        assertLe(post.covUtilWAD, pre.covUtilWAD, "the bonus must never raise coverage utilization");
        _assertCommittedConservation();
    }

    /**
     * @notice `stMaxRedeem` is bounded only by the global raw NAVs, so a sole senior LP can redeem its full balance
     *         and the claims stay within the owned-asset ledgers.
     * @dev Derivation: each per-leg share bound is `T * rawNAV / claimOnLegNAV` with `claimOnLegNAV <= rawNAV`, so
     *      both bounds are at least the total supply and the owner's balance is the binding term.
     */
    function test_STRedeem_maxRedeemInversion() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applySTYield(0.03e18);
        _sync();

        uint256 maxShares = ST.maxRedeem(ST_ALICE_ADDRESS);
        assertEq(maxShares, ST.balanceOf(ST_ALICE_ADDRESS), "an ST holder's max redemption must be its full balance");
        uint256 stSupply = ST.totalSupply();
        AssetClaims memory expectedClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.SENIOR), maxShares, stSupply);
        MarketSnapshot memory pre = _snap();
        assertLe(expectedClaims.stAssets, pre.stOwned, "the ST asset claim must stay within the owned senior assets");
        assertLe(expectedClaims.jtAssets, pre.jtOwned, "the JT asset claim must stay within the owned junior assets");

        OpReceipt memory r = _doRedeemST(ST_ALICE_ADDRESS, maxShares);
        _assertClaimsEq(r.claims, expectedClaims, "max-redemption claims");
        assertEq(r.post.stSupply, pre.stSupply - maxShares, "ST supply must fall by exactly the redeemed shares");
        assertEq(ST.balanceOf(ST_ALICE_ADDRESS), 0, "the redeemer must exit fully");
        _assertCommittedConservation();
    }

    /// @notice With the liquidity requirement breached a senior redemption still succeeds and pays its exact
    ///         scaled claims: senior exits are never liquidity-gated (the no-run guarantee's exempt direction).
    function test_STRedeem_liquidityBreach_notGated() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _setMinLiquidityWAD(0.9e18);
        _sync();
        MarketSnapshot memory pre = _snap();
        assertGt(pre.liqUtilWAD, WAD, "arrange: the liquidity requirement must be breached");

        uint256 shares = ST.balanceOf(ST_ALICE_ADDRESS) / 4;
        AssetClaims memory expectedClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.SENIOR), shares, ST.totalSupply());
        assertGt(toUint256(expectedClaims.nav), 0, "arrange: the redemption must carry value");
        OpReceipt memory r = _doRedeemST(ST_ALICE_ADDRESS, shares);
        _assertClaimsEq(r.claims, expectedClaims, "liquidity-breached senior exit claims");
        assertEq(r.post.stSupply, r.pre.stSupply - shares, "ST supply must fall by exactly the redeemed shares");
        _assertCommittedConservation();
    }

    // ── S3.2 JT redemptions ──

    /**
     * @notice A JT redemption pays exactly the per-field floor-scaled slice of the junior tranche's decomposed
     *         claims, matches `previewRedeem` exactly, and books the measured redemption NAV out of the committed
     *         junior effective NAV.
     */
    function test_JTRedeem_exactClaimScaling_andPreviewParity() public {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 2);
        _applyJTYield(0.05e18);
        _sync();

        uint256 jtSupply = JT.totalSupply();
        uint256 shares = JT.balanceOf(JT_ALICE_ADDRESS) / 2;
        AssetClaims memory expectedClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.JUNIOR), shares, jtSupply);
        assertGt(toUint256(expectedClaims.jtAssets), 0, "arrange: the redemption must claim junior assets");
        AssetClaims memory previewClaims = JT.previewRedeem(shares);
        _assertClaimsEq(previewClaims, expectedClaims, "previewRedeem vs the independent derivation");
        MarketSnapshot memory pre = _snap();
        uint256 stAssetBalPre = IERC20(testConfig.stAsset).balanceOf(JT_ALICE_ADDRESS);
        uint256 jtAssetBalPre = IERC20(testConfig.jtAsset).balanceOf(JT_ALICE_ADDRESS);

        vm.startPrank(JT_ALICE_ADDRESS);
        _expectRedeem(address(JT), JT_ALICE_ADDRESS, JT_ALICE_ADDRESS, expectedClaims, shares);
        AssetClaims memory claims = JT.redeem(shares, JT_ALICE_ADDRESS, JT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        _assertClaimsEq(claims, expectedClaims, "executed claims");
        _assertSTAndJTClaimsPaid(JT_ALICE_ADDRESS, stAssetBalPre, jtAssetBalPre, expectedClaims);
        MarketSnapshot memory post = _snap();
        assertEq(post.jtSupply, pre.jtSupply - shares, "JT supply must fall by exactly the redeemed shares");
        assertEq(post.stOwned, pre.stOwned - expectedClaims.stAssets, "stOwned must fall by the ST asset claim");
        assertEq(post.jtOwned, pre.jtOwned - expectedClaims.jtAssets, "jtOwned must fall by the JT asset claim");
        NAV_UNIT redemptionNAV = (pre.lastSTRaw - post.lastSTRaw) + (pre.lastJTRaw - post.lastJTRaw);
        assertEq(post.lastJTEff, pre.lastJTEff - redemptionNAV, "the junior effective NAV must fall by exactly the measured redemption NAV");
        assertEq(post.lastSTEff, pre.lastSTEff, "the senior effective NAV must be untouched");
        assertEq(post.lastIL, pre.lastIL, "no impermanent loss may move on a redemption without IL");
        assertApproxEqAbs(redemptionNAV, expectedClaims.nav, maxNAVDelta(), "the measured redemption NAV must round-trip the claim NAV");
        assertGe(post.covUtilWAD, pre.covUtilWAD, "a JT redemption cannot lower coverage utilization");
        _assertCommittedConservation();
    }

    /// @notice A JT redemption whose independently derived removal NAV exceeds the coverage breach boundary reverts
    ///         with `COVERAGE_REQUIREMENT_VIOLATED` and leaves the market untouched.
    function test_JTRedeem_reverts_coverageBreach() public {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 20);
        _sync();

        uint256 jtSupply = JT.totalSupply();
        uint256 shares = JT.balanceOf(JT_ALICE_ADDRESS);
        AssetClaims memory expectedClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.JUNIOR), shares, jtSupply);
        MarketSnapshot memory pre = _snap();
        assertLe(pre.covUtilWAD, WAD, "arrange: coverage must start satisfied");
        assertGt(toUint256(expectedClaims.nav), _jtCoverageBreachRedemptionNAV(), "arrange: the redemption must clear the breach boundary");
        assertLt(JT.maxRedeem(JT_ALICE_ADDRESS), shares, "arrange: the redemption must exceed the reported maximum");

        vm.prank(JT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        JT.redeem(shares, JT_ALICE_ADDRESS, JT_ALICE_ADDRESS);
        _assertMarketUnchanged(pre);
    }

    /// @notice In a fixed-term market a JT redemption reverts with `DISABLED_IN_FIXED_TERM_STATE`, `maxRedeem`
    ///         reports zero, and the junior max-withdrawable view zeroes.
    function test_JTRedeem_reverts_inFixedTerm() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        uint256 shares = JT.balanceOf(JT_ALICE_ADDRESS) / 2;
        _enterFixedTerm();

        assertEq(JT.maxRedeem(JT_ALICE_ADDRESS), 0, "jtMaxRedeem must report zero in a fixed term");
        (,, NAV_UNIT stMaxWithdrawableNAV, NAV_UNIT jtMaxWithdrawableNAV,) = KERNEL.jtMaxWithdrawable(JT_ALICE_ADDRESS);
        assertEq(stMaxWithdrawableNAV, ZERO_NAV_UNITS, "the junior ST-leg withdrawable must zero in a fixed term");
        assertEq(jtMaxWithdrawableNAV, ZERO_NAV_UNITS, "the junior JT-leg withdrawable must zero in a fixed term");

        vm.prank(JT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        JT.redeem(shares, JT_ALICE_ADDRESS, JT_ALICE_ADDRESS);
    }

    /// @notice With the liquidity requirement breached a coverage-satisfying junior redemption still succeeds:
    ///         the junior exit is coverage-gated only, never liquidity-gated.
    function test_JTRedeem_liquidityBreach_notGated() public whenLT {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 2);
        _seedDefaultLT();
        _setMinLiquidityWAD(0.9e18);
        _sync();
        MarketSnapshot memory pre = _snap();
        assertGt(pre.liqUtilWAD, WAD, "arrange: the liquidity requirement must be breached");

        uint256 shares = JT.maxRedeem(JT_ALICE_ADDRESS) / 2;
        assertGt(shares, 0, "arrange: the junior redemption must be nonzero");
        AssetClaims memory expectedClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.JUNIOR), shares, JT.totalSupply());
        OpReceipt memory r = _doRedeemJT(JT_ALICE_ADDRESS, shares);
        _assertClaimsEq(r.claims, expectedClaims, "liquidity-breached junior exit claims");
        assertLe(r.post.covUtilWAD, WAD, "the junior exit must leave coverage satisfied");
        assertEq(r.post.jtSupply, r.pre.jtSupply - shares, "JT supply must fall by exactly the redeemed shares");
        _assertCommittedConservation();
    }

    /**
     * @notice `jtMaxRedeem` inverts the coverage gate: the max-size redemption lands under it and a redemption past
     *         the independently derived breach boundary reverts.
     * @dev The breach share count converts `_jtCoverageBreachRedemptionNAV` to shares at the committed junior share
     *      price (ceiling) plus one share for the conversion floor.
     */
    function test_JTRedeem_maxRedeemInversion() public {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 20);
        _sync();

        uint256 maxShares = JT.maxRedeem(JT_ALICE_ADDRESS);
        assertGt(maxShares, 0, "arrange: the coverage surplus must be redeemable");
        assertLt(maxShares, JT.balanceOf(JT_ALICE_ADDRESS), "arrange: coverage must bound the redemption");

        uint256 snapshotId = vm.snapshotState();
        OpReceipt memory r = _doRedeemJT(JT_ALICE_ADDRESS, maxShares);
        assertLe(r.post.covUtilWAD, WAD, "a max-size JT redemption must leave coverage satisfied");
        _assertCommittedConservation();
        vm.revertToState(snapshotId);

        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 breachShares = Math.mulDiv(_jtCoverageBreachRedemptionNAV(), JT.totalSupply(), toUint256(a.lastJTEffectiveNAV), Math.Rounding.Ceil) + 1;
        assertGt(breachShares, maxShares, "the breach redemption must exceed the reported maximum");
        assertLe(breachShares, JT.balanceOf(JT_ALICE_ADDRESS), "arrange: the breach redemption must be affordable");

        vm.prank(JT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        JT.redeem(breachShares, JT_ALICE_ADDRESS, JT_ALICE_ADDRESS);
    }

    /**
     * @notice A JT redemption in PERPETUAL with retained impermanent loss floor-scales the committed IL by the
     *         junior effective NAV ratio, realizing the redeemer's proportional recovery claim.
     * @dev D12 staging: IL is observable in PERPETUAL only when `0 < IL <= dust`, so the senior dust tolerance is
     *      raised above a small covered loss before it is taken (with a nonzero fixed-term duration so the erase
     *      branch does not fire).
     */
    function test_JTRedeem_scalesImpermanentLossFloor() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 2);
        _setFixedTermDuration(7 days);
        _sync();
        _raiseSTDustTolerance(toNAVUnits(toUint256(ACCOUNTANT.getState().lastSTRawNAV) / 100));
        _applySTLoss(0.001e18);
        _sync();

        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertTrue(a.lastMarketState == MarketState.PERPETUAL, "arrange: the dust-classified loss must keep the market perpetual");
        NAV_UNIT il0 = a.lastJTCoverageImpermanentLoss;
        assertGt(toUint256(il0), 0, "arrange: the impermanent loss must be retained");
        NAV_UNIT jtEff0 = a.lastJTEffectiveNAV;

        OpReceipt memory r = _doRedeemJT(JT_ALICE_ADDRESS, JT.balanceOf(JT_ALICE_ADDRESS) / 4);
        NAV_UNIT redemptionNAV = (r.pre.lastSTRaw - r.post.lastSTRaw) + (r.pre.lastJTRaw - r.post.lastJTRaw);
        NAV_UNIT jtEff1 = r.post.lastJTEff;
        assertEq(jtEff1, jtEff0 - redemptionNAV, "the junior effective NAV must fall by exactly the measured redemption NAV");
        NAV_UNIT expectedIL = toNAVUnits(Math.mulDiv(toUint256(il0), toUint256(jtEff1), toUint256(jtEff0)));
        assertEq(r.post.lastIL, expectedIL, "the impermanent loss must floor-scale by the junior effective NAV ratio");
        _assertCommittedConservation();
    }

    // ── S3.3 LT redemptions ──

    /**
     * @notice An in-kind LT redemption pays the proportional BPT slice plus the pro-rata slice of the staged idle
     *         premium senior shares directly to the redeemer, with exact per-field floor scaling and an exact-args
     *         `Redeem` event.
     */
    function test_LTRedeem_inKind_paysBPTAndIdleSliceDirectly() public whenLT {
        uint256 idleShares = _arrangeLTWithStagedIdlePremium();

        uint256 ltSupply = LT.totalSupply();
        AssetClaims memory totalClaims = _expectedTrancheClaims(TrancheType.LIQUIDITY);
        assertEq(totalClaims.stShares, idleShares, "arrange: the idle ledger must back the claims");
        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 8;
        AssetClaims memory expectedClaims = _scaleExpectedClaims(totalClaims, shares, ltSupply);
        assertGt(toUint256(expectedClaims.ltAssets), 0, "arrange: the redemption must claim a BPT slice");
        assertGt(expectedClaims.stShares, 0, "arrange: the redemption must claim an idle premium slice");
        MarketSnapshot memory pre = _snap();
        uint256 bptBalPre = IERC20(POOL).balanceOf(LT_ALICE_ADDRESS);
        uint256 stShareBalPre = ST.balanceOf(LT_ALICE_ADDRESS);

        vm.startPrank(LT_ALICE_ADDRESS);
        _expectRedeem(address(LT), LT_ALICE_ADDRESS, LT_ALICE_ADDRESS, expectedClaims, shares);
        AssetClaims memory claims = LT.redeem(shares, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        _assertClaimsEq(claims, expectedClaims, "executed claims");
        MarketSnapshot memory post = _snap();
        assertEq(IERC20(POOL).balanceOf(LT_ALICE_ADDRESS) - bptBalPre, toUint256(expectedClaims.ltAssets), "the BPT slice must be paid in kind");
        assertEq(ST.balanceOf(LT_ALICE_ADDRESS) - stShareBalPre, expectedClaims.stShares, "the idle premium slice must be paid as senior shares directly");
        assertEq(post.ltOwned, pre.ltOwned - expectedClaims.ltAssets, "ltOwned must fall by the BPT slice");
        assertEq(post.idleSTShares, pre.idleSTShares - expectedClaims.stShares, "the idle premium ledger must fall by the paid slice");
        assertEq(post.ltSupply, pre.ltSupply - shares, "LT supply must fall by exactly the redeemed shares");
        assertEq(post.lastLTRaw, KERNEL.ltConvertTrancheUnitsToNAVUnits(post.ltOwned), "the committed LT mark must be the fresh venue mark");
        assertLt(post.lastLTRaw, pre.lastLTRaw, "the committed LT mark must fall");
        assertEq(post.lastSTRaw, pre.lastSTRaw, "moving idle senior shares must not move the senior raw NAV");
        assertEq(post.lastSTEff, pre.lastSTEff, "moving idle senior shares must not move the senior effective NAV");
        assertLe(post.liqUtilWAD, WAD, "the redemption must leave the liquidity requirement satisfied");
        _assertCommittedConservation();
    }

    /// @notice Both LT redemption previews (in-kind view and multi-asset query-mode) equal execution exactly per
    ///         field in the same block, with staged idle premium in play.
    function test_LTRedeem_previewParity_inKindAndMultiAsset() public whenLT {
        _arrangeLTWithStagedIdlePremium();
        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 10;

        AssetClaims memory previewInKindClaims = LT.previewRedeem(shares);
        uint256 snapshotId = vm.snapshotState();
        OpReceipt memory rInKind = _doRedeemLT(LT_ALICE_ADDRESS, shares);
        _assertClaimsEq(rInKind.claims, previewInKindClaims, "in-kind previewRedeem parity");
        assertGt(toUint256(rInKind.claims.ltAssets), 0, "the in-kind redemption must pay a BPT slice");
        _assertCommittedConservation();
        vm.revertToState(snapshotId);

        (AssetClaims memory previewMultiClaims, uint256 previewQuoteAssets) = _previewRedeemLTMulti(shares);
        OpReceipt memory rMulti = _doRedeemLTMulti(LT_ALICE_ADDRESS, shares, 0, 0);
        _assertClaimsEq(rMulti.claims, previewMultiClaims, "multi-asset previewRedeem parity");
        assertEq(rMulti.quoteAssets, previewQuoteAssets, "the previewed quote assets must equal execution exactly");
        assertGt(rMulti.quoteAssets, 0, "the multi-asset redemption must pay quote assets");
        _assertCommittedConservation();
    }

    /// @notice An LT redemption that would pull the pooled depth below the senior liquidity floor reverts with
    ///         `LIQUIDITY_REQUIREMENT_VIOLATED` and leaves the market untouched.
    function test_LTRedeem_reverts_liquidityGateBreach() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtil(0.9e18);
        _setMinLiquidityWAD(minLiquidityWAD);
        _sync();

        MarketSnapshot memory pre = _snap();
        assertLe(pre.liqUtilWAD, WAD, "arrange: the gate must start open");
        assertGt(pre.liqUtilWAD, WAD / 2, "arrange: utilization must sit near the gate");
        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 2;
        _assertSliceWouldBreachLiquidity(shares, minLiquidityWAD, pre);

        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        LT.redeem(shares, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
        _assertMarketUnchanged(pre);
    }

    /**
     * @notice Once the liquidation coverage utilization threshold is breached an LT redemption bypasses the
     *         liquidity gate entirely: a redemption that leaves utilization above WAD succeeds and `maxRedeem`
     *         reports the holder's full balance.
     */
    function test_LTRedeem_liquidationBreach_bypassesLiquidityGate() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtil(0.9e18);
        _setMinLiquidityWAD(minLiquidityWAD);
        _breachLiquidation();

        MarketSnapshot memory pre = _snap();
        assertGe(pre.covUtilWAD, ACCOUNTANT.getState().coverageLiquidationUtilizationWAD, "arrange: the liquidation threshold must be breached");
        uint256 shares = (LT.balanceOf(LT_ALICE_ADDRESS) * 3) / 4;
        _assertSliceWouldBreachLiquidity(shares, minLiquidityWAD, pre);
        assertEq(LT.maxRedeem(LT_ALICE_ADDRESS), LT.balanceOf(LT_ALICE_ADDRESS), "the full pooled depth must be withdrawable once liquidation is breached");

        OpReceipt memory r = _doRedeemLT(LT_ALICE_ADDRESS, shares);
        assertGt(toUint256(r.claims.ltAssets), 0, "the bypassed redemption must pay the BPT slice");
        assertGt(r.post.liqUtilWAD, WAD, "the gate must have been truly bypassed");
        assertEq(r.post.ltSupply, r.pre.ltSupply - shares, "LT supply must fall by exactly the redeemed shares");
        _assertCommittedConservation();
    }

    /**
     * @notice `ltMaxRedeem` inverts the liquidity gate: the max-size redemption lands under it and the same
     *         redemption plus the documented slack reverts.
     * @dev Breach slack derivation (F17): `maxLTWithdrawal` under-reports the exact boundary by the senior dust
     *      tolerance plus at most one wei of ceiling drift, and the realized venue-mark drop can undershoot the
     *      scaled claim value by up to two quoter round-trips, so the slack is that dust plus two `maxNAVDelta()`
     *      plus two wei, converted to LT shares at the committed mark (ceiling) plus two shares for share floors.
     */
    function test_LTRedeem_maxRedeemInversion() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtil(0.5e18);
        _setMinLiquidityWAD(minLiquidityWAD);
        _sync();

        uint256 maxShares = LT.maxRedeem(LT_ALICE_ADDRESS);
        assertGt(maxShares, 0, "arrange: the liquidity surplus must be redeemable");
        assertLt(maxShares, LT.balanceOf(LT_ALICE_ADDRESS), "arrange: the liquidity requirement must bound the redemption");

        uint256 snapshotId = vm.snapshotState();
        OpReceipt memory r = _doRedeemLT(LT_ALICE_ADDRESS, maxShares);
        assertLe(r.post.liqUtilWAD, WAD, "a max-size LT redemption must leave the liquidity requirement satisfied");
        _assertCommittedConservation();
        vm.revertToState(snapshotId);

        IRoycoDayAccountant.RoycoDayAccountantState memory a2 = ACCOUNTANT.getState();
        uint256 slackValue = toUint256(a2.stNAVDustTolerance) + 2 * toUint256(maxNAVDelta()) + 2;
        uint256 breachShares = maxShares + Math.mulDiv(slackValue, LT.totalSupply(), toUint256(a2.lastLTRawNAV), Math.Rounding.Ceil) + 2;
        assertLe(breachShares, LT.balanceOf(LT_ALICE_ADDRESS), "arrange: the breach redemption must be affordable");

        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        LT.redeem(breachShares, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
    }

    /**
     * @notice A multi-asset LT redemption unwinds the senior leg to the receiver in underlying, pays the quote
     *         straight through, burns the venue-withdrawn plus idle senior shares, emits an exact-args
     *         `MultiAssetRedeem`, and a quote min-out breach reverts inside Balancer leaving the market untouched.
     * @dev Event and balance expectations reuse the query-mode preview, whose exactness against execution is pinned
     *      by the parity test. The min-out breach asserts Balancer's exact `AmountOutBelowMin` args (D9). No
     *      deadline parameter exists on this surface (D1).
     */
    function test_LTRedeemMultiAsset_unwindsSeniorLeg_minOutsAndEvent() public whenLT {
        _arrangeLTWithStagedIdlePremium();

        uint256 ltSupply = LT.totalSupply();
        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 8;
        AssetClaims memory expectedLTClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.LIQUIDITY), shares, ltSupply);
        assertGt(expectedLTClaims.stShares, 0, "arrange: the redemption must carry an idle premium slice");
        (AssetClaims memory previewClaims, uint256 previewQuoteAssets) = _previewRedeemLTMulti(shares);
        assertGt(previewQuoteAssets, 0, "arrange: the redemption must pay quote assets");

        uint256 snapshotId = vm.snapshotState();
        MarketSnapshot memory pre = _snap();
        uint256 quoteBalPre = IERC20(testConfig.quoteAsset).balanceOf(LT_ALICE_ADDRESS);
        uint256 kernelQuoteBalPre = IERC20(testConfig.quoteAsset).balanceOf(address(KERNEL));
        uint256 stAssetBalPre = IERC20(testConfig.stAsset).balanceOf(LT_ALICE_ADDRESS);
        uint256 jtAssetBalPre = IERC20(testConfig.jtAsset).balanceOf(LT_ALICE_ADDRESS);

        vm.startPrank(LT_ALICE_ADDRESS);
        vm.expectEmit(true, true, true, true, address(LT));
        emit IRoycoLiquidityTranche.MultiAssetRedeem(LT_ALICE_ADDRESS, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS, shares, previewClaims, previewQuoteAssets);
        (AssetClaims memory claims, uint256 quoteAssets) =
            IRoycoLiquidityTranche(address(LT)).redeemMultiAsset(shares, 0, previewQuoteAssets, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        _assertClaimsEq(claims, previewClaims, "executed multi-asset claims");
        assertEq(quoteAssets, previewQuoteAssets, "the executed quote assets must equal the preview");
        MarketSnapshot memory post = _snap();
        assertEq(IERC20(testConfig.quoteAsset).balanceOf(LT_ALICE_ADDRESS) - quoteBalPre, previewQuoteAssets, "the quote must go straight to the receiver");
        assertEq(IERC20(testConfig.quoteAsset).balanceOf(address(KERNEL)), kernelQuoteBalPre, "the kernel must never custody the quote leg");
        _assertSTAndJTClaimsPaid(LT_ALICE_ADDRESS, stAssetBalPre, jtAssetBalPre, previewClaims);
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal - expectedLTClaims.stShares, "the kernel's held senior shares must fall by the idle slice");
        assertEq(post.idleSTShares, pre.idleSTShares - expectedLTClaims.stShares, "the idle premium ledger must fall by the idle slice");
        assertEq(post.ltOwned, pre.ltOwned - expectedLTClaims.ltAssets, "ltOwned must fall by the BPT slice");
        assertEq(post.ltSupply, pre.ltSupply - shares, "LT supply must fall by exactly the redeemed shares");
        uint256 stSharesBurned = pre.stSupply - post.stSupply;
        assertGt(stSharesBurned, expectedLTClaims.stShares, "the venue-withdrawn senior shares must be burned on top of the idle slice");
        NAV_UNIT redemptionNAV = (pre.lastSTRaw - post.lastSTRaw) + (pre.lastJTRaw - post.lastJTRaw);
        assertEq(post.lastSTEff, pre.lastSTEff - redemptionNAV, "the senior effective NAV must fall by exactly the measured redemption NAV");
        assertEq(post.lastJTEff, pre.lastJTEff, "the junior effective NAV must be untouched with no liquidation bonus");
        assertApproxEqAbs(redemptionNAV, previewClaims.nav, maxNAVDelta(), "the measured redemption NAV must round-trip the claim NAV");
        assertLe(post.liqUtilWAD, WAD, "the redemption must leave the liquidity requirement satisfied");
        _assertCommittedConservation();

        // A quote min-out one wei above the removal's output reverts inside Balancer and the market is untouched
        vm.revertToState(snapshotId);
        MarketSnapshot memory preBreach = _snap();
        vm.startPrank(LT_ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.AmountOutBelowMin.selector, testConfig.quoteAsset, previewQuoteAssets, previewQuoteAssets + 1));
        IRoycoLiquidityTranche(address(LT)).redeemMultiAsset(shares, 0, previewQuoteAssets + 1, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertMarketUnchanged(preBreach);
    }

    /// @notice A zero-share LT redemption reverts with `MUST_REQUEST_NON_ZERO_SHARES` on both the in-kind and the
    ///         multi-asset flow.
    function test_LTRedeem_reverts_zeroShares() public whenLT {
        _setupLTProviders();
        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoVaultTranche.MUST_REQUEST_NON_ZERO_SHARES.selector);
        LT.redeem(0, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);

        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoVaultTranche.MUST_REQUEST_NON_ZERO_SHARES.selector);
        IRoycoLiquidityTranche(address(LT)).redeemMultiAsset(0, 0, 0, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
    }

    /// @notice In a fixed-term market both LT redemption flows revert with `DISABLED_IN_FIXED_TERM_STATE`,
    ///         `maxRedeem` reports zero, and both previews return empty claims (the preview-zeros contract).
    function test_LTRedeem_reverts_inFixedTerm() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 2;
        _enterFixedTerm();

        assertEq(LT.maxRedeem(LT_ALICE_ADDRESS), 0, "ltMaxRedeem must report zero in a fixed term");
        AssetClaims memory emptyClaims;
        _assertClaimsEq(LT.previewRedeem(shares), emptyClaims, "the in-kind preview must zero in a fixed term");
        (AssetClaims memory previewMultiClaims, uint256 previewQuoteAssets) = _previewRedeemLTMulti(shares);
        _assertClaimsEq(previewMultiClaims, emptyClaims, "the multi-asset preview must zero in a fixed term");
        assertEq(previewQuoteAssets, 0, "the multi-asset preview quote must zero in a fixed term");

        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        LT.redeem(shares, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);

        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        IRoycoLiquidityTranche(address(LT)).redeemMultiAsset(shares, 0, 0, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
    }

    /**
     * @notice A multi-asset LT redemption whose senior-share min-out exceeds the venue withdrawal reverts inside
     *         Balancer with the exact-args `AmountOutBelowMin` on the senior share token and leaves the market
     *         untouched (atomicity).
     * @dev The venue's senior-share withdrawal is measured by a snapshot-reverted execution probe (the burned
     *      supply delta, exactly the venue leg with no idle premium staged), which is deterministic against the
     *      identical same-block state the breach call then sees.
     */
    function test_LTRedeemMultiAsset_reverts_minSTSharesOutBreach_atomic() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _sync();
        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 4;
        MarketSnapshot memory pre = _snap();
        assertEq(pre.idleSTShares, 0, "arrange: no staged premium may exist");

        uint256 snapshotId = vm.snapshotState();
        vm.prank(LT_ALICE_ADDRESS);
        IRoycoLiquidityTranche(address(LT)).redeemMultiAsset(shares, 0, 0, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
        uint256 venueSTSharesOut = pre.stSupply - ST.totalSupply();
        vm.revertToState(snapshotId);
        assertGt(venueSTSharesOut, 0, "arrange: the venue must withdraw senior shares");

        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.AmountOutBelowMin.selector, address(ST), venueSTSharesOut, venueSTSharesOut + 1));
        IRoycoLiquidityTranche(address(LT)).redeemMultiAsset(shares, venueSTSharesOut + 1, 0, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
        _assertMarketUnchanged(pre);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S4 — SYNC / WATERFALL / PREMIUM LIFECYCLE BATTERY
    // ═══════════════════════════════════════════════════════════════════════════

    // ── S4.0 Section-local helpers ──

    /// @notice Executes a sync as the sync role and returns the resulting synced accounting state packet.
    function _syncWithState() internal returns (SyncedAccountingState memory state) {
        vm.prank(SYNC_ROLE_ADDRESS);
        state = KERNEL.syncTrancheAccounting();
    }

    /**
     * @notice Flushes any residual premium accrual with a small premium-paying sync, so the next measured
     *         window prices as a single constant-share window against zeroed accumulators.
     * @dev Admin operations warp and sync flat, which accrues time-weighted yield share without paying it
     *      (nothing pays until a gain lands). A small yield plus a sync pays the pending premiums, resetting
     *      both accumulators and stamping the accrual and payment timestamps to now.
     */
    function _flushPremiumAccrual() internal {
        _applySTYield(0.001e18);
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertEq(uint256(a.twJTYieldShareAccruedWAD), 0, "flush: the JT accrual accumulator must reset");
        assertEq(uint256(a.twLTYieldShareAccruedWAD), 0, "flush: the LT accrual accumulator must reset");
        assertEq(uint256(a.lastYieldShareAccrualTimestamp), uint256(a.lastPremiumPaymentTimestamp), "flush: the accrual and premium windows must coincide");
    }

    /**
     * @notice Builds and computes the independent waterfall expectation for the sync about to execute, from
     *         the committed checkpoint, the sync-time YDM previews, and the measured raw NAVs (D2).
     * @dev Must be called in the sync's own block, after every warp and simulate, so the previews and the
     *      elapsed window match what the sync will use. The stored time-weighted accumulators and both window
     *      starts are carried as inputs, so a window with residual unpaid accrual (an earlier non-paying sync,
     *      an admin warp, or a warp-required loss hook) prices exactly like production. Raw NAVs and YDM
     *      previews are waterfall inputs, not the code under test.
     */
    function _buildSyncExpectation(bool _fixedTermActive) internal returns (SyncExpectation memory e) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        e.twJTStart = uint256(a.twJTYieldShareAccruedWAD);
        e.twLTStart = uint256(a.twLTYieldShareAccruedWAD);
        e.premiumElapsed = block.timestamp - a.lastPremiumPaymentTimestamp;

        e.jtYieldShareWAD = _previewYieldShareAsAccountant(
            a.jtYDM,
            a.lastMarketState,
            _expectedCovUtil(a.lastSTRawNAV, a.lastJTRawNAV, ACCOUNTANT.JT_COINVESTED(), a.minCoverageWAD, a.lastJTEffectiveNAV),
            a.maxJTYieldShareWAD
        );
        e.ltYieldShareWAD = a.maxLTYieldShareWAD == 0
            ? 0
            : _previewYieldShareAsAccountant(
                a.ltYDM, a.lastMarketState, _expectedLiqUtil(a.lastSTEffectiveNAV, a.minLiquidityWAD, a.lastLTRawNAV), a.maxLTYieldShareWAD
            );
        e.elapsed = block.timestamp - a.lastYieldShareAccrualTimestamp;
        (e.stRawNew, e.jtRawNew,) = _measureFreshSyncInputs(ZERO_TRANCHE_UNITS);
        e.lastSTRaw = a.lastSTRawNAV;
        e.lastJTRaw = a.lastJTRawNAV;
        e.lastSTEff = a.lastSTEffectiveNAV;
        e.lastJTEff = a.lastJTEffectiveNAV;
        e.lastIL = a.lastJTCoverageImpermanentLoss;
        e.stFeeWAD = a.stProtocolFeeWAD;
        e.jtFeeWAD = a.jtProtocolFeeWAD;
        e.jtYsFeeWAD = a.jtYieldShareProtocolFeeWAD;
        e.ltYsFeeWAD = a.ltYieldShareProtocolFeeWAD;
        e.effectiveDust = a.effectiveNAVDustTolerance;
        e.fixedTermActive = _fixedTermActive;
        e = _expectedSync(e);
    }

    /// @notice Asserts the executed sync's returned packet and committed checkpoint against the independent
    ///         waterfall expectation, plus wei-exact committed conservation.
    function _assertSyncMatchesExpectation(SyncedAccountingState memory _state, SyncExpectation memory _e) internal view {
        assertEq(_state.stEffectiveNAV, _e.stEff, "returned ST effective NAV vs the independent waterfall");
        assertEq(_state.jtEffectiveNAV, _e.jtEff, "returned JT effective NAV vs the independent waterfall");
        assertEq(_state.ltLiquidityPremium, _e.ltPremium, "returned LT liquidity premium vs the independent waterfall");
        assertEq(_state.stProtocolFee, _e.stFee, "returned ST protocol fee vs the independent waterfall");
        assertEq(_state.jtProtocolFee, _e.jtFee, "returned JT protocol fee vs the independent waterfall");
        assertEq(_state.ltProtocolFee, _e.ltFee, "returned LT protocol fee vs the independent waterfall");
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertEq(a.lastSTRawNAV, _e.stRawNew, "committed ST raw NAV must equal the measured input");
        assertEq(a.lastJTRawNAV, _e.jtRawNew, "committed JT raw NAV must equal the measured input");
        assertEq(a.lastSTEffectiveNAV, _e.stEff, "committed ST effective NAV vs the independent waterfall");
        assertEq(a.lastJTEffectiveNAV, _e.jtEff, "committed JT effective NAV vs the independent waterfall");
        _assertCommittedConservation();
    }

    /**
     * @notice Arranges the dust-pool staged-premium market for the premium-mint syncs and returns the built
     *         expectation for the sync under test (which the caller executes).
     * @dev The pool is dust-deep so the premium overruns the venue's unbalanced-add invariant-ratio cap and
     *      the inline reinvestment reverts, staying idle, with the zero-slippage seam as the first belt.
     *      Skips the test when the venue exposes no reinvestment slippage seam (capability, D7).
     */
    function _arrangeStagedPremiumSyncExpectation() internal returns (SyncExpectation memory e) {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _setupLTProviders();
        uint256 stLegAssets = testConfig.initialFunding / 10_000;
        _seedLTBalanced(LT_ALICE_ADDRESS, stLegAssets);
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtil(0.8e18);
        _enableLTOverlay(0.1e18, 0.5e18, minLiquidityWAD);
        vm.skip(!_trySetReinvestmentSlippage(0));
        _flushPremiumAccrual();
        _warpForward(1 days);
        _applySTYield(0.01e18);
        e = _buildSyncExpectation(false);
        assertGt(toUint256(e.ltPremium), 0, "arrange: the LDM must price a nonzero liquidity premium");
    }

    /// @notice Stages an idle premium against the dust-deep pool (where the inline deployment cannot land)
    ///         and returns the staged idle senior share balance.
    function _arrangeStagedIdlePremium() internal returns (uint256 idleShares) {
        _arrangeStagedPremiumSyncExpectation();
        _sync();
        idleShares = KERNEL.getState().ltOwnedSeniorTrancheShares;
        assertGt(idleShares, 0, "arrange: the liquidity premium must be staged idle");
    }

    /**
     * @notice Arranges a staged idle premium the venue CAN absorb once the slippage gate opens: the premium
     *         stages against the dust-deep pool (whose venue bounds reject the inline add), then the pool is
     *         deepened in the same block, so the staged tranche becomes deployable on demand.
     * @dev The deepening deposits sync flat in the same block, so they mint no new premium and cannot touch
     *      the staged idle ledger, which is asserted. Skips when no slippage seam exists (capability, D7).
     */
    function _arrangeReinvestableIdlePremium() internal returns (uint256 idleShares) {
        idleShares = _arrangeStagedIdlePremium();
        uint256 stLegAssets = testConfig.initialFunding / 100;
        _seedLTBalanced(LT_BOB_ADDRESS, stLegAssets);
        assertEq(KERNEL.getState().ltOwnedSeniorTrancheShares, idleShares, "arrange: deepening the pool must not consume the staged premium");
    }

    /// @notice Scans recorded logs for the given event topic from the given emitter, returning the match
    ///         count and the data of the last match.
    function _lastLogData(Vm.Log[] memory _logs, address _emitter, bytes32 _topic0) internal pure returns (uint256 count, bytes memory data) {
        for (uint256 i = 0; i < _logs.length; ++i) {
            if (_logs[i].emitter == _emitter && _logs[i].topics[0] == _topic0) {
                ++count;
                data = _logs[i].data;
            }
        }
    }

    // ── S4.1 Sync idempotence and the flat window ──

    /// @notice A second sync in the same block is a no-op: it re-reports the identical marks, pays nothing,
    ///         mints nothing, and moves no committed state, supply, or accrual accumulator.
    function test_Sync_idempotent_sameBlockNoOp() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applySTYield(0.05e18);
        SyncedAccountingState memory first = _syncWithState();
        MarketSnapshot memory pre = _snap();

        SyncedAccountingState memory second = _syncWithState();
        MarketSnapshot memory post = _snap();

        assertTrue(second.marketState == first.marketState, "the market state must not move");
        assertEq(second.stRawNAV, first.stRawNAV, "the senior raw NAV must not move");
        assertEq(second.jtRawNAV, first.jtRawNAV, "the junior raw NAV must not move");
        assertEq(second.ltRawNAV, first.ltRawNAV, "the liquidity raw NAV must not move");
        assertEq(second.stEffectiveNAV, first.stEffectiveNAV, "the senior effective NAV must not move");
        assertEq(second.jtEffectiveNAV, first.jtEffectiveNAV, "the junior effective NAV must not move");
        assertEq(second.jtCoverageImpermanentLoss, first.jtCoverageImpermanentLoss, "the impermanent loss must not move");
        assertEq(second.coverageUtilizationWAD, first.coverageUtilizationWAD, "the coverage utilization must not move");
        assertEq(second.liquidityUtilizationWAD, first.liquidityUtilizationWAD, "the liquidity utilization must not move");
        assertEq(second.ltLiquidityPremium, ZERO_NAV_UNITS, "the second sync must pay no liquidity premium");
        assertEq(second.stProtocolFee, ZERO_NAV_UNITS, "the second sync must take no ST fee");
        assertEq(second.jtProtocolFee, ZERO_NAV_UNITS, "the second sync must take no JT fee");
        assertEq(second.ltProtocolFee, ZERO_NAV_UNITS, "the second sync must take no LT fee");

        assertEq(post.lastSTRaw, pre.lastSTRaw, "the committed ST raw NAV must not move");
        assertEq(post.lastJTRaw, pre.lastJTRaw, "the committed JT raw NAV must not move");
        assertEq(post.lastLTRaw, pre.lastLTRaw, "the committed LT raw NAV must not move");
        assertEq(post.lastSTEff, pre.lastSTEff, "the committed ST effective NAV must not move");
        assertEq(post.lastJTEff, pre.lastJTEff, "the committed JT effective NAV must not move");
        assertEq(post.lastIL, pre.lastIL, "the committed impermanent loss must not move");
        assertEq(post.stSupply, pre.stSupply, "no senior shares may mint");
        assertEq(post.jtSupply, pre.jtSupply, "no junior shares may mint");
        assertEq(post.ltSupply, pre.ltSupply, "no liquidity shares may mint");
        assertEq(post.idleSTShares, pre.idleSTShares, "no premium may double-stage");
        assertEq(post.feeRecipientSTShares, pre.feeRecipientSTShares, "no ST fee may double-mint");
        assertEq(post.feeRecipientJTShares, pre.feeRecipientJTShares, "no JT fee may double-mint");
        assertEq(uint256(post.twJT), uint256(pre.twJT), "the JT accrual accumulator must not move");
        assertEq(uint256(post.twLT), uint256(pre.twLT), "the LT accrual accumulator must not move");
        assertEq(uint256(post.lastAccrualTs), uint256(pre.lastAccrualTs), "the accrual timestamp must not move");
        assertEq(uint256(post.lastPremiumTs), uint256(pre.lastPremiumTs), "the premium timestamp must not move");
        _assertCommittedConservation();
    }

    /**
     * @notice A sync over a window with no senior gain pays no premium, takes no fee, and mints nothing: it
     *         only settles the measured deltas and books the window's time-weighted yield share accrual.
     * @dev A warp-only window is not guaranteed flat (a streaming underlying, like snUSD, drifts the raw NAV
     *      up with time), so the measured drift is countered through the yield hook with a one-basis-point
     *      overshoot, pinning the window to the deterministic no-gain cell. The residual small covered loss
     *      settles exactly per the independent waterfall with every fee and premium output zero.
     */
    function test_Sync_flat_noPnl_noFeesNoPremium() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        _warpForward(1 days);

        // Counter any streaming drift so the window nets to no senior gain (a 0 percent move pins the rate)
        (NAV_UNIT stRawDrifted,,) = _measureFreshSyncInputs(ZERO_TRANCHE_UNITS);
        NAV_UNIT lastSTRawNAV = ACCOUNTANT.getState().lastSTRawNAV;
        uint256 driftCounterPctWAD = stRawDrifted > lastSTRawNAV
            ? Math.mulDiv(toUint256(stRawDrifted - lastSTRawNAV), WAD, toUint256(stRawDrifted), Math.Rounding.Ceil) + 0.0001e18
            : 0;
        simulateSTLoss(driftCounterPctWAD);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertLe(e.stRawNew, e.lastSTRaw, "arrange: the countered window must carry no senior gain");
        assertGt(e.elapsed, 0, "arrange: the accrual window must be nonzero");
        assertEq(e.ltPremium, ZERO_NAV_UNITS, "a no-gain window must pay no liquidity premium");
        assertEq(e.stFee, ZERO_NAV_UNITS, "a no-gain window must take no ST fee");
        assertEq(e.jtFee, ZERO_NAV_UNITS, "a no-gain window must take no JT fee");
        assertEq(e.ltFee, ZERO_NAV_UNITS, "a no-gain window must take no LT fee");
        assertFalse(e.premiumsPaid, "a no-gain window must not pay premiums");
        MarketSnapshot memory pre = _snap();

        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertEq(state.ltLiquidityPremium, ZERO_NAV_UNITS, "the sync must pay no liquidity premium");
        assertEq(state.stProtocolFee, ZERO_NAV_UNITS, "the sync must take no ST fee");
        assertEq(state.jtProtocolFee, ZERO_NAV_UNITS, "the sync must take no JT fee");
        assertEq(state.ltProtocolFee, ZERO_NAV_UNITS, "the sync must take no LT fee");
        assertEq(post.stSupply, pre.stSupply, "no senior shares may mint on a no-gain sync");
        assertEq(post.jtSupply, pre.jtSupply, "no junior shares may mint on a no-gain sync");
        assertEq(post.idleSTShares, pre.idleSTShares, "no premium may stage on a no-gain sync");
        assertEq(uint256(post.twJT), uint256(pre.twJT) + e.jtYieldShareWAD * e.elapsed, "the JT accrual must book exactly the window");
        assertEq(uint256(post.twLT), uint256(pre.twLT) + e.ltYieldShareWAD * e.elapsed, "the LT accrual must book exactly the window");
        assertEq(uint256(post.lastAccrualTs), block.timestamp, "the accrual timestamp must re-stamp");
        assertEq(uint256(post.lastPremiumTs), uint256(pre.lastPremiumTs), "no premium payment may stamp without a paid premium");
    }

    // ── S4.2 The PnL waterfall matrix ──

    /**
     * @notice A senior-gain sync settles the full waterfall exactly: attribution, JT risk premium, both
     *         protocol fees, exact-args accrual and fee-mint events, and the post-payment accumulator reset.
     * @dev On coinvested markets the hook moves both raw NAVs, so the expectation runs on the measured
     *      deltas (D2). The name describes the hook intent, not a guaranteed delta shape.
     */
    function test_Sync_stGain_exactWaterfall() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        _warpForward(1 days);
        _applySTYield(0.05e18);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(e.stRawNew, e.lastSTRaw, "arrange: the senior raw NAV must have appreciated");
        assertTrue(e.premiumsPaid, "arrange: the gain must clear the dust gate");
        assertGt(toUint256(e.stFee), 0, "arrange: an ST protocol fee must accrue");
        assertGt(toUint256(e.jtFee), 0, "arrange: a JT yield-share protocol fee must accrue");

        uint256 stSupplyPre = ST.totalSupply();
        uint256 jtSupplyPre = JT.totalSupply();
        (uint256 premShares, uint256 stFeeShares) = _expectedPremiumShares(e.ltPremium, e.stFee, e.stEff, stSupplyPre);
        uint256 jtFeeShares = _expectedShares(e.jtFee, jtSupplyPre, e.jtEff - e.jtFee);
        MarketSnapshot memory pre = _snap();

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareAccrued(e.jtYieldShareWAD, e.twJTStart + e.jtYieldShareWAD * e.elapsed);
        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.LiquidityTrancheYieldShareAccrued(e.ltYieldShareWAD, e.twLTStart + e.ltYieldShareWAD * e.elapsed);
        vm.expectEmit(true, false, false, true, address(ST));
        emit IRoycoVaultTranche.ProtocolFeeSharesMinted(PROTOCOL_FEE_RECIPIENT_ADDRESS, stFeeShares, stSupplyPre + premShares + stFeeShares);
        vm.expectEmit(true, false, false, true, address(JT));
        emit IRoycoVaultTranche.ProtocolFeeSharesMinted(PROTOCOL_FEE_RECIPIENT_ADDRESS, jtFeeShares, jtSupplyPre + jtFeeShares);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertEq(post.lastIL, e.il, "committed impermanent loss must match the independent waterfall");
        assertEq(post.stSupply, pre.stSupply + premShares + stFeeShares, "ST supply must grow by exactly the premium and fee mints");
        assertEq(post.jtSupply, pre.jtSupply + jtFeeShares, "JT supply must grow by exactly the fee mint");
        assertEq(post.feeRecipientSTShares - pre.feeRecipientSTShares, stFeeShares, "ST fee shares minted to the recipient");
        assertEq(post.feeRecipientJTShares - pre.feeRecipientJTShares, jtFeeShares, "JT fee shares minted to the recipient");
        assertEq(uint256(post.lastPremiumTs), block.timestamp, "the premium payment must stamp");
        assertEq(uint256(post.twJT), 0, "the JT accrual accumulator must reset after payment");
        assertEq(uint256(post.twLT), 0, "the LT accrual accumulator must reset after payment");
    }

    /// @notice A covered senior loss flows through JT coverage, and with a zero fixed-term duration the
    ///         forced-perpetual transition erases the just-created impermanent loss in the same sync.
    function test_Sync_stLoss_coveredByJT_ilErasedWhenPerpetualForced() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        // Establish the zero-duration (permanently perpetual) regime rather than requiring it of the deployed config
        if (uint256(ACCOUNTANT.getState().fixedTermDurationSeconds) != 0) _setFixedTermDuration(0);

        _applySTLoss(0.02e18);
        SyncExpectation memory e = _buildSyncExpectation(false);
        assertLt(e.stRawNew, e.lastSTRaw, "arrange: the senior raw NAV must have depreciated");
        assertGt(toUint256(e.il), 0, "arrange: coverage must be applied");
        assertGt(toUint256(e.jtEff), 0, "arrange: the loss must not exhaust the junior tranche");
        assertEq(e.stEff, e.lastSTEff, "the covered loss must leave the senior effective NAV whole");

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(e.il);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertTrue(a.lastMarketState == MarketState.PERPETUAL, "the market must stay perpetual");
        assertEq(a.lastJTCoverageImpermanentLoss, ZERO_NAV_UNITS, "the forced perpetual transition must erase the impermanent loss");
        assertEq(state.jtCoverageImpermanentLoss, ZERO_NAV_UNITS, "the returned packet must carry the erased impermanent loss");
        assertEq(state.stProtocolFee, ZERO_NAV_UNITS, "a loss sync must take no ST fee");
        assertEq(state.jtProtocolFee, ZERO_NAV_UNITS, "a loss sync must take no JT fee");
    }

    /**
     * @notice A covered loss on a nonzero-duration market commences a fixed term: exact end timestamp and
     *         event, exact retained impermanent loss, every fee and the LT premium zeroed, the accrued
     *         yield-share window retained (not reset), and the deposit lockout active.
     */
    function test_Sync_stLoss_entersFixedTerm_feesAndLTPremiumZeroed() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _setupLTProviders();
        uint256 stLegAssets = testConfig.initialFunding / 100;
        _seedLTBalanced(LT_ALICE_ADDRESS, stLegAssets);
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtil(0.8e18);
        _enableLTOverlay(0.1e18, 0.5e18, minLiquidityWAD);
        _setFixedTermDuration(7 days);
        _flushPremiumAccrual();
        uint256 premiumTsPre = ACCOUNTANT.getState().lastPremiumPaymentTimestamp;
        _warpForward(1 days);
        _applySTLoss(0.02e18);

        SyncExpectation memory e = _buildSyncExpectation(true);
        assertGt(e.il, e.effectiveDust, "arrange: the coverage applied must exceed the dust tolerance");
        assertGt(toUint256(e.jtEff), 0, "arrange: the loss must not exhaust the junior tranche");
        assertGt(e.ltYieldShareWAD, 0, "arrange: a liquidity premium must have been accruing");
        uint32 expectedEndTimestamp = uint32(block.timestamp + 7 days);

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.FixedTermCommenced(expectedEndTimestamp);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        assertTrue(state.marketState == MarketState.FIXED_TERM, "the returned packet must carry the fixed-term state");
        assertEq(state.ltLiquidityPremium, ZERO_NAV_UNITS, "the fixed-term sync must pay no liquidity premium");
        assertEq(state.stProtocolFee, ZERO_NAV_UNITS, "the fixed-term sync must take no ST fee");
        assertEq(state.jtProtocolFee, ZERO_NAV_UNITS, "the fixed-term sync must take no JT fee");
        assertEq(state.ltProtocolFee, ZERO_NAV_UNITS, "the fixed-term sync must take no LT fee");
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertTrue(a.lastMarketState == MarketState.FIXED_TERM, "the market must enter the fixed term");
        assertEq(uint256(a.fixedTermEndTimestamp), uint256(expectedEndTimestamp), "the fixed-term end must stamp exactly");
        assertEq(a.lastJTCoverageImpermanentLoss, e.il, "the impermanent loss must be retained exactly");
        assertEq(uint256(a.twJTYieldShareAccruedWAD), e.twJTStart + e.jtYieldShareWAD * e.elapsed, "the unpaid JT accrual must be retained");
        assertEq(uint256(a.twLTYieldShareAccruedWAD), e.twLTStart + e.ltYieldShareWAD * e.elapsed, "the unpaid LT accrual must be retained");
        assertEq(uint256(a.lastPremiumPaymentTimestamp), premiumTsPre, "no premium payment may stamp on a loss sync");

        uint256 assets = testConfig.initialFunding / 100;
        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), assets);
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        ST.deposit(toTrancheUnits(assets), ST_BOB_ADDRESS);
        vm.stopPrank();
    }

    /// @notice A gain covering the full impermanent loss recovers it to the junior tranche before premiums,
    ///         ends the fixed term, and settles the residual gain through the normal premium and fee path.
    function test_Sync_ilRecovery_exitsFixedTerm() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _setFixedTermDuration(7 days);
        _flushPremiumAccrual();
        _applySTLoss(0.02e18);
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        assertTrue(a0.lastMarketState == MarketState.FIXED_TERM, "arrange: the market must be in a fixed term");
        assertGt(a0.lastJTCoverageImpermanentLoss, ZERO_NAV_UNITS, "arrange: an impermanent loss must be retained");

        _warpForward(1 days);
        _applySTYield(0.05e18);
        SyncExpectation memory e = _buildSyncExpectation(false);
        assertEq(e.il, ZERO_NAV_UNITS, "arrange: the gain must fully recover the impermanent loss");
        assertTrue(e.premiumsPaid, "arrange: a residual gain must remain after the recovery");
        assertGt(toUint256(e.stFee), 0, "arrange: the exited market must take fees again");

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.FixedTermEnded();
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertTrue(a.lastMarketState == MarketState.PERPETUAL, "the market must exit the fixed term");
        assertEq(a.lastJTCoverageImpermanentLoss, ZERO_NAV_UNITS, "the impermanent loss must be fully recovered");
        assertEq(uint256(a.fixedTermEndTimestamp), 0, "the fixed-term end must clear");
        assertEq(uint256(a.lastPremiumPaymentTimestamp), block.timestamp, "the premium payment must stamp");
        assertEq(uint256(a.twJTYieldShareAccruedWAD), 0, "the JT accrual accumulator must reset after payment");
        assertEq(uint256(a.twLTYieldShareAccruedWAD), 0, "the LT accrual accumulator must reset after payment");
    }

    /// @notice A flat sync after the fixed term elapses forces the market perpetual, erases the retained
    ///         impermanent loss with exact-args events, and moves no effective NAV.
    function test_Sync_fixedTermElapsed_forcesPerpetual_erasesIL() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _setFixedTermDuration(7 days);
        _flushPremiumAccrual();
        _applySTLoss(0.02e18);
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        assertTrue(a0.lastMarketState == MarketState.FIXED_TERM, "arrange: the market must be in a fixed term");
        NAV_UNIT ilBefore = a0.lastJTCoverageImpermanentLoss;
        assertGt(ilBefore, ZERO_NAV_UNITS, "arrange: an impermanent loss must be retained");

        _warpForward(uint256(a0.fixedTermDurationSeconds) + 1);
        assertGt(block.timestamp, uint256(a0.fixedTermEndTimestamp), "arrange: the fixed term must have elapsed");
        uint256 premiumTsPre = a0.lastPremiumPaymentTimestamp;

        // The elapsed window may carry streaming drift, so the settlement runs on the measured deltas (D2)
        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(toUint256(e.il), 0, "arrange: an unrecovered impermanent loss must remain to erase");
        assertLe(e.il, ilBefore, "arrange: recovery can only shrink the retained impermanent loss");

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(e.il);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertTrue(state.marketState == MarketState.PERPETUAL, "the market must be forced perpetual");
        assertEq(post.lastIL, ZERO_NAV_UNITS, "the unrecovered impermanent loss must be erased");
        assertEq(state.jtCoverageImpermanentLoss, ZERO_NAV_UNITS, "the returned packet must carry the erased impermanent loss");
        assertEq(uint256(post.fixedTermEnd), 0, "the fixed-term end must clear");
        assertEq(uint256(post.lastPremiumTs), e.premiumsPaid ? block.timestamp : premiumTsPre, "the premium stamp must track the payment");
        assertEq(uint256(post.twJT), e.premiumsPaid ? 0 : e.twJTStart + e.jtYieldShareWAD * e.elapsed, "the accumulator must reset only on payment");
    }

    /**
     * @notice A junior-gain sync settles the full waterfall exactly against the measured deltas.
     * @dev On coinvested markets the hook moves both raw NAVs together (D2), so this completes the reachable
     *      delta matrix alongside the flat, senior-gain, and loss cells.
     */
    function test_Sync_jtGain_exactWaterfall() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        uint256 premiumTsPre = ACCOUNTANT.getState().lastPremiumPaymentTimestamp;
        _warpForward(1 days);
        _applyJTYield(0.05e18);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(e.jtRawNew, e.lastJTRaw, "arrange: the junior raw NAV must have appreciated");

        uint256 stSupplyPre = ST.totalSupply();
        uint256 jtSupplyPre = JT.totalSupply();
        (uint256 premShares, uint256 stFeeShares) = _expectedPremiumShares(e.ltPremium, e.stFee, e.stEff, stSupplyPre);
        uint256 jtFeeShares = _expectedShares(e.jtFee, jtSupplyPre, e.jtEff - e.jtFee);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertEq(post.lastIL, e.il, "committed impermanent loss must match the independent waterfall");
        assertEq(post.stSupply, stSupplyPre + premShares + stFeeShares, "ST supply must grow by exactly the premium and fee mints");
        assertEq(post.jtSupply, jtSupplyPre + jtFeeShares, "JT supply must grow by exactly the fee mint");
        assertEq(uint256(post.lastPremiumTs), e.premiumsPaid ? block.timestamp : premiumTsPre, "the premium stamp must track the payment");
        assertEq(uint256(post.twJT), e.premiumsPaid ? 0 : e.twJTStart + e.jtYieldShareWAD * e.elapsed, "the accumulator must reset only on payment");
        _assertCommittedConservation();
    }

    /**
     * @notice A junior-loss sync settles the coverage waterfall exactly against the measured deltas, with
     *         the forced-perpetual erase on the zero-duration baseline.
     * @dev The coverage expectation branches on the MEASURED senior delta: on a coupled-PnL kernel (shared
     *      feed, like the coinvested family) the junior loss drags the senior raw NAV down too, so coverage
     *      applies and the erase event fires, while on a decoupled kernel the junior tranche simply absorbs
     *      its own loss with no coverage touched. Both cells settle to the same independent waterfall.
     */
    function test_Sync_jtLoss_exactWaterfall() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        // Establish the zero-duration (permanently perpetual) regime rather than requiring it of the deployed config
        if (uint256(ACCOUNTANT.getState().fixedTermDurationSeconds) != 0) _setFixedTermDuration(0);

        _applyJTLoss(0.02e18);
        SyncExpectation memory e = _buildSyncExpectation(false);
        assertLt(e.jtRawNew, e.lastJTRaw, "arrange: the junior raw NAV must have depreciated");
        assertLt(e.jtEff, e.lastJTEff, "the junior effective NAV must absorb the loss");

        if (toUint256(e.il) > 0) {
            // Coupled hooks: the senior raw NAV depreciated alongside, so coverage applied and is erased
            assertLt(e.stRawNew, e.lastSTRaw, "a nonzero coverage application requires a measured senior depreciation");
            vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
            emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(e.il);
        }
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertTrue(a.lastMarketState == MarketState.PERPETUAL, "the market must stay perpetual");
        assertEq(a.lastJTCoverageImpermanentLoss, ZERO_NAV_UNITS, "the forced perpetual transition must erase the impermanent loss");
        assertEq(state.stProtocolFee, ZERO_NAV_UNITS, "a loss sync must take no ST fee");
        assertEq(state.jtProtocolFee, ZERO_NAV_UNITS, "a loss sync must take no JT fee");
        assertEq(state.ltLiquidityPremium, ZERO_NAV_UNITS, "a loss sync must pay no liquidity premium");
    }

    /**
     * @notice A loss exceeding the junior loss-absorption buffer settles the residual waterfall exactly: coverage
     *         exhausts the junior effective NAV to exactly zero, the residual falls on the senior effective NAV,
     *         coverage utilization saturates, and the exhausted market is forced perpetual with the IL erased.
     */
    function test_Sync_stLoss_residualExceedsCoverage_exactWaterfall() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 16);
        _sync();

        // Size the loss from the measured committed ratio so it strictly exceeds the junior buffer
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        uint256 lossPctWAD = Math.mulDiv(toUint256(a0.lastJTEffectiveNAV), WAD, toUint256(a0.lastSTRawNAV), Math.Rounding.Ceil) + 0.02e18;
        assertLt(lossPctWAD, WAD, "arrange: the exhausting loss must be representable");
        _applySTLoss(lossPctWAD);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertLt(e.stRawNew, e.lastSTRaw, "arrange: the senior raw NAV must have depreciated");
        assertEq(e.jtEff, ZERO_NAV_UNITS, "the coverage application must exhaust the junior effective NAV to exactly zero");
        assertLt(e.stEff, e.lastSTEff, "the residual loss must fall on the senior effective NAV");
        assertGt(toUint256(e.il), 0, "arrange: the applied coverage must book an impermanent loss");

        // The exhausted (jtEff == 0, stEff > 0) market is forced perpetual, erasing the just-booked IL
        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(e.il);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        assertEq(state.coverageUtilizationWAD, type(uint256).max, "coverage utilization must saturate with an exhausted junior tranche");
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertTrue(a.lastMarketState == MarketState.PERPETUAL, "the exhausted market must be forced perpetual");
        assertEq(a.lastJTCoverageImpermanentLoss, ZERO_NAV_UNITS, "the forced perpetual transition must erase the impermanent loss");
        assertEq(state.stProtocolFee, ZERO_NAV_UNITS, "a loss sync must take no ST fee");
        assertEq(state.jtProtocolFee, ZERO_NAV_UNITS, "a loss sync must take no JT fee");
    }

    // ── S4.3 Premium accrual windows ──

    /// @notice The first-ever sync initializes the accrual clock only: a pre-genesis window with pending
    ///         oracle drift pays no premium, takes no fee, mints nothing, and stamps both timestamps.
    function test_Sync_firstSyncAfterDeploy_paysNoPremium() public {
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        assertEq(uint256(a0.lastYieldShareAccrualTimestamp), 0, "arrange: no accrual may be stamped yet");
        assertEq(uint256(a0.lastPremiumPaymentTimestamp), 0, "arrange: no premium may be stamped yet");

        _warpForward(1 days);
        _applySTYield(0.05e18);
        SyncedAccountingState memory state = _syncWithState();

        assertEq(state.ltLiquidityPremium, ZERO_NAV_UNITS, "the genesis sync must pay no liquidity premium");
        assertEq(state.stProtocolFee, ZERO_NAV_UNITS, "the genesis sync must take no ST fee");
        assertEq(state.jtProtocolFee, ZERO_NAV_UNITS, "the genesis sync must take no JT fee");
        assertEq(state.stEffectiveNAV, ZERO_NAV_UNITS, "no senior value exists before the first deposit");
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertEq(uint256(a.lastYieldShareAccrualTimestamp), block.timestamp, "the accrual clock must initialize");
        assertEq(uint256(a.lastPremiumPaymentTimestamp), block.timestamp, "the premium clock must initialize");
        assertEq(uint256(a.twJTYieldShareAccruedWAD), 0, "no pre-genesis JT accrual may book");
        assertEq(uint256(a.twLTYieldShareAccruedWAD), 0, "no pre-genesis LT accrual may book");
        assertEq(ST.totalSupply(), 0, "no senior shares may mint");
        assertEq(ST.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS), 0, "no fee shares may mint");
        _assertCommittedConservation();
    }

    /// @notice A single warped accrual window pays the JT risk premium exactly, emits the exact-args accrual
    ///         event, resets the accumulators, and stamps the premium payment.
    function test_Sync_jtRiskPremium_singleWindowExact() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        _warpForward(1 days);
        _applySTYield(0.05e18);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(toUint256(e.jtRiskPremium), 0, "arrange: a JT risk premium must be due");
        assertGt(e.elapsed, 0, "arrange: the accrual window must be nonzero");
        uint256 jtSupplyPre = JT.totalSupply();
        uint256 jtFeeShares = _expectedShares(e.jtFee, jtSupplyPre, e.jtEff - e.jtFee);
        uint256 feeRecipientJTPre = JT.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareAccrued(e.jtYieldShareWAD, e.twJTStart + e.jtYieldShareWAD * e.elapsed);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertEq(uint256(a.lastPremiumPaymentTimestamp), block.timestamp, "the premium payment must stamp");
        assertEq(uint256(a.twJTYieldShareAccruedWAD), 0, "the JT accrual accumulator must reset after payment");
        assertEq(uint256(a.twLTYieldShareAccruedWAD), 0, "the LT accrual accumulator must reset after payment");
        assertEq(JT.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS) - feeRecipientJTPre, jtFeeShares, "JT yield-share fee shares minted to the recipient");
    }

    /**
     * @notice A premium spanning two accrual windows (the first flat and unpaid) settles as the exact
     *         time-weighted average: `floor(stGain * (twCarried + share * window2) / (premiumWindow * WAD))`.
     * @dev The first window is pinned flat with the drift counter (the flat-sync test's technique) so its
     *      accrual carries unpaid, making the premium window strictly longer than the final accrual window.
     */
    function test_Sync_premium_multiWindowAccrual_exact() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _flushPremiumAccrual();

        // Window 1: warp, counter the streaming drift so no senior gain books, and sync (accrues, pays nothing)
        _warpForward(1 days);
        (NAV_UNIT stRawDrifted,,) = _measureFreshSyncInputs(ZERO_TRANCHE_UNITS);
        NAV_UNIT lastSTRawNAV = ACCOUNTANT.getState().lastSTRawNAV;
        uint256 driftCounterPctWAD = stRawDrifted > lastSTRawNAV
            ? Math.mulDiv(toUint256(stRawDrifted - lastSTRawNAV), WAD, toUint256(stRawDrifted), Math.Rounding.Ceil) + 0.0001e18
            : 0;
        simulateSTLoss(driftCounterPctWAD);
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a1 = ACCOUNTANT.getState();
        assertGt(uint256(a1.twJTYieldShareAccruedWAD), 0, "arrange: the first window's accrual must carry unpaid");
        assertGt(uint256(a1.lastYieldShareAccrualTimestamp), uint256(a1.lastPremiumPaymentTimestamp), "arrange: the accrual clock must lead the premium clock");

        // Window 2: a real gain pays the premium priced over BOTH windows
        _warpForward(1 days);
        _applySTYield(0.05e18);
        SyncExpectation memory e = _buildSyncExpectation(false);
        assertEq(e.twJTStart, uint256(a1.twJTYieldShareAccruedWAD), "arrange: the carried accrual must feed the expectation");
        assertGt(e.premiumElapsed, e.elapsed, "arrange: the premium window must span both accrual windows");
        assertTrue(e.premiumsPaid, "arrange: the gain must clear the dust gate");
        assertGt(toUint256(e.jtRiskPremium), 0, "arrange: a JT risk premium must be due");

        SyncedAccountingState memory state = _syncWithState();
        _assertSyncMatchesExpectation(state, e);
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertEq(uint256(a.lastPremiumPaymentTimestamp), block.timestamp, "the premium payment must stamp");
        assertEq(uint256(a.twJTYieldShareAccruedWAD), 0, "the JT accrual accumulator must reset after payment");
        assertEq(uint256(a.twLTYieldShareAccruedWAD), 0, "the LT accrual accumulator must reset after payment");
    }

    // ── S4.4 The LT liquidity premium mint ──

    /// @notice The LT liquidity premium mints exactly the expected senior shares into the kernel's idle
    ///         ledger, with exact-args accrual and premium-mint events and the joint-pricing supply growth.
    function test_Sync_ltLiquidityPremium_mintsIdleSTShares() public whenLT {
        SyncExpectation memory e = _arrangeStagedPremiumSyncExpectation();
        assertLe(e.jtYieldShareWAD + e.ltYieldShareWAD, WAD, "the yield share caps must preclude PREMIUMS_EXCEED_SENIOR_YIELD");
        uint256 stSupplyPre = ST.totalSupply();
        (uint256 premShares, uint256 stFeeShares) = _expectedPremiumShares(e.ltPremium, e.stFee, e.stEff, stSupplyPre);
        assertGt(premShares, 0, "arrange: the premium must mint shares");
        MarketSnapshot memory pre = _snap();

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.LiquidityTrancheYieldShareAccrued(e.ltYieldShareWAD, e.twLTStart + e.ltYieldShareWAD * e.elapsed);
        vm.expectEmit(true, false, false, true, address(ST));
        emit IRoycoSeniorTranche.LiquidityPremiumSharesMinted(address(KERNEL), premShares, stSupplyPre + premShares);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertEq(post.idleSTShares, pre.idleSTShares + premShares, "the premium must stage as idle senior shares");
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal + premShares, "the kernel must custody the minted premium shares");
        assertEq(post.stSupply, pre.stSupply + premShares + stFeeShares, "senior supply must grow by exactly the two carve-outs");
        _assertSolvency();
    }

    /**
     * @notice The premium mint is coverage-neutral: it moves no raw NAV, grows senior supply by exactly the
     *         two carve-outs, keeps the premium inside the senior effective NAV, and leaves the production
     *         coverage utilization equal to the independent recompute.
     */
    function test_Sync_premiumMint_coverageNeutral() public whenLT {
        SyncExpectation memory e = _arrangeStagedPremiumSyncExpectation();
        uint256 stSupplyPre = ST.totalSupply();
        (uint256 premShares, uint256 stFeeShares) = _expectedPremiumShares(e.ltPremium, e.stFee, e.stEff, stSupplyPre);
        assertGt(premShares, 0, "arrange: the premium must mint shares");

        SyncedAccountingState memory state = _syncWithState();

        MarketSnapshot memory post = _snap();
        assertEq(post.lastSTRaw, e.stRawNew, "the mint must move no senior raw NAV");
        assertEq(post.lastJTRaw, e.jtRawNew, "the mint must move no junior raw NAV");
        assertEq(post.stSupply, stSupplyPre + premShares + stFeeShares, "senior supply must grow by exactly the premium and fee shares");
        assertEq(post.lastSTEff, e.stEff, "the senior effective NAV must include the minted premium");
        assertEq(
            state.coverageUtilizationWAD,
            _expectedCovUtil(e.stRawNew, e.jtRawNew, ACCOUNTANT.JT_COINVESTED(), ACCOUNTANT.getState().minCoverageWAD, e.jtEff),
            "the production coverage utilization must match the independent recompute"
        );
        _assertCommittedConservation();
    }

    /// @notice The committed LT raw NAV marks the BPT only while the LT effective NAV adds the claimable idle
    ///         premium leg, and the liquidity utilization reads the BPT-only mark.
    function test_Sync_ltRawNAVExcludesIdle_effectiveIncludesIt() public whenLT {
        uint256 idleShares = _arrangeLTWithStagedIdlePremium();

        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertEq(
            a.lastLTRawNAV,
            KERNEL.ltConvertTrancheUnitsToNAVUnits(KERNEL.getState().ltOwnedYieldBearingAssets),
            "the committed LT raw NAV must be the BPT mark only"
        );
        NAV_UNIT idleValue = _expectedValue(idleShares, ST.totalSupply(), a.lastSTEffectiveNAV);
        assertGt(toUint256(idleValue), 0, "arrange: the staged premium must carry value");
        assertApproxEqAbs(LT.totalAssets().nav, a.lastLTRawNAV + idleValue, maxNAVDelta(), "the LT effective NAV must include the claimable idle leg");

        SyncedAccountingState memory state = _syncWithState();
        uint256 rawBasedUtilWAD = _expectedLiqUtil(a.lastSTEffectiveNAV, a.minLiquidityWAD, a.lastLTRawNAV);
        assertEq(state.liquidityUtilizationWAD, rawBasedUtilWAD, "the production liquidity utilization must match the BPT-only recompute exactly");
        assertGt(
            rawBasedUtilWAD,
            _expectedLiqUtil(a.lastSTEffectiveNAV, a.minLiquidityWAD, a.lastLTRawNAV + idleValue),
            "the BPT-only utilization must read strictly under-provisioned versus the effective NAV while premium is staged"
        );
    }

    // ── S4.5 The premium reinvestment (inline and on demand) ──

    /**
     * @notice The production steady state: with the slippage gate open against a deep pool, a plain sync mints
     *         the liquidity premium AND deploys it inline in the same sync — nothing stages, the owned depth
     *         grows by the reported venue mint clearing the gate's derived minimum, and the freshly deployed
     *         depth is re-committed.
     */
    function test_Sync_ltPremium_inlineReinvestment_deploysSameSync() public whenLT {
        uint64 slippageWAD = 0.5e18;
        vm.skip(!_trySetReinvestmentSlippage(slippageWAD));
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _sync();
        _enableLTOverlay(0.1e18, 0.5e18, _minLiquidityForTargetUtil(0.8e18));
        _flushPremiumAccrual();
        _warpForward(1 days);
        _applySTYield(0.02e18);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(toUint256(e.ltPremium), 0, "arrange: the LDM must price a nonzero liquidity premium");
        uint256 stSupplyPre = ST.totalSupply();
        (uint256 premShares, uint256 stFeeShares) = _expectedPremiumShares(e.ltPremium, e.stFee, e.stEff, stSupplyPre);
        assertGt(premShares, 0, "arrange: the premium must mint shares");
        NAV_UNIT premiumValue = _expectedValue(premShares, stSupplyPre + premShares + stFeeShares, e.stEff);
        uint256 minLtAssetsOut = Math.mulDiv(toUint256(KERNEL.ltConvertNAVUnitsToTrancheUnits(premiumValue)), WAD - slippageWAD, WAD, Math.Rounding.Ceil);
        assertGt(minLtAssetsOut, 0, "arrange: the gate minimum must be nonzero");
        MarketSnapshot memory pre = _snap();
        assertEq(pre.idleSTShares, 0, "arrange: nothing may be staged before the sync");

        vm.recordLogs();
        SyncedAccountingState memory state = _syncWithState();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertEq(post.idleSTShares, 0, "the premium must deploy inline, staging nothing");
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal, "the kernel must hold no residual senior shares");
        assertEq(post.stSupply, pre.stSupply + premShares + stFeeShares, "senior supply must grow by exactly the two carve-outs");

        (uint256 reinvestedCount, bytes memory reinvestedData) = _lastLogData(logs, address(KERNEL), IRoycoDayKernel.LiquidityPremiumReinvested.selector);
        assertEq(reinvestedCount, 1, "exactly one inline reinvestment must be reported");
        (uint256 stSharesReinvested, uint256 ltAssetsMinted) = abi.decode(reinvestedData, (uint256, uint256));
        assertEq(stSharesReinvested, premShares, "the entire minted premium must deploy");
        uint256 ownedDeltaAssets = toUint256(post.ltOwned - pre.ltOwned);
        assertEq(ltAssetsMinted, ownedDeltaAssets, "the reported venue mint must match the owned-ledger delta");
        assertEq(post.kernelBPTBal - pre.kernelBPTBal, ownedDeltaAssets, "the kernel's BPT balance must grow by exactly the venue mint");
        assertGe(ownedDeltaAssets, minLtAssetsOut, "the inline mint must clear the slippage gate's derived minimum");
        assertEq(post.lastLTRaw, KERNEL.ltConvertTrancheUnitsToNAVUnits(post.ltOwned), "the freshly deployed depth must be re-committed");
        assertGt(post.lastLTRaw, pre.lastLTRaw, "the committed depth must grow");
        _assertSolvency();
        _assertCommittedConservation();
    }

    /**
     * @notice Opening the slippage gate and reinvesting deploys the entire idle balance into the venue: the
     *         idle ledger zeroes, the owned BPT grows by at least the gate's derived minimum and by exactly
     *         the event's reported mint, the fresh depth is re-committed, and utilization falls.
     * @dev The venue mint itself is a venue output, so its event args are cross-checked against the owned
     *      ledger delta from recorded logs rather than predicted.
     */
    function test_ReinvestLiquidityPremium_movesIdleIntoBPT() public whenLT {
        uint256 idleShares = _arrangeReinvestableIdlePremium();
        uint64 slippageWAD = 0.5e18;
        assertTrue(_trySetReinvestmentSlippage(slippageWAD), "arrange: the slippage gate must open");

        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        NAV_UNIT idleValue = _expectedValue(idleShares, ST.totalSupply(), a.lastSTEffectiveNAV);
        uint256 minLtAssetsOut = Math.mulDiv(toUint256(KERNEL.ltConvertNAVUnitsToTrancheUnits(idleValue)), WAD - slippageWAD, WAD, Math.Rounding.Ceil);
        assertGt(minLtAssetsOut, 0, "arrange: the gate minimum must be nonzero");
        MarketSnapshot memory pre = _snap();

        vm.recordLogs();
        vm.prank(KERNEL_ADMIN_ADDRESS);
        KERNEL.reinvestLiquidityPremium(type(uint256).max);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        MarketSnapshot memory post = _snap();
        assertEq(post.idleSTShares, 0, "the entire idle balance must deploy");
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal - idleShares, "the kernel must release the reinvested shares to the venue");
        assertEq(post.stSupply, pre.stSupply, "a reinvestment mints and burns no senior shares");
        uint256 ownedDeltaAssets = toUint256(post.ltOwned - pre.ltOwned);
        assertGe(ownedDeltaAssets, minLtAssetsOut, "the venue mint must clear the slippage gate's derived minimum");

        (uint256 reinvestedCount, bytes memory reinvestedData) = _lastLogData(logs, address(KERNEL), IRoycoDayKernel.LiquidityPremiumReinvested.selector);
        assertEq(reinvestedCount, 1, "exactly one reinvestment must be reported");
        (uint256 stSharesReinvested, uint256 ltAssetsMinted) = abi.decode(reinvestedData, (uint256, uint256));
        assertEq(stSharesReinvested, idleShares, "the event must report the exact idle balance deployed");
        assertEq(ltAssetsMinted, ownedDeltaAssets, "the event's venue mint must match the owned-ledger delta exactly");
        // The independent signal: the kernel's ERC20 BPT balance grew by exactly the credited mint
        assertEq(post.kernelBPTBal - pre.kernelBPTBal, ownedDeltaAssets, "the kernel's BPT balance must grow by exactly the credited venue mint");

        (uint256 commitCount, bytes memory commitData) = _lastLogData(logs, address(ACCOUNTANT), IRoycoDayAccountant.LiquidityTrancheRawNAVCommitted.selector);
        assertGt(commitCount, 0, "the fresh depth must be re-committed");
        assertEq(toNAVUnits(abi.decode(commitData, (uint256))), post.lastLTRaw, "the final commit must carry the committed mark");
        assertGt(post.lastLTRaw, pre.lastLTRaw, "the committed depth must grow");
        assertLt(post.liqUtilWAD, pre.liqUtilWAD, "the deployment must lower liquidity utilization");
        _assertSolvency();
        _assertCommittedConservation();
    }

    /// @notice A partial reinvestment debits exactly the requested shares from the idle ledger, leaves the
    ///         remainder staged, and its venue mint clears the slippage gate's derived minimum.
    function test_ReinvestLiquidityPremium_partialAmount() public whenLT {
        uint256 idleShares = _arrangeReinvestableIdlePremium();
        uint64 slippageWAD = 0.5e18;
        assertTrue(_trySetReinvestmentSlippage(slippageWAD), "arrange: the slippage gate must open");
        uint256 partialShares = idleShares / 2;
        assertGt(partialShares, 0, "arrange: the partial amount must be nonzero");

        // The same min-out derivation as the full-amount test, applied to the partial share count
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        NAV_UNIT partialValue = _expectedValue(partialShares, ST.totalSupply(), a.lastSTEffectiveNAV);
        uint256 minLtAssetsOut = Math.mulDiv(toUint256(KERNEL.ltConvertNAVUnitsToTrancheUnits(partialValue)), WAD - slippageWAD, WAD, Math.Rounding.Ceil);
        assertGt(minLtAssetsOut, 0, "arrange: the gate minimum must be nonzero");
        MarketSnapshot memory pre = _snap();

        vm.prank(KERNEL_ADMIN_ADDRESS);
        KERNEL.reinvestLiquidityPremium(partialShares);

        MarketSnapshot memory post = _snap();
        assertEq(post.idleSTShares, idleShares - partialShares, "exactly the requested shares must leave the idle ledger");
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal - partialShares, "the kernel must release exactly the requested shares");
        assertGe(toUint256(post.ltOwned - pre.ltOwned), minLtAssetsOut, "the venue mint must clear the slippage gate's derived minimum");
        assertEq(post.kernelBPTBal - pre.kernelBPTBal, toUint256(post.ltOwned - pre.ltOwned), "the kernel's BPT balance must grow by exactly the credited mint");
        _assertSolvency();
        _assertCommittedConservation();
    }

    /**
     * @notice A reinvestment attempt whose venue add cannot land is tolerated, not reverted: the idle and
     *         owned ledgers are untouched, no reinvestment event fires, and the market is unchanged.
     * @dev The staged premium overruns the dust pool's venue bounds and the slippage gate is forced shut,
     *      so the inner add reverts and the failure must be swallowed gracefully.
     */
    function test_ReinvestLiquidityPremium_gateFailureTolerated() public whenLT {
        uint256 idleShares = _arrangeStagedIdlePremium();
        MarketSnapshot memory pre = _snap();

        vm.recordLogs();
        vm.prank(KERNEL_ADMIN_ADDRESS);
        KERNEL.reinvestLiquidityPremium(type(uint256).max);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 reinvestedCount,) = _lastLogData(logs, address(KERNEL), IRoycoDayKernel.LiquidityPremiumReinvested.selector);
        assertEq(reinvestedCount, 0, "no reinvestment event may fire against a shut gate");
        assertEq(KERNEL.getState().ltOwnedSeniorTrancheShares, idleShares, "the idle ledger must be untouched");
        _assertMarketUnchanged(pre);
        _assertSolvency();
    }

    /**
     * @notice The full premium lifecycle: a staged tranche of premium is partially claimed in kind by a
     *         redeemer, the remainder deploys once the gate opens, and every minted premium share is
     *         accounted for as paid out, reinvested, or still idle (the I15 ghost ledger).
     */
    function test_LTPremium_lifecycle_endToEnd() public whenLT {
        uint256 idleStaged = _arrangeReinvestableIdlePremium();

        // Step 1: a redeemer takes 25 percent in kind and is paid its idle premium slice directly
        uint256 ltSupply = LT.totalSupply();
        uint256 shares = LT.balanceOf(LT_BOB_ADDRESS) / 4;
        uint256 expectedIdleSlice = Math.mulDiv(idleStaged, shares, ltSupply);
        assertGt(expectedIdleSlice, 0, "arrange: the redemption must claim an idle premium slice");
        uint256 redeemerSTSharesPre = ST.balanceOf(LT_BOB_ADDRESS);
        OpReceipt memory r = _doRedeemLT(LT_BOB_ADDRESS, shares);
        assertEq(ST.balanceOf(LT_BOB_ADDRESS) - redeemerSTSharesPre, expectedIdleSlice, "the idle premium slice must be paid directly");
        assertEq(r.post.idleSTShares, idleStaged - expectedIdleSlice, "the idle ledger must fall by the paid slice");
        assertGt(toUint256(r.claims.ltAssets), 0, "the redemption must pay a BPT slice");
        assertLe(r.post.liqUtilWAD, WAD, "the redemption must leave the liquidity requirement satisfied");
        _assertCommittedConservation();

        // Step 2: the gate opens and the remaining staged premium deploys into real depth
        assertTrue(_trySetReinvestmentSlippage(0.5e18), "arrange: the slippage gate must open");
        MarketSnapshot memory preReinvest = _snap();
        uint256 reinvestedShares = preReinvest.idleSTShares;
        vm.prank(KERNEL_ADMIN_ADDRESS);
        KERNEL.reinvestLiquidityPremium(type(uint256).max);
        MarketSnapshot memory post = _snap();
        assertEq(post.idleSTShares, 0, "the remaining staged premium must deploy");
        assertGt(post.ltOwned, preReinvest.ltOwned, "the deployment must credit the owned ledger");
        assertGt(post.lastLTRaw, preReinvest.lastLTRaw, "the committed depth must grow");
        assertLt(post.liqUtilWAD, preReinvest.liqUtilWAD, "the deployment must lower liquidity utilization");

        // Ghost ledger (I15): every minted premium share is paid out, reinvested, or still idle
        assertEq(idleStaged, expectedIdleSlice + reinvestedShares + post.idleSTShares, "ghost: minted premium shares must be fully accounted for");
        _assertSolvency();
        _assertCommittedConservation();
    }

    // ── S4.6 The yield share caps ──

    /// @notice When the YDM curves price above the configured maximums, the accrued yield shares bind at the
    ///         caps exactly, pinned by the exact-args accrual events and the capped premium settlement.
    function test_Sync_maxYieldSharesCapBinds() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 16);
        _setupLTProviders();
        uint256 stLegAssets = testConfig.initialFunding / 100;
        _seedLTBalanced(LT_ALICE_ADDRESS, stLegAssets);
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtil(0.8e18);
        uint64 capJTWAD = 1e12;
        uint64 capLTWAD = 1e12;
        _enableLTOverlay(capJTWAD, capLTWAD, minLiquidityWAD);
        _flushPremiumAccrual();
        _warpForward(1 days);
        _applySTYield(0.02e18);

        // Arrange guard: both raw curve outputs must exceed the configured caps at the committed utilizations
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 covUtilWAD = _expectedCovUtil(a.lastSTRawNAV, a.lastJTRawNAV, ACCOUNTANT.JT_COINVESTED(), a.minCoverageWAD, a.lastJTEffectiveNAV);
        uint256 liqUtilWAD = _expectedLiqUtil(a.lastSTEffectiveNAV, a.minLiquidityWAD, a.lastLTRawNAV);
        vm.prank(address(ACCOUNTANT));
        uint256 rawJTYieldShareWAD = IYDM(a.jtYDM).previewYieldShare(a.lastMarketState, covUtilWAD);
        vm.prank(address(ACCOUNTANT));
        uint256 rawLTYieldShareWAD = IYDM(a.ltYDM).previewYieldShare(a.lastMarketState, liqUtilWAD);
        assertGt(rawJTYieldShareWAD, capJTWAD, "arrange: the JT curve must price above its cap");
        assertGt(rawLTYieldShareWAD, capLTWAD, "arrange: the LT curve must price above its cap");

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertEq(e.jtYieldShareWAD, capJTWAD, "the accrued JT yield share must bind at the cap");
        assertEq(e.ltYieldShareWAD, capLTWAD, "the accrued LT yield share must bind at the cap");

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.JuniorTrancheYieldShareAccrued(capJTWAD, e.twJTStart + uint256(capJTWAD) * e.elapsed);
        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.LiquidityTrancheYieldShareAccrued(capLTWAD, e.twLTStart + uint256(capLTWAD) * e.elapsed);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // S5 — ADVERSARIAL + AUTH + SEQUENCE BATTERY
    // ═══════════════════════════════════════════════════════════════════════════

    // ── S5.0 Section-local helpers ──

    /**
     * @notice Schedules an accountant admin operation and warps past the admin's configured execution delay
     *         with fresh oracles, without executing it.
     * @dev Split from execution so a caller can arm an exact-args `vm.expectEmit` against the execute call.
     *      The delay is read from the AccessManager rather than hardcoded, so the helper follows any market
     *      whose roles configuration ships a different accountant-admin execution delay.
     */
    function _scheduleAccountantOperation(bytes memory _data) internal {
        (, uint32 executionDelay) = ACCESS_MANAGER.hasRole(ADMIN_ACCOUNTANT_ROLE, ACCOUNTANT_ADMIN_ADDRESS);
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        ACCESS_MANAGER.schedule(address(ACCOUNTANT), _data, 0);
        _warpForward(uint256(executionDelay) + 1);
    }

    /// @notice Executes a previously scheduled accountant admin operation.
    function _executeScheduledAccountantOperation(bytes memory _data) internal {
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        ACCESS_MANAGER.execute(address(ACCOUNTANT), _data);
    }

    /**
     * @notice Independent recompute of the senior deposit capacity from the committed checkpoint, coverage leg only.
     * @dev Mirrors `RoycoDayAccountant.maxSTDeposit` (testing-strategy F15) for a market whose minimum liquidity is
     *      zero, which callers must guarantee. Callers must have synced in the same block so the committed checkpoint
     *      equals the preview state the production view prices against. The final quoter conversion is an input.
     */
    function _expectedMaxSTDepositAssets() internal view returns (TRANCHE_UNIT assets) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 totalCoveredValue = Math.mulDiv(toUint256(a.lastJTEffectiveNAV), WAD, a.minCoverageWAD);
        uint256 requiredValue = (ACCOUNTANT.JT_COINVESTED() ? toUint256(a.lastJTRawNAV) : 0) + toUint256(a.jtNAVDustTolerance) + toUint256(a.lastSTRawNAV)
            + toUint256(a.stNAVDustTolerance);
        return KERNEL.stConvertNAVUnitsToTrancheUnits(toNAVUnits(totalCoveredValue > requiredValue ? totalCoveredValue - requiredValue : 0));
    }

    /**
     * @notice Independent recompute of the withdrawable pooled depth from the committed checkpoint.
     * @dev Mirrors `RoycoDayAccountant.maxLTWithdrawal` (testing-strategy F17) below the liquidation threshold with a
     *      nonzero minimum liquidity, which callers must guarantee. Callers must have synced in the same block.
     */
    function _expectedMaxLTWithdrawalNAV() internal view returns (NAV_UNIT) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 requiredValue = Math.mulDiv(toUint256(a.lastSTEffectiveNAV), a.minLiquidityWAD, WAD, Math.Rounding.Ceil) + toUint256(a.stNAVDustTolerance);
        uint256 ltRawValue = toUint256(a.lastLTRawNAV);
        return toNAVUnits(ltRawValue > requiredValue ? ltRawValue - requiredValue : 0);
    }

    /// @notice Asserts the reduction contract of a zero-liquidity market on a just-executed sync packet: no liquidity
    ///         premium, no LT fee, zero liquidity utilization, and no staged premium senior shares anywhere.
    function _assertZeroLiquidityReduction(SyncedAccountingState memory _state) internal view {
        assertEq(_state.ltLiquidityPremium, ZERO_NAV_UNITS, "a zero-liquidity market must pay no liquidity premium");
        assertEq(_state.ltProtocolFee, ZERO_NAV_UNITS, "a zero-liquidity market must take no LT protocol fee");
        assertEq(_state.liquidityUtilizationWAD, 0, "a zero-liquidity market must read zero liquidity utilization");
        assertEq(KERNEL.getState().ltOwnedSeniorTrancheShares, 0, "no premium senior shares may ever stage");
        assertEq(ST.balanceOf(address(KERNEL)), 0, "the kernel must never hold senior shares");
        _assertCommittedConservation();
    }

    /// @notice Per-tranche share-price inputs captured between the flagship sequence's steps.
    struct SeqPrices {
        uint256 stEffNAV;
        uint256 stSupply;
        uint256 jtEffNAV;
        uint256 jtSupply;
        uint256 ltEffNAV;
        uint256 ltSupply;
    }

    /// @notice Captures the committed effective NAVs and live supplies that define each tranche's share price.
    /// @dev The LT effective NAV is the committed BPT mark plus the claimable idle premium leg at the committed senior rate.
    function _seqSnapPrices() internal view returns (SeqPrices memory p) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        p.stEffNAV = toUint256(a.lastSTEffectiveNAV);
        p.stSupply = ST.totalSupply();
        p.jtEffNAV = toUint256(a.lastJTEffectiveNAV);
        p.jtSupply = JT.totalSupply();
        if (testConfig.hasLiquidityTranche) {
            p.ltSupply = LT.totalSupply();
            p.ltEffNAV = toUint256(a.lastLTRawNAV) + toUint256(_expectedValue(KERNEL.getState().ltOwnedSeniorTrancheShares, p.stSupply, a.lastSTEffectiveNAV));
        }
    }

    /**
     * @notice The flagship sequence's per-step check: committed conservation, kernel solvency, and share-price
     *         monotonicity against the previous step, compared as cross-multiplied integers.
     * @dev Non-decreasing comparisons tolerate one `maxNAVDelta()` of effective-NAV drift (a redemption's measured
     *      raw delta can exceed its floor-scaled claim NAV by quoter convexity, testing-strategy D2). The expected
     *      junior price drop on the covered-loss step is asserted strictly. Zero-supply sides are skipped, since no
     *      price exists to compare.
     */
    function _seqCheckStep(SeqPrices memory _prev, bool _expectJTPriceDrop, bool _checkLTPrice) internal view returns (SeqPrices memory cur) {
        cur = _seqSnapPrices();
        _assertCommittedConservation();
        _assertSolvency();
        uint256 tolerance = toUint256(maxNAVDelta());
        if (_prev.stSupply != 0 && cur.stSupply != 0) {
            assertGe((cur.stEffNAV + tolerance) * _prev.stSupply, _prev.stEffNAV * cur.stSupply, "sequence: the senior share price must not decrease");
        }
        if (_prev.jtSupply != 0 && cur.jtSupply != 0) {
            if (_expectJTPriceDrop) {
                assertLt(cur.jtEffNAV * _prev.jtSupply, _prev.jtEffNAV * cur.jtSupply, "sequence: the junior share price must drop on the covered loss");
            } else {
                assertGe((cur.jtEffNAV + tolerance) * _prev.jtSupply, _prev.jtEffNAV * cur.jtSupply, "sequence: the junior share price must not decrease");
            }
        }
        if (_checkLTPrice && _prev.ltSupply != 0 && cur.ltSupply != 0) {
            assertGe((cur.ltEffNAV + tolerance) * _prev.ltSupply, _prev.ltEffNAV * cur.ltSupply, "sequence: the liquidity share price must not decrease");
        }
    }

    // ── S5.1 Donations are inert ──

    /**
     * @notice A direct ST-asset transfer to the kernel is inert: the live and committed raw NAVs read the owned-asset
     *         ledger, share pricing is unchanged from a pre-donation expectation, and the donation only strengthens
     *         solvency.
     * @dev The donation is a real ERC20 transfer from a funded provider, never a forge `deal` (which would overwrite
     *      the balance instead of modeling a donation).
     */
    function test_Donation_assetToKernel_isInert() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applySTYield(0.02e18);
        _sync();

        // Pre-donation share-pricing expectation for the post-donation deposit
        uint256 assets = testConfig.initialFunding / 20;
        NAV_UNIT value = KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets));
        uint256 expectedShares = _expectedShares(value, ST.totalSupply(), ACCOUNTANT.getState().lastSTEffectiveNAV);
        NAV_UNIT stRawBefore = ST.getRawNAV();
        MarketSnapshot memory pre = _snap();

        uint256 donationAssets = testConfig.initialFunding / 10;
        vm.prank(ST_CHARLIE_ADDRESS);
        IERC20(testConfig.stAsset).transfer(address(KERNEL), donationAssets);

        assertEq(ST.getRawNAV(), stRawBefore, "the live senior raw NAV must ignore the donated balance");
        _sync();
        MarketSnapshot memory post = _snap();
        assertEq(post.lastSTRaw, pre.lastSTRaw, "the committed senior raw NAV must ignore the donation");
        assertEq(post.lastJTRaw, pre.lastJTRaw, "the committed junior raw NAV must ignore the donation");
        assertEq(post.lastSTEff, pre.lastSTEff, "the committed senior effective NAV must ignore the donation");
        assertEq(post.lastJTEff, pre.lastJTEff, "the committed junior effective NAV must ignore the donation");
        assertEq(post.stSupply, pre.stSupply, "no shares may mint against a donation");

        // Solvency is now strictly overcollateralized by exactly the donated balance
        IRoycoDayKernel.RoycoDayKernelState memory k = KERNEL.getState();
        uint256 ledgerAssets = toUint256(k.stOwnedYieldBearingAssets) + (testConfig.stAsset == testConfig.jtAsset ? toUint256(k.jtOwnedYieldBearingAssets) : 0);
        assertGe(IERC20(testConfig.stAsset).balanceOf(address(KERNEL)) - ledgerAssets, donationAssets, "the donation must sit above the owned-asset ledger");

        OpReceipt memory r = _doDepositST(ST_BOB_ADDRESS, assets);
        assertEq(r.shares, expectedShares, "share pricing must be unchanged by the donation");
        _assertCommittedConservation();
    }

    /// @notice Direct asset transfers to the tranche contracts are inert: tranches never custody assets, so raw NAVs,
    ///         sync, and share pricing are all unchanged.
    function test_Donation_toTranches_isInert() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();

        uint256 assets = testConfig.initialFunding / 20;
        NAV_UNIT stValue = KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets));
        NAV_UNIT jtValue = KERNEL.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets));
        uint256 expectedSTShares = _expectedShares(stValue, ST.totalSupply(), ACCOUNTANT.getState().lastSTEffectiveNAV);
        uint256 expectedJTShares = _expectedShares(jtValue, JT.totalSupply(), ACCOUNTANT.getState().lastJTEffectiveNAV);
        NAV_UNIT stRawBefore = ST.getRawNAV();
        NAV_UNIT jtRawBefore = JT.getRawNAV();
        MarketSnapshot memory pre = _snap();

        uint256 donationAssets = testConfig.initialFunding / 10;
        vm.prank(ST_CHARLIE_ADDRESS);
        IERC20(testConfig.stAsset).transfer(address(ST), donationAssets);
        vm.prank(JT_CHARLIE_ADDRESS);
        IERC20(testConfig.jtAsset).transfer(address(JT), donationAssets);
        assertGe(IERC20(testConfig.stAsset).balanceOf(address(ST)), donationAssets, "arrange: the senior tranche must hold the donated balance");

        assertEq(ST.getRawNAV(), stRawBefore, "the live senior raw NAV must ignore assets donated to the tranche");
        assertEq(JT.getRawNAV(), jtRawBefore, "the live junior raw NAV must ignore assets donated to the tranche");
        _sync();
        MarketSnapshot memory post = _snap();
        assertEq(post.lastSTRaw, pre.lastSTRaw, "the committed senior raw NAV must ignore the donations");
        assertEq(post.lastJTRaw, pre.lastJTRaw, "the committed junior raw NAV must ignore the donations");
        assertEq(post.lastSTEff, pre.lastSTEff, "the committed senior effective NAV must ignore the donations");
        assertEq(post.lastJTEff, pre.lastJTEff, "the committed junior effective NAV must ignore the donations");

        assertEq(_doDepositST(ST_BOB_ADDRESS, assets).shares, expectedSTShares, "senior share pricing must be unchanged by the donations");
        assertEq(_doDepositJT(JT_BOB_ADDRESS, assets).shares, expectedJTShares, "junior share pricing must be unchanged by the donations");
        _assertCommittedConservation();
    }

    /**
     * @notice BPT and senior-share transfers to the kernel are inert: the committed LT mark and the idle premium
     *         ledger are storage ledgers rather than balance reads, LT share pricing is unchanged, and operations
     *         still succeed.
     */
    function test_Donation_bptAndSTSharesToKernel_isInert() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        OpReceipt memory rRedeem = _doRedeemLT(LT_ALICE_ADDRESS, LT.balanceOf(LT_ALICE_ADDRESS) / 4);
        uint256 bptAssets = toUint256(rRedeem.claims.ltAssets);
        assertGt(bptAssets, 1, "arrange: the redemption must pay out BPT");
        _sync();

        // Pre-donation pricing expectation for an in-kind deposit of half of the withdrawn BPT
        uint256 bptDepositAssets = bptAssets / 2;
        NAV_UNIT value = KERNEL.ltConvertTrancheUnitsToNAVUnits(toTrancheUnits(bptDepositAssets));
        MarketSnapshot memory pre = _snap();
        assertEq(pre.idleSTShares, 0, "arrange: no staged premium may exist");
        uint256 expectedShares = _expectedShares(value, LT.totalSupply(), pre.lastLTRaw);

        // Donate the other half of the BPT plus live senior shares to the kernel
        uint256 bptDonationAssets = bptAssets - bptDepositAssets;
        vm.prank(LT_ALICE_ADDRESS);
        IERC20(POOL).transfer(address(KERNEL), bptDonationAssets);
        uint256 stShareDonation = ST.balanceOf(ST_ALICE_ADDRESS) / 100;
        assertGt(stShareDonation, 0, "arrange: the senior share donation must be nonzero");
        vm.prank(ST_ALICE_ADDRESS);
        IERC20(address(ST)).transfer(address(KERNEL), stShareDonation);

        _sync();
        MarketSnapshot memory post = _snap();
        assertEq(post.lastLTRaw, pre.lastLTRaw, "the committed LT mark must ignore the donated BPT");
        assertEq(post.idleSTShares, pre.idleSTShares, "the idle premium ledger must ignore the donated senior shares");
        assertEq(post.ltOwned, pre.ltOwned, "the owned BPT ledger must ignore the donation");
        assertEq(post.lastSTRaw, pre.lastSTRaw, "the committed senior raw NAV must ignore the share donation");
        assertEq(post.kernelBPTBal, pre.kernelBPTBal + bptDonationAssets, "the kernel must hold the donated BPT above the ledger");
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal + stShareDonation, "the kernel must hold the donated shares above the idle ledger");

        // LT share pricing is unchanged and operations still succeed
        vm.startPrank(LT_ALICE_ADDRESS);
        IERC20(POOL).approve(address(LT), bptDepositAssets);
        uint256 shares = LT.deposit(toTrancheUnits(bptDepositAssets), LT_ALICE_ADDRESS);
        vm.stopPrank();
        assertEq(shares, expectedShares, "LT share pricing must be unchanged by the donations");
        _assertSolvency();
        _assertCommittedConservation();
    }

    /**
     * @notice A quote-asset transfer to the pool contract address (not a venue join) leaves the market healthy: sync,
     *         LT deposit, and LT redemption all still succeed and conservation holds.
     * @dev Balancer V3 custodies pool tokens in its Vault, so balances at the pool address are venue-inert by design.
     */
    function test_Donation_quoteToPoolAddress_marketStillHealthy() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _sync();

        uint256 donationQuoteAssets = _quoteAssetsForValue(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(testConfig.initialFunding / 1000)));
        assertGt(donationQuoteAssets, 0, "arrange: the quote donation must be nonzero");
        vm.prank(LT_BOB_ADDRESS);
        IERC20(testConfig.quoteAsset).transfer(POOL, donationQuoteAssets);

        _sync();
        uint256 quoteDepositAssets = _quoteAssetsForValue(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(testConfig.initialFunding / 1000)));
        assertGt(_doDepositLTMulti(LT_BOB_ADDRESS, 0, quoteDepositAssets, 0).shares, 0, "an LT deposit must still succeed after the donation");
        OpReceipt memory r = _doRedeemLT(LT_ALICE_ADDRESS, LT.balanceOf(LT_ALICE_ADDRESS) / 10);
        assertGt(toUint256(r.claims.ltAssets), 0, "an LT redemption must still pay out after the donation");
        _assertCommittedConservation();
        _assertSolvency();
    }

    // ── S5.2 Economic attacks ──

    /**
     * @notice The classic first-depositor inflation attack is neutralized: a donation to the kernel never enters the
     *         owned-asset ledger, so the victim's shares match the pre-donation expectation exactly and the victim's
     *         holding round-trips its deposit value.
     */
    function test_FirstDepositor_inflationAttack_neutralized() public {
        _depositJT(JT_ALICE_ADDRESS, testConfig.initialFunding / 10);

        // The attacker enters with the smallest deposit carrying nonzero value
        uint256 attackerAssets = 1;
        while (toUint256(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(attackerAssets))) == 0) {
            attackerAssets *= 10;
        }
        OpReceipt memory rAttacker = _doDepositST(ST_BOB_ADDRESS, attackerAssets);
        assertGt(rAttacker.shares, 0, "arrange: the attacker must hold shares");

        // The attacker transfer-donates a large ST-asset balance to the kernel
        uint256 donationAssets = testConfig.initialFunding / 10;
        vm.prank(ST_BOB_ADDRESS);
        IERC20(testConfig.stAsset).transfer(address(KERNEL), donationAssets);
        _sync();

        // The victim's expectation prices off the committed (donation-free) checkpoint
        uint256 victimAssets = testConfig.initialFunding / 10;
        NAV_UNIT victimValue = KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(victimAssets));
        uint256 expectedVictimShares = _expectedShares(victimValue, ST.totalSupply(), ACCOUNTANT.getState().lastSTEffectiveNAV);
        assertGt(expectedVictimShares, 0, "the victim's shares must not floor to zero");

        OpReceipt memory rVictim = _doDepositST(ST_ALICE_ADDRESS, victimAssets);
        assertEq(rVictim.shares, expectedVictimShares, "the donation must not move the victim's share pricing");
        assertApproxEqAbs(
            rVictim.post.lastSTRaw - rAttacker.post.lastSTRaw, victimValue, maxNAVDelta(), "the committed raw NAV must grow only by the victim's deposit"
        );
        NAV_UNIT victimHoldingValue = _expectedValue(rVictim.shares, rVictim.post.stSupply, rVictim.post.lastSTEff);
        assertApproxEqAbs(victimHoldingValue, victimValue, maxNAVDelta(), "the victim's holding must round-trip its deposit value");
        _assertCommittedConservation();
    }

    /**
     * @notice A deposit-before-gain sandwich extracts no more than the attacker's pro-rata slice of the booked senior
     *         gain, and never less than its principal on a gain window, both within quoter dust.
     * @dev Bound derivation: `valueOut = floor(stEff1 * shares / S1) <= (stEff0 + G) * shares / S0` since `S1 >= S0`,
     *      and the deposit's floor share pricing makes `stEff0 * shares / S0 <= valueIn` up to a wei of rounding, so
     *      `valueOut <= valueIn + floor(G * shares / S0)` within `maxNAVDelta()`. Fees and premiums only tighten it.
     */
    function test_Sandwich_depositBeforeSyncGain_profitBounded() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();

        OpReceipt memory rIn = _doDepositST(ST_BOB_ADDRESS, testConfig.initialFunding / 10);
        uint256 valueIn = toUint256(rIn.post.lastSTRaw - rIn.pre.lastSTRaw);
        uint256 supplyAfterDeposit = rIn.post.stSupply;
        uint256 stEffAfterDeposit = toUint256(rIn.post.lastSTEff);

        _warpForward(1 days);
        _applySTYield(0.05e18);
        _sync();
        uint256 stEffAfterGain = toUint256(ACCOUNTANT.getState().lastSTEffectiveNAV);
        assertGt(stEffAfterGain, stEffAfterDeposit, "arrange: the sync must book a senior gain");
        uint256 proRataGainBound = Math.mulDiv(stEffAfterGain - stEffAfterDeposit, rIn.shares, supplyAfterDeposit);

        OpReceipt memory rOut = _doRedeemST(ST_BOB_ADDRESS, rIn.shares);
        uint256 valueOut = toUint256(rOut.claims.nav);
        assertLe(valueOut, valueIn + proRataGainBound + toUint256(maxNAVDelta()), "the sandwich profit must be bounded by the pro-rata gain slice");
        assertGe(valueOut + toUint256(maxNAVDelta()), valueIn, "the attacker cannot be paid less than principal on a gain window");
        assertEq(ST.balanceOf(ST_BOB_ADDRESS), 0, "the attacker must exit fully");
        _assertCommittedConservation();
    }

    // ── S5.3 Pinned edge cases ──

    /**
     * @notice PINS testing-strategy Appendix B.2: an LT redemption whose BPT slice floors to zero while its idle
     *         premium slice is nonzero reverts with `INVALID_POST_OP_STATE(LT_REDEEM)` and leaves the market untouched.
     * @dev The venue removal of a zero BPT slice moves no committed LT mark, which the post-op state check rejects.
     */
    function test_LTRedeem_zeroBPTSlice_nonzeroIdle_pinned() public whenLT {
        uint256 idleShares = _arrangeStagedIdlePremium();

        uint256 ltSupply = LT.totalSupply();
        uint256 ltOwnedAssets = toUint256(KERNEL.getState().ltOwnedYieldBearingAssets);
        // The largest share count whose proportional BPT slice floors to zero
        uint256 shares = (ltSupply - 1) / ltOwnedAssets;
        assertGt(shares, 0, "arrange: the BPT-per-share ratio must make a zero-BPT slice representable");
        assertLe(shares, LT.balanceOf(LT_ALICE_ADDRESS), "arrange: the redeemer must afford the dust redemption");
        assertEq(Math.mulDiv(ltOwnedAssets, shares, ltSupply), 0, "arrange: the BPT slice must floor to zero");
        assertGt(Math.mulDiv(idleShares, shares, ltSupply), 0, "arrange: the idle premium slice must be nonzero");
        MarketSnapshot memory pre = _snap();

        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.LT_REDEEM));
        LT.redeem(shares, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
        _assertMarketUnchanged(pre);
    }

    /**
     * @notice PINS testing-strategy Appendix B.4: a JT deposit against a live supply with zero junior effective NAV
     *         prices against the documented one-wei denominator, so the depositor takes over the tranche and the
     *         pre-existing unbacked holder is diluted to its floor-scaled dust claim.
     */
    function test_JTDeposit_zeroNAVLiveSupply_pinned() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 16);
        _sync();

        // A loss large enough that coverage exhausts the junior effective NAV to exactly zero, sized from the
        // measured committed ratio so the arrange holds whatever the two assets' relative per-unit values are
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        uint256 lossPctWAD = Math.mulDiv(toUint256(a0.lastJTEffectiveNAV), WAD, toUint256(a0.lastSTRawNAV), Math.Rounding.Ceil) + 0.02e18;
        assertLt(lossPctWAD, WAD, "arrange: the exhausting loss must be representable");
        _applySTLoss(lossPctWAD);
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertEq(a.lastJTEffectiveNAV, ZERO_NAV_UNITS, "arrange: the junior effective NAV must exhaust to exactly zero");
        uint256 jtSupplyPre = JT.totalSupply();
        assertGt(jtSupplyPre, 0, "arrange: the junior supply must remain live");
        assertEq(_snap().covUtilWAD, type(uint256).max, "coverage utilization must saturate with an exhausted junior tranche");
        uint256 aliceShares = JT.balanceOf(JT_ALICE_ADDRESS);

        // The zero-NAV denominator branch prices the deposit (ValuationLogic substitutes one NAV wei)
        uint256 assets = testConfig.initialFunding / 1000;
        NAV_UNIT value = KERNEL.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets));
        uint256 expectedShares = _expectedShares(value, jtSupplyPre, ZERO_NAV_UNITS);
        assertEq(expectedShares, toUint256(value) * jtSupplyPre, "the zero-NAV branch must price against the one-wei denominator");

        OpReceipt memory r = _doDepositJT(JT_BOB_ADDRESS, assets);
        assertEq(r.shares, expectedShares, "deposit shares must match the zero-NAV denominator formula exactly");
        _assertCommittedConservation();
        _assertSolvency();

        // The unbacked holder is diluted to its floor-scaled dust claim
        NAV_UNIT expectedAliceValue = _expectedValue(aliceShares, r.post.jtSupply, r.post.lastJTEff);
        assertEq(JT.previewRedeem(aliceShares).nav, expectedAliceValue, "the unbacked holder's claim must be the floor-scaled dust slice");
        assertLt(toUint256(expectedAliceValue) * 100, toUint256(value), "the unbacked holder must be diluted to under a percent of the new value");
    }

    // ── S5.4 Liquidation-breach behavior ──

    /// @notice The self-liquidation bonus is bank-run-neutral: a bonus-paying senior redemption in a breached market
    ///         never raises coverage utilization.
    function test_SelfLiquidationBonus_neverRaisesCovUtil() public {
        _ensureSelfLiquidationBonusConfigured();
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _breachLiquidation();

        MarketSnapshot memory pre = _snap();
        assertGe(pre.covUtilWAD, ACCOUNTANT.getState().coverageLiquidationUtilizationWAD, "arrange: the liquidation threshold must be breached");
        uint256 shares = ST.balanceOf(ST_ALICE_ADDRESS) / 3;
        AssetClaims memory baseClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.SENIOR), shares, ST.totalSupply());
        (, NAV_UNIT bonusNAV) = _expectedClaimsWithSelfLiquidationBonus(baseClaims);
        assertGt(toUint256(bonusNAV), 0, "arrange: the redemption must pay a bonus");

        OpReceipt memory r = _doRedeemST(ST_ALICE_ADDRESS, shares);
        assertEq(r.post.lastJTEff, r.pre.lastJTEff - bonusNAV, "the junior effective NAV must fund exactly the bonus");
        assertLe(r.post.covUtilWAD, r.pre.covUtilWAD, "the bonus must never raise coverage utilization");
        _assertCommittedConservation();
    }

    /**
     * @notice PINS spec D10, the post-liquidation-breach withdrawal matrix: senior redemptions pay the bonus, LT
     *         redemptions bypass the liquidity gate with the full pooled depth reported withdrawable, and junior
     *         redemptions stay coverage-gated with zero reported capacity.
     */
    function test_LiquidationBreach_withdrawalMatrix() public whenLT {
        _ensureSelfLiquidationBonusConfigured();
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtil(0.9e18);
        _setMinLiquidityWAD(minLiquidityWAD);
        _breachLiquidation();

        MarketSnapshot memory pre = _snap();
        assertGe(pre.covUtilWAD, ACCOUNTANT.getState().coverageLiquidationUtilizationWAD, "arrange: the liquidation threshold must be breached");
        assertGt(toUint256(pre.lastJTEff), 0, "arrange: the junior tranche must not be exhausted");

        // (c) Junior redemptions stay coverage-gated: zero reported capacity and a hard revert
        assertEq(JT.maxRedeem(JT_ALICE_ADDRESS), 0, "jtMaxRedeem must report zero once liquidation is breached");
        uint256 jtShares = JT.balanceOf(JT_ALICE_ADDRESS) / 10;
        vm.prank(JT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        JT.redeem(jtShares, JT_ALICE_ADDRESS, JT_ALICE_ADDRESS);

        // (d) The full pooled depth is reported withdrawable
        (, NAV_UNIT ltMaxWithdrawableNAV,) = KERNEL.ltMaxWithdrawable(LT_ALICE_ADDRESS);
        assertEq(ltMaxWithdrawableNAV, pre.lastLTRaw, "the full pooled depth must be withdrawable once liquidation is breached");
        assertEq(LT.maxRedeem(LT_ALICE_ADDRESS), LT.balanceOf(LT_ALICE_ADDRESS), "ltMaxRedeem must report the holder's full balance");

        // (b) An LT redemption that overruns the liquidity floor succeeds (the gate is bypassed)
        uint256 ltShares = (LT.balanceOf(LT_ALICE_ADDRESS) * 3) / 4;
        _assertSliceWouldBreachLiquidity(ltShares, minLiquidityWAD, pre);
        OpReceipt memory rLT = _doRedeemLT(LT_ALICE_ADDRESS, ltShares);
        assertGt(toUint256(rLT.claims.ltAssets), 0, "the bypassed LT redemption must pay the BPT slice");
        assertGt(rLT.post.liqUtilWAD, WAD, "the liquidity gate must have been truly bypassed");

        // (a) A senior redemption succeeds and pays the exact bonus out of the junior effective NAV
        _sync();
        uint256 stShares = ST.balanceOf(ST_ALICE_ADDRESS) / 2;
        AssetClaims memory baseClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.SENIOR), stShares, ST.totalSupply());
        (, NAV_UNIT bonusNAV) = _expectedClaimsWithSelfLiquidationBonus(baseClaims);
        assertGt(toUint256(bonusNAV), 0, "arrange: the senior redemption must pay a bonus");
        OpReceipt memory rST = _doRedeemST(ST_ALICE_ADDRESS, stShares);
        assertEq(rST.post.lastJTEff, rST.pre.lastJTEff - bonusNAV, "the junior effective NAV must fund exactly the bonus");
        assertLe(rST.post.covUtilWAD, rST.pre.covUtilWAD, "the bonus must never raise coverage utilization");
        _assertCommittedConservation();
    }

    // ── S5.5 Oracle staleness, pause, and blacklist bricks ──

    /**
     * @notice PINS the staleness brick: past the oracle staleness threshold every state-mutating quoting flow
     *         (deposit and sync) reverts with the venue's staleness selector, while the view preview surface keeps
     *         answering at the transaction's transient cached rate, and a fresh oracle update resumes the market.
     * @dev The raw `vm.warp` without an oracle refresh is the brick under test, deliberately bypassing the sanctioned
     *      `_warpForward`. The 30-day jump dominates any realistic staleness threshold configuration. The view pin is
     *      a same-transaction artifact of the transient quoter cache (D6): mutating entrypoints re-initialize the
     *      cache from the live oracle and brick, while views reuse the cache an earlier op left populated. In a fresh
     *      transaction with an empty cache the view surface bricks identically, which a single-transaction test
     *      cannot observe.
     */
    function test_OracleStaleness_bricksFlows_pinned() public {
        vm.skip(_oracleStalenessSelector() == bytes4(0));
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        simulateSTYield(0);
        _sync();

        vm.warp(block.timestamp + 30 days);
        bytes4 staleSelector = _oracleStalenessSelector();
        uint256 assets = testConfig.initialFunding / 100;

        vm.startPrank(ST_ALICE_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), assets);
        vm.expectRevert(staleSelector);
        ST.deposit(toTrancheUnits(assets), ST_ALICE_ADDRESS);
        vm.stopPrank();

        vm.prank(SYNC_ROLE_ADDRESS);
        vm.expectRevert(staleSelector);
        KERNEL.syncTrancheAccounting();

        // The view surface keeps pricing at the transient cached rate inside this transaction (current behavior pin)
        (SyncedAccountingState memory previewState,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        assertGt(toUint256(previewState.stRawNAV), 0, "the cached-rate preview must keep answering within the transaction");

        // A brick, not a corruption: a fresh oracle update resumes the market
        _refreshOraclesAfterWarp();
        assertGt(_doDepositST(ST_ALICE_ADDRESS, assets).shares, 0, "the market must resume once the oracle is fresh again");
        _assertCommittedConservation();
    }

    /// @notice While the kernel is paused every mutating entrypoint (and the pause-guarded preview surface) reverts
    ///         with `EnforcedPause`, every max view reports zero, and the market resumes after unpause.
    function test_Pause_reverts_allMutatingEntries() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        uint256 bptAssets;
        if (testConfig.hasLiquidityTranche) {
            _seedDefaultLT();
            bptAssets = toUint256(_doRedeemLT(LT_ALICE_ADDRESS, LT.balanceOf(LT_ALICE_ADDRESS) / 10).claims.ltAssets);
            assertGt(bptAssets, 0, "arrange: the redeemer must hold BPT for the paused in-kind deposit attempt");
        }
        _sync();
        _pauseKernel();
        uint256 assets = testConfig.initialFunding / 100;

        // Every max view zeroes while paused
        assertEq(ST.maxDeposit(ST_ALICE_ADDRESS), ZERO_TRANCHE_UNITS, "stMaxDeposit must report zero while paused");
        assertEq(JT.maxDeposit(JT_ALICE_ADDRESS), ZERO_TRANCHE_UNITS, "jtMaxDeposit must report zero while paused");
        assertEq(ST.maxRedeem(ST_ALICE_ADDRESS), 0, "stMaxRedeem must report zero while paused");
        assertEq(JT.maxRedeem(JT_ALICE_ADDRESS), 0, "jtMaxRedeem must report zero while paused");

        vm.startPrank(ST_ALICE_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), assets);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        ST.deposit(toTrancheUnits(assets), ST_ALICE_ADDRESS);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        ST.redeem(1, ST_ALICE_ADDRESS, ST_ALICE_ADDRESS);
        vm.stopPrank();

        vm.startPrank(JT_ALICE_ADDRESS);
        IERC20(testConfig.jtAsset).approve(address(JT), assets);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        JT.deposit(toTrancheUnits(assets), JT_ALICE_ADDRESS);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        JT.redeem(1, JT_ALICE_ADDRESS, JT_ALICE_ADDRESS);
        vm.stopPrank();

        vm.prank(SYNC_ROLE_ADDRESS);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        KERNEL.syncTrancheAccounting();
        vm.prank(KERNEL_ADMIN_ADDRESS);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        KERNEL.reinvestLiquidityPremium(type(uint256).max);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);

        if (testConfig.hasLiquidityTranche) {
            assertEq(LT.maxDeposit(LT_ALICE_ADDRESS), ZERO_TRANCHE_UNITS, "ltMaxDeposit must report zero while paused");
            assertEq(LT.maxRedeem(LT_ALICE_ADDRESS), 0, "ltMaxRedeem must report zero while paused");
            uint256 quoteAssets = 10 ** IERC20Metadata(testConfig.quoteAsset).decimals();
            vm.startPrank(LT_ALICE_ADDRESS);
            IERC20(POOL).approve(address(LT), bptAssets);
            vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
            LT.deposit(toTrancheUnits(bptAssets), LT_ALICE_ADDRESS);
            vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
            LT.redeem(1, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
            IERC20(testConfig.quoteAsset).approve(address(LT), quoteAssets);
            vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
            IRoycoLiquidityTranche(address(LT)).depositMultiAsset(0, quoteAssets, 0, LT_ALICE_ADDRESS);
            vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
            IRoycoLiquidityTranche(address(LT)).redeemMultiAsset(1, 0, 0, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
            vm.stopPrank();
        }

        _unpauseKernel();
        assertGt(_doDepositST(ST_ALICE_ADDRESS, assets).shares, 0, "the market must resume after unpause");
        _assertCommittedConservation();
    }

    /// @notice A blacklisted account can neither receive a deposit, transfer its shares out, nor redeem them, its max
    ///         views report zero, and an untouched account still operates.
    function test_Blacklist_deniesDepositRedeemTransfer() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        address eve = ST_CHARLIE_ADDRESS;
        uint256 assets = testConfig.initialFunding / 100;
        uint256 eveShares = _doDepositST(eve, assets).shares;
        assertGt(eveShares, 0, "arrange: eve must hold shares before being blacklisted");
        _blacklist(eve);
        bytes memory blacklistedError = abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, eve);

        // Deposits to the blacklisted receiver are screened at the mint
        vm.startPrank(ST_ALICE_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), assets);
        vm.expectRevert(blacklistedError);
        ST.deposit(toTrancheUnits(assets), eve);
        vm.stopPrank();

        // Held shares can neither transfer out (the from-screen) nor redeem
        vm.prank(eve);
        vm.expectRevert(blacklistedError);
        ST.transfer(ST_BOB_ADDRESS, eveShares);
        vm.prank(eve);
        vm.expectRevert(blacklistedError);
        ST.redeem(eveShares, eve, eve);

        // Max views zero for the blacklisted account, and an untouched account still operates
        assertEq(ST.maxDeposit(eve), ZERO_TRANCHE_UNITS, "maxDeposit must report zero for a blacklisted receiver");
        assertEq(ST.maxRedeem(eve), 0, "maxRedeem must report zero for a blacklisted owner");
        assertGt(_doDepositST(ST_BOB_ADDRESS, assets).shares, 0, "an untouched account must still operate");
        _assertCommittedConservation();
    }

    /**
     * @notice The blacklist screens the junior and liquidity tranche flows identically to the senior: a
     *         blacklisted account can neither receive a deposit, transfer its shares out, nor redeem them on
     *         either tranche, every max view zeroes, and the deliberately-public LT deposit surface is
     *         screened at the share mint.
     */
    function test_Blacklist_deniesJTAndLTFlows() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        address eve = JT_CHARLIE_ADDRESS;
        uint256 assets = testConfig.initialFunding / 100;
        uint256 eveJTShares = _doDepositJT(eve, assets).shares;
        assertGt(eveJTShares, 0, "arrange: eve must hold junior shares before being blacklisted");

        uint256 eveLTShares;
        if (testConfig.hasLiquidityTranche) {
            _seedDefaultLT();
            // Grant eve the LT LP role so the blacklist screen (not the auth gate) is what rejects the LT flows
            vm.prank(LP_ROLE_ADMIN_ADDRESS);
            ACCESS_MANAGER.grantRole(LT_LP_ROLE, eve, 0);
            eveLTShares = LT.balanceOf(LT_ALICE_ADDRESS) / 10;
            vm.prank(LT_ALICE_ADDRESS);
            LT.transfer(eve, eveLTShares);
            assertGt(eveLTShares, 0, "arrange: eve must hold liquidity shares before being blacklisted");
        }
        _blacklist(eve);
        bytes memory blacklistedError = abi.encodeWithSelector(IRoycoBlacklist.ACCOUNT_BLACKLISTED.selector, eve);

        // Junior tranche: deposit-to, transfer-out, and redeem are all screened, and the max views zero
        vm.startPrank(JT_ALICE_ADDRESS);
        IERC20(testConfig.jtAsset).approve(address(JT), assets);
        vm.expectRevert(blacklistedError);
        JT.deposit(toTrancheUnits(assets), eve);
        vm.stopPrank();
        vm.prank(eve);
        vm.expectRevert(blacklistedError);
        JT.transfer(JT_BOB_ADDRESS, eveJTShares);
        vm.prank(eve);
        vm.expectRevert(blacklistedError);
        JT.redeem(eveJTShares, eve, eve);
        assertEq(JT.maxDeposit(eve), ZERO_TRANCHE_UNITS, "jtMaxDeposit must report zero for a blacklisted receiver");
        assertEq(JT.maxRedeem(eve), 0, "jtMaxRedeem must report zero for a blacklisted owner");

        if (testConfig.hasLiquidityTranche) {
            // The public multi-asset LT deposit surface is screened at the share mint
            uint256 quoteAssets = _quoteAssetsForValue(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(testConfig.initialFunding / 1000)));
            vm.startPrank(LT_BOB_ADDRESS);
            IERC20(testConfig.quoteAsset).approve(address(LT), quoteAssets);
            vm.expectRevert(blacklistedError);
            IRoycoLiquidityTranche(address(LT)).depositMultiAsset(0, quoteAssets, 0, eve);
            vm.stopPrank();
            // Held LT shares can neither transfer out nor redeem on either flow, and the max views zero
            vm.prank(eve);
            vm.expectRevert(blacklistedError);
            LT.transfer(LT_BOB_ADDRESS, eveLTShares);
            vm.prank(eve);
            vm.expectRevert(blacklistedError);
            LT.redeem(eveLTShares, eve, eve);
            vm.prank(eve);
            vm.expectRevert(blacklistedError);
            IRoycoLiquidityTranche(address(LT)).redeemMultiAsset(eveLTShares, 0, 0, eve, eve);
            assertEq(LT.maxDeposit(eve), ZERO_TRANCHE_UNITS, "ltMaxDeposit must report zero for a blacklisted receiver");
            assertEq(LT.maxRedeem(eve), 0, "ltMaxRedeem must report zero for a blacklisted owner");
        }

        // An untouched account still operates on the screened tranches
        assertGt(_doDepositJT(JT_BOB_ADDRESS, assets).shares, 0, "an untouched junior account must still operate");
        _assertCommittedConservation();
    }

    // ── S5.6 Access control and caller gates ──

    /// @notice A role-less outsider is rejected with the exact-arg `AccessManagedUnauthorized` on every restricted
    ///         entrypoint, while the deliberately public LT deposit surface lands real deposits for the same caller.
    function test_AccessControl_restrictedSweep() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        if (testConfig.hasLiquidityTranche) _seedDefaultLT();
        address outsider = _randomOutsider();
        bytes memory unauthorizedError = abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider);
        uint256 assets = testConfig.initialFunding / 100;

        vm.startPrank(outsider);
        vm.expectRevert(unauthorizedError);
        ST.deposit(toTrancheUnits(assets), outsider);
        vm.expectRevert(unauthorizedError);
        ST.redeem(1, outsider, outsider);
        vm.expectRevert(unauthorizedError);
        JT.deposit(toTrancheUnits(assets), outsider);
        vm.expectRevert(unauthorizedError);
        JT.redeem(1, outsider, outsider);
        vm.expectRevert(unauthorizedError);
        KERNEL.syncTrancheAccounting();
        vm.expectRevert(unauthorizedError);
        KERNEL.reinvestLiquidityPremium(1);
        vm.expectRevert(unauthorizedError);
        KERNEL.setProtocolFeeRecipient(outsider);
        vm.expectRevert(unauthorizedError);
        ACCOUNTANT.setMinCoverage(0.2e18);
        if (testConfig.hasLiquidityTranche) {
            vm.expectRevert(unauthorizedError);
            LT.redeem(1, outsider, outsider);
            vm.expectRevert(unauthorizedError);
            IRoycoLiquidityTranche(address(LT)).redeemMultiAsset(1, 0, 0, outsider, outsider);
        }
        vm.stopPrank();

        // The LT deposit surface is deliberately public: the outsider proceeds past auth and lands real deposits
        if (testConfig.hasLiquidityTranche) {
            uint256 quoteAssets = _quoteAssetsForValue(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(testConfig.initialFunding / 1000)));
            vm.startPrank(outsider);
            IERC20(testConfig.quoteAsset).approve(address(LT), quoteAssets);
            uint256 multiShares = IRoycoLiquidityTranche(address(LT)).depositMultiAsset(0, quoteAssets, 0, outsider);
            vm.stopPrank();
            assertGt(multiShares, 0, "the public multi-asset LT deposit must succeed for a role-less caller");

            OpReceipt memory r = _doRedeemLT(LT_ALICE_ADDRESS, LT.balanceOf(LT_ALICE_ADDRESS) / 10);
            uint256 bptAssets = toUint256(r.claims.ltAssets);
            assertGt(bptAssets, 0, "arrange: the redemption must pay out BPT");
            vm.prank(LT_ALICE_ADDRESS);
            IERC20(POOL).transfer(outsider, bptAssets);
            vm.startPrank(outsider);
            IERC20(POOL).approve(address(LT), bptAssets);
            uint256 inKindShares = LT.deposit(toTrancheUnits(bptAssets), outsider);
            vm.stopPrank();
            assertGt(inKindShares, 0, "the public in-kind LT deposit must succeed for a role-less caller");
            _assertSolvency();
        }
        _assertCommittedConservation();
    }

    /// @notice Every kernel and accountant inter-contract entrypoint rejects a direct EOA caller with its exact
    ///         caller-gate error, and the tranche mint surface is kernel-only.
    function test_KernelAndAccountant_callerGates() public {
        address outsider = _randomOutsider();
        vm.startPrank(outsider);
        vm.expectRevert(IRoycoDayKernel.ONLY_SENIOR_TRANCHE.selector);
        KERNEL.stDeposit(toTrancheUnits(1));
        vm.expectRevert(IRoycoDayKernel.ONLY_SENIOR_TRANCHE.selector);
        KERNEL.stRedeem(1, outsider);
        vm.expectRevert(IRoycoDayKernel.ONLY_JUNIOR_TRANCHE.selector);
        KERNEL.jtDeposit(toTrancheUnits(1));
        vm.expectRevert(IRoycoDayKernel.ONLY_JUNIOR_TRANCHE.selector);
        KERNEL.jtRedeem(1, outsider);
        if (testConfig.hasLiquidityTranche) {
            vm.expectRevert(IRoycoDayKernel.ONLY_LIQUIDITY_TRANCHE.selector);
            KERNEL.ltDeposit(toTrancheUnits(1));
            vm.expectRevert(IRoycoDayKernel.ONLY_LIQUIDITY_TRANCHE.selector);
            KERNEL.ltRedeem(1, outsider);
            vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
            KERNEL.addLiquidity(1, 1, ZERO_TRANCHE_UNITS);
            vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
            KERNEL.removeLiquidity(toTrancheUnits(1), 0, 0, outsider);
            vm.expectRevert(IRoycoDayKernel.ONLY_SELF.selector);
            KERNEL.attemptLiquidityPremiumReinvestment(1, ZERO_NAV_UNITS, 0);
        }
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        ACCOUNTANT.preOpSyncTrancheAccounting(ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        ACCOUNTANT.commitLiquidityTrancheRawNAV(ZERO_NAV_UNITS);
        vm.expectRevert(IRoycoDayAccountant.ONLY_ROYCO_KERNEL.selector);
        ACCOUNTANT.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, false);
        vm.expectRevert(IRoycoVaultTranche.ONLY_KERNEL.selector);
        ST.mint(outsider, 1);
        vm.expectRevert(IRoycoVaultTranche.ONLY_KERNEL.selector);
        ST.mintProtocolFeeShares(outsider, 1);
        vm.expectRevert(IRoycoVaultTranche.ONLY_KERNEL.selector);
        JT.mint(outsider, 1);
        vm.stopPrank();
    }

    // ── S5.7 Scripted sequences ──

    /**
     * @notice The flagship day-in-the-life sequence: deposits across all three tranches, premium staging against a
     *         dust pool, pool deepening, a covered loss, the premium reinvestment, multi-asset exit, and premium-window
     *         syncs, with conservation, solvency, and share-price monotonicity asserted after every step.
     * @dev Two arrangement notes against the spec's step list: the LT is seeded before the overlay is enabled (each
     *      chunked seeding deposit enforces the liquidity gate post-op, so a pre-set minimum against an empty pool
     *      reverts by design), and LT price monotonicity is skipped only across the reinvestment step, whose venue add
     *      pays real slippage bounded by the opened gate rather than accruing a lossless mark.
     */
    function test_Sequence_dayInTheLife() public whenLT {
        vm.skip(!_trySetReinvestmentSlippage(0));
        _setupLTProviders();
        uint256 funding = testConfig.initialFunding;
        SeqPrices memory p = _seqSnapPrices();

        // (1) JT_ALICE collateralizes and (2) ST_ALICE enters under coverage
        _depositJT(JT_ALICE_ADDRESS, funding / 4);
        p = _seqCheckStep(p, false, false);
        _depositST(ST_ALICE_ADDRESS, funding / 2);
        p = _seqCheckStep(p, false, false);

        // (3) A dust-deep LT is seeded, then (4) the overlay is enabled against it
        _seedLTBalanced(LT_ALICE_ADDRESS, funding / 20_000);
        p = _seqCheckStep(p, false, true);
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtil(0.3e18);
        _enableLTOverlay(0.1e18, 0.5e18, minLiquidityWAD);
        p = _seqCheckStep(p, false, true);

        // (5) The first premium window accrues and stages against the dust pool (the shut gate is the second belt)
        _warpForward(1 days);
        _applySTYield(0.02e18);
        _sync();
        assertGt(KERNEL.getState().ltOwnedSeniorTrancheShares, 0, "the liquidity premium must stage idle against the dust pool");
        p = _seqCheckStep(p, false, true);

        // (6) LT_BOB enters at dust scale, keeping the pool shallow so the staged premium cannot deploy early
        uint256 idleBeforeEntry = KERNEL.getState().ltOwnedSeniorTrancheShares;
        _seedLTBalanced(LT_BOB_ADDRESS, funding / 50_000);
        assertEq(KERNEL.getState().ltOwnedSeniorTrancheShares, idleBeforeEntry, "the LT entry must not consume the staged premium");
        p = _seqCheckStep(p, false, true);

        // (7) ST_BOB enters and (8) ST_ALICE partially exits
        _doDepositST(ST_BOB_ADDRESS, funding / 10);
        p = _seqCheckStep(p, false, true);
        _doRedeemST(ST_ALICE_ADDRESS, ST.balanceOf(ST_ALICE_ADDRESS) / 4);
        p = _seqCheckStep(p, false, true);

        // (9) A covered loss: the junior price drops while the senior and liquidity prices hold
        _applySTLoss(0.02e18);
        _sync();
        assertGt(toUint256(ACCOUNTANT.getState().lastJTEffectiveNAV), 0, "arrange: the loss must stay covered");
        p = _seqCheckStep(p, true, true);

        // (10) JT_BOB re-collateralizes
        _doDepositJT(JT_BOB_ADDRESS, funding / 10);
        p = _seqCheckStep(p, false, true);

        // (11) A second premium window accrues and stages against the still-dust pool
        _warpForward(1 days);
        _applySTYield(0.03e18);
        _sync();
        p = _seqCheckStep(p, false, true);
        uint256 idleBeforeReinvest = KERNEL.getState().ltOwnedSeniorTrancheShares;
        assertGt(idleBeforeReinvest, 0, "arrange: staged premium must exist for the reinvestment");

        // (12) The pool deepens flat (no premium mints, so the idle survives), the gate opens, and the staged
        //      premium deploys into the real depth
        _seedLTBalanced(LT_BOB_ADDRESS, funding / 100);
        assertEq(KERNEL.getState().ltOwnedSeniorTrancheShares, idleBeforeReinvest, "deepening the pool must not consume the staged premium");
        assertTrue(_trySetReinvestmentSlippage(uint64(WAD - 1)), "arrange: the slippage gate must open");
        NAV_UNIT ltRawBeforeReinvest = ACCOUNTANT.getState().lastLTRawNAV;
        vm.prank(KERNEL_ADMIN_ADDRESS);
        KERNEL.reinvestLiquidityPremium(type(uint256).max);
        assertEq(KERNEL.getState().ltOwnedSeniorTrancheShares, 0, "the staged premium must fully deploy");
        assertGt(ACCOUNTANT.getState().lastLTRawNAV, ltRawBeforeReinvest, "the committed depth must grow on deployment");
        p = _seqCheckStep(p, false, false);

        // (13) LT_ALICE exits half via the multi-asset unwind
        OpReceipt memory rMulti = _doRedeemLTMulti(LT_ALICE_ADDRESS, LT.balanceOf(LT_ALICE_ADDRESS) / 2, 0, 0);
        assertGt(rMulti.quoteAssets, 0, "the multi-asset exit must pay quote assets");
        assertLe(rMulti.post.liqUtilWAD, WAD, "the exit must leave the liquidity requirement satisfied");
        p = _seqCheckStep(p, false, true);

        // (14) A longer premium window settles with the gate open
        _warpForward(3 days);
        _applySTYield(0.03e18);
        _sync();
        p = _seqCheckStep(p, false, true);

        // (15) JT_ALICE partially exits under the coverage gate
        _doRedeemJT(JT_ALICE_ADDRESS, JT.balanceOf(JT_ALICE_ADDRESS) / 4);
        p = _seqCheckStep(p, false, true);
        assertLe(_snap().covUtilWAD, WAD, "the sequence must end with coverage satisfied");
    }

    /**
     * @notice The CLAUDE.md P1/P2 reduction acceptance test in fork form: a market with the LT overlay off behaves as
     *         a plain ST/JT market through deposits, yield, loss, redemptions, and a max-size senior deposit, with no
     *         liquidity premium, zero liquidity utilization, and no staged premium at any sync.
     */
    function test_Sequence_zeroLiquidityReduction_behavesAsPlainSTJT() public {
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        vm.skip(a0.minLiquidityWAD != 0 || a0.maxLTYieldShareWAD != 0);

        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _assertZeroLiquidityReduction(_syncWithState());

        _warpForward(1 days);
        _applySTYield(0.03e18);
        _assertZeroLiquidityReduction(_syncWithState());

        _applySTLoss(0.02e18);
        _assertZeroLiquidityReduction(_syncWithState());

        OpReceipt memory rST = _doRedeemST(ST_ALICE_ADDRESS, ST.balanceOf(ST_ALICE_ADDRESS) / 4);
        assertGt(toUint256(rST.claims.nav), 0, "the senior redemption must pay out");
        uint256 jtShares = JT.maxRedeem(JT_ALICE_ADDRESS) / 2;
        assertGt(jtShares, 0, "arrange: the junior redemption must be nonzero");
        _doRedeemJT(JT_ALICE_ADDRESS, jtShares);
        _assertZeroLiquidityReduction(_syncWithState());

        _warpForward(1 days);
        _applySTYield(0.02e18);
        _assertZeroLiquidityReduction(_syncWithState());

        // A max-size senior deposit is bounded by coverage alone: the liquidity leg never binds and never reverts
        TRANCHE_UNIT maxAssets = ST.maxDeposit(ST_BOB_ADDRESS);
        assertGt(maxAssets, ZERO_TRANCHE_UNITS, "arrange: the coverage headroom must be nonzero");
        assertLt(maxAssets, MAX_TRANCHE_UNITS, "coverage must be the binding bound");
        dealSTAsset(ST_BOB_ADDRESS, toUint256(maxAssets));
        OpReceipt memory r = _doDepositST(ST_BOB_ADDRESS, toUint256(maxAssets));
        assertGt(r.shares, 0, "the max-size senior deposit must land with the liquidity leg unbounded");
        assertLe(r.post.covUtilWAD, WAD, "the max-size deposit must leave coverage satisfied");
        _assertZeroLiquidityReduction(_syncWithState());
    }

    /**
     * @notice Raising the coverage and liquidity requirements re-prices the deposit and withdrawal gates exactly per
     *         the F15 and F17 recomputations, with exact-args setter events and the setter's inline pre-sync
     *         observable on the checkpoint timestamps.
     */
    function test_Sequence_gateConsistency_afterParamChanges() public {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 10);
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        assertEq(uint256(a0.minLiquidityWAD), 0, "arrange: coverage must be the only senior deposit bound");
        TRANCHE_UNIT maxDepositBefore = ST.maxDeposit(ST_BOB_ADDRESS);
        assertEq(maxDepositBefore, _expectedMaxSTDepositAssets(), "stMaxDeposit must match the F15 recompute");
        assertLt(maxDepositBefore, MAX_TRANCHE_UNITS, "arrange: coverage must bound the deposit");

        // Raising the coverage requirement shrinks the senior deposit capacity per F15
        uint64 newMinCoverageWAD = uint64(uint256(a0.minCoverageWAD) * 2);
        bytes memory coverageData = abi.encodeCall(ACCOUNTANT.setMinCoverage, (newMinCoverageWAD));
        _scheduleAccountantOperation(coverageData);
        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.CoverageUpdated(newMinCoverageWAD);
        _executeScheduledAccountantOperation(coverageData);
        assertEq(uint256(ACCOUNTANT.getState().minCoverageWAD), uint256(newMinCoverageWAD), "the coverage requirement must update");
        assertEq(uint256(ACCOUNTANT.getState().lastYieldShareAccrualTimestamp), block.timestamp, "the setter's inline sync must stamp the checkpoint");
        _sync();
        TRANCHE_UNIT maxDepositAfter = ST.maxDeposit(ST_BOB_ADDRESS);
        assertEq(maxDepositAfter, _expectedMaxSTDepositAssets(), "stMaxDeposit must match the F15 recompute after the raise");
        assertLt(maxDepositAfter, maxDepositBefore, "raising the coverage requirement must shrink the senior deposit capacity");

        // Raising the liquidity requirement shrinks the withdrawable pooled depth per F17
        if (testConfig.hasLiquidityTranche) {
            _seedDefaultLT();
            _sync();
            uint64 minLiquidityA = _minLiquidityForTargetUtil(0.4e18);
            bytes memory liquidityData = abi.encodeCall(ACCOUNTANT.setMinLiquidity, (minLiquidityA));
            _scheduleAccountantOperation(liquidityData);
            vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
            emit IRoycoDayAccountant.LiquidityUpdated(minLiquidityA);
            _executeScheduledAccountantOperation(liquidityData);
            assertEq(uint256(ACCOUNTANT.getState().lastYieldShareAccrualTimestamp), block.timestamp, "the liquidity setter's inline sync must stamp the checkpoint");
            _sync();
            (, NAV_UNIT maxWithdrawableA,) = KERNEL.ltMaxWithdrawable(LT_ALICE_ADDRESS);
            assertEq(maxWithdrawableA, _expectedMaxLTWithdrawalNAV(), "ltMaxWithdrawable must match the F17 recompute");
            assertGt(toUint256(maxWithdrawableA), 0, "arrange: the liquidity surplus must be nonzero");

            _setMinLiquidityWAD(minLiquidityA * 2);
            _sync();
            (, NAV_UNIT maxWithdrawableB,) = KERNEL.ltMaxWithdrawable(LT_ALICE_ADDRESS);
            assertEq(maxWithdrawableB, _expectedMaxLTWithdrawalNAV(), "ltMaxWithdrawable must match the F17 recompute after the raise");
            assertLt(maxWithdrawableB, maxWithdrawableA, "raising the liquidity requirement must shrink the withdrawable depth");
        }
        _assertCommittedConservation();
    }
}
