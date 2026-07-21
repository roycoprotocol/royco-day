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
import { DeploymentResult } from "../../../script/config/DeploymentTypes.sol";
import { ADMIN_ACCOUNTANT_ROLE, ADMIN_UNPAUSER_ROLE, LT_LP_ROLE } from "../../../src/factory/Roles.sol";
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
import { IKernelTestHooks } from "../../utils/IKernelTestHooks.sol";
import { RoycoDayTestBase } from "../../utils/RoycoDayTestBase.sol";

/**
 * @title Test_KernelSuiteBase
 * @notice The shared, config-driven base every Day kernel test extends. `setUp` reads the concrete kernel's `TestConfig`,
 *         forks the configured network, deploys the market end-to-end through the real `DeployScript` (via the concrete
 *         `_deployKernelAndMarket` hook, which selects a market config by name from the config file), wires every deployed
 *         contract into member vars (including the Day-only LT/pool/hook/LDM topology the script's result omits), and
 *         funds the ST/JT providers. Concrete kernel tests then only supply the per-kernel `IKernelTestHooks` and the market
 *         name — following an "abstract kernel test per kernel type" pattern.
 * @dev The shared tests live here on top of the scaffolding, grouped by flow: deposits, redemptions, syncs, adversarial.
 */
abstract contract Test_KernelSuiteBase is RoycoDayTestBase, IKernelTestHooks {
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
    function _deployKernelAndMarket() internal virtual returns (DeploymentResult memory result);

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
            VAULT = IVault(address(GyroECLPPoolFactory(DEPLOY_SCRIPT.getChainConfig(block.chainid, false).gyroECLPPoolFactory).getVault()));
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
        NAV_UNIT stRawNAV = ST.getRawNAV();
        NAV_UNIT jtRawNAV = JT.getRawNAV();
        NAV_UNIT stEffectiveNAV = ST.totalAssets().nav;
        NAV_UNIT jtEffectiveNAV = JT.totalAssets().nav;
        assertApproxEqAbs(stRawNAV + jtRawNAV, stEffectiveNAV + jtEffectiveNAV, maxNAVDelta(), "NAV conservation");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SHARED HELPERS + SNAPSHOT MACHINERY (no tests)
    // ═══════════════════════════════════════════════════════════════════════════

    // ── Snapshot struct + capture ──

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
     * @dev Utilizations are recomputed from the committed checkpoint fields via the pure recompute helpers,
     *      never by re-calling an accountant view, so gate assertions stay independent.
     */
    struct MarketSnapshot {
        // Live raw NAVs (quoter conversions of owned assets). ltRawNAV is 0 when the market has no LT
        NAV_UNIT stRawNAV;
        NAV_UNIT jtRawNAV;
        NAV_UNIT ltRawNAV;
        // Committed accountant checkpoint (ACCOUNTANT.getState())
        NAV_UNIT lastSTRawNAV;
        NAV_UNIT lastJTRawNAV;
        NAV_UNIT lastLTRawNAV;
        NAV_UNIT lastSTEffectiveNAV;
        NAV_UNIT lastJTEffectiveNAV;
        NAV_UNIT lastJTCoverageImpermanentLoss;
        MarketState marketState;
        uint32 fixedTermEnd;
        uint32 lastAccrualTs;
        uint32 lastPremiumTs;
        uint192 twJT;
        uint192 twLT;
        // Utilizations recomputed live from committed inputs via _expectedCoverageUtilization/_expectedLiquidityUtilization
        uint256 coverageUtilizationWAD;
        uint256 liquidityUtilizationWAD;
        // Supplies
        uint256 stSupply;
        uint256 jtSupply;
        uint256 ltSupply;
        // Kernel owned-asset accounting (KERNEL.getState())
        TRANCHE_UNIT stOwned;
        TRANCHE_UNIT jtOwned;
        TRANCHE_UNIT ltOwned;
        uint256 ltOwnedSeniorTrancheShares;
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
        s.stRawNAV = ST.getRawNAV();
        s.jtRawNAV = JT.getRawNAV();
        if (hasLT) s.ltRawNAV = LT.getRawNAV();

        // Committed accountant checkpoint
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        s.lastSTRawNAV = a.lastSTRawNAV;
        s.lastJTRawNAV = a.lastJTRawNAV;
        s.lastLTRawNAV = a.lastLTRawNAV;
        s.lastSTEffectiveNAV = a.lastSTEffectiveNAV;
        s.lastJTEffectiveNAV = a.lastJTEffectiveNAV;
        s.lastJTCoverageImpermanentLoss = a.lastJTCoverageImpermanentLoss;
        s.marketState = a.lastMarketState;
        s.fixedTermEnd = a.fixedTermEndTimestamp;
        s.lastAccrualTs = a.lastYieldShareAccrualTimestamp;
        s.lastPremiumTs = a.lastPremiumPaymentTimestamp;
        s.twJT = a.twJTYieldShareAccruedWAD;
        s.twLT = a.twLTYieldShareAccruedWAD;

        // Utilizations recomputed independently from the committed checkpoint
        s.coverageUtilizationWAD = _expectedCoverageUtilization(a.lastSTRawNAV, a.lastJTRawNAV, a.minCoverageWAD, a.lastJTEffectiveNAV);
        s.liquidityUtilizationWAD = _expectedLiquidityUtilization(a.lastSTEffectiveNAV, a.minLiquidityWAD, a.lastLTRawNAV);

        // Supplies
        s.stSupply = ST.totalSupply();
        s.jtSupply = JT.totalSupply();
        if (hasLT) s.ltSupply = LT.totalSupply();

        // Kernel owned-asset ledger
        IRoycoDayKernel.RoycoDayKernelState memory k = KERNEL.getState();
        s.stOwned = k.stOwnedYieldBearingAssets;
        s.jtOwned = k.jtOwnedYieldBearingAssets;
        s.ltOwned = k.ltOwnedYieldBearingAssets;
        s.ltOwnedSeniorTrancheShares = k.ltOwnedSeniorTrancheShares;

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

    // ── Solvency + conservation asserts ──

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
            assertGe(ST.balanceOf(address(KERNEL)), k.ltOwnedSeniorTrancheShares, "solvency: ST share balance below the idle liquidity premium ledger");
        }
    }

    /// @notice Wei-exact two-term conservation on the COMMITTED checkpoint: `stRaw + jtRaw == stEff + jtEff`
    ///         holds byte-for-byte, because the waterfall only ever re-labels value between the two tranches.
    function _assertCommittedConservation() internal view {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertNAVConservation(a.lastSTRawNAV, a.lastJTRawNAV, a.lastSTEffectiveNAV, a.lastJTEffectiveNAV, "committed checkpoint");
    }

    // ── Actors, roles, gating ──

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

    // ── Independent expected-value math (pure, Math.mulDiv only) ──

    /**
     * @dev The share-pricing denominator used when a tranche has live supply but zero effective NAV.
     *      Mirrors `ValuationLogic._convertToShares`, which substitutes ONE_NAV_UNIT (1 wei of NAV) so
     *      new depositors dilute the existing unbacked holders (src/libraries/logic/ValuationLogic.sol).
     */
    uint256 internal constant ZERO_NAV_SHARE_PRICING_DENOMINATOR = 1;

    /// @dev The max mint dilution, restated from Constants.sol (MAX_MINT_DILUTION_WAD = WAD − 1e6):
    ///      a single mint owns at most (1 − 1e-12) of the post-mint supply
    uint256 internal constant MAX_MINT_DILUTION = 1e18 - 1e6;

    /// @notice Expected shares minted for `_value` against `_supply` shares backed by `_totalNAV` (floor).
    /// @dev Mirrors `ValuationLogic._convertToShares` including its zero-supply and zero-NAV boundaries and
    ///      the mint-dilution clamp (bind iff value·(WAD − MAX_MINT_DILUTION) > denominator·MAX_MINT_DILUTION; products fit on the suite domain).
    function _expectedShares(NAV_UNIT _value, uint256 _supply, NAV_UNIT _totalNAV) internal pure returns (uint256) {
        if (_supply == 0) return toUint256(_value);
        uint256 denominator = toUint256(_totalNAV) == 0 ? ZERO_NAV_SHARE_PRICING_DENOMINATOR : toUint256(_totalNAV);
        if (toUint256(_value) * (WAD - MAX_MINT_DILUTION) > denominator * MAX_MINT_DILUTION) {
            return Math.mulDiv(_supply, MAX_MINT_DILUTION, WAD - MAX_MINT_DILUTION);
        }
        return Math.mulDiv(toUint256(_value), _supply, denominator);
    }

    /// @notice Expected value redeemed for `_shares` against `_supply` shares backed by `_totalNAV` (floor).
    /// @dev Mirrors `ValuationLogic._convertToValue` including its zero-supply boundary.
    function _expectedValue(uint256 _shares, uint256 _supply, NAV_UNIT _totalNAV) internal pure returns (NAV_UNIT) {
        if (_supply == 0) return toNAVUnits(uint256(0));
        return toNAVUnits(Math.mulDiv(toUint256(_totalNAV), _shares, _supply));
    }

    /// @notice Independent coverage utilization recomputation (ceil), mirroring `UtilizationLogic._computeCoverageUtilization`.
    function _expectedCoverageUtilization(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint64 _minCoverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        internal
        pure
        returns (uint256)
    {
        if (_minCoverageWAD == 0) return 0;
        uint256 totalCoveredExposure = toUint256(_stRawNAV) + toUint256(_jtRawNAV);
        if (totalCoveredExposure == 0) return 0;
        if (toUint256(_jtEffectiveNAV) == 0) return type(uint256).max;
        return Math.mulDiv(totalCoveredExposure, _minCoverageWAD, toUint256(_jtEffectiveNAV), Math.Rounding.Ceil);
    }

    /// @notice Independent liquidity utilization recomputation (ceil), mirroring `UtilizationLogic._computeLiquidityUtilization`.
    function _expectedLiquidityUtilization(NAV_UNIT _stEffectiveNAV, uint64 _minLiquidityWAD, NAV_UNIT _ltRawNAV) internal pure returns (uint256) {
        if (toUint256(_stEffectiveNAV) == 0 || _minLiquidityWAD == 0) return 0;
        if (toUint256(_ltRawNAV) == 0) return type(uint256).max;
        return Math.mulDiv(toUint256(_stEffectiveNAV), _minLiquidityWAD, toUint256(_ltRawNAV), Math.Rounding.Ceil);
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
     * @notice Input/output packet for the independent two-term tranche accounting sync recomputation.
     * @dev Inputs are the committed checkpoint, the MEASURED post-simulate raw NAVs, the premium-window
     *      inputs (the stored time-weighted accumulators plus this sync's YDM previews weighted by the
     *      accrual window), the fee rates, and the effective dust. Outputs are every committed field the
     *      sync produces, filled in by `_expectedSync`.
     */
    struct SyncExpectation {
        // Inputs: measured raw NAVs + committed checkpoint
        NAV_UNIT stRawNAVNew;
        NAV_UNIT jtRawNAVNew;
        NAV_UNIT lastSTRawNAV;
        NAV_UNIT lastJTRawNAV;
        NAV_UNIT lastSTEffectiveNAV;
        NAV_UNIT lastJTEffectiveNAV;
        NAV_UNIT lastJTCoverageImpermanentLoss;
        // Inputs: the premium window (yield shares capped at the max* config, accumulators as stored)
        uint256 jtYieldShareWAD;
        uint256 ltYieldShareWAD;
        uint256 twJTStart;
        uint256 twLTStart;
        uint256 elapsed;
        uint256 premiumElapsed;
        // Inputs: fee rates and dust
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 jtYieldShareProtocolFeeWAD;
        uint64 ltYieldShareProtocolFeeWAD;
        NAV_UNIT effectiveDust;
        // Input: whether the resulting market state zeroes the LT premium and all fees
        bool fixedTermActive;
        // Outputs
        NAV_UNIT stEffectiveNAV;
        NAV_UNIT jtEffectiveNAV;
        NAV_UNIT jtCoverageImpermanentLoss;
        NAV_UNIT ltLiquidityPremium;
        NAV_UNIT stProtocolFee;
        NAV_UNIT jtProtocolFee;
        NAV_UNIT ltProtocolFee;
        NAV_UNIT jtRiskPremium;
        bool premiumsPaid;
    }

    /**
     * @notice Re-derives the full tranche accounting sync from the written accounting rules, independently of production code.
     * @dev Mirrors `RoycoDayAccountant._previewSyncTrancheAccounting`: claim decomposition, floor-on-magnitude
     *      attribution with JT absorbing the rounding residual, JT loss/gain booking with the dust-gated JT fee,
     *      coverage `min(stLoss, jtEffectiveNAV)` with the JT-fee recompute, IL recovery `min(stGain, IL)`, premiums
     *      `floor(stGain * (twStart + yieldShare * elapsed) / (premiumElapsed * WAD))` — the time-weighted
     *      average yield share over the full window since the last premium payment, which reduces to
     *      `floor(stGain * yieldShare / WAD)` for a single constant-share window — with the same-block
     *      (`premiumElapsed == 0`) instantaneous-share path, fee floors, `premiumsPaid = stGain > dust` gating
     *      every fee, the LT premium folded back into stEffectiveNAV, and the FIXED_TERM zeroing of the LT premium plus
     *      all fees (but NOT the JT risk premium, which is already booked into jtEffectiveNAV).
     */
    function _expectedSync(SyncExpectation memory _e) internal pure returns (SyncExpectation memory) {
        uint256 stEffectiveNAV = toUint256(_e.lastSTEffectiveNAV);
        uint256 jtEffectiveNAV = toUint256(_e.lastJTEffectiveNAV);
        uint256 jtCoverageImpermanentLoss = toUint256(_e.lastJTCoverageImpermanentLoss);
        uint256 dust = toUint256(_e.effectiveDust);

        // STEP_APPLY_PNL_ATTRIBUTION: decompose the checkpointed claims and attribute each raw delta
        int256 dStEff;
        int256 dJtEff;
        {
            uint256 lastSTRawNAV = toUint256(_e.lastSTRawNAV);
            uint256 lastJTRawNAV = toUint256(_e.lastJTRawNAV);
            uint256 stClaimOnJTRaw = stEffectiveNAV > lastSTRawNAV ? stEffectiveNAV - lastSTRawNAV : 0;
            uint256 jtClaimOnSTRaw = jtEffectiveNAV > lastJTRawNAV ? jtEffectiveNAV - lastJTRawNAV : 0;
            uint256 stClaimOnSTRaw = lastSTRawNAV - jtClaimOnSTRaw;
            int256 deltaSTRaw = int256(toUint256(_e.stRawNAVNew)) - int256(lastSTRawNAV);
            int256 deltaJTRaw = int256(toUint256(_e.jtRawNAVNew)) - int256(lastJTRawNAV);
            int256 dStOnSTRaw = lastSTRawNAV == 0 ? (stEffectiveNAV > 0 ? deltaSTRaw : int256(0)) : _attributeDelta(deltaSTRaw, stClaimOnSTRaw, lastSTRawNAV);
            int256 dStOnJTRaw = _attributeDelta(deltaJTRaw, stClaimOnJTRaw, lastJTRawNAV);
            dStEff = dStOnSTRaw + dStOnJTRaw;
            dJtEff = (deltaSTRaw + deltaJTRaw) - dStEff;
        }

        // STEP_APPLY_JT_LOSS / STEP_APPLY_JT_GAIN
        uint256 jtNetGain;
        uint256 jtProtocolFee;
        if (dJtEff < 0) {
            jtEffectiveNAV -= uint256(-dJtEff);
        } else if (dJtEff > 0) {
            jtNetGain = uint256(dJtEff);
            if (jtNetGain > dust) jtProtocolFee = Math.mulDiv(jtNetGain, _e.jtProtocolFeeWAD, WAD);
            jtEffectiveNAV += jtNetGain;
        }

        uint256 ltLiquidityPremium;
        uint256 stProtocolFee;
        uint256 ltProtocolFee;
        uint256 jtRiskPremium;
        bool premiumsPaid;
        if (dStEff < 0) {
            // STEP_APPLY_JT_COVERAGE_TO_ST + STEP_ST_INCURS_RESIDUAL_LOSSES
            uint256 stLoss = uint256(-dStEff);
            uint256 coverageApplied = Math.min(stLoss, jtEffectiveNAV);
            if (coverageApplied != 0) {
                if (jtProtocolFee != 0) {
                    jtNetGain = jtNetGain > coverageApplied ? jtNetGain - coverageApplied : 0;
                    jtProtocolFee = jtNetGain > dust ? Math.mulDiv(jtNetGain, _e.jtProtocolFeeWAD, WAD) : 0;
                }
                jtEffectiveNAV -= coverageApplied;
                jtCoverageImpermanentLoss += coverageApplied;
                stLoss -= coverageApplied;
            }
            if (stLoss != 0) stEffectiveNAV -= stLoss;
        } else if (dStEff > 0) {
            // STEP_JT_COVERAGE_IMPERMANENT_LOSS_RECOVERY + STEP_PAY_PREMIUMS
            uint256 stGain = uint256(dStEff);
            uint256 ilRecovery = Math.min(stGain, jtCoverageImpermanentLoss);
            if (ilRecovery != 0) {
                jtCoverageImpermanentLoss -= ilRecovery;
                jtEffectiveNAV += ilRecovery;
                stGain -= ilRecovery;
            }
            if (stGain != 0) {
                if (stGain > dust) premiumsPaid = true;
                (jtRiskPremium, ltLiquidityPremium) = _expectedPremiums(_e, stGain);
                if (jtRiskPremium != 0) {
                    if (premiumsPaid) jtProtocolFee += Math.mulDiv(jtRiskPremium, _e.jtYieldShareProtocolFeeWAD, WAD);
                    jtEffectiveNAV += jtRiskPremium;
                    stGain -= jtRiskPremium;
                }
                if (ltLiquidityPremium != 0) {
                    if (premiumsPaid) ltProtocolFee = Math.mulDiv(ltLiquidityPremium, _e.ltYieldShareProtocolFeeWAD, WAD);
                    stGain -= ltLiquidityPremium;
                }
                if (premiumsPaid) stProtocolFee = Math.mulDiv(stGain, _e.stProtocolFeeWAD, WAD);
                stEffectiveNAV += stGain + ltLiquidityPremium;
            }
        }

        // A FIXED_TERM-resulting sync pays no LT premium and takes no fees
        if (_e.fixedTermActive) {
            ltLiquidityPremium = 0;
            stProtocolFee = 0;
            jtProtocolFee = 0;
            ltProtocolFee = 0;
        }

        _e.stEffectiveNAV = toNAVUnits(stEffectiveNAV);
        _e.jtEffectiveNAV = toNAVUnits(jtEffectiveNAV);
        _e.jtCoverageImpermanentLoss = toNAVUnits(jtCoverageImpermanentLoss);
        _e.ltLiquidityPremium = toNAVUnits(ltLiquidityPremium);
        _e.stProtocolFee = toNAVUnits(stProtocolFee);
        _e.jtProtocolFee = toNAVUnits(jtProtocolFee);
        _e.ltProtocolFee = toNAVUnits(ltProtocolFee);
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
    function _expectedPremiums(SyncExpectation memory _e, uint256 _stGain) internal pure returns (uint256 jtRiskPremium, uint256 ltLiquidityPremium) {
        uint256 twJT = _e.twJTStart + _e.jtYieldShareWAD * _e.elapsed;
        uint256 twLT = _e.twLTStart + _e.ltYieldShareWAD * _e.elapsed;
        uint256 premiumElapsed = _e.premiumElapsed;
        if (premiumElapsed == 0) {
            premiumElapsed = 1;
            twJT = _e.jtYieldShareWAD;
            twLT = _e.ltYieldShareWAD;
        }
        jtRiskPremium = Math.mulDiv(_stGain, twJT, premiumElapsed * WAD);
        ltLiquidityPremium = Math.mulDiv(_stGain, twLT, premiumElapsed * WAD);
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
     *         `(stEffectiveNAVPost - prem - fee)` at the pre-sync supply.
     * @dev Mirrors `FeeAndLiquidityPremiumLogic._computeSTFeeAndLiquidityPremiumSharesToMint`. The LT protocol fee
     *      is carved out of the premium: the premium leg mints `(prem - ltFee)` and the fee leg mints `(fee + ltFee)`,
     *      so the LT holds the premium net of the fee and the protocol receives the fee as senior shares. The retained
     *      denominator subtracts the gross premium and the ST fee, so the carve-out leaves it unchanged.
     */
    function _expectedPremiumShares(
        NAV_UNIT _prem,
        NAV_UNIT _fee,
        NAV_UNIT _ltFee,
        NAV_UNIT _stEffectiveNAVPost,
        uint256 _preSupply
    )
        internal
        pure
        returns (uint256 premShares, uint256 feeShares)
    {
        NAV_UNIT retainedSeniorNAV = toNAVUnits(toUint256(_stEffectiveNAVPost) - toUint256(_prem) - toUint256(_fee));
        premShares = _expectedShares(toNAVUnits(toUint256(_prem) - toUint256(_ltFee)), _preSupply, retainedSeniorNAV);
        feeShares = _expectedShares(toNAVUnits(toUint256(_fee) + toUint256(_ltFee)), _preSupply, retainedSeniorNAV);
    }

    /**
     * @notice Independent counterweight for the senior premium/fee/deposit share mints: every mint is floor-priced
     *         against the senior NAV retained by pre-existing holders, so their NAV-per-share can never fall across
     *         the operation. Cross-multiplied on plain checked integers, sharing nothing with the share-pricing mirror.
     * @dev `_mintedForValue` is the total NAV the mints paid for (premium + fee, plus the booked deposit value when
     *      a deposit rode the same sync). Pre-existing holders keep `preSupply / postSupply` of the post-op senior
     *      effective NAV, which must cover at least the value the checkpoint retains for them
     *      (`stEffectiveNAV - mintedForValue`): `stEffPost * preSupply >= (stEffPost - minted) * postSupply`.
     */
    function _assertSeniorMintsNonDilutive(uint256 _stSupplyPre, NAV_UNIT _mintedForValue) internal view {
        uint256 stEffPost = toUint256(ACCOUNTANT.getState().lastSTEffectiveNAV);
        uint256 retained = stEffPost - toUint256(_mintedForValue);
        assertGe(stEffPost * _stSupplyPre, retained * ST.totalSupply(), "the senior share mints must never dilute pre-existing holders' NAV-per-share");
    }

    /**
     * @notice Independent pro-rata ceiling on a redemption's claims: whoever redeems `_shares` out of `_supplyPre`
     *         can be paid at most that exact fraction of the tranche's pre-redemption effective NAV, because floor
     *         scaling only ever rounds the payout down. Cross-multiplied on plain checked integers so the bound
     *         shares no code with the claim-scaling mirror.
     */
    function _assertClaimsWithinProRataCeiling(AssetClaims memory _claims, uint256 _shares, uint256 _supplyPre, NAV_UNIT _effPre) internal pure {
        assertLe(toUint256(_claims.nav) * _supplyPre, toUint256(_effPre) * _shares, "a redeemer can never be paid more NAV than its exact pro-rata slice");
    }

    // ── Flow executors ──

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

    // ── Market staging helpers ──

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
     *      initialization path for the pool (see the family override's note).
     */
    function _initializeLTVenueIfNeeded() internal virtual { }

    /**
     * @notice Returns the raw NAV inputs the LAST sync committed (the measured post-simulate raws).
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
     *      Replaces RoycoDayTestBase's `_executeAccountantAdminOperation`, whose warp would
     *      otherwise leave a Chainlink-family feed stale at execute time.
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

    /// @notice Drives `coverageUtilizationWAD >= coverageLiquidationUtilizationWAD` via measured-loss iteration, syncing each step.
    /// @dev Fails the test (never silently gives up) if the threshold is not reached within the iteration bound.
    function _breachLiquidation() internal {
        for (uint256 i = 0; i < 60; ++i) {
            _applySTLoss(0.05e18);
            _sync();
            IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
            uint256 coverageUtilizationWAD = _expectedCoverageUtilization(a.lastSTRawNAV, a.lastJTRawNAV, a.minCoverageWAD, a.lastJTEffectiveNAV);
            if (coverageUtilizationWAD >= a.coverageLiquidationUtilizationWAD) return;
        }
        fail("_breachLiquidation: liquidation coverage utilization threshold not reached");
    }

    /// @notice Enters FIXED_TERM: nonzero duration, a covered loss (below jtEffectiveNAV), then a sync, with an arrange-guard.
    function _enterFixedTerm() internal {
        _setFixedTermDuration(7 days);
        _applySTLoss(0.02e18);
        _sync();
        assertTrue(ACCOUNTANT.getState().lastMarketState == MarketState.FIXED_TERM, "arrange: market must be in a fixed term state");
    }

    /// @notice Stages idle liquidity premium: reinvest gate forced shut, warp, yield, sync. Returns the idle ST share balance.
    /// @dev Skips the test when the venue exposes no reinvestment slippage seam (capability gate).
    function _stageIdleLiquidityPremium() internal returns (uint256 idleShares) {
        vm.skip(!_trySetReinvestmentSlippage(0));
        _sync();
        _warpForward(1 days);
        _applySTYield(0.05e18);
        _sync();
        idleShares = KERNEL.getState().ltOwnedSeniorTrancheShares;
        assertGt(idleShares, 0, "arrange: no liquidity premium ST shares were staged");
    }

    // ── Preview + pause + blacklist utilities ──

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
        address[] memory accounts = new address[](1);
        accounts[0] = _account;
        // The blacklist admin surface is gated by ADMIN_BLACKLIST_ROLE, granted to the market-ops admin.
        vm.prank(KERNEL_ADMIN_ADDRESS);
        BLACKLIST.blacklistAccounts(accounts);
    }

    // ── Event helpers ──

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

    // ── New virtual seams (safe defaults, per-family overrides allowed) ──

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
     *      a wrong role binding), which fails the test loudly instead of silently skipping the premium tests.
     */
    function _trySetReinvestmentSlippage(uint64 _slippageWAD) internal virtual returns (bool ok) {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        bytes memory returnData;
        (ok, returnData) = address(KERNEL).call(abi.encodeWithSignature("setMaxReinvestmentSlippage(uint64)", _slippageWAD));
        if (!ok && returnData.length != 0) fail("the reinvestment slippage seam exists but its setter reverted");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPOSIT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    // ── Section-local helpers ──

    /**
     * @notice Measures the fresh post-simulate sync inputs (committed raw NAVs and the deposit valuation) under a
     *         reverted state snapshot, so a pending oracle move is read at the rate execution will actually use.
     * @dev A live pre-sync `getRawNAV()` view is stale against the transient quoter cache left by an earlier kernel
     *      op in the same test transaction, so the raws are read from the checkpoint a throwaway sync commits and
     *      the whole probe is rolled back. Raw NAVs and quoter conversions are sync INPUTS, so this read is not circular with any assertion.
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
        returns (NAV_UNIT depositNAV, NAV_UNIT effectiveNAV, TRANCHE_UNIT ltAssetsOut, uint256 ltTotalSupplyAfterMints)
    {
        uint256 snapshotId = vm.snapshotState();
        vm.prank(address(0), address(0));
        (bool ok, bytes memory ret) =
            address(KERNEL).call(abi.encodeCall(IRoycoDayKernel.ltPreviewDepositMultiAsset, (toTrancheUnits(_stAssets), _quoteAssets)));
        vm.revertToState(snapshotId);
        if (!ok) _bubbleRevert(ret);
        (depositNAV, effectiveNAV, ltAssetsOut, ltTotalSupplyAfterMints) = abi.decode(ret, (NAV_UNIT, NAV_UNIT, TRANCHE_UNIT, uint256));
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
     * @notice Derives the `minLiquidityWAD` that puts the committed liquidity utilization at `_targetUtilizationWAD`.
     * @dev Callers must have synced in the same block so the committed checkpoint is fresh. The narrowing cast
     *      is guarded, since a pool deeper than about twenty times the senior tranche would otherwise truncate
     *      the requirement silently into an arbitrary value.
     */
    function _minLiquidityForTargetUtilization(uint256 _targetUtilizationWAD) internal view returns (uint64 minLiquidityWAD) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 requirementWAD = Math.mulDiv(_targetUtilizationWAD, toUint256(a.lastLTRawNAV), toUint256(a.lastSTEffectiveNAV));
        assertGt(requirementWAD, 0, "arrange: the computed minimum liquidity must be nonzero");
        assertLe(requirementWAD, uint256(type(uint64).max), "arrange: the computed minimum liquidity must fit uint64");
        minLiquidityWAD = uint64(requirementWAD);
    }

    /// @notice Arrange guard asserting that removing `_shares`' proportional BPT slice from the committed mark
    ///         would push the liquidity utilization above WAD.
    function _assertSliceWouldBreachLiquidity(uint256 _shares, uint64 _minLiquidityWAD, MarketSnapshot memory _pre) internal view {
        uint256 sliceValue = Math.mulDiv(toUint256(_pre.lastLTRawNAV), _shares, LT.totalSupply());
        assertGt(
            _expectedLiquidityUtilization(_pre.lastSTEffectiveNAV, _minLiquidityWAD, toNAVUnits(toUint256(_pre.lastLTRawNAV) - sliceValue)),
            WAD,
            "arrange: the redemption must breach the liquidity requirement"
        );
    }

    /**
     * @notice Senior-deposit slack (in ST tranche units) whose addition to `stMaxDeposit` guarantees a coverage breach.
     * @dev Derivation: `maxSTDeposit` under-reports the true breach boundary by exactly the
     *      two raw-NAV dust tolerances, so a deposit must exceed it by more than `stDust + jtDust` in NAV to
     *      guarantee `coverageUtilizationWAD > WAD`. Each quoter conversion floors (up to one NAV-per-tranche-unit of error in
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
        assertEq(post.ltOwnedSeniorTrancheShares, _pre.ltOwnedSeniorTrancheShares, "atomicity: idle liquidity premium shares moved");
        assertEq(post.lastSTRawNAV, _pre.lastSTRawNAV, "atomicity: committed ST raw NAV moved");
        assertEq(post.lastJTRawNAV, _pre.lastJTRawNAV, "atomicity: committed JT raw NAV moved");
        assertEq(post.lastLTRawNAV, _pre.lastLTRawNAV, "atomicity: committed LT raw NAV moved");
        assertEq(post.lastSTEffectiveNAV, _pre.lastSTEffectiveNAV, "atomicity: committed ST effective NAV moved");
        assertEq(post.lastJTEffectiveNAV, _pre.lastJTEffectiveNAV, "atomicity: committed JT effective NAV moved");
        assertEq(post.lastJTCoverageImpermanentLoss, _pre.lastJTCoverageImpermanentLoss, "atomicity: committed JT coverage IL moved");
        assertTrue(post.marketState == _pre.marketState, "atomicity: market state moved");
        assertEq(post.kernelSTAssetBal, _pre.kernelSTAssetBal, "atomicity: kernel ST asset balance moved");
        assertEq(post.kernelJTAssetBal, _pre.kernelJTAssetBal, "atomicity: kernel JT asset balance moved");
        assertEq(post.kernelBPTBal, _pre.kernelBPTBal, "atomicity: kernel BPT balance moved");
        assertEq(post.kernelSTShareBal, _pre.kernelSTShareBal, "atomicity: kernel ST share balance moved");
        assertEq(post.feeRecipientSTShares, _pre.feeRecipientSTShares, "atomicity: fee recipient ST shares moved");
        assertEq(post.feeRecipientJTShares, _pre.feeRecipientJTShares, "atomicity: fee recipient JT shares moved");
        assertEq(post.feeRecipientLTShares, _pre.feeRecipientLTShares, "atomicity: fee recipient LT shares moved");
    }

    // ── ST/JT first deposits ──

    /**
     * @notice A first JT deposit mints shares 1:1 with the deposited value and commits `jtRawNAV == jtEffectiveNAV` exactly.
     * @dev The deposited value is captured through the quoter before the first kernel op of the test, so it is the
     *      same live rate the deposit's own quoter cache resolves.
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
        assertEq(post.lastJTRawNAV, value, "committed JT raw NAV must equal the deposited value");
        assertEq(post.lastJTEffectiveNAV, post.lastJTRawNAV, "committed JT effective NAV must equal its raw NAV");
        assertEq(post.lastSTRawNAV, ZERO_NAV_UNITS, "committed ST raw NAV must stay zero");
        assertEq(post.lastSTEffectiveNAV, ZERO_NAV_UNITS, "committed ST effective NAV must stay zero");
        // With jtRawNAV == jtEffectiveNAV the coverage utilization is exactly minCoverage
        // The production value is read via a same-block flat sync (a no-op on the committed state), never recomputed by the suite
        uint256 expectedCovUtilWAD = uint256(ACCOUNTANT.getState().minCoverageWAD);
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
            _expectedCoverageUtilization(pre.lastSTRawNAV + value, pre.lastJTRawNAV, ACCOUNTANT.getState().minCoverageWAD, pre.lastJTEffectiveNAV);
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
        assertEq(post.lastSTRawNAV, value, "committed ST raw NAV must equal the deposited value");
        assertEq(post.lastSTEffectiveNAV, value, "committed ST effective NAV must equal the deposited value");
        assertEq(post.lastJTRawNAV, pre.lastJTRawNAV, "the junior raw NAV must be untouched");
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV, "the junior effective NAV must be untouched");
        // The production value is read via a same-block flat sync (a no-op on the committed state), never recomputed by the suite
        assertEq(_syncWithState().coverageUtilizationWAD, expectedCovUtilWAD, "production coverage utilization must match the independent recompute");
        _assertCommittedConservation();
    }

    // ── ST deposit pricing, previews, and gates ──

    /// @notice After committed yield an ST deposit mints exactly `floor(value * supply / stEffectiveNAV)` shares and the
    ///         post-op checkpoint books exactly the measured raw-NAV delta into the senior effective NAV.
    function test_STDeposit_exactSharePricing_afterYield() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applySTYield(0.05e18);
        _sync();

        uint256 assets = testConfig.initialFunding / 10;
        NAV_UNIT value = KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets));
        uint256 stSupply = ST.totalSupply();
        NAV_UNIT stEffectiveNAV = ACCOUNTANT.getState().lastSTEffectiveNAV;
        uint256 expectedShares = _expectedShares(value, stSupply, stEffectiveNAV);
        MarketSnapshot memory pre = _snap();

        vm.startPrank(ST_BOB_ADDRESS);
        IERC20(testConfig.stAsset).approve(address(ST), assets);
        _expectDeposit(address(ST), ST_BOB_ADDRESS, ST_BOB_ADDRESS, toTrancheUnits(assets), expectedShares);
        uint256 shares = ST.deposit(toTrancheUnits(assets), ST_BOB_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        MarketSnapshot memory post = _snap();
        assertEq(shares, expectedShares, "deposit shares must match the independent floor pricing exactly");
        NAV_UNIT measuredRawDelta = post.lastSTRawNAV - pre.lastSTRawNAV;
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV + measuredRawDelta, "post ST effective NAV must grow by exactly the measured raw delta");
        assertApproxEqAbs(measuredRawDelta, value, maxNAVDelta(), "the raw delta must round-trip the deposited value through the quoter");
        assertEq(post.stSupply, pre.stSupply + shares, "no fee mint may accompany a same-block deposit");
        assertEq(post.stOwned, pre.stOwned + toTrancheUnits(assets), "stOwned must grow by the deposited assets");
        assertEq(post.lastJTRawNAV, pre.lastJTRawNAV, "the junior raw NAV must be untouched");
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV, "the junior effective NAV must be untouched");
        _assertCommittedConservation();
    }

    /**
     * @notice `previewDeposit` equals the executed deposit exactly in the same block, at a non-1:1 share price after
     *         a warped accrual window.
     * @dev The final `_sync()` commits the window's rate drift so the parity is pinned at a committed non-1:1
     *      rate. `previewDeposit` replays the real mutating deposit inside a reverted simulation, so it prices
     *      identically to execution by construction. The pending-PnL deposit pricing itself is pinned
     *      independently in `test_STDeposit_emitsDepositEvent` via the full tranche accounting recomputation.
     */
    function test_STDeposit_previewParity() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applySTYield(0.04e18);
        _sync();
        _warpForward(1 days);
        _sync();

        uint256 assets = testConfig.initialFunding / 20;
        // The quoter value of the deposited assets, the raw NAV delta the deposit must book
        NAV_UNIT depositNAV = KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets));
        uint256 previewShares = ST.previewDeposit(toTrancheUnits(assets));
        OpReceipt memory r = _doDepositST(ST_BOB_ADDRESS, assets);

        assertEq(r.shares, previewShares, "previewDeposit must equal the executed deposit exactly");
        assertApproxEqAbs(r.post.lastSTRawNAV - r.pre.lastSTRawNAV, depositNAV, maxNAVDelta(), "the quoter-valued deposit must match the booked raw delta");
        assertEq(r.post.stSupply, r.pre.stSupply + r.shares, "supply must grow by exactly the minted shares");
        _assertCommittedConservation();
    }

    /// @notice A zero-asset ST deposit reverts with the accountant's exact-arg `INVALID_POST_OP_STATE(ST_DEPOSIT)`.
    /// @dev The post-op sync's `deltaSTRawNAV > 0` requirement fires before the tranche's `INVALID_DEPOSIT_NAV` check can.
    function test_RevertIf_STDepositZeroAssets() public {
        vm.prank(ST_ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        ST.deposit(ZERO_TRANCHE_UNITS, ST_ALICE_ADDRESS);
    }

    /// @notice An ST deposit to the zero receiver reverts with the exact OZ `ERC20InvalidReceiver` error.
    function test_RevertIf_STDepositZeroReceiver() public {
        uint256 assets = testConfig.initialFunding / 10;
        vm.prank(ST_ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        ST.deposit(toTrancheUnits(assets), address(0));
    }

    /// @notice While the kernel is paused an ST deposit reverts with `EnforcedPause`, `maxDeposit` reports zero, and
    ///         the market resumes after unpause.
    function test_RevertIf_STDepositWhenPaused() public {
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
    function test_RevertIf_STDepositInFixedTerm() public {
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
    function test_RevertIf_STDepositBreachesCoverage() public {
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
     * @dev Pins that senior deposits ARE liquidity-gated: a senior entry raises the exit demand the pool must
     *      back without adding any pooled depth, so the gate prices it like any other depth-consuming move.
     */
    function test_RevertIf_STDepositBreachesLiquidity() public whenLT {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 2);
        _seedDefaultLT();
        _setMinLiquidityWAD(0.1e18);
        _sync();
        MarketSnapshot memory pre = _snap();
        assertLe(pre.liquidityUtilizationWAD, WAD, "arrange: liquidity must start satisfied");

        uint256 assets = (testConfig.initialFunding / 10) * 3;
        NAV_UNIT value = KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets));
        assertGt(
            _expectedLiquidityUtilization(pre.lastSTEffectiveNAV + value, 0.1e18, pre.lastLTRawNAV),
            WAD,
            "arrange: the deposit must breach the liquidity requirement"
        );
        assertLe(
            _expectedCoverageUtilization(pre.lastSTRawNAV + value, pre.lastJTRawNAV, ACCOUNTANT.getState().minCoverageWAD, pre.lastJTEffectiveNAV),
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
    function test_STDeposit_maxDepositExactlyDepositable() public {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 20);
        _sync();
        TRANCHE_UNIT maxAssets = ST.maxDeposit(ST_BOB_ADDRESS);
        assertGt(maxAssets, ZERO_TRANCHE_UNITS, "arrange: the coverage headroom must be nonzero");
        assertLt(maxAssets, MAX_TRANCHE_UNITS, "arrange: coverage must bound the deposit");

        uint256 snapshotId = vm.snapshotState();
        OpReceipt memory r = _doDepositST(ST_BOB_ADDRESS, toUint256(maxAssets));
        assertGt(r.shares, 0, "the max-size deposit must mint shares");
        assertLe(r.post.coverageUtilizationWAD, WAD, "a max-size deposit must leave coverage satisfied");
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
     *         reports the independent liquidity-leg recompute: the max-size deposit lands under the gate and the same
     *         deposit plus the documented slack reverts with `LIQUIDITY_REQUIREMENT_VIOLATED`.
     * @dev The liquidity leg mirrors `RoycoDayAccountant.maxSTDeposit`: `floor(ltRawNAV * WAD / minLiquidity) -
     *      stEffectiveNAV - stDust`. The coverage-derived breach slack strictly dominates the liquidity boundary's
     *      under-report (the single ST dust tolerance plus conversion floors), so it is reused.
     */
    function test_STDeposit_maxDepositExactlyDepositable_liquidityBound() public whenLT {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 2);
        _seedDefaultLT();
        _setMinLiquidityWAD(_minLiquidityForTargetUtilization(0.5e18));
        _sync();

        // Independent two-leg recompute with the liquidity leg binding
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 liquidityHeadroomValue =
            Math.mulDiv(toUint256(a.lastLTRawNAV), WAD, a.minLiquidityWAD) - toUint256(a.lastSTEffectiveNAV) - toUint256(a.stNAVDustTolerance);
        uint256 coverageHeadroomValue = Math.mulDiv(toUint256(a.lastJTEffectiveNAV), WAD, a.minCoverageWAD)
            - (toUint256(a.lastJTRawNAV) + toUint256(a.jtNAVDustTolerance)) - (toUint256(a.lastSTRawNAV) + toUint256(a.stNAVDustTolerance));
        assertLt(liquidityHeadroomValue, coverageHeadroomValue, "arrange: liquidity must be the binding leg");
        TRANCHE_UNIT maxAssets = ST.maxDeposit(ST_BOB_ADDRESS);
        assertEq(
            maxAssets,
            KERNEL.stConvertNAVUnitsToTrancheUnits(toNAVUnits(liquidityHeadroomValue)),
            "stMaxDeposit must match the independent liquidity-leg recompute"
        );

        uint256 snapshotId = vm.snapshotState();
        OpReceipt memory r = _doDepositST(ST_BOB_ADDRESS, toUint256(maxAssets));
        assertGt(r.shares, 0, "the max-size deposit must mint shares");
        assertLe(r.post.liquidityUtilizationWAD, WAD, "a max-size deposit must leave the liquidity requirement satisfied");
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
     *         `Deposit` events, with every value derived from the independent tranche accounting recomputation.
     * @dev The measured post-simulate raw NAVs and the deposit valuation are read via `_measureFreshSyncInputs`
     *      (inputs only). The YDM yield-share previews are captured at sync time as accrual inputs.
     */
    function test_STDeposit_emitsDepositEvent() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        uint256 stSupplyPre = ST.totalSupply();
        uint256 jtSupplyPre = JT.totalSupply();

        _warpForward(1 days);
        _applySTYield(0.05e18);

        // Build the independent sync expectation for the deposit's inline pre-op sync from measured inputs
        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(e.elapsed, 0, "arrange: the accrual window must be nonzero");
        assertGt(e.stRawNAVNew, e.lastSTRawNAV, "arrange: the senior raw NAV must have appreciated");
        uint256 assets = testConfig.initialFunding / 10;
        (,, NAV_UNIT value) = _measureFreshSyncInputs(toTrancheUnits(assets));
        assertTrue(e.premiumsPaid, "arrange: the yield must clear the dust gate");
        assertGt(toUint256(e.stProtocolFee), 0, "arrange: an ST protocol fee must accrue");
        assertGt(toUint256(e.jtProtocolFee), 0, "arrange: a JT yield-share protocol fee must accrue");

        (uint256 premShares, uint256 stFeeShares) =
            _expectedPremiumShares(e.ltLiquidityPremium, e.stProtocolFee, e.ltProtocolFee, e.stEffectiveNAV, stSupplyPre);
        uint256 jtFeeShares = _expectedShares(e.jtProtocolFee, jtSupplyPre, e.jtEffectiveNAV - e.jtProtocolFee);
        uint256 expectedDepositShares = _expectedShares(value, stSupplyPre + premShares + stFeeShares, e.stEffectiveNAV);
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

        assertEq(shares, expectedDepositShares, "deposit shares must match the sync-derived pricing");
        assertEq(ST.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS) - feeRecipientSTPre, stFeeShares, "ST fee shares minted to the recipient");
        assertEq(JT.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS) - feeRecipientJTPre, jtFeeShares, "JT fee shares minted to the recipient");
        IRoycoDayAccountant.RoycoDayAccountantState memory aPost = ACCOUNTANT.getState();
        assertEq(aPost.lastJTRawNAV, e.jtRawNAVNew, "committed JT raw NAV must equal the measured input");
        assertEq(aPost.lastJTEffectiveNAV, e.jtEffectiveNAV, "committed JT effective NAV must match the independent recomputation");
        assertEq(
            aPost.lastSTEffectiveNAV,
            e.stEffectiveNAV + (aPost.lastSTRawNAV - e.stRawNAVNew),
            "committed ST effective NAV must be the sync output plus the deposit"
        );
        assertEq(aPost.lastJTCoverageImpermanentLoss, e.jtCoverageImpermanentLoss, "committed IL must match the independent recomputation");
        assertEq(uint256(aPost.lastPremiumPaymentTimestamp), block.timestamp, "the premium payment must stamp");
        assertEq(uint256(aPost.twJTYieldShareAccruedWAD), 0, "the accrual accumulators must reset after payment");
        // Counterweight independent of the share-pricing mirror: the premium, fee, and deposit mints all pay for
        // real value, so the pre-existing holders' NAV-per-share cannot fall across the whole operation.
        _assertSeniorMintsNonDilutive(stSupplyPre, e.ltLiquidityPremium + e.stProtocolFee + (aPost.lastSTRawNAV - e.stRawNAVNew));
        _assertCommittedConservation();
    }

    // ── JT deposit pricing, previews, and gates ──

    /// @notice After committed yield a JT deposit mints exactly `floor(value * supply / jtEffectiveNAV)` shares, books exactly
    ///         the measured junior raw delta, and lowers coverage utilization to the independent recompute.
    function test_JTDeposit_exactSharePricing_afterYield() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applyJTYield(0.05e18);
        _sync();

        uint256 assets = testConfig.initialFunding / 10;
        NAV_UNIT value = KERNEL.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets));
        uint256 jtSupply = JT.totalSupply();
        NAV_UNIT jtEffectiveNAV = ACCOUNTANT.getState().lastJTEffectiveNAV;
        uint256 expectedShares = _expectedShares(value, jtSupply, jtEffectiveNAV);

        MarketSnapshot memory pre = _snap();
        vm.startPrank(JT_BOB_ADDRESS);
        IERC20(testConfig.jtAsset).approve(address(JT), assets);
        _expectDeposit(address(JT), JT_BOB_ADDRESS, JT_BOB_ADDRESS, toTrancheUnits(assets), expectedShares);
        uint256 shares = JT.deposit(toTrancheUnits(assets), JT_BOB_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        MarketSnapshot memory post = _snap();
        assertEq(shares, expectedShares, "deposit shares must match the independent floor pricing exactly");
        NAV_UNIT measuredRawDelta = post.lastJTRawNAV - pre.lastJTRawNAV;
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV + measuredRawDelta, "post JT effective NAV must grow by exactly the measured raw delta");
        assertApproxEqAbs(measuredRawDelta, value, maxNAVDelta(), "the raw delta must round-trip the deposited value through the quoter");
        assertEq(post.lastSTRawNAV, pre.lastSTRawNAV, "the senior raw NAV must be untouched");
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV, "the senior effective NAV must be untouched");
        assertEq(post.jtSupply, pre.jtSupply + shares, "no fee mint may accompany a same-block deposit");
        assertEq(post.jtOwned, pre.jtOwned + toTrancheUnits(assets), "jtOwned must grow by the deposited assets");
        uint256 expectedCovUtilWAD = _expectedCoverageUtilization(
            pre.lastSTRawNAV, pre.lastJTRawNAV + measuredRawDelta, ACCOUNTANT.getState().minCoverageWAD, pre.lastJTEffectiveNAV + measuredRawDelta
        );
        // The production value is read via a same-block flat sync (a no-op on the committed state), never recomputed by the suite
        uint256 productionCovUtilWAD = _syncWithState().coverageUtilizationWAD;
        assertEq(productionCovUtilWAD, expectedCovUtilWAD, "production coverage utilization must match the independent recompute");
        assertLt(productionCovUtilWAD, pre.coverageUtilizationWAD, "the JT deposit must lower coverage utilization");
        _assertCommittedConservation();
    }

    /// @notice `previewDeposit` on the JT equals the executed deposit exactly in the same block.
    /// @dev Same warped-window-then-sync arrangement as the ST parity test: the final sync commits the warped
    ///      window, so preview and execution price off one committed rate with no pending accrual between them.
    function test_JTDeposit_previewParity() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _applyJTYield(0.04e18);
        _sync();
        _warpForward(1 days);
        _sync();

        uint256 assets = testConfig.initialFunding / 20;
        // The quoter value of the deposited assets, the raw NAV delta the deposit must book
        NAV_UNIT depositNAV = KERNEL.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets));
        uint256 previewShares = JT.previewDeposit(toTrancheUnits(assets));
        OpReceipt memory r = _doDepositJT(JT_BOB_ADDRESS, assets);

        assertEq(r.shares, previewShares, "previewDeposit must equal the executed deposit exactly");
        assertApproxEqAbs(r.post.lastJTRawNAV - r.pre.lastJTRawNAV, depositNAV, maxNAVDelta(), "the quoter-valued deposit must match the booked raw delta");
        assertEq(r.post.jtSupply, r.pre.jtSupply + r.shares, "supply must grow by exactly the minted shares");
        _assertCommittedConservation();
    }

    /// @notice A zero-asset JT deposit reverts with the accountant's exact-arg `INVALID_POST_OP_STATE(JT_DEPOSIT)`.
    /// @dev The post-op sync's `deltaJTRawNAV > 0` requirement fires before the tranche's `INVALID_DEPOSIT_NAV` check can.
    function test_RevertIf_JTDepositZeroAssets() public {
        vm.prank(JT_ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoDayAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        JT.deposit(ZERO_TRANCHE_UNITS, JT_ALICE_ADDRESS);
    }

    /// @notice In a fixed-term market a JT deposit reverts with `DISABLED_IN_FIXED_TERM_STATE` and `maxDeposit` reports zero.
    function test_RevertIf_JTDepositInFixedTerm() public {
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
        assertLe(rST.post.coverageUtilizationWAD, WAD, "arrange: coverage must be satisfied at the brink");
        // Brink floor derivation: stMaxDeposit under-reports the exact coverage boundary only by the two NAV dust
        // tolerances plus quoter conversion floors — wei-to-dust magnitudes against an exposure seeded from
        // `initialFunding` — so the max-size deposit parks utilization within a sliver of 100%. A 99% floor is
        // orders of magnitude above that slack and cleanly separates "at the brink" from a failed arrange.
        assertGt(rST.post.coverageUtilizationWAD, (WAD * 99) / 100, "arrange: coverage utilization must sit at the brink");

        assertEq(JT.maxDeposit(JT_BOB_ADDRESS), MAX_TRANCHE_UNITS, "jtMaxDeposit must report the unbounded sentinel");
        OpReceipt memory rJT = _doDepositJT(JT_BOB_ADDRESS, testConfig.initialFunding / 10);
        assertGt(rJT.shares, 0, "the coverage-improving JT deposit must succeed");
        assertLt(rJT.post.coverageUtilizationWAD, rST.post.coverageUtilizationWAD, "the JT deposit must lower coverage utilization");
        _assertCommittedConservation();
    }

    // ── LT deposits ──

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
        // The independent first-mint pin: shares equal the EXECUTED venue mint valued through the quoter (an
        // input), so a shared preview/execution valuation bug cannot hide. The preview equality below is parity only
        assertEq(
            shares, toUint256(KERNEL.ltConvertTrancheUnitsToNAVUnits(post.ltOwned - pre.ltOwned)), "the first LT mint must be 1:1 with the minted BPT value"
        );
        assertEq(shares, expectedShares, "the previewed depositNAV must equal the executed mint (parity)");
        assertEq(LT.balanceOf(LT_ALICE_ADDRESS), shares, "receiver LT share balance");
        assertEq(post.ltOwned, pre.ltOwned + previewLtAssetsOut, "ltOwned must grow by exactly the previewed venue mint");
        assertEq(post.stOwned, pre.stOwned + toTrancheUnits(stAssets), "stOwned must grow by the senior leg");
        assertEq(post.stSupply, pre.stSupply + expectedSTSharesMinted, "the senior leg must mint at the committed senior rate");
        assertEq(post.ltSupply, pre.ltSupply + shares, "LT supply must grow by exactly the minted shares");
        assertEq(post.ltOwnedSeniorTrancheShares, pre.ltOwnedSeniorTrancheShares, "no idle liquidity premium may be staged by a deposit");
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal, "the minted senior shares must all land in the venue");
        assertEq(quoteBalPre - IERC20(testConfig.quoteAsset).balanceOf(LT_ALICE_ADDRESS), quoteAssets, "the quote leg must be pulled exactly");
        assertEq(post.lastLTRawNAV, KERNEL.ltConvertTrancheUnitsToNAVUnits(post.ltOwned), "committed LT raw NAV must be the fresh venue mark");
        assertLe(post.liquidityUtilizationWAD, pre.liquidityUtilizationWAD, "an LT deposit can only improve liquidity utilization");
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
    function test_RevertIf_LTDepositMultiAssetBothLegsZero() public whenLT {
        _setupLTProviders();
        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayKernel.MUST_DEPOSIT_NON_ZERO_ASSETS.selector);
        IRoycoLiquidityTranche(address(LT)).depositMultiAsset(0, 0, 0, LT_ALICE_ADDRESS);
    }

    /**
     * @notice A multi-asset LT deposit whose `minLTAssetsOut` exceeds the venue mint reverts inside Balancer with
     *         `BptAmountOutBelowMin` and leaves the whole market state untouched (atomicity).
     * @dev No deadline parameter exists anywhere on this surface, only the min-out bound asserted here.
     */
    function test_RevertIf_LTDepositMultiAssetMinLTAssetsOutBreached_atomic() public whenLT {
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
        assertEq(pre.ltOwnedSeniorTrancheShares, 0, "arrange: no staged premium may exist");
        uint256 previewShares = _previewDepositLTMulti(0, quoteAssets);

        OpReceipt memory r = _doDepositLTMulti(LT_BOB_ADDRESS, 0, quoteAssets, 0);
        assertEq(r.shares, previewShares, "the quote-only preview must equal execution");
        NAV_UNIT depositNAV = KERNEL.ltConvertTrancheUnitsToNAVUnits(r.post.ltOwned - r.pre.ltOwned);
        assertEq(r.shares, _expectedShares(depositNAV, ltSupplyPre, pre.lastLTRawNAV), "quote-only shares must price at the pre-deposit LT effective NAV");
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
        assertEq(pre.ltOwnedSeniorTrancheShares, 0, "arrange: no staged premium may exist");
        uint256 expectedShares = _expectedShares(value, ltSupply, pre.lastLTRawNAV);

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
        assertApproxEqAbs(post.lastLTRawNAV - pre.lastLTRawNAV, value, maxNAVDelta(), "the committed LT mark must grow by the deposited value");
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
        assertGt(_snap().liquidityUtilizationWAD, WAD, "arrange: the liquidity requirement must be breached");
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
    function test_RevertIf_LTDepositMultiAssetBreachesCoverage_atomic() public whenLT {
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
        assertLe(pre.liquidityUtilizationWAD, WAD, "arrange: liquidity must not be the binding gate");

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
    function test_RevertIf_LTDepositMultiAssetBreachesLiquidity_atomic() public whenLT {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 2);
        _seedDefaultLT();
        _setMinLiquidityWAD(0.9e18);
        _sync();
        MarketSnapshot memory pre = _snap();
        assertGt(pre.liquidityUtilizationWAD, WAD, "arrange: the liquidity requirement must be breached");

        uint256 stAssets = testConfig.initialFunding / 1000;
        NAV_UNIT stValue = KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(stAssets));
        uint256 quoteAssets = _quoteAssetsForValue(stValue);
        assertLe(
            _expectedCoverageUtilization(pre.lastSTRawNAV + stValue, pre.lastJTRawNAV, ACCOUNTANT.getState().minCoverageWAD, pre.lastJTEffectiveNAV),
            WAD,
            "arrange: coverage must not be the binding gate"
        );
        // Even crediting both legs fully to the pooled depth, the post-op utilization stays breached
        assertGt(
            _expectedLiquidityUtilization(pre.lastSTEffectiveNAV + stValue, 0.9e18, pre.lastLTRawNAV + stValue + stValue),
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
    // REDEMPTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    // ── Section-local helpers ──

    /**
     * @notice Derives a tranche's cumulative asset claims independently from the committed checkpoint plus quoter
     *         conversions, mirroring `TrancheClaimsLogic._deriveTrancheAssetClaims` on the documented decomposition.
     * @dev `stClaimOnJTRaw = sat(stEffectiveNAV - stRawNAV)`, `jtClaimOnSTRaw = sat(jtEffectiveNAV - jtRawNAV)`, self-backed legs are the
     *      raw remainders. The quoter conversions of the claim NAVs are inputs, not the function under test.
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
        uint256 stRawNAV = toUint256(a.lastSTRawNAV);
        uint256 jtRawNAV = toUint256(a.lastJTRawNAV);
        uint256 stEffectiveNAV = toUint256(a.lastSTEffectiveNAV);
        uint256 jtEffectiveNAV = toUint256(a.lastJTEffectiveNAV);
        uint256 stClaimOnJTRawNAV = stEffectiveNAV > stRawNAV ? stEffectiveNAV - stRawNAV : 0;
        uint256 jtClaimOnSTRawNAV = jtEffectiveNAV > jtRawNAV ? jtEffectiveNAV - jtRawNAV : 0;
        if (_trancheType == TrancheType.SENIOR) {
            uint256 stClaimOnSTRawNAV = stRawNAV - jtClaimOnSTRawNAV;
            if (stClaimOnSTRawNAV != 0) claims.stAssets = KERNEL.stConvertNAVUnitsToTrancheUnits(toNAVUnits(stClaimOnSTRawNAV));
            if (stClaimOnJTRawNAV != 0) claims.jtAssets = KERNEL.jtConvertNAVUnitsToTrancheUnits(toNAVUnits(stClaimOnJTRawNAV));
            claims.nav = a.lastSTEffectiveNAV;
        } else {
            uint256 jtClaimOnJTRawNAV = jtRawNAV - stClaimOnJTRawNAV;
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
     * @dev The bonus is `min(floor(nav * bonusWAD / WAD), jtEffectiveNAV, maxUtilizationNeutralBonus)` with the neutral cap
     *      from the library's documented derivation, sourced ST-assets-first. Quoter conversions
     *      of the claim legs are inputs. Callers must have synced in the same block.
     */
    function _expectedClaimsWithSelfLiquidationBonus(AssetClaims memory _userClaims)
        internal
        view
        returns (AssetClaims memory claimsWithBonus, NAV_UNIT bonusNAV)
    {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 coverageUtilizationWAD = _expectedCoverageUtilization(a.lastSTRawNAV, a.lastJTRawNAV, a.minCoverageWAD, a.lastJTEffectiveNAV);
        if (coverageUtilizationWAD < a.coverageLiquidationUtilizationWAD) return (_userClaims, ZERO_NAV_UNITS);

        uint256 jtEffectiveNAV = toUint256(a.lastJTEffectiveNAV);
        uint256 jtRawNAV = toUint256(a.lastJTRawNAV);
        uint256 desiredBonus = Math.mulDiv(toUint256(_userClaims.nav), KERNEL.getState().stSelfLiquidationBonusWAD, WAD);
        uint256 jtClaimOnSTRawNAV = jtEffectiveNAV > jtRawNAV ? jtEffectiveNAV - jtRawNAV : 0;

        // The maximum bonus that does not raise coverage utilization (the bank-run-neutral cap)
        uint256 maxNeutralBonus;
        if (jtEffectiveNAV != 0) {
            uint256 exposure = toUint256(a.lastSTRawNAV) + jtRawNAV;
            uint256 weightedClaimNAV = toUint256(KERNEL.stConvertTrancheUnitsToNAVUnits(_userClaims.stAssets))
                + toUint256(KERNEL.jtConvertTrancheUnitsToNAVUnits(_userClaims.jtAssets));
            if (weightedClaimNAV != 0) {
                maxNeutralBonus = Math.mulDiv(weightedClaimNAV, jtEffectiveNAV, exposure - jtEffectiveNAV);
            }
        }

        uint256 bonus = Math.min(Math.min(desiredBonus, jtEffectiveNAV), maxNeutralBonus);
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
     * @dev Derivation (post coverageUtilizationWAD > WAD, the gate rounds up in favor of breach): redeeming `x` NAV removes
     *      the full `x` from the covered exposure, so the exact boundary solves `(E - x)*minCov > (J - x)*WAD`, giving
     *      `x > (J*WAD - E*minCov) / (WAD - minCov)`. The margin adds the two raw-NAV dust tolerances plus four
     *      `maxNAVDelta()` quoter round-trips (claim NAV -> tranche units -> measured raw delta on each leg) plus two
     *      wei, so the realized removal strictly dominates the boundary. Requires pre coverageUtilizationWAD <= WAD.
     */
    function _jtCoverageBreachRedemptionNAV() internal view returns (uint256 breachNAV) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 jtEffectiveNAV = toUint256(a.lastJTEffectiveNAV);
        uint256 exposure = toUint256(a.lastSTRawNAV) + toUint256(a.lastJTRawNAV);

        uint256 boundary = Math.ceilDiv(jtEffectiveNAV * WAD - exposure * a.minCoverageWAD, WAD - a.minCoverageWAD);
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
            assertEq(
                IERC20(testConfig.stAsset).balanceOf(_receiver) - _stAssetBalPre,
                toUint256(_claims.stAssets),
                "receiver must be paid the ST asset claim exactly"
            );
            assertEq(
                IERC20(testConfig.jtAsset).balanceOf(_receiver) - _jtAssetBalPre,
                toUint256(_claims.jtAssets),
                "receiver must be paid the JT asset claim exactly"
            );
        }
    }

    /**
     * @notice Arranges the LT state shared by the staged-premium redemption tests: seeded ST/JT market, a deliberately
     *         dust-sized LT pool, overlay on with the liquidity utilization near its target, and a staged idle liquidity premium.
     * @dev The pool is sized to roughly 1/10000 of the funding so the accrued premium overruns the venue's unbalanced-add
     *      invariant-ratio cap and the single-sided reinvestment reverts, staying idle. The zero-slippage seam inside
     *      `_stageIdleLiquidityPremium` is a second belt (on this venue the BPT oracle can mark under the mint rate, so the
     *      slippage gate alone does not guarantee staging). The minimum liquidity is sized so utilization sits at about
     *      80 percent, keeping the LDM paying while leaving the redemption tests headroom under the 100 percent gate.
     */
    function _arrangeLTWithStagedIdleLiquidityPremium() internal returns (uint256 idleShares) {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _setupLTProviders();
        uint256 stLegAssets = testConfig.initialFunding / 10_000;
        _seedLTBalanced(LT_ALICE_ADDRESS, stLegAssets);
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.8e18);
        _enableLTOverlay(0.1e18, 0.5e18, minLiquidityWAD);
        idleShares = _stageIdleLiquidityPremium();
        _sync();
    }

    // ── ST redemptions ──

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
        // Counterweight independent of the claim-scaling mirror: the payout can never exceed the exact pro-rata
        // slice of the pre-redemption senior effective NAV, so repeated redemptions cannot round-steal value.
        _assertClaimsWithinProRataCeiling(claims, shares, stSupply, pre.lastSTEffectiveNAV);
        _assertSTAndJTClaimsPaid(ST_ALICE_ADDRESS, stAssetBalPre, jtAssetBalPre, expectedClaims);
        MarketSnapshot memory post = _snap();
        assertEq(post.stSupply, pre.stSupply - shares, "ST supply must fall by exactly the redeemed shares");
        assertEq(post.stOwned, pre.stOwned - expectedClaims.stAssets, "stOwned must fall by the ST asset claim");
        assertEq(post.jtOwned, pre.jtOwned - expectedClaims.jtAssets, "jtOwned must fall by the JT asset claim");
        NAV_UNIT redemptionNAV = (pre.lastSTRawNAV - post.lastSTRawNAV) + (pre.lastJTRawNAV - post.lastJTRawNAV);
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV - redemptionNAV, "the senior effective NAV must fall by exactly the measured redemption NAV");
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV, "the junior effective NAV must be untouched with no liquidation bonus");
        assertApproxEqAbs(redemptionNAV, expectedClaims.nav, maxNAVDelta(), "the measured redemption NAV must round-trip the claim NAV");
        _assertCommittedConservation();
    }

    /// @notice `previewRedeem` on the ST equals the executed redemption exactly on every claims field in the same block.
    /// @dev The warped window is committed by the final sync so preview and execution price off one committed rate.
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
    function test_RevertIf_STRedeemZeroShares() public {
        vm.prank(ST_ALICE_ADDRESS);
        vm.expectRevert(IRoycoVaultTranche.MUST_REQUEST_NON_ZERO_SHARES.selector);
        ST.redeem(0, ST_ALICE_ADDRESS, ST_ALICE_ADDRESS);
    }

    /// @notice In a fixed-term market an ST redemption reverts with `DISABLED_IN_FIXED_TERM_STATE` and `maxRedeem` reports zero.
    function test_RevertIf_STRedeemInFixedTerm() public {
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
        assertGe(pre.coverageUtilizationWAD, a.coverageLiquidationUtilizationWAD, "arrange: the liquidation threshold must be breached");
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
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV - bonusNAV, "the junior effective NAV must fund exactly the bonus");
        NAV_UNIT redemptionNAV = (pre.lastSTRawNAV - post.lastSTRawNAV) + (pre.lastJTRawNAV - post.lastJTRawNAV);
        assertEq(
            post.lastSTEffectiveNAV,
            pre.lastSTEffectiveNAV - (redemptionNAV - bonusNAV),
            "the senior effective NAV must fall by the redemption net of the bonus"
        );
        assertLe(post.coverageUtilizationWAD, pre.coverageUtilizationWAD, "the bonus must never raise coverage utilization");
        // Counterweights independent of the bonus mirror, on measured quantities only: the junior drain (the bonus
        // actually funded) must stay within the configured bonus fraction of the paid claim — the desired bonus is
        // that fraction of the BASE claim, and the paid claim only exceeds the base, so cross-multiplying is a
        // strict ceiling on plain checked integers.
        uint256 measuredBonus = toUint256(pre.lastJTEffectiveNAV) - toUint256(post.lastJTEffectiveNAV);
        assertLe(
            measuredBonus * WAD,
            toUint256(claims.nav) * uint256(KERNEL.getState().stSelfLiquidationBonusWAD),
            "the funded bonus must stay within its configured fraction of the paid claim"
        );
        _assertCommittedConservation();
    }

    /**
     * @notice `stMaxRedeem` is bounded only by the global raw NAVs, so a sole senior LP can redeem its full balance
     *         and the claims stay within the owned-asset ledgers.
     * @dev Derivation: each per-leg share bound is `T * rawNAV / claimOnLegNAV` with `claimOnLegNAV <= rawNAV`, so
     *      both bounds are at least the total supply and the owner's balance is the binding term.
     */
    function test_STRedeem_maxRedeemFullyRedeemable() public {
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
        assertGt(pre.liquidityUtilizationWAD, WAD, "arrange: the liquidity requirement must be breached");

        uint256 shares = ST.balanceOf(ST_ALICE_ADDRESS) / 4;
        AssetClaims memory expectedClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.SENIOR), shares, ST.totalSupply());
        assertGt(toUint256(expectedClaims.nav), 0, "arrange: the redemption must carry value");
        OpReceipt memory r = _doRedeemST(ST_ALICE_ADDRESS, shares);
        _assertClaimsEq(r.claims, expectedClaims, "liquidity-breached senior exit claims");
        assertEq(r.post.stSupply, r.pre.stSupply - shares, "ST supply must fall by exactly the redeemed shares");
        _assertCommittedConservation();
    }

    // ── JT redemptions ──

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
        // Counterweight independent of the claim-scaling mirror: the payout can never exceed the exact pro-rata
        // slice of the pre-redemption junior effective NAV.
        _assertClaimsWithinProRataCeiling(claims, shares, jtSupply, pre.lastJTEffectiveNAV);
        _assertSTAndJTClaimsPaid(JT_ALICE_ADDRESS, stAssetBalPre, jtAssetBalPre, expectedClaims);
        MarketSnapshot memory post = _snap();
        assertEq(post.jtSupply, pre.jtSupply - shares, "JT supply must fall by exactly the redeemed shares");
        assertEq(post.stOwned, pre.stOwned - expectedClaims.stAssets, "stOwned must fall by the ST asset claim");
        assertEq(post.jtOwned, pre.jtOwned - expectedClaims.jtAssets, "jtOwned must fall by the JT asset claim");
        NAV_UNIT redemptionNAV = (pre.lastSTRawNAV - post.lastSTRawNAV) + (pre.lastJTRawNAV - post.lastJTRawNAV);
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV - redemptionNAV, "the junior effective NAV must fall by exactly the measured redemption NAV");
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV, "the senior effective NAV must be untouched");
        assertEq(post.lastJTCoverageImpermanentLoss, pre.lastJTCoverageImpermanentLoss, "no impermanent loss may move on a redemption without IL");
        assertApproxEqAbs(redemptionNAV, expectedClaims.nav, maxNAVDelta(), "the measured redemption NAV must round-trip the claim NAV");
        assertGe(post.coverageUtilizationWAD, pre.coverageUtilizationWAD, "a JT redemption cannot lower coverage utilization");
        _assertCommittedConservation();
    }

    /// @notice A JT redemption whose independently derived removal NAV exceeds the coverage breach boundary reverts
    ///         with `COVERAGE_REQUIREMENT_VIOLATED` and leaves the market untouched.
    function test_RevertIf_JTRedeemBreachesCoverage() public {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 20);
        _sync();

        uint256 jtSupply = JT.totalSupply();
        uint256 shares = JT.balanceOf(JT_ALICE_ADDRESS);
        AssetClaims memory expectedClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.JUNIOR), shares, jtSupply);
        MarketSnapshot memory pre = _snap();
        assertLe(pre.coverageUtilizationWAD, WAD, "arrange: coverage must start satisfied");
        assertGt(toUint256(expectedClaims.nav), _jtCoverageBreachRedemptionNAV(), "arrange: the redemption must clear the breach boundary");
        assertLt(JT.maxRedeem(JT_ALICE_ADDRESS), shares, "arrange: the redemption must exceed the reported maximum");

        vm.prank(JT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        JT.redeem(shares, JT_ALICE_ADDRESS, JT_ALICE_ADDRESS);
        _assertMarketUnchanged(pre);
    }

    /// @notice In a fixed-term market a JT redemption reverts with `DISABLED_IN_FIXED_TERM_STATE`, `maxRedeem`
    ///         reports zero, and the junior max-withdrawable view zeroes.
    function test_RevertIf_JTRedeemInFixedTerm() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        uint256 shares = JT.balanceOf(JT_ALICE_ADDRESS) / 2;
        _enterFixedTerm();

        assertEq(JT.maxRedeem(JT_ALICE_ADDRESS), 0, "jtMaxRedeem must report zero in a fixed term");
        (, NAV_UNIT jtMaxWithdrawableNAV,) = KERNEL.jtMaxWithdrawable(JT_ALICE_ADDRESS);
        assertEq(jtMaxWithdrawableNAV, ZERO_NAV_UNITS, "the junior max-withdrawable NAV must zero in a fixed term");

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
        assertGt(pre.liquidityUtilizationWAD, WAD, "arrange: the liquidity requirement must be breached");

        uint256 shares = JT.maxRedeem(JT_ALICE_ADDRESS) / 2;
        assertGt(shares, 0, "arrange: the junior redemption must be nonzero");
        AssetClaims memory expectedClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.JUNIOR), shares, JT.totalSupply());
        OpReceipt memory r = _doRedeemJT(JT_ALICE_ADDRESS, shares);
        _assertClaimsEq(r.claims, expectedClaims, "liquidity-breached junior exit claims");
        assertLe(r.post.coverageUtilizationWAD, WAD, "the junior exit must leave coverage satisfied");
        assertEq(r.post.jtSupply, r.pre.jtSupply - shares, "JT supply must fall by exactly the redeemed shares");
        _assertCommittedConservation();
    }

    /**
     * @notice `jtMaxRedeem` inverts the coverage gate: the max-size redemption lands under it and a redemption past
     *         the independently derived breach boundary reverts.
     * @dev The breach share count converts `_jtCoverageBreachRedemptionNAV` to shares at the committed junior share
     *      price (ceiling) plus one share for the conversion floor.
     */
    function test_JTRedeem_maxRedeemExactlyRedeemable() public {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 20);
        _sync();

        uint256 maxShares = JT.maxRedeem(JT_ALICE_ADDRESS);
        assertGt(maxShares, 0, "arrange: the coverage surplus must be redeemable");
        assertLt(maxShares, JT.balanceOf(JT_ALICE_ADDRESS), "arrange: coverage must bound the redemption");

        uint256 snapshotId = vm.snapshotState();
        OpReceipt memory r = _doRedeemJT(JT_ALICE_ADDRESS, maxShares);
        assertLe(r.post.coverageUtilizationWAD, WAD, "a max-size JT redemption must leave coverage satisfied");
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
     * @dev Staging note: IL is observable in PERPETUAL only when `0 < IL <= dust`, so the senior dust tolerance is
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
        NAV_UNIT redemptionNAV = (r.pre.lastSTRawNAV - r.post.lastSTRawNAV) + (r.pre.lastJTRawNAV - r.post.lastJTRawNAV);
        NAV_UNIT jtEff1 = r.post.lastJTEffectiveNAV;
        assertEq(jtEff1, jtEff0 - redemptionNAV, "the junior effective NAV must fall by exactly the measured redemption NAV");
        NAV_UNIT expectedIL = toNAVUnits(Math.mulDiv(toUint256(il0), toUint256(jtEff1), toUint256(jtEff0)));
        assertEq(r.post.lastJTCoverageImpermanentLoss, expectedIL, "the impermanent loss must floor-scale by the junior effective NAV ratio");
        _assertCommittedConservation();
    }

    // ── LT redemptions ──

    /**
     * @notice An in-kind LT redemption pays the proportional BPT slice plus the pro-rata slice of the staged idle
     *         premium senior shares directly to the redeemer, with exact per-field floor scaling and an exact-args
     *         `Redeem` event.
     */
    function test_LTRedeem_inKind_paysBPTAndIdleSliceDirectly() public whenLT {
        uint256 idleShares = _arrangeLTWithStagedIdleLiquidityPremium();

        uint256 ltSupply = LT.totalSupply();
        AssetClaims memory totalClaims = _expectedTrancheClaims(TrancheType.LIQUIDITY);
        assertEq(totalClaims.stShares, idleShares, "arrange: the idle ledger must back the claims");
        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 8;
        AssetClaims memory expectedClaims = _scaleExpectedClaims(totalClaims, shares, ltSupply);
        assertGt(toUint256(expectedClaims.ltAssets), 0, "arrange: the redemption must claim a BPT slice");
        assertGt(expectedClaims.stShares, 0, "arrange: the redemption must claim an idle liquidity premium slice");
        MarketSnapshot memory pre = _snap();
        uint256 bptBalPre = IERC20(POOL).balanceOf(LT_ALICE_ADDRESS);
        uint256 stShareBalPre = ST.balanceOf(LT_ALICE_ADDRESS);
        NAV_UNIT ltEffPre = LT.totalAssets().nav; // the production live LT mark, captured as a ceiling input

        vm.startPrank(LT_ALICE_ADDRESS);
        _expectRedeem(address(LT), LT_ALICE_ADDRESS, LT_ALICE_ADDRESS, expectedClaims, shares);
        AssetClaims memory claims = LT.redeem(shares, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
        vm.stopPrank();
        _assertSolvency();

        _assertClaimsEq(claims, expectedClaims, "executed claims");
        // Counterweight independent of the claim-scaling mirror: the payout can never exceed the exact pro-rata
        // slice of the tranche's own pre-redemption effective NAV (padded one quoter round-trip, since the live
        // BPT valuation can drift a floor's worth from the committed mark the claims were derived on).
        _assertClaimsWithinProRataCeiling(claims, shares, ltSupply, ltEffPre + maxNAVDelta());
        MarketSnapshot memory post = _snap();
        assertEq(IERC20(POOL).balanceOf(LT_ALICE_ADDRESS) - bptBalPre, toUint256(expectedClaims.ltAssets), "the BPT slice must be paid in kind");
        assertEq(
            ST.balanceOf(LT_ALICE_ADDRESS) - stShareBalPre, expectedClaims.stShares, "the idle liquidity premium slice must be paid as senior shares directly"
        );
        assertEq(post.ltOwned, pre.ltOwned - expectedClaims.ltAssets, "ltOwned must fall by the BPT slice");
        assertEq(
            post.ltOwnedSeniorTrancheShares,
            pre.ltOwnedSeniorTrancheShares - expectedClaims.stShares,
            "the idle liquidity premium ledger must fall by the paid slice"
        );
        assertEq(post.ltSupply, pre.ltSupply - shares, "LT supply must fall by exactly the redeemed shares");
        assertEq(post.lastLTRawNAV, KERNEL.ltConvertTrancheUnitsToNAVUnits(post.ltOwned), "the committed LT mark must be the fresh venue mark");
        assertLt(post.lastLTRawNAV, pre.lastLTRawNAV, "the committed LT mark must fall");
        assertEq(post.lastSTRawNAV, pre.lastSTRawNAV, "moving idle senior shares must not move the senior raw NAV");
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV, "moving idle senior shares must not move the senior effective NAV");
        assertLe(post.liquidityUtilizationWAD, WAD, "the redemption must leave the liquidity requirement satisfied");
        _assertCommittedConservation();
    }

    /// @notice Both LT redemption previews (in-kind view and multi-asset query-mode) equal execution exactly per
    ///         field in the same block, with staged idle liquidity premium in play.
    function test_LTRedeem_previewParity_inKindAndMultiAsset() public whenLT {
        _arrangeLTWithStagedIdleLiquidityPremium();
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
    function test_RevertIf_LTRedeemBreachesLiquidityGate() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.9e18);
        _setMinLiquidityWAD(minLiquidityWAD);
        _sync();

        MarketSnapshot memory pre = _snap();
        assertLe(pre.liquidityUtilizationWAD, WAD, "arrange: the gate must start open");
        assertGt(pre.liquidityUtilizationWAD, WAD / 2, "arrange: utilization must sit near the gate");
        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 2;
        _assertSliceWouldBreachLiquidity(shares, minLiquidityWAD, pre);

        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        LT.redeem(shares, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
        _assertMarketUnchanged(pre);
    }

    /**
     * @notice A breached liquidation coverage utilization does NOT waive the in-kind liquidity gate: `maxRedeem`
     *         stays bounded below the holder's full balance and an in-kind redemption that would strand the pool
     *         below the senior floor reverts LIQUIDITY_REQUIREMENT_VIOLATED.
     */
    function test_LTRedeem_liquidationBreach_enforcesLiquidityGate() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.9e18);
        _setMinLiquidityWAD(minLiquidityWAD);
        _breachLiquidation();

        MarketSnapshot memory pre = _snap();
        assertGe(pre.coverageUtilizationWAD, ACCOUNTANT.getState().coverageLiquidationUtilizationWAD, "arrange: the liquidation threshold must be breached");
        uint256 shares = (LT.balanceOf(LT_ALICE_ADDRESS) * 3) / 4;
        _assertSliceWouldBreachLiquidity(shares, minLiquidityWAD, pre);
        assertLt(LT.maxRedeem(LT_ALICE_ADDRESS), LT.balanceOf(LT_ALICE_ADDRESS), "the liquidation breach must not waive the in-kind liquidity gate");

        // The in-kind redemption only shrinks the pool depth, so it cannot relax its own floor and reverts
        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        LT.redeem(shares, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
        _assertMarketUnchanged(pre);
    }

    /**
     * @notice `ltMaxRedeem` inverts the liquidity gate: the max-size redemption lands under it and the same
     *         redemption plus the documented slack reverts.
     * @dev Breach slack derivation: `maxLTWithdrawal` under-reports the exact boundary by the senior dust
     *      tolerance plus at most one wei of ceiling drift, and the realized venue-mark drop can undershoot the
     *      scaled claim value by up to two quoter round-trips, so the slack is that dust plus two `maxNAVDelta()`
     *      plus two wei, converted to LT shares at the committed mark (ceiling) plus two shares for share floors.
     */
    function test_LTRedeem_maxRedeemExactlyRedeemable() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.5e18);
        _setMinLiquidityWAD(minLiquidityWAD);
        _sync();

        uint256 maxShares = LT.maxRedeem(LT_ALICE_ADDRESS);
        assertGt(maxShares, 0, "arrange: the liquidity surplus must be redeemable");
        assertLt(maxShares, LT.balanceOf(LT_ALICE_ADDRESS), "arrange: the liquidity requirement must bound the redemption");

        uint256 snapshotId = vm.snapshotState();
        OpReceipt memory r = _doRedeemLT(LT_ALICE_ADDRESS, maxShares);
        assertLe(r.post.liquidityUtilizationWAD, WAD, "a max-size LT redemption must leave the liquidity requirement satisfied");
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
     *      by the parity test. The min-out breach asserts Balancer's exact `AmountOutBelowMin` args. No
     *      deadline parameter exists on this surface.
     */
    function test_LTRedeemMultiAsset_unwindsSeniorLeg_minOutsAndEvent() public whenLT {
        _arrangeLTWithStagedIdleLiquidityPremium();

        uint256 ltSupply = LT.totalSupply();
        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 8;
        AssetClaims memory expectedLTClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.LIQUIDITY), shares, ltSupply);
        assertGt(expectedLTClaims.stShares, 0, "arrange: the redemption must carry an idle liquidity premium slice");
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
        assertEq(
            post.ltOwnedSeniorTrancheShares,
            pre.ltOwnedSeniorTrancheShares - expectedLTClaims.stShares,
            "the idle liquidity premium ledger must fall by the idle slice"
        );
        assertEq(post.ltOwned, pre.ltOwned - expectedLTClaims.ltAssets, "ltOwned must fall by the BPT slice");
        assertEq(post.ltSupply, pre.ltSupply - shares, "LT supply must fall by exactly the redeemed shares");
        uint256 stSharesBurned = pre.stSupply - post.stSupply;
        assertGt(stSharesBurned, expectedLTClaims.stShares, "the venue-withdrawn senior shares must be burned on top of the idle slice");
        NAV_UNIT redemptionNAV = (pre.lastSTRawNAV - post.lastSTRawNAV) + (pre.lastJTRawNAV - post.lastJTRawNAV);
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV - redemptionNAV, "the senior effective NAV must fall by exactly the measured redemption NAV");
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV, "the junior effective NAV must be untouched with no liquidation bonus");
        assertApproxEqAbs(redemptionNAV, previewClaims.nav, maxNAVDelta(), "the measured redemption NAV must round-trip the claim NAV");
        assertLe(post.liquidityUtilizationWAD, WAD, "the redemption must leave the liquidity requirement satisfied");
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
    function test_RevertIf_LTRedeemZeroShares() public whenLT {
        _setupLTProviders();
        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoVaultTranche.MUST_REQUEST_NON_ZERO_SHARES.selector);
        LT.redeem(0, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);

        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoVaultTranche.MUST_REQUEST_NON_ZERO_SHARES.selector);
        IRoycoLiquidityTranche(address(LT)).redeemMultiAsset(0, 0, 0, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);
    }

    /// @notice In a fixed-term market both LT redemption flows revert with `DISABLED_IN_FIXED_TERM_STATE`,
    ///         `maxRedeem` reports zero, the in-kind preview bubbles the exact exec revert (preview == exec),
    ///         and the multi-asset preview returns empty claims (its preview-zeros contract).
    function test_RevertIf_LTRedeemInFixedTerm() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 2;
        _enterFixedTerm();

        assertEq(LT.maxRedeem(LT_ALICE_ADDRESS), 0, "ltMaxRedeem must report zero in a fixed term");
        vm.expectRevert(IRoycoDayKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        LT.previewRedeem(shares);
        AssetClaims memory emptyClaims;
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
     *      supply delta, exactly the venue leg with no idle liquidity premium staged), which is deterministic against the
     *      identical same-block state the breach call then sees.
     */
    function test_RevertIf_LTRedeemMultiAssetMinSTSharesOutBreached_atomic() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _sync();
        uint256 shares = LT.balanceOf(LT_ALICE_ADDRESS) / 4;
        MarketSnapshot memory pre = _snap();
        assertEq(pre.ltOwnedSeniorTrancheShares, 0, "arrange: no staged premium may exist");

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
    // SYNC / TRANCHE ACCOUNTING / PREMIUM LIFECYCLE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    // ── Section-local helpers ──

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
     * @notice Builds and computes the independent sync expectation for the sync about to execute, from
     *         the committed checkpoint, the sync-time YDM previews, and the measured raw NAVs.
     * @dev Must be called in the sync's own block, after every warp and simulate, so the previews and the
     *      elapsed window match what the sync will use. The stored time-weighted accumulators and both window
     *      starts are carried as inputs, so a window with residual unpaid accrual (an earlier non-paying sync,
     *      an admin warp, or a warp-required loss hook) prices exactly like production. Raw NAVs and YDM
     *      previews are sync inputs, not the code under test.
     */
    function _buildSyncExpectation(bool _fixedTermActive) internal returns (SyncExpectation memory e) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        e.twJTStart = uint256(a.twJTYieldShareAccruedWAD);
        e.twLTStart = uint256(a.twLTYieldShareAccruedWAD);
        e.premiumElapsed = block.timestamp - a.lastPremiumPaymentTimestamp;

        e.jtYieldShareWAD = _previewYieldShareAsAccountant(
            a.jtYDM,
            a.lastMarketState,
            _expectedCoverageUtilization(a.lastSTRawNAV, a.lastJTRawNAV, a.minCoverageWAD, a.lastJTEffectiveNAV),
            a.maxJTYieldShareWAD
        );
        e.ltYieldShareWAD = a.maxLTYieldShareWAD == 0
            ? 0
            : _previewYieldShareAsAccountant(
                a.ltYDM, a.lastMarketState, _expectedLiquidityUtilization(a.lastSTEffectiveNAV, a.minLiquidityWAD, a.lastLTRawNAV), a.maxLTYieldShareWAD
            );
        e.elapsed = block.timestamp - a.lastYieldShareAccrualTimestamp;
        (e.stRawNAVNew, e.jtRawNAVNew,) = _measureFreshSyncInputs(ZERO_TRANCHE_UNITS);
        e.lastSTRawNAV = a.lastSTRawNAV;
        e.lastJTRawNAV = a.lastJTRawNAV;
        e.lastSTEffectiveNAV = a.lastSTEffectiveNAV;
        e.lastJTEffectiveNAV = a.lastJTEffectiveNAV;
        e.lastJTCoverageImpermanentLoss = a.lastJTCoverageImpermanentLoss;
        e.stProtocolFeeWAD = a.stProtocolFeeWAD;
        e.jtProtocolFeeWAD = a.jtProtocolFeeWAD;
        e.jtYieldShareProtocolFeeWAD = a.jtYieldShareProtocolFeeWAD;
        e.ltYieldShareProtocolFeeWAD = a.ltYieldShareProtocolFeeWAD;
        e.effectiveDust = a.effectiveNAVDustTolerance;
        e.fixedTermActive = _fixedTermActive;
        e = _expectedSync(e);
    }

    /// @notice Asserts the executed sync's returned packet and committed checkpoint against the independent
    ///         sync expectation, plus wei-exact committed conservation.
    function _assertSyncMatchesExpectation(SyncedAccountingState memory _state, SyncExpectation memory _e) internal view {
        assertEq(_state.stEffectiveNAV, _e.stEffectiveNAV, "returned ST effective NAV vs the independent recomputation");
        assertEq(_state.jtEffectiveNAV, _e.jtEffectiveNAV, "returned JT effective NAV vs the independent recomputation");
        assertEq(_state.ltLiquidityPremium, _e.ltLiquidityPremium, "returned LT liquidity premium vs the independent recomputation");
        assertEq(_state.stProtocolFee, _e.stProtocolFee, "returned ST protocol fee vs the independent recomputation");
        assertEq(_state.jtProtocolFee, _e.jtProtocolFee, "returned JT protocol fee vs the independent recomputation");
        assertEq(_state.ltProtocolFee, _e.ltProtocolFee, "returned LT protocol fee vs the independent recomputation");
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertEq(a.lastSTRawNAV, _e.stRawNAVNew, "committed ST raw NAV must equal the measured input");
        assertEq(a.lastJTRawNAV, _e.jtRawNAVNew, "committed JT raw NAV must equal the measured input");
        assertEq(a.lastSTEffectiveNAV, _e.stEffectiveNAV, "committed ST effective NAV vs the independent recomputation");
        assertEq(a.lastJTEffectiveNAV, _e.jtEffectiveNAV, "committed JT effective NAV vs the independent recomputation");
        _assertCommittedConservation();

        // ── Independent counterweights (plain checked integers, no shared formula with the recomputation) ──
        // A sync only re-labels value between tranches: the liquidity premium and every fee are slices carved out
        // of what the vault marks actually gained since the checkpoint, so none of them can exceed the measured
        // gross raw gain (each fee additionally bounded by its configured rate on that gain).
        uint256 grossGain = (toUint256(_e.stRawNAVNew) > toUint256(_e.lastSTRawNAV) ? toUint256(_e.stRawNAVNew) - toUint256(_e.lastSTRawNAV) : 0)
            + (toUint256(_e.jtRawNAVNew) > toUint256(_e.lastJTRawNAV) ? toUint256(_e.jtRawNAVNew) - toUint256(_e.lastJTRawNAV) : 0);
        assertLe(toUint256(_state.ltLiquidityPremium), grossGain, "the liquidity premium cannot exceed the measured gross raw gain");
        assertLe(toUint256(_state.stProtocolFee) * WAD, grossGain * _e.stProtocolFeeWAD, "the ST fee cannot exceed its rate on the measured gross raw gain");
        assertLe(
            toUint256(_state.jtProtocolFee) * WAD,
            grossGain * (uint256(_e.jtProtocolFeeWAD) + _e.jtYieldShareProtocolFeeWAD),
            "the JT fee cannot exceed its combined rates on the measured gross raw gain"
        );
        assertLe(
            toUint256(_state.ltProtocolFee) * WAD, grossGain * _e.ltYieldShareProtocolFeeWAD, "the LT fee cannot exceed its rate on the measured gross raw gain"
        );
        // Monotonicity: when neither vault mark fell, attribution and the premium split can only move gain between
        // tranches — no tranche's effective NAV may fall on a no-loss sync.
        if (toUint256(_e.stRawNAVNew) >= toUint256(_e.lastSTRawNAV) && toUint256(_e.jtRawNAVNew) >= toUint256(_e.lastJTRawNAV)) {
            assertGe(toUint256(a.lastSTEffectiveNAV), toUint256(_e.lastSTEffectiveNAV), "a no-loss sync must not lower the senior effective NAV");
            assertGe(toUint256(a.lastJTEffectiveNAV), toUint256(_e.lastJTEffectiveNAV), "a no-loss sync must not lower the junior effective NAV");
        }
    }

    /**
     * @notice Arranges the dust-pool staged-premium market for the premium-mint syncs and returns the built
     *         expectation for the sync under test (which the caller executes).
     * @dev The pool is dust-deep so the premium overruns the venue's unbalanced-add invariant-ratio cap and
     *      the inline reinvestment reverts, staying idle, with the zero-slippage seam as the first belt.
     *      Skips the test when the venue exposes no reinvestment slippage seam (capability gate).
     */
    function _arrangeStagedPremiumSyncExpectation() internal returns (SyncExpectation memory e) {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _setupLTProviders();
        uint256 stLegAssets = testConfig.initialFunding / 10_000;
        _seedLTBalanced(LT_ALICE_ADDRESS, stLegAssets);
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.8e18);
        _enableLTOverlay(0.1e18, 0.5e18, minLiquidityWAD);
        vm.skip(!_trySetReinvestmentSlippage(0));
        _flushPremiumAccrual();
        _warpForward(1 days);
        _applySTYield(0.01e18);
        e = _buildSyncExpectation(false);
        assertGt(toUint256(e.ltLiquidityPremium), 0, "arrange: the LDM must price a nonzero liquidity premium");
    }

    /// @notice Stages an idle liquidity premium against the dust-deep pool (where the inline deployment cannot land)
    ///         and returns the staged idle senior share balance.
    function _arrangeStagedIdleLiquidityPremium() internal returns (uint256 idleShares) {
        _arrangeStagedPremiumSyncExpectation();
        _sync();
        idleShares = KERNEL.getState().ltOwnedSeniorTrancheShares;
        assertGt(idleShares, 0, "arrange: the liquidity premium must be staged idle");
    }

    /**
     * @notice Arranges a staged idle liquidity premium the venue CAN absorb once the slippage gate opens: the premium
     *         stages against the dust-deep pool (whose venue bounds reject the inline add), then the pool is
     *         deepened in the same block, so the staged tranche becomes deployable on demand.
     * @dev The deepening deposits sync flat in the same block, so they mint no new premium and cannot touch
     *      the staged idle ledger, which is asserted. Skips when no slippage seam exists (capability gate).
     */
    function _arrangeReinvestableIdleLiquidityPremium() internal returns (uint256 idleShares) {
        idleShares = _arrangeStagedIdleLiquidityPremium();
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

    // ── Sync idempotence and the flat window ──

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

        assertEq(post.lastSTRawNAV, pre.lastSTRawNAV, "the committed ST raw NAV must not move");
        assertEq(post.lastJTRawNAV, pre.lastJTRawNAV, "the committed JT raw NAV must not move");
        assertEq(post.lastLTRawNAV, pre.lastLTRawNAV, "the committed LT raw NAV must not move");
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV, "the committed ST effective NAV must not move");
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV, "the committed JT effective NAV must not move");
        assertEq(post.lastJTCoverageImpermanentLoss, pre.lastJTCoverageImpermanentLoss, "the committed impermanent loss must not move");
        assertEq(post.stSupply, pre.stSupply, "no senior shares may mint");
        assertEq(post.jtSupply, pre.jtSupply, "no junior shares may mint");
        assertEq(post.ltSupply, pre.ltSupply, "no liquidity shares may mint");
        assertEq(post.ltOwnedSeniorTrancheShares, pre.ltOwnedSeniorTrancheShares, "no premium may double-stage");
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
     *      overshoot, pinning the window to the deterministic no-gain scenario. The residual small covered loss
     *      settles exactly per the independent recomputation with every fee and premium output zero.
     */
    function test_Sync_flat_noPnl_noFeesNoPremium() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        _warpForward(1 days);

        // Counter any streaming drift so the window nets to no senior gain (a 0 percent move pins the rate)
        (NAV_UNIT stRawDrifted,,) = _measureFreshSyncInputs(ZERO_TRANCHE_UNITS);
        NAV_UNIT lastSTRawNAV = ACCOUNTANT.getState().lastSTRawNAV;
        uint256 driftCounterPctWAD =
            stRawDrifted > lastSTRawNAV ? Math.mulDiv(toUint256(stRawDrifted - lastSTRawNAV), WAD, toUint256(stRawDrifted), Math.Rounding.Ceil) + 0.0001e18 : 0;
        simulateSTLoss(driftCounterPctWAD);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertLe(e.stRawNAVNew, e.lastSTRawNAV, "arrange: the countered window must carry no senior gain");
        assertGt(e.elapsed, 0, "arrange: the accrual window must be nonzero");
        assertEq(e.ltLiquidityPremium, ZERO_NAV_UNITS, "a no-gain window must pay no liquidity premium");
        assertEq(e.stProtocolFee, ZERO_NAV_UNITS, "a no-gain window must take no ST fee");
        assertEq(e.jtProtocolFee, ZERO_NAV_UNITS, "a no-gain window must take no JT fee");
        assertEq(e.ltProtocolFee, ZERO_NAV_UNITS, "a no-gain window must take no LT fee");
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
        assertEq(post.ltOwnedSeniorTrancheShares, pre.ltOwnedSeniorTrancheShares, "no premium may stage on a no-gain sync");
        assertEq(uint256(post.twJT), uint256(pre.twJT) + e.jtYieldShareWAD * e.elapsed, "the JT accrual must book exactly the window");
        assertEq(uint256(post.twLT), uint256(pre.twLT) + e.ltYieldShareWAD * e.elapsed, "the LT accrual must book exactly the window");
        assertEq(uint256(post.lastAccrualTs), block.timestamp, "the accrual timestamp must re-stamp");
        assertEq(uint256(post.lastPremiumTs), uint256(pre.lastPremiumTs), "no premium payment may stamp without a paid premium");
    }

    // ── PnL sync scenarios: senior gain, covered loss, junior gain/loss, residual loss ──

    /**
     * @notice A senior-gain sync settles the full tranche accounting sync exactly: attribution, JT risk premium, both
     *         protocol fees, exact-args accrual and fee-mint events, and the post-payment accumulator reset.
     * @dev On coupled-PnL kernels the hook moves both raw NAVs, so the expectation runs on the measured
     *      deltas. The name describes the hook intent, not a guaranteed delta shape.
     */
    function test_Sync_stGain_exactTrancheAccounting() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        _warpForward(1 days);
        _applySTYield(0.05e18);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(e.stRawNAVNew, e.lastSTRawNAV, "arrange: the senior raw NAV must have appreciated");
        assertTrue(e.premiumsPaid, "arrange: the gain must clear the dust gate");
        assertGt(toUint256(e.stProtocolFee), 0, "arrange: an ST protocol fee must accrue");
        assertGt(toUint256(e.jtProtocolFee), 0, "arrange: a JT yield-share protocol fee must accrue");

        uint256 stSupplyPre = ST.totalSupply();
        uint256 jtSupplyPre = JT.totalSupply();
        (uint256 premShares, uint256 stFeeShares) =
            _expectedPremiumShares(e.ltLiquidityPremium, e.stProtocolFee, e.ltProtocolFee, e.stEffectiveNAV, stSupplyPre);
        uint256 jtFeeShares = _expectedShares(e.jtProtocolFee, jtSupplyPre, e.jtEffectiveNAV - e.jtProtocolFee);
        MarketSnapshot memory pre = _snap();

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.YieldSharesAccrued(
            e.jtYieldShareWAD, e.twJTStart + e.jtYieldShareWAD * e.elapsed, e.ltYieldShareWAD, e.twLTStart + e.ltYieldShareWAD * e.elapsed
        );
        vm.expectEmit(true, false, false, true, address(ST));
        emit IRoycoVaultTranche.ProtocolFeeSharesMinted(PROTOCOL_FEE_RECIPIENT_ADDRESS, stFeeShares, stSupplyPre + premShares + stFeeShares);
        vm.expectEmit(true, false, false, true, address(JT));
        emit IRoycoVaultTranche.ProtocolFeeSharesMinted(PROTOCOL_FEE_RECIPIENT_ADDRESS, jtFeeShares, jtSupplyPre + jtFeeShares);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertEq(post.lastJTCoverageImpermanentLoss, e.jtCoverageImpermanentLoss, "committed impermanent loss must match the independent recomputation");
        assertEq(post.stSupply, pre.stSupply + premShares + stFeeShares, "ST supply must grow by exactly the premium and fee mints");
        assertEq(post.jtSupply, pre.jtSupply + jtFeeShares, "JT supply must grow by exactly the fee mint");
        assertEq(post.feeRecipientSTShares - pre.feeRecipientSTShares, stFeeShares, "ST fee shares minted to the recipient");
        assertEq(post.feeRecipientJTShares - pre.feeRecipientJTShares, jtFeeShares, "JT fee shares minted to the recipient");
        assertEq(uint256(post.lastPremiumTs), block.timestamp, "the premium payment must stamp");
        assertEq(uint256(post.twJT), 0, "the JT accrual accumulator must reset after payment");
        assertEq(uint256(post.twLT), 0, "the LT accrual accumulator must reset after payment");
        // Counterweight independent of the share-pricing mirror: the premium/fee mints pay for value already booked
        // into the senior effective NAV, so the pre-existing holders' NAV-per-share cannot fall across the sync.
        _assertSeniorMintsNonDilutive(stSupplyPre, e.ltLiquidityPremium + e.stProtocolFee);
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
        assertLt(e.stRawNAVNew, e.lastSTRawNAV, "arrange: the senior raw NAV must have depreciated");
        assertGt(toUint256(e.jtCoverageImpermanentLoss), 0, "arrange: coverage must be applied");
        assertGt(toUint256(e.jtEffectiveNAV), 0, "arrange: the loss must not exhaust the junior tranche");
        assertEq(e.stEffectiveNAV, e.lastSTEffectiveNAV, "the covered loss must leave the senior effective NAV whole");

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(e.jtCoverageImpermanentLoss);
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
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.8e18);
        _enableLTOverlay(0.1e18, 0.5e18, minLiquidityWAD);
        _setFixedTermDuration(7 days);
        _flushPremiumAccrual();
        uint256 premiumTsPre = ACCOUNTANT.getState().lastPremiumPaymentTimestamp;
        _warpForward(1 days);
        _applySTLoss(0.02e18);

        SyncExpectation memory e = _buildSyncExpectation(true);
        assertGt(e.jtCoverageImpermanentLoss, e.effectiveDust, "arrange: the coverage applied must exceed the dust tolerance");
        assertGt(toUint256(e.jtEffectiveNAV), 0, "arrange: the loss must not exhaust the junior tranche");
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
        assertEq(a.lastJTCoverageImpermanentLoss, e.jtCoverageImpermanentLoss, "the impermanent loss must be retained exactly");
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
        assertEq(e.jtCoverageImpermanentLoss, ZERO_NAV_UNITS, "arrange: the gain must fully recover the impermanent loss");
        assertTrue(e.premiumsPaid, "arrange: a residual gain must remain after the recovery");
        assertGt(toUint256(e.stProtocolFee), 0, "arrange: the exited market must take fees again");

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

        // The elapsed window may carry streaming drift, so the settlement runs on the measured deltas
        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(toUint256(e.jtCoverageImpermanentLoss), 0, "arrange: an unrecovered impermanent loss must remain to erase");
        assertLe(e.jtCoverageImpermanentLoss, ilBefore, "arrange: recovery can only shrink the retained impermanent loss");

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.FixedTermEnded();
        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(e.jtCoverageImpermanentLoss);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertTrue(state.marketState == MarketState.PERPETUAL, "the market must be forced perpetual");
        assertEq(post.lastJTCoverageImpermanentLoss, ZERO_NAV_UNITS, "the unrecovered impermanent loss must be erased");
        assertEq(state.jtCoverageImpermanentLoss, ZERO_NAV_UNITS, "the returned packet must carry the erased impermanent loss");
        assertEq(uint256(post.fixedTermEnd), 0, "the fixed-term end must clear");
        assertEq(uint256(post.lastPremiumTs), e.premiumsPaid ? block.timestamp : premiumTsPre, "the premium stamp must track the payment");
        assertEq(uint256(post.twJT), e.premiumsPaid ? 0 : e.twJTStart + e.jtYieldShareWAD * e.elapsed, "the accumulator must reset only on payment");
    }

    /**
     * @notice A junior-gain sync settles the full tranche accounting sync exactly against the measured deltas.
     * @dev On coupled-PnL kernels the hook moves both raw NAVs together, so this completes the reachable
     *      set of reachable delta scenarios alongside the flat, senior-gain, and loss syncs.
     */
    function test_Sync_jtGain_exactTrancheAccounting() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        uint256 premiumTsPre = ACCOUNTANT.getState().lastPremiumPaymentTimestamp;
        _warpForward(1 days);
        _applyJTYield(0.05e18);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(e.jtRawNAVNew, e.lastJTRawNAV, "arrange: the junior raw NAV must have appreciated");

        uint256 stSupplyPre = ST.totalSupply();
        uint256 jtSupplyPre = JT.totalSupply();
        (uint256 premShares, uint256 stFeeShares) =
            _expectedPremiumShares(e.ltLiquidityPremium, e.stProtocolFee, e.ltProtocolFee, e.stEffectiveNAV, stSupplyPre);
        uint256 jtFeeShares = _expectedShares(e.jtProtocolFee, jtSupplyPre, e.jtEffectiveNAV - e.jtProtocolFee);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertEq(post.lastJTCoverageImpermanentLoss, e.jtCoverageImpermanentLoss, "committed impermanent loss must match the independent recomputation");
        assertEq(post.stSupply, stSupplyPre + premShares + stFeeShares, "ST supply must grow by exactly the premium and fee mints");
        assertEq(post.jtSupply, jtSupplyPre + jtFeeShares, "JT supply must grow by exactly the fee mint");
        assertEq(uint256(post.lastPremiumTs), e.premiumsPaid ? block.timestamp : premiumTsPre, "the premium stamp must track the payment");
        assertEq(uint256(post.twJT), e.premiumsPaid ? 0 : e.twJTStart + e.jtYieldShareWAD * e.elapsed, "the accumulator must reset only on payment");
        // Counterweight independent of the share-pricing mirror: any premium/fee mint this sync produced pays for
        // value already booked into the senior effective NAV, so pre-existing holders cannot be diluted.
        _assertSeniorMintsNonDilutive(stSupplyPre, e.ltLiquidityPremium + e.stProtocolFee);
        _assertCommittedConservation();
    }

    /**
     * @notice A junior-loss sync settles the coverage path of the sync exactly against the measured deltas, with
     *         the forced-perpetual erase on the zero-duration baseline.
     * @dev The coverage expectation branches on the MEASURED senior delta: on a coupled-PnL kernel (shared
     *      feed) the junior loss drags the senior raw NAV down too, so coverage
     *      applies and the erase event fires, while on a decoupled kernel the junior tranche simply absorbs
     *      its own loss with no coverage touched. Both settle to the same independent recomputation.
     */
    function test_Sync_jtLoss_exactTrancheAccounting() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _sync();
        // Establish the zero-duration (permanently perpetual) regime rather than requiring it of the deployed config
        if (uint256(ACCOUNTANT.getState().fixedTermDurationSeconds) != 0) _setFixedTermDuration(0);

        _applyJTLoss(0.02e18);
        SyncExpectation memory e = _buildSyncExpectation(false);
        assertLt(e.jtRawNAVNew, e.lastJTRawNAV, "arrange: the junior raw NAV must have depreciated");
        assertLt(e.jtEffectiveNAV, e.lastJTEffectiveNAV, "the junior effective NAV must absorb the loss");

        if (toUint256(e.jtCoverageImpermanentLoss) > 0) {
            // Coupled hooks: the senior raw NAV depreciated alongside, so coverage applied and is erased
            assertLt(e.stRawNAVNew, e.lastSTRawNAV, "a nonzero coverage application requires a measured senior depreciation");
            vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
            emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(e.jtCoverageImpermanentLoss);
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
     * @notice A loss exceeding the junior loss-absorption buffer settles the residual-loss path of the sync exactly: coverage
     *         exhausts the junior effective NAV to exactly zero, the residual falls on the senior effective NAV,
     *         coverage utilization saturates, and the exhausted market is forced perpetual with the IL erased.
     */
    function test_Sync_stLoss_residualExceedsCoverage_exactTrancheAccounting() public {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 16);
        _sync();

        // Size the loss from the measured committed ratio so it strictly exceeds the junior buffer
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        uint256 lossPctWAD = Math.mulDiv(toUint256(a0.lastJTEffectiveNAV), WAD, toUint256(a0.lastSTRawNAV), Math.Rounding.Ceil) + 0.02e18;
        assertLt(lossPctWAD, WAD, "arrange: the exhausting loss must be representable");
        _applySTLoss(lossPctWAD);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertLt(e.stRawNAVNew, e.lastSTRawNAV, "arrange: the senior raw NAV must have depreciated");
        assertEq(e.jtEffectiveNAV, ZERO_NAV_UNITS, "the coverage application must exhaust the junior effective NAV to exactly zero");
        assertLt(e.stEffectiveNAV, e.lastSTEffectiveNAV, "the residual loss must fall on the senior effective NAV");
        assertGt(toUint256(e.jtCoverageImpermanentLoss), 0, "arrange: the applied coverage must book an impermanent loss");

        // The exhausted (jtEffectiveNAV == 0, stEffectiveNAV > 0) market is forced perpetual, erasing the just-booked IL
        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.JuniorTrancheCoverageImpermanentLossReset(e.jtCoverageImpermanentLoss);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        assertEq(state.coverageUtilizationWAD, type(uint256).max, "coverage utilization must saturate with an exhausted junior tranche");
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertTrue(a.lastMarketState == MarketState.PERPETUAL, "the exhausted market must be forced perpetual");
        assertEq(a.lastJTCoverageImpermanentLoss, ZERO_NAV_UNITS, "the forced perpetual transition must erase the impermanent loss");
        assertEq(state.stProtocolFee, ZERO_NAV_UNITS, "a loss sync must take no ST fee");
        assertEq(state.jtProtocolFee, ZERO_NAV_UNITS, "a loss sync must take no JT fee");
    }

    // ── Premium accrual windows ──

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
        uint256 jtFeeShares = _expectedShares(e.jtProtocolFee, jtSupplyPre, e.jtEffectiveNAV - e.jtProtocolFee);
        uint256 feeRecipientJTPre = JT.balanceOf(PROTOCOL_FEE_RECIPIENT_ADDRESS);

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.YieldSharesAccrued(
            e.jtYieldShareWAD, e.twJTStart + e.jtYieldShareWAD * e.elapsed, e.ltYieldShareWAD, e.twLTStart + e.ltYieldShareWAD * e.elapsed
        );
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
        uint256 driftCounterPctWAD =
            stRawDrifted > lastSTRawNAV ? Math.mulDiv(toUint256(stRawDrifted - lastSTRawNAV), WAD, toUint256(stRawDrifted), Math.Rounding.Ceil) + 0.0001e18 : 0;
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

    // ── The LT liquidity premium mint ──

    /// @notice The LT liquidity premium mints exactly the expected senior shares into the kernel's idle
    ///         ledger, with exact-args accrual and premium-mint events and the joint-pricing supply growth.
    function test_Sync_ltLiquidityPremium_mintsIdleSTShares() public whenLT {
        SyncExpectation memory e = _arrangeStagedPremiumSyncExpectation();
        assertLe(e.jtYieldShareWAD + e.ltYieldShareWAD, WAD, "the yield share caps must preclude PREMIUMS_EXCEED_SENIOR_YIELD");
        uint256 stSupplyPre = ST.totalSupply();
        (uint256 premShares, uint256 stFeeShares) =
            _expectedPremiumShares(e.ltLiquidityPremium, e.stProtocolFee, e.ltProtocolFee, e.stEffectiveNAV, stSupplyPre);
        assertGt(premShares, 0, "arrange: the premium must mint shares");
        MarketSnapshot memory pre = _snap();

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.YieldSharesAccrued(
            e.jtYieldShareWAD, e.twJTStart + e.jtYieldShareWAD * e.elapsed, e.ltYieldShareWAD, e.twLTStart + e.ltYieldShareWAD * e.elapsed
        );
        vm.expectEmit(true, false, false, true, address(ST));
        emit IRoycoSeniorTranche.LiquidityPremiumSharesMinted(address(KERNEL), premShares, stSupplyPre + premShares);
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertEq(post.ltOwnedSeniorTrancheShares, pre.ltOwnedSeniorTrancheShares + premShares, "the premium must stage as idle senior shares");
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal + premShares, "the kernel must custody the minted premium shares");
        assertEq(post.stSupply, pre.stSupply + premShares + stFeeShares, "senior supply must grow by exactly the premium and fee share mints");
        // Counterweight independent of the share-pricing mirror: the staged premium shares are floor-priced against
        // the retained senior NAV, so plain senior holders' NAV-per-share cannot fall when the premium mints.
        _assertSeniorMintsNonDilutive(stSupplyPre, e.ltLiquidityPremium + e.stProtocolFee);
        _assertSolvency();
    }

    /**
     * @notice The premium mint is coverage-neutral: it moves no raw NAV, grows senior supply by exactly the
     *         premium and fee share mints, keeps the premium inside the senior effective NAV, and leaves the production
     *         coverage utilization equal to the independent recompute.
     */
    function test_Sync_premiumMint_coverageNeutral() public whenLT {
        SyncExpectation memory e = _arrangeStagedPremiumSyncExpectation();
        uint256 stSupplyPre = ST.totalSupply();
        (uint256 premShares, uint256 stFeeShares) =
            _expectedPremiumShares(e.ltLiquidityPremium, e.stProtocolFee, e.ltProtocolFee, e.stEffectiveNAV, stSupplyPre);
        assertGt(premShares, 0, "arrange: the premium must mint shares");

        SyncedAccountingState memory state = _syncWithState();

        MarketSnapshot memory post = _snap();
        assertEq(post.lastSTRawNAV, e.stRawNAVNew, "the mint must move no senior raw NAV");
        assertEq(post.lastJTRawNAV, e.jtRawNAVNew, "the mint must move no junior raw NAV");
        assertEq(post.stSupply, stSupplyPre + premShares + stFeeShares, "senior supply must grow by exactly the premium and fee shares");
        assertEq(post.lastSTEffectiveNAV, e.stEffectiveNAV, "the senior effective NAV must include the minted premium");
        assertEq(
            state.coverageUtilizationWAD,
            _expectedCoverageUtilization(e.stRawNAVNew, e.jtRawNAVNew, ACCOUNTANT.getState().minCoverageWAD, e.jtEffectiveNAV),
            "the production coverage utilization must match the independent recompute"
        );
        // Counterweight independent of the share-pricing mirror: the coverage-neutral mint reassigns senior
        // appreciation without diluting the pre-existing holders' NAV-per-share.
        _assertSeniorMintsNonDilutive(stSupplyPre, e.ltLiquidityPremium + e.stProtocolFee);
        _assertCommittedConservation();
    }

    /// @notice The committed LT raw NAV marks the BPT only while the LT effective NAV adds the claimable idle
    ///         premium leg, and the liquidity utilization reads the BPT-only mark.
    function test_Sync_ltRawNAVExcludesIdle_effectiveIncludesIt() public whenLT {
        uint256 idleShares = _arrangeLTWithStagedIdleLiquidityPremium();

        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        assertEq(
            a.lastLTRawNAV,
            KERNEL.ltConvertTrancheUnitsToNAVUnits(KERNEL.getState().ltOwnedYieldBearingAssets),
            "the committed LT raw NAV must be the BPT mark only"
        );
        NAV_UNIT idleValue = _expectedValue(idleShares, ST.totalSupply(), a.lastSTEffectiveNAV);
        assertGt(toUint256(idleValue), 0, "arrange: the staged premium must carry value");
        assertApproxEqAbs(LT.totalAssets().nav, a.lastLTRawNAV + idleValue, maxNAVDelta(), "the LT effective NAV must include the claimable idle leg");

        // The split valuation surfaces on the real stack: the external convert* exchange rate is BPT-only (raw NAV,
        // no idle senior-share leg), while totalAssets (above) and previewRedeem keep the claimable idle leg — so
        // the convert quote sits strictly below the redemption quote for the same shares while premium is staged.
        // previewRedeem simulates the real redemption, so the probe is sized to clear the post-op liquidity gate
        // (a tenth of the supply leaves utilization near 0.8 / 0.9 against the ~80 percent arranged target)
        uint256 probeShares = LT.totalSupply() / 10;
        AssetClaims memory convClaims = LT.convertToAssets(probeShares);
        assertEq(convClaims.stShares, 0, "convertToAssets must report no senior-share claim (the idle leg is excluded)");
        assertApproxEqAbs(
            convClaims.nav,
            _expectedValue(probeShares, LT.totalSupply(), a.lastLTRawNAV),
            maxNAVDelta(),
            "convertToAssets must price the pro-rata slice of the BPT-only raw NAV"
        );
        assertGt(
            toUint256(LT.previewRedeem(probeShares).nav),
            toUint256(convClaims.nav),
            "the redemption quote must sit strictly above the BPT-only convert quote while premium is staged"
        );

        SyncedAccountingState memory state = _syncWithState();
        uint256 rawBasedUtilWAD = _expectedLiquidityUtilization(a.lastSTEffectiveNAV, a.minLiquidityWAD, a.lastLTRawNAV);
        assertEq(state.liquidityUtilizationWAD, rawBasedUtilWAD, "the production liquidity utilization must match the BPT-only recompute exactly");
        assertGt(
            rawBasedUtilWAD,
            _expectedLiquidityUtilization(a.lastSTEffectiveNAV, a.minLiquidityWAD, a.lastLTRawNAV + idleValue),
            "the BPT-only utilization must read strictly under-provisioned versus the effective NAV while premium is staged"
        );
    }

    // ── The premium reinvestment (inline and on demand) ──

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
        _enableLTOverlay(0.1e18, 0.5e18, _minLiquidityForTargetUtilization(0.8e18));
        _flushPremiumAccrual();
        _warpForward(1 days);
        _applySTYield(0.02e18);

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertGt(toUint256(e.ltLiquidityPremium), 0, "arrange: the LDM must price a nonzero liquidity premium");
        uint256 stSupplyPre = ST.totalSupply();
        (uint256 premShares, uint256 stFeeShares) =
            _expectedPremiumShares(e.ltLiquidityPremium, e.stProtocolFee, e.ltProtocolFee, e.stEffectiveNAV, stSupplyPre);
        assertGt(premShares, 0, "arrange: the premium must mint shares");
        NAV_UNIT premiumValue = _expectedValue(premShares, stSupplyPre + premShares + stFeeShares, e.stEffectiveNAV);
        uint256 minLtAssetsOut = Math.mulDiv(toUint256(KERNEL.ltConvertNAVUnitsToTrancheUnits(premiumValue)), WAD - slippageWAD, WAD, Math.Rounding.Ceil);
        assertGt(minLtAssetsOut, 0, "arrange: the gate minimum must be nonzero");
        MarketSnapshot memory pre = _snap();
        assertEq(pre.ltOwnedSeniorTrancheShares, 0, "arrange: nothing may be staged before the sync");

        vm.recordLogs();
        SyncedAccountingState memory state = _syncWithState();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertSyncMatchesExpectation(state, e);
        MarketSnapshot memory post = _snap();
        assertEq(post.ltOwnedSeniorTrancheShares, 0, "the premium must deploy inline, staging nothing");
        assertEq(post.kernelSTShareBal, pre.kernelSTShareBal, "the kernel must hold no residual senior shares");
        assertEq(post.stSupply, pre.stSupply + premShares + stFeeShares, "senior supply must grow by exactly the premium and fee share mints");

        (uint256 reinvestedCount, bytes memory reinvestedData) = _lastLogData(logs, address(KERNEL), IRoycoDayKernel.LiquidityPremiumReinvested.selector);
        assertEq(reinvestedCount, 1, "exactly one inline reinvestment must be reported");
        (uint256 stSharesReinvested, uint256 ltAssetsMinted) = abi.decode(reinvestedData, (uint256, uint256));
        assertEq(stSharesReinvested, premShares, "the entire minted premium must deploy");
        uint256 ownedDeltaAssets = toUint256(post.ltOwned - pre.ltOwned);
        assertEq(ltAssetsMinted, ownedDeltaAssets, "the reported venue mint must match the owned-ledger delta");
        assertEq(post.kernelBPTBal - pre.kernelBPTBal, ownedDeltaAssets, "the kernel's BPT balance must grow by exactly the venue mint");
        assertGe(ownedDeltaAssets, minLtAssetsOut, "the inline mint must clear the slippage gate's derived minimum");
        assertEq(post.lastLTRawNAV, KERNEL.ltConvertTrancheUnitsToNAVUnits(post.ltOwned), "the freshly deployed depth must be re-committed");
        assertGt(post.lastLTRawNAV, pre.lastLTRawNAV, "the committed depth must grow");
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
        uint256 idleShares = _arrangeReinvestableIdleLiquidityPremium();
        uint64 slippageWAD = 0.5e18;
        assertTrue(_trySetReinvestmentSlippage(slippageWAD), "arrange: the slippage gate must open");

        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        NAV_UNIT idleValue = _expectedValue(idleShares, ST.totalSupply(), a.lastSTEffectiveNAV);
        uint256 minLtAssetsOut = Math.mulDiv(toUint256(KERNEL.ltConvertNAVUnitsToTrancheUnits(idleValue)), WAD - slippageWAD, WAD, Math.Rounding.Ceil);
        assertGt(minLtAssetsOut, 0, "arrange: the gate minimum must be nonzero");
        MarketSnapshot memory pre = _snap();

        vm.recordLogs();
        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN_ADDRESS);
        KERNEL.reinvestLiquidityPremium(type(uint256).max);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        MarketSnapshot memory post = _snap();
        assertEq(post.ltOwnedSeniorTrancheShares, 0, "the entire idle balance must deploy");
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
        assertEq(toNAVUnits(abi.decode(commitData, (uint256))), post.lastLTRawNAV, "the final commit must carry the committed mark");
        assertGt(post.lastLTRawNAV, pre.lastLTRawNAV, "the committed depth must grow");
        assertLt(post.liquidityUtilizationWAD, pre.liquidityUtilizationWAD, "the deployment must lower liquidity utilization");
        _assertSolvency();
        _assertCommittedConservation();
    }

    /// @notice A partial reinvestment debits exactly the requested shares from the idle ledger, leaves the
    ///         remainder staged, and its venue mint clears the slippage gate's derived minimum.
    function test_ReinvestLiquidityPremium_partialAmount() public whenLT {
        uint256 idleShares = _arrangeReinvestableIdleLiquidityPremium();
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

        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN_ADDRESS);
        KERNEL.reinvestLiquidityPremium(partialShares);

        MarketSnapshot memory post = _snap();
        assertEq(post.ltOwnedSeniorTrancheShares, idleShares - partialShares, "exactly the requested shares must leave the idle ledger");
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
        uint256 idleShares = _arrangeStagedIdleLiquidityPremium();
        MarketSnapshot memory pre = _snap();

        vm.recordLogs();
        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN_ADDRESS);
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
     *         accounted for as paid out, reinvested, or still idle (a ghost-ledger identity).
     */
    function test_LTPremium_lifecycle_endToEnd() public whenLT {
        uint256 idleStaged = _arrangeReinvestableIdleLiquidityPremium();

        // Step 1: a redeemer takes 25 percent in kind and is paid its idle liquidity premium slice directly
        uint256 ltSupply = LT.totalSupply();
        uint256 shares = LT.balanceOf(LT_BOB_ADDRESS) / 4;
        uint256 expectedIdleSlice = Math.mulDiv(idleStaged, shares, ltSupply);
        assertGt(expectedIdleSlice, 0, "arrange: the redemption must claim an idle liquidity premium slice");
        uint256 redeemerSTSharesPre = ST.balanceOf(LT_BOB_ADDRESS);
        OpReceipt memory r = _doRedeemLT(LT_BOB_ADDRESS, shares);
        assertEq(ST.balanceOf(LT_BOB_ADDRESS) - redeemerSTSharesPre, expectedIdleSlice, "the idle liquidity premium slice must be paid directly");
        assertEq(r.post.ltOwnedSeniorTrancheShares, idleStaged - expectedIdleSlice, "the idle ledger must fall by the paid slice");
        assertGt(toUint256(r.claims.ltAssets), 0, "the redemption must pay a BPT slice");
        assertLe(r.post.liquidityUtilizationWAD, WAD, "the redemption must leave the liquidity requirement satisfied");
        _assertCommittedConservation();

        // Step 2: the gate opens and the remaining staged premium deploys into real depth
        assertTrue(_trySetReinvestmentSlippage(0.5e18), "arrange: the slippage gate must open");
        MarketSnapshot memory preReinvest = _snap();
        uint256 reinvestedShares = preReinvest.ltOwnedSeniorTrancheShares;
        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN_ADDRESS);
        KERNEL.reinvestLiquidityPremium(type(uint256).max);
        MarketSnapshot memory post = _snap();
        assertEq(post.ltOwnedSeniorTrancheShares, 0, "the remaining staged premium must deploy");
        assertGt(post.ltOwned, preReinvest.ltOwned, "the deployment must credit the owned ledger");
        assertGt(post.lastLTRawNAV, preReinvest.lastLTRawNAV, "the committed depth must grow");
        assertLt(post.liquidityUtilizationWAD, preReinvest.liquidityUtilizationWAD, "the deployment must lower liquidity utilization");

        // Ghost ledger: every minted premium share is paid out, reinvested, or still idle
        assertEq(idleStaged, expectedIdleSlice + reinvestedShares + post.ltOwnedSeniorTrancheShares, "ghost: minted premium shares must be fully accounted for");
        _assertSolvency();
        _assertCommittedConservation();
    }

    // ── The yield share caps ──

    /// @notice When the YDM curves price above the configured maximums, the accrued yield shares bind at the
    ///         caps exactly, pinned by the exact-args accrual events and the capped premium settlement.
    function test_Sync_maxYieldSharesCapBinds() public whenLT {
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 16);
        _setupLTProviders();
        uint256 stLegAssets = testConfig.initialFunding / 100;
        _seedLTBalanced(LT_ALICE_ADDRESS, stLegAssets);
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.8e18);
        uint64 capJTWAD = 1e12;
        uint64 capLTWAD = 1e12;
        _enableLTOverlay(capJTWAD, capLTWAD, minLiquidityWAD);
        _flushPremiumAccrual();
        _warpForward(1 days);
        _applySTYield(0.02e18);

        // Arrange guard: both raw curve outputs must exceed the configured caps at the committed utilizations
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 coverageUtilizationWAD = _expectedCoverageUtilization(a.lastSTRawNAV, a.lastJTRawNAV, a.minCoverageWAD, a.lastJTEffectiveNAV);
        uint256 liquidityUtilizationWAD = _expectedLiquidityUtilization(a.lastSTEffectiveNAV, a.minLiquidityWAD, a.lastLTRawNAV);
        vm.prank(address(ACCOUNTANT));
        uint256 rawJTYieldShareWAD = IYDM(a.jtYDM).previewYieldShare(a.lastMarketState, coverageUtilizationWAD);
        vm.prank(address(ACCOUNTANT));
        uint256 rawLTYieldShareWAD = IYDM(a.ltYDM).previewYieldShare(a.lastMarketState, liquidityUtilizationWAD);
        assertGt(rawJTYieldShareWAD, capJTWAD, "arrange: the JT curve must price above its cap");
        assertGt(rawLTYieldShareWAD, capLTWAD, "arrange: the LT curve must price above its cap");

        SyncExpectation memory e = _buildSyncExpectation(false);
        assertEq(e.jtYieldShareWAD, capJTWAD, "the accrued JT yield share must bind at the cap");
        assertEq(e.ltYieldShareWAD, capLTWAD, "the accrued LT yield share must bind at the cap");

        vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
        emit IRoycoDayAccountant.YieldSharesAccrued(
            capJTWAD, e.twJTStart + uint256(capJTWAD) * e.elapsed, capLTWAD, e.twLTStart + uint256(capLTWAD) * e.elapsed
        );
        SyncedAccountingState memory state = _syncWithState();

        _assertSyncMatchesExpectation(state, e);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADVERSARIAL + AUTH + SEQUENCE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    // ── Section-local helpers ──

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
     * @dev Mirrors `RoycoDayAccountant.maxSTDeposit` for a market whose minimum liquidity is
     *      zero, which callers must guarantee. Callers must have synced in the same block so the committed checkpoint
     *      equals the preview state the production view prices against. The final quoter conversion is an input.
     */
    function _expectedMaxSTDepositAssets() internal view returns (TRANCHE_UNIT assets) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 totalCoveredValue = Math.mulDiv(toUint256(a.lastJTEffectiveNAV), WAD, a.minCoverageWAD);
        uint256 requiredValue = toUint256(a.lastJTRawNAV) + toUint256(a.jtNAVDustTolerance) + toUint256(a.lastSTRawNAV) + toUint256(a.stNAVDustTolerance);
        return KERNEL.stConvertNAVUnitsToTrancheUnits(toNAVUnits(totalCoveredValue > requiredValue ? totalCoveredValue - requiredValue : 0));
    }

    /**
     * @notice Independent recompute of the withdrawable pooled depth from the committed checkpoint.
     * @dev Mirrors `RoycoDayAccountant.maxLTWithdrawal` below the liquidation threshold with a
     *      nonzero minimum liquidity, which callers must guarantee. Callers must have synced in the same block.
     */
    function _expectedMaxLTWithdrawalNAV() internal view returns (NAV_UNIT) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        uint256 requiredValue = Math.mulDiv((toUint256(a.lastSTEffectiveNAV) + toUint256(a.stNAVDustTolerance)), a.minLiquidityWAD, WAD, Math.Rounding.Ceil);
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
        uint256 stEffectiveNAV;
        uint256 stSupply;
        uint256 jtEffectiveNAV;
        uint256 jtSupply;
        uint256 ltEffectiveNAV;
        uint256 ltSupply;
    }

    /// @notice Captures the committed effective NAVs and live supplies that define each tranche's share price.
    /// @dev The LT effective NAV is the committed BPT mark plus the claimable idle liquidity premium leg at the committed senior rate.
    function _seqSnapPrices() internal view returns (SeqPrices memory p) {
        IRoycoDayAccountant.RoycoDayAccountantState memory a = ACCOUNTANT.getState();
        p.stEffectiveNAV = toUint256(a.lastSTEffectiveNAV);
        p.stSupply = ST.totalSupply();
        p.jtEffectiveNAV = toUint256(a.lastJTEffectiveNAV);
        p.jtSupply = JT.totalSupply();
        if (testConfig.hasLiquidityTranche) {
            p.ltSupply = LT.totalSupply();
            p.ltEffectiveNAV =
                toUint256(a.lastLTRawNAV) + toUint256(_expectedValue(KERNEL.getState().ltOwnedSeniorTrancheShares, p.stSupply, a.lastSTEffectiveNAV));
        }
    }

    /**
     * @notice The flagship sequence's per-step check: committed conservation, kernel solvency, and share-price
     *         monotonicity against the previous step, compared as cross-multiplied integers.
     * @dev Non-decreasing comparisons tolerate one `maxNAVDelta()` of effective-NAV drift (a redemption's measured
     *      raw delta can exceed its floor-scaled claim NAV by quoter convexity). The expected
     *      junior price drop on the covered-loss step is asserted strictly. Zero-supply sides are skipped, since no
     *      price exists to compare.
     */
    function _seqCheckStep(SeqPrices memory _prev, bool _expectJTPriceDrop, bool _checkLTPrice) internal view returns (SeqPrices memory cur) {
        cur = _seqSnapPrices();
        _assertCommittedConservation();
        _assertSolvency();
        uint256 tolerance = toUint256(maxNAVDelta());
        if (_prev.stSupply != 0 && cur.stSupply != 0) {
            assertGe(
                (cur.stEffectiveNAV + tolerance) * _prev.stSupply, _prev.stEffectiveNAV * cur.stSupply, "sequence: the senior share price must not decrease"
            );
        }
        if (_prev.jtSupply != 0 && cur.jtSupply != 0) {
            if (_expectJTPriceDrop) {
                assertLt(
                    cur.jtEffectiveNAV * _prev.jtSupply, _prev.jtEffectiveNAV * cur.jtSupply, "sequence: the junior share price must drop on the covered loss"
                );
            } else {
                assertGe(
                    (cur.jtEffectiveNAV + tolerance) * _prev.jtSupply, _prev.jtEffectiveNAV * cur.jtSupply, "sequence: the junior share price must not decrease"
                );
            }
        }
        if (_checkLTPrice && _prev.ltSupply != 0 && cur.ltSupply != 0) {
            assertGe(
                (cur.ltEffectiveNAV + tolerance) * _prev.ltSupply, _prev.ltEffectiveNAV * cur.ltSupply, "sequence: the liquidity share price must not decrease"
            );
        }
    }

    // ── Donations are inert ──

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
        assertEq(post.lastSTRawNAV, pre.lastSTRawNAV, "the committed senior raw NAV must ignore the donation");
        assertEq(post.lastJTRawNAV, pre.lastJTRawNAV, "the committed junior raw NAV must ignore the donation");
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV, "the committed senior effective NAV must ignore the donation");
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV, "the committed junior effective NAV must ignore the donation");
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
        assertEq(post.lastSTRawNAV, pre.lastSTRawNAV, "the committed senior raw NAV must ignore the donations");
        assertEq(post.lastJTRawNAV, pre.lastJTRawNAV, "the committed junior raw NAV must ignore the donations");
        assertEq(post.lastSTEffectiveNAV, pre.lastSTEffectiveNAV, "the committed senior effective NAV must ignore the donations");
        assertEq(post.lastJTEffectiveNAV, pre.lastJTEffectiveNAV, "the committed junior effective NAV must ignore the donations");

        assertEq(_doDepositST(ST_BOB_ADDRESS, assets).shares, expectedSTShares, "senior share pricing must be unchanged by the donations");
        assertEq(_doDepositJT(JT_BOB_ADDRESS, assets).shares, expectedJTShares, "junior share pricing must be unchanged by the donations");
        _assertCommittedConservation();
    }

    /**
     * @notice BPT and senior-share transfers to the kernel are inert: the committed LT mark and the idle liquidity premium
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
        assertEq(pre.ltOwnedSeniorTrancheShares, 0, "arrange: no staged premium may exist");
        uint256 expectedShares = _expectedShares(value, LT.totalSupply(), pre.lastLTRawNAV);

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
        assertEq(post.lastLTRawNAV, pre.lastLTRawNAV, "the committed LT mark must ignore the donated BPT");
        assertEq(post.ltOwnedSeniorTrancheShares, pre.ltOwnedSeniorTrancheShares, "the idle liquidity premium ledger must ignore the donated senior shares");
        assertEq(post.ltOwned, pre.ltOwned, "the owned BPT ledger must ignore the donation");
        assertEq(post.lastSTRawNAV, pre.lastSTRawNAV, "the committed senior raw NAV must ignore the share donation");
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

    // ── Economic attacks ──

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
            rVictim.post.lastSTRawNAV - rAttacker.post.lastSTRawNAV, victimValue, maxNAVDelta(), "the committed raw NAV must grow only by the victim's deposit"
        );
        NAV_UNIT victimHoldingValue = _expectedValue(rVictim.shares, rVictim.post.stSupply, rVictim.post.lastSTEffectiveNAV);
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
        uint256 valueIn = toUint256(rIn.post.lastSTRawNAV - rIn.pre.lastSTRawNAV);
        uint256 supplyAfterDeposit = rIn.post.stSupply;
        uint256 stEffAfterDeposit = toUint256(rIn.post.lastSTEffectiveNAV);

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

    // ── Pinned edge cases ──

    /**
     * @notice PINS the zero-BPT-slice edge: an LT redemption whose BPT slice floors to zero while its idle premium
     *         slice is nonzero commits as a NAV-neutral redemption, handing the redeemer exactly its pro-rata idle
     *         senior-share slice while the floored BPT leg pays nothing.
     * @dev The idle premium is a claimable leg of the LT's effective NAV. Handing the senior shares over moves no raw
     *      NAV (they stay in the senior supply), so the LT_REDEEM shape check (a redemption never grows the LT's
     *      deployed raw NAV) commits it. The arranged market is liquidity-healthy (utilization ~0.8), so the liquidity
     *      requirement passes and the premium is delivered rather than stranded.
     */
    function test_LTRedeem_zeroBPTSlice_nonzeroIdle_pinned() public whenLT {
        uint256 idleShares = _arrangeStagedIdleLiquidityPremium();

        uint256 ltSupply = LT.totalSupply();
        uint256 ltOwnedAssets = toUint256(KERNEL.getState().ltOwnedYieldBearingAssets);
        // The largest share count whose proportional BPT slice floors to zero
        uint256 shares = (ltSupply - 1) / ltOwnedAssets;
        assertGt(shares, 0, "arrange: the BPT-per-share ratio must make a zero-BPT slice representable");
        assertLe(shares, LT.balanceOf(LT_ALICE_ADDRESS), "arrange: the redeemer must afford the dust redemption");
        assertEq(Math.mulDiv(ltOwnedAssets, shares, ltSupply), 0, "arrange: the BPT slice must floor to zero");
        uint256 expectedIdleSlice = Math.mulDiv(idleShares, shares, ltSupply);
        assertGt(expectedIdleSlice, 0, "arrange: the idle liquidity premium slice must be nonzero");

        uint256 aliceSTPre = ST.balanceOf(LT_ALICE_ADDRESS);
        OpReceipt memory r = _doRedeemLT(LT_ALICE_ADDRESS, shares);

        // Exactly the pro-rata idle senior shares are handed over in kind, the floored BPT leg pays nothing, and the
        // kernel's idle pile drops by exactly that slice
        assertEq(r.claims.stShares, expectedIdleSlice, "the in-kind redeem must pay exactly the pro-rata idle senior share slice");
        assertEq(toUint256(r.claims.ltAssets), 0, "the floored BPT leg must pay nothing in kind");
        assertEq(ST.balanceOf(LT_ALICE_ADDRESS) - aliceSTPre, expectedIdleSlice, "the redeemer must receive exactly its idle senior share slice");
        assertEq(r.post.ltOwnedSeniorTrancheShares, idleShares - expectedIdleSlice, "the kernel's idle pile must drop by exactly the redeemed slice");
        _assertCommittedConservation();
    }

    /**
     * @notice PINS the zero-NAV live-supply edge (with the mint-dilution clamp): a JT deposit against a
     *         live supply with zero junior effective NAV prices against the documented one-wei denominator and
     *         BINDS the clamp, so the depositor takes over the tranche up to the 1e-12 residual — the mint is
     *         exactly cap = floor(supply x (WAD - eps) / eps) instead of the pre-clamp unbounded supply x value —
     *         and the pre-existing unbacked holder is diluted to its floor-scaled dust claim.
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
        assertEq(_snap().coverageUtilizationWAD, type(uint256).max, "coverage utilization must saturate with an exhausted junior tranche");
        uint256 aliceShares = JT.balanceOf(JT_ALICE_ADDRESS);

        // The zero-NAV denominator branch prices the deposit (ValuationLogic substitutes one NAV wei) and the
        // clamp binds: the deposit's NAV value dwarfs the 1-wei denominator's bind threshold (~1e12 wei)
        uint256 assets = testConfig.initialFunding / 1000;
        NAV_UNIT value = KERNEL.jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(assets));
        uint256 expectedShares = _expectedShares(value, jtSupplyPre, ZERO_NAV_UNITS);
        assertGt(toUint256(value) * (WAD - MAX_MINT_DILUTION), MAX_MINT_DILUTION, "arrange: the dilution deposit must bind the clamp");
        assertEq(expectedShares, Math.mulDiv(jtSupplyPre, MAX_MINT_DILUTION, WAD - MAX_MINT_DILUTION), "the zero-NAV branch must clamp to the dilution cap");

        OpReceipt memory r = _doDepositJT(JT_BOB_ADDRESS, assets);
        assertEq(r.shares, expectedShares, "deposit shares must match the zero-NAV denominator formula exactly");
        _assertCommittedConservation();
        _assertSolvency();

        // The unbacked holder is diluted to its floor-scaled dust claim, valued through convertToAssets:
        // previewRedeem simulates the real redemption and bubbles the still-breached coverage gate like exec
        NAV_UNIT expectedAliceValue = _expectedValue(aliceShares, r.post.jtSupply, r.post.lastJTEffectiveNAV);
        assertEq(JT.convertToAssets(aliceShares).nav, expectedAliceValue, "the unbacked holder's claim must be the floor-scaled dust slice");
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        JT.previewRedeem(aliceShares);
        assertLt(toUint256(expectedAliceValue) * 100, toUint256(value), "the unbacked holder must be diluted to under a percent of the new value");
    }

    // ── Liquidation-breach behavior ──

    /// @notice The self-liquidation bonus is bank-run-neutral: a bonus-paying senior redemption in a breached market
    ///         never raises coverage utilization.
    function test_SelfLiquidationBonus_neverRaisesCoverageUtilization() public {
        _ensureSelfLiquidationBonusConfigured();
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _breachLiquidation();

        MarketSnapshot memory pre = _snap();
        assertGe(pre.coverageUtilizationWAD, ACCOUNTANT.getState().coverageLiquidationUtilizationWAD, "arrange: the liquidation threshold must be breached");
        uint256 shares = ST.balanceOf(ST_ALICE_ADDRESS) / 3;
        AssetClaims memory baseClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.SENIOR), shares, ST.totalSupply());
        (, NAV_UNIT bonusNAV) = _expectedClaimsWithSelfLiquidationBonus(baseClaims);
        assertGt(toUint256(bonusNAV), 0, "arrange: the redemption must pay a bonus");

        OpReceipt memory r = _doRedeemST(ST_ALICE_ADDRESS, shares);
        assertEq(r.post.lastJTEffectiveNAV, r.pre.lastJTEffectiveNAV - bonusNAV, "the junior effective NAV must fund exactly the bonus");
        assertLe(r.post.coverageUtilizationWAD, r.pre.coverageUtilizationWAD, "the bonus must never raise coverage utilization");
        _assertCommittedConservation();
    }

    /**
     * @notice PINS the post-liquidation-breach per-tranche withdrawal rules: senior redemptions pay the bonus, LT
     *         redemptions stay liquidity-gated with only a bounded surplus reported withdrawable and an
     *         over-floor in-kind redemption reverting, and junior redemptions stay coverage-gated with zero
     *         reported capacity.
     */
    function test_LiquidationBreach_perTrancheWithdrawalRules() public whenLT {
        _ensureSelfLiquidationBonusConfigured();
        _seedMarket(testConfig.initialFunding / 2, testConfig.initialFunding / 10);
        _seedDefaultLT();
        _sync();
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.9e18);
        _setMinLiquidityWAD(minLiquidityWAD);
        _breachLiquidation();

        MarketSnapshot memory pre = _snap();
        assertGe(pre.coverageUtilizationWAD, ACCOUNTANT.getState().coverageLiquidationUtilizationWAD, "arrange: the liquidation threshold must be breached");
        assertGt(toUint256(pre.lastJTEffectiveNAV), 0, "arrange: the junior tranche must not be exhausted");

        // (c) Junior redemptions stay coverage-gated: zero reported capacity and a hard revert
        assertEq(JT.maxRedeem(JT_ALICE_ADDRESS), 0, "jtMaxRedeem must report zero once liquidation is breached");
        uint256 jtShares = JT.balanceOf(JT_ALICE_ADDRESS) / 10;
        vm.prank(JT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.COVERAGE_REQUIREMENT_VIOLATED.selector);
        JT.redeem(jtShares, JT_ALICE_ADDRESS, JT_ALICE_ADDRESS);

        // (d) The liquidity gate is enforced under liquidation: only a bounded surplus below the full pooled depth is reported
        (, NAV_UNIT ltMaxWithdrawableNAV,) = KERNEL.ltMaxWithdrawable(LT_ALICE_ADDRESS);
        assertLt(ltMaxWithdrawableNAV, pre.lastLTRawNAV, "the liquidation breach must not waive the pooled-depth liquidity floor");
        assertLt(LT.maxRedeem(LT_ALICE_ADDRESS), LT.balanceOf(LT_ALICE_ADDRESS), "ltMaxRedeem must stay bounded below the full balance");

        // (b) An in-kind LT redemption that overruns the liquidity floor reverts even during the breach
        uint256 ltShares = (LT.balanceOf(LT_ALICE_ADDRESS) * 3) / 4;
        _assertSliceWouldBreachLiquidity(ltShares, minLiquidityWAD, pre);
        vm.prank(LT_ALICE_ADDRESS);
        vm.expectRevert(IRoycoDayAccountant.LIQUIDITY_REQUIREMENT_VIOLATED.selector);
        LT.redeem(ltShares, LT_ALICE_ADDRESS, LT_ALICE_ADDRESS);

        // (a) A senior redemption succeeds and pays the exact bonus out of the junior effective NAV
        _sync();
        uint256 stShares = ST.balanceOf(ST_ALICE_ADDRESS) / 2;
        AssetClaims memory baseClaims = _scaleExpectedClaims(_expectedTrancheClaims(TrancheType.SENIOR), stShares, ST.totalSupply());
        (, NAV_UNIT bonusNAV) = _expectedClaimsWithSelfLiquidationBonus(baseClaims);
        assertGt(toUint256(bonusNAV), 0, "arrange: the senior redemption must pay a bonus");
        OpReceipt memory rST = _doRedeemST(ST_ALICE_ADDRESS, stShares);
        assertEq(rST.post.lastJTEffectiveNAV, rST.pre.lastJTEffectiveNAV - bonusNAV, "the junior effective NAV must fund exactly the bonus");
        assertLe(rST.post.coverageUtilizationWAD, rST.pre.coverageUtilizationWAD, "the bonus must never raise coverage utilization");
        _assertCommittedConservation();
    }

    // ── Oracle staleness, pause, and blacklist bricks ──

    /**
     * @notice PINS the staleness brick: past the oracle staleness threshold every state-mutating quoting flow
     *         (deposit and sync) reverts with the venue's staleness selector, while the view preview surface keeps
     *         answering at the transaction's transient cached rate, and a fresh oracle update resumes the market.
     * @dev The raw `vm.warp` without an oracle refresh is the brick under test, deliberately bypassing the sanctioned
     *      `_warpForward`. The 30-day jump dominates any realistic staleness threshold configuration. The view pin is
     *      a same-transaction artifact of the transient quoter cache: mutating entrypoints re-initialize the
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
    function test_RevertIf_Paused_allMutatingEntrypoints() public {
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
        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN_ADDRESS);
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
            // A roled LT depositor is still screened at the share mint: it cannot mint to a blacklisted receiver
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

    // ── Access control and caller gates ──

    /// @notice A role-less outsider is rejected with the exact-arg `AccessManagedUnauthorized` on every restricted
    ///         entrypoint, across the deposit and redeem surfaces of all three tranches.
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
            LT.deposit(toTrancheUnits(assets), outsider);
            vm.expectRevert(unauthorizedError);
            IRoycoLiquidityTranche(address(LT)).depositMultiAsset(0, assets, 0, outsider);
            vm.expectRevert(unauthorizedError);
            LT.redeem(1, outsider, outsider);
            vm.expectRevert(unauthorizedError);
            IRoycoLiquidityTranche(address(LT)).redeemMultiAsset(1, 0, 0, outsider, outsider);
        }
        vm.stopPrank();
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

    // ── Scripted sequences ──

    /**
     * @notice The flagship day-in-the-life sequence: deposits across all three tranches, premium staging against a
     *         dust pool, pool deepening, a covered loss, the premium reinvestment, multi-asset exit, and premium-window
     *         syncs, with conservation, solvency, and share-price monotonicity asserted after every step.
     * @dev Two arrangement notes: the LT is seeded before the overlay is enabled (each
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
        uint64 minLiquidityWAD = _minLiquidityForTargetUtilization(0.3e18);
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
        vm.prank(MARKET_REINVEST_LIQUIDITY_PREMIUM_ADMIN_ADDRESS);
        KERNEL.reinvestLiquidityPremium(type(uint256).max);
        assertEq(KERNEL.getState().ltOwnedSeniorTrancheShares, 0, "the staged premium must fully deploy");
        assertGt(ACCOUNTANT.getState().lastLTRawNAV, ltRawBeforeReinvest, "the committed depth must grow on deployment");
        p = _seqCheckStep(p, false, false);

        // (13) LT_ALICE exits half via the multi-asset unwind
        OpReceipt memory rMulti = _doRedeemLTMulti(LT_ALICE_ADDRESS, LT.balanceOf(LT_ALICE_ADDRESS) / 2, 0, 0);
        assertGt(rMulti.quoteAssets, 0, "the multi-asset exit must pay quote assets");
        assertLe(rMulti.post.liquidityUtilizationWAD, WAD, "the exit must leave the liquidity requirement satisfied");
        p = _seqCheckStep(p, false, true);

        // (14) A longer premium window settles with the gate open
        _warpForward(3 days);
        _applySTYield(0.03e18);
        _sync();
        p = _seqCheckStep(p, false, true);

        // (15) JT_ALICE partially exits under the coverage gate
        _doRedeemJT(JT_ALICE_ADDRESS, JT.balanceOf(JT_ALICE_ADDRESS) / 4);
        p = _seqCheckStep(p, false, true);
        assertLe(_snap().coverageUtilizationWAD, WAD, "the sequence must end with coverage satisfied");
    }

    /**
     * @notice The zero-minimum-liquidity reduction acceptance test in fork form: a market with the LT overlay off behaves as
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
        assertLe(r.post.coverageUtilizationWAD, WAD, "the max-size deposit must leave coverage satisfied");
        _assertZeroLiquidityReduction(_syncWithState());
    }

    /**
     * @notice Raising the coverage and liquidity requirements re-prices the deposit and withdrawal gates exactly per
     *         the independent max-deposit and max-withdrawal recomputations, with exact-args setter events and the setter's inline pre-sync
     *         observable on the checkpoint timestamps.
     */
    function test_Sequence_gateConsistency_afterParamChanges() public {
        _seedMarket(testConfig.initialFunding / 10, testConfig.initialFunding / 10);
        _sync();
        IRoycoDayAccountant.RoycoDayAccountantState memory a0 = ACCOUNTANT.getState();
        assertEq(uint256(a0.minLiquidityWAD), 0, "arrange: coverage must be the only senior deposit bound");
        TRANCHE_UNIT maxDepositBefore = ST.maxDeposit(ST_BOB_ADDRESS);
        assertEq(maxDepositBefore, _expectedMaxSTDepositAssets(), "stMaxDeposit must match the independent recompute");
        assertLt(maxDepositBefore, MAX_TRANCHE_UNITS, "arrange: coverage must bound the deposit");
        // Counterweight independent of the max-deposit mirror: the reported maximum, valued through the quoter,
        // must itself fit under the coverage gate's defining inequality — depositing it leaves the covered
        // exposure times the minimum coverage within the junior effective NAV (plain cross-multiplied integers).
        assertLe(
            (toUint256(a0.lastSTRawNAV) + toUint256(KERNEL.stConvertTrancheUnitsToNAVUnits(maxDepositBefore)) + toUint256(a0.lastJTRawNAV))
                * uint256(a0.minCoverageWAD),
            toUint256(a0.lastJTEffectiveNAV) * WAD,
            "the reported max deposit must satisfy the coverage gate's defining inequality"
        );

        // Raising the coverage requirement shrinks the senior deposit capacity per the independent recompute
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
        assertEq(maxDepositAfter, _expectedMaxSTDepositAssets(), "stMaxDeposit must match the independent recompute after the raise");
        assertLt(maxDepositAfter, maxDepositBefore, "raising the coverage requirement must shrink the senior deposit capacity");

        // Raising the liquidity requirement shrinks the withdrawable pooled depth per the independent recompute
        if (testConfig.hasLiquidityTranche) {
            _seedDefaultLT();
            _sync();
            uint64 minLiquidityA = _minLiquidityForTargetUtilization(0.4e18);
            bytes memory liquidityData = abi.encodeCall(ACCOUNTANT.setMinLiquidity, (minLiquidityA));
            _scheduleAccountantOperation(liquidityData);
            vm.expectEmit(false, false, false, true, address(ACCOUNTANT));
            emit IRoycoDayAccountant.LiquidityUpdated(minLiquidityA);
            _executeScheduledAccountantOperation(liquidityData);
            assertEq(
                uint256(ACCOUNTANT.getState().lastYieldShareAccrualTimestamp), block.timestamp, "the liquidity setter's inline sync must stamp the checkpoint"
            );
            _sync();
            (, NAV_UNIT maxWithdrawableA,) = KERNEL.ltMaxWithdrawable(LT_ALICE_ADDRESS);
            assertEq(maxWithdrawableA, _expectedMaxLTWithdrawalNAV(), "ltMaxWithdrawable must match the independent recompute");
            assertGt(toUint256(maxWithdrawableA), 0, "arrange: the liquidity surplus must be nonzero");
            // Counterweights independent of the max-withdrawal mirror: the withdrawable depth can never exceed the
            // pooled depth itself, and removing it must leave enough depth to satisfy the liquidity requirement
            // (remaining ltRawNAV * WAD >= stEffectiveNAV * minLiquidity, plain cross-multiplied integers).
            IRoycoDayAccountant.RoycoDayAccountantState memory aL = ACCOUNTANT.getState();
            assertLe(toUint256(maxWithdrawableA), toUint256(aL.lastLTRawNAV), "the withdrawable depth cannot exceed the pooled depth");
            assertGe(
                (toUint256(aL.lastLTRawNAV) - toUint256(maxWithdrawableA)) * WAD,
                toUint256(aL.lastSTEffectiveNAV) * uint256(aL.minLiquidityWAD),
                "the reported max withdrawal must leave the liquidity requirement satisfied"
            );

            _setMinLiquidityWAD(minLiquidityA * 2);
            _sync();
            (, NAV_UNIT maxWithdrawableB,) = KERNEL.ltMaxWithdrawable(LT_ALICE_ADDRESS);
            assertEq(maxWithdrawableB, _expectedMaxLTWithdrawalNAV(), "ltMaxWithdrawable must match the independent recompute after the raise");
            assertLt(maxWithdrawableB, maxWithdrawableA, "raising the liquidity requirement must shrink the withdrawable depth");
        }
        _assertCommittedConservation();
    }
}
